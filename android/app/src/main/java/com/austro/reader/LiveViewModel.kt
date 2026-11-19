package com.austro.reader

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.mutableStateMapOf
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.austro.reader.can.Ae3Crypto
import com.austro.reader.can.Ae3Decoder
import com.austro.reader.can.DiagException
import com.austro.reader.can.DiagSecurity
import com.austro.reader.can.EcuDatalogReader
import com.austro.reader.can.IsoTp
import com.austro.reader.can.Keys
import com.austro.reader.can.Kwp
import com.austro.reader.can.PcanDeviceInfo
import com.austro.reader.can.PcanUsbSource
import com.austro.reader.can.TimedFrame
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.austro.reader.core.Broadcast
import com.austro.reader.core.BroadcastDecoder
import com.austro.reader.core.BroadcastGroup
import com.austro.reader.core.ECUSide
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class LiveViewModel(app: Application) : AndroidViewModel(app) {

    val source = PcanUsbSource(app)

    var connected by mutableStateOf(false); private set
    var status by mutableStateOf("Disconnected"); private set
    var error by mutableStateOf<String?>(null); private set
    var info by mutableStateOf<PcanDeviceInfo?>(null); private set
    var frameCount by mutableIntStateOf(0); private set
    var node by mutableIntStateOf(0); private set
    var now by mutableLongStateOf(System.currentTimeMillis()); private set

    /** Latest broadcast per (ECU, group), with host arrival time. */
    val latest: SnapshotStateMap<Pair<ECUSide, BroadcastGroup>, Entry> = mutableStateMapOf()

    data class Entry(val broadcast: Broadcast, val millis: Long)

    val staleAfterMs = 2_000L

    private var decoder = BroadcastDecoder(0)
    private var rxJob: Job? = null
    private var tickJob: Job? = null

    fun selectNode(newNode: Int) {
        if (newNode == node) return
        node = newNode
        decoder = BroadcastDecoder(newNode)
        latest.clear()
    }

    // ---- Diagnostics (fault codes + flash read). Shares the one USB connection; a diag op
    //      disconnects Live first because the adapter can't be held by both at once. ----
    var diagBusy by mutableStateOf(false); private set
    var diagStatus by mutableStateOf(""); private set
    var faults by mutableStateOf<List<Kwp.Dtc>>(emptyList()); private set
    var faultsEcu by mutableStateOf("A")
    var flashEcu by mutableStateOf("A")
    var flashHours by mutableIntStateOf(2)
    var flashProgress by mutableFloatStateOf(0f); private set
    var flashSummary by mutableStateOf<List<String>>(emptyList()); private set
    var savedPath by mutableStateOf<String?>(null); private set

    /** One pending action awaiting the USB-permission dialog result. */
    private var pending: (() -> Unit)? = null

    private fun ensurePermissionThen(action: () -> Unit) {
        error = null
        val device = source.findDevice()
        if (device == null) { status = "No PCAN-USB found. Connect it via USB-C OTG."; return }
        if (!source.hasPermission(device)) {
            pending = action; status = "Requesting USB permission…"; source.requestPermission(device); return
        }
        action()
    }

    /** Called by the activity's receiver when the USB-permission dialog is answered. */
    fun onPermissionResult(granted: Boolean) {
        val p = pending; pending = null
        if (granted) p?.invoke() else { status = "USB permission denied"; diagStatus = status }
    }

    /** Attempt to connect (Live): find the device, request permission if needed, then open. */
    fun connect() { ensurePermissionThen { open() } }

    fun readFaults(ecu: String) { faultsEcu = ecu; ensurePermissionThen { runFaults(ecu) } }

    fun readFlash(ecu: String, hours: Int?) { flashEcu = ecu; ensurePermissionThen { runFlash(ecu, hours) } }

    private fun runFaults(ecuArg: String) {
        if (diagBusy) return
        if (connected) disconnect()
        diagBusy = true; faults = emptyList(); diagStatus = "Connecting…"
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val device = source.findDevice() ?: throw Exception("No PCAN-USB found")
                source.open(device, listenOnly = false)
                val txId = if (ecuArg == "A") 0x7E0 else 0x7E1
                val rxId = if (ecuArg == "A") 0x7E8 else 0x7E9
                val kwp = Kwp(IsoTp(source.asLink(), txId, rxId))
                diagStatus = "Reading fault codes (ECU $ecuArg)…"
                kwp.startCommunication(); kwp.startDiagnosticSession(0x84)
                val dtcs = try { kwp.readDTCs() } catch (e: DiagException) {
                    if (e.nrc == 0x33) {
                        val mask = DiagSecurity.resolveMask()
                            ?: throw DiagException("fault read needs the security key mask. Add it on the Keys tab.")
                        kwp.securityAccess(mask); kwp.readDTCs()
                    } else throw e
                }
                kwp.stopSession()
                faults = dtcs
                diagStatus = if (dtcs.isEmpty()) "No fault codes stored on ECU $ecuArg."
                             else "ECU $ecuArg — ${dtcs.size} fault code(s)"
            } catch (e: Exception) {
                diagStatus = "Fault read failed: ${(e as? DiagException)?.message ?: e.message ?: e.toString()}"
            } finally {
                runCatching { source.close() }; diagBusy = false
            }
        }
    }

    private fun runFlash(ecu: String, hours: Int?) {
        if (diagBusy) return
        if (connected) disconnect()
        diagBusy = true; savedPath = null; flashSummary = emptyList(); flashProgress = 0f; diagStatus = "Connecting…"
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val device = source.findDevice() ?: throw Exception("No PCAN-USB found")
                source.open(device, listenOnly = false)
                val result = EcuDatalogReader().read(source, ecu, hours,
                    progress = { p -> flashProgress = p.fraction.toFloat(); diagStatus = p.message })
                flashSummary = result.rows.groupBy { "${it.ecu}#${it.session}" }
                    .toSortedMap().map { (k, v) -> "session $k: ${v.size} rows" }
                val pass = Keys.passphrase()
                if (pass.isNotBlank() && result.rawSectors.isNotEmpty()) {
                    val df = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
                    val sn = result.engineSerial?.let { s ->
                        "_SN" + s.filter { it.isLetterOrDigit() || it == '-' }
                    } ?: ""
                    val name = "DataLog_${ecu}${sn}_${df.format(Date())}.ae3"
                    val dir = File(getApplication<Application>().getExternalFilesDir("datalogs"), "").apply { mkdirs() }
                    val out = File(dir, name)
                    val xml = Ae3Decoder.buildHexdumpXML(result.rawSectors, name.replace(".ae3", ".xml"))
                    out.writeBytes(Ae3Crypto.encryptAe3(xml, pass))
                    savedPath = out.absolutePath
                    diagStatus = "Saved ${out.name} (${out.length() / 1024} KB)"
                } else {
                    diagStatus = "Read ${result.rows.size} row(s) (no passphrase — .ae3 not saved)"
                }
            } catch (e: Exception) {
                diagStatus = "Flash read failed: ${(e as? DiagException)?.message ?: e.message ?: e.toString()}"
            } finally {
                runCatching { source.close() }; diagBusy = false; flashProgress = 0f
            }
        }
    }

    /** Called after permission is granted (from the activity's receiver) or directly. */
    fun open() {
        if (connected) return
        val device = source.findDevice() ?: run {
            status = "No PCAN-USB found."; return
        }
        rxJob = viewModelScope.launch {
            try {
                val i = withContext(Dispatchers.IO) { source.open(device) }
                info = i
                connected = true
                error = null
                status = "Connected — listening (500 kbit/s, listen-only)"
                startTicker()
                source.frames().collect { handle(it) }
            } catch (e: Exception) {
                connected = false
                status = "Disconnected"
                error = e.message ?: e.toString()
            }
        }
    }

    fun disconnect() {
        rxJob?.cancel(); rxJob = null
        tickJob?.cancel(); tickJob = null
        viewModelScope.launch(Dispatchers.IO) { runCatching { source.close() } }
        connected = false
        status = "Disconnected"
    }

    private fun handle(timed: TimedFrame) {
        frameCount += 1
        val b = runCatching { decoder.decode(timed.frame) }.getOrNull() ?: return
        latest[b.ecu to b.group] = Entry(b, timed.receivedMillis)
    }

    private fun startTicker() {
        tickJob?.cancel()
        tickJob = viewModelScope.launch {
            while (isActive) { now = System.currentTimeMillis(); delay(1_000) }
        }
    }

    override fun onCleared() {
        disconnect()
        super.onCleared()
    }
}
