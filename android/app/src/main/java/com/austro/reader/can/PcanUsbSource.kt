package com.austro.reader.can

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import com.austro.reader.core.CanFrame
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive

/** A received frame plus host arrival time (the adapter's own timestamps are ignored). */
data class TimedFrame(val frame: CanFrame, val receivedMillis: Long)

data class PcanDeviceInfo(
    val productName: String,
    val manufacturer: String,
    val serial: String?,
)

/**
 * Receive-only transport for the classic PEAK PCAN-USB (0x0C72/0x000C) over the
 * Android USB Host API. Opens the bus at 500 kbit/s in listen-only mode (never
 * transmits / never ACKs — safe on a live engine bus) and decodes standard-ID
 * broadcast frames.
 *
 * The command set, bit-timing, open sequence, and RX record framing are
 * implemented from the GPL Linux kernel driver `drivers/net/can/usb/peak_usb/
 * pcan_usb.c` as a protocol reference (clean-room: from the documented behaviour,
 * not copied code). UNTESTED against hardware yet — verify on the adapter.
 */
class PcanUsbSource(private val context: Context) {

    companion object {
        const val VENDOR_ID = 0x0C72   // 3186, PEAK-System
        const val PRODUCT_ID = 0x000C  // 12, classic PCAN-USB
        const val ACTION_USB_PERMISSION = "com.austro.reader.USB_PERMISSION"

        // Endpoint addresses (pcan_usb.c): cmd out/in on EP1, msg out/in on EP2.
        private const val EP_CMD_OUT = 0x01
        private const val EP_CMD_IN = 0x81
        private const val EP_MSG_OUT = 0x02
        private const val EP_MSG_IN = 0x82

        // Command buffer: [func][num][14 bytes args] = 16 bytes.
        private const val CMD_LEN = 16
        private const val CMD_ARGS = 2
        private const val CMD_ARGS_LEN = 14

        // Command functions / numbers.
        private const val CMD_BITRATE = 1
        private const val CMD_SET_BUS = 3
        private const val CMD_REGISTER = 9
        private const val CMD_EXT_VCC = 10
        private const val GET = 1
        private const val SET = 2
        private const val BUS_XCVER = 2     // transceiver on/off
        private const val BUS_SILENT = 3    // listen-only on/off
        private const val SJA1000_MODE_INIT = 0x01

        // 500 kbit/s on the SJA1000 @ 8 MHz: BTR0=0x00, BTR1=0x1C (== PCAN_BAUD_500K 0x001C).
        private const val BTR0_500K = 0x00
        private const val BTR1_500K = 0x1C

        // TX record framing (pcan_usb.c pcan_usb_encode_msg): fixed 64-byte buffer,
        //   [0]=PCAN_USB_MSG_TX_CAN(2) [1]=1 record, then status/len + LE16(id<<5) + data,
        //   and a rolling counter in the last byte. RX framing lives in PcanFrameParser.
        private const val TX_BUFFER_SIZE = 64
        private const val MSG_TX_CAN = 2

        private const val RX_BUFFER_SIZE = 64
        private const val CMD_TIMEOUT_MS = 1000
        private const val RX_TIMEOUT_MS = 200
        private const val STARTUP_DELAY_MS = 50L
    }

    private var connection: UsbDeviceConnection? = null
    private var usbInterface: UsbInterface? = null
    private var cmdOut: UsbEndpoint? = null
    private var msgIn: UsbEndpoint? = null
    private var msgOut: UsbEndpoint? = null
    private var txCounter = 0
    private val rxQueue = ArrayDeque<Pair<Int, ByteArray>>()

    fun usbManager(): UsbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager

    fun findDevice(): UsbDevice? =
        usbManager().deviceList.values.firstOrNull {
            it.vendorId == VENDOR_ID && it.productId == PRODUCT_ID
        }

    fun hasPermission(device: UsbDevice): Boolean = usbManager().hasPermission(device)

    /** Shows the system USB consent dialog; the caller's receiver gets ACTION_USB_PERMISSION. */
    fun requestPermission(device: UsbDevice) {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        val intent = PendingIntent.getBroadcast(
            context, 0, Intent(ACTION_USB_PERMISSION).setPackage(context.packageName), flags
        )
        usbManager().requestPermission(device, intent)
    }

    /**
     * Opens the channel at 500 kbit/s. `listenOnly=true` (default) never transmits/ACKs —
     * safe on a live bus, used by the Live view. `listenOnly=false` enables transmit for
     * diagnostics (datalogger / fault-code reads); engine must be off on the ground.
     */
    fun open(device: UsbDevice, listenOnly: Boolean = true): PcanDeviceInfo {
        val manager = usbManager()
        val iface = device.getInterface(0)
        val conn = manager.openDevice(device)
            ?: throw IllegalStateException("openDevice returned null (permission denied?)")
        if (!conn.claimInterface(iface, true)) {
            conn.close()
            throw IllegalStateException("could not claim USB interface")
        }

        var epCmdOut: UsbEndpoint? = null
        var epMsgIn: UsbEndpoint? = null
        var epMsgOut: UsbEndpoint? = null
        for (i in 0 until iface.endpointCount) {
            val ep = iface.getEndpoint(i)
            if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
            when (ep.address and 0xFF) {
                EP_CMD_OUT -> epCmdOut = ep
                EP_MSG_IN -> epMsgIn = ep
                EP_MSG_OUT -> epMsgOut = ep
            }
        }
        if (epCmdOut == null || epMsgIn == null) {
            conn.releaseInterface(iface); conn.close()
            throw IllegalStateException("expected PCAN-USB bulk endpoints not found")
        }

        connection = conn
        usbInterface = iface
        cmdOut = epCmdOut
        msgIn = epMsgIn
        msgOut = epMsgOut
        rxQueue.clear()

        init(listenOnly)

        return PcanDeviceInfo(
            productName = device.productName ?: "PCAN-USB",
            manufacturer = device.manufacturerName ?: "PEAK-System",
            serial = runCatching { device.serialNumber }.getOrNull(),
        )
    }

    private fun init(listenOnly: Boolean) {
        // Mirror pcan_usb bring-up: bus off + SJA1000 init, set bitrate, listen-only on/off,
        // ext-vcc off, then bus on.
        sendCmd(CMD_SET_BUS, BUS_XCVER, argByte(0, 0))            // transceiver off
        sendCmd(CMD_REGISTER, SET, argByte(1, SJA1000_MODE_INIT)) // controller init/reset
        sendCmd(CMD_BITRATE, SET, args(BTR1_500K, BTR0_500K))     // args[0]=BTR1, args[1]=BTR0
        sendCmd(CMD_SET_BUS, BUS_SILENT, argByte(0, if (listenOnly) 1 else 0)) // listen-only on/off
        sendCmd(CMD_EXT_VCC, SET, argByte(0, 0))                  // no external Vcc
        sendCmd(CMD_SET_BUS, BUS_XCVER, argByte(0, 1))            // transceiver on
        try { Thread.sleep(STARTUP_DELAY_MS) } catch (_: InterruptedException) {}
    }

    // MARK: - diagnostic transmit / blocking receive (used by the ISO-TP / KWP layer)

    /** Transmit one standard-ID CAN frame (pcan_usb_encode_msg framing). Pads to DLC 8. */
    fun sendFrame(id: Int, data: ByteArray) {
        val conn = connection ?: throw IllegalStateException("open() must be called first")
        val ep = msgOut ?: throw IllegalStateException("no MSGOUT endpoint (TX unavailable)")
        val padded = ByteArray(8) { 0xFF.toByte() }
        System.arraycopy(data, 0, padded, 0, minOf(data.size, 8))
        val buf = ByteArray(TX_BUFFER_SIZE)
        buf[0] = MSG_TX_CAN.toByte()
        buf[1] = 1                                   // one record
        var pc = PcanFrameParser.MSG_HEADER_LEN
        buf[pc] = 0x08                               // status/len: DLC 8, std id, no RTR/EXT
        pc += 1
        val idField = (id and 0x7FF) shl 5           // LE16, id in the high 11 bits
        buf[pc] = (idField and 0xFF).toByte()
        buf[pc + 1] = ((idField ushr 8) and 0xFF).toByte()
        pc += 2
        System.arraycopy(padded, 0, buf, pc, 8)
        buf[TX_BUFFER_SIZE - 1] = (txCounter++ and 0xFF).toByte()   // rolling tx counter
        conn.bulkTransfer(ep, buf, buf.size, CMD_TIMEOUT_MS)
    }

    /** Next received data frame (id, data), or null on timeout. Buffers multi-frame bulks. */
    fun recvFrame(timeoutMs: Int): Pair<Int, ByteArray>? {
        if (rxQueue.isEmpty()) {
            val conn = connection ?: return null
            val ep = msgIn ?: return null
            val buf = ByteArray(RX_BUFFER_SIZE)
            val n = conn.bulkTransfer(ep, buf, buf.size, timeoutMs)
            if (n <= PcanFrameParser.MSG_HEADER_LEN) return null
            for (f in PcanFrameParser.parse(buf, n)) if (!f.isRemote) rxQueue.addLast(f.id to f.data)
        }
        return if (rxQueue.isEmpty()) null else rxQueue.removeFirst()
    }

    /** A CanLink view over this transport for the ISO-TP / KWP layer. */
    fun asLink(): CanLink = object : CanLink {
        override fun send(id: Int, data: ByteArray) = sendFrame(id, data)
        override fun recv(timeoutMs: Int): Pair<Int, ByteArray>? = recvFrame(timeoutMs)
    }

    /** Cold flow: streams received frames while collected; cancelling stops RX. */
    fun frames(): Flow<TimedFrame> = flow {
        val conn = connection ?: throw IllegalStateException("open() must be called first")
        val ep = msgIn ?: throw IllegalStateException("no MSGIN endpoint")
        val buf = ByteArray(RX_BUFFER_SIZE)
        while (currentCoroutineContext().isActive) {
            val n = conn.bulkTransfer(ep, buf, buf.size, RX_TIMEOUT_MS)
            if (n <= PcanFrameParser.MSG_HEADER_LEN) continue  // timeout or header-only
            val now = System.currentTimeMillis()
            for (frame in PcanFrameParser.parse(buf, n)) emit(TimedFrame(frame, now))
        }
    }.flowOn(Dispatchers.IO)

    fun close() {
        val conn = connection
        val iface = usbInterface
        try {
            if (conn != null) {
                // Best-effort bus off.
                runCatching { sendCmd(CMD_SET_BUS, BUS_XCVER, argByte(0, 0)) }
                if (iface != null) conn.releaseInterface(iface)
                conn.close()
            }
        } finally {
            connection = null; usbInterface = null; cmdOut = null; msgIn = null; msgOut = null
            rxQueue.clear()
        }
    }

    // MARK: - command helpers

    private fun sendCmd(func: Int, num: Int, args: ByteArray) {
        val conn = connection ?: return
        val ep = cmdOut ?: return
        val cmd = ByteArray(CMD_LEN)
        cmd[0] = func.toByte()
        cmd[1] = num.toByte()
        System.arraycopy(args, 0, cmd, CMD_ARGS, minOf(args.size, CMD_ARGS_LEN))
        conn.bulkTransfer(ep, cmd, cmd.size, CMD_TIMEOUT_MS)
    }

    private fun args(vararg values: Int): ByteArray =
        ByteArray(CMD_ARGS_LEN).also { for (i in values.indices) it[i] = values[i].toByte() }

    private fun argByte(index: Int, value: Int): ByteArray =
        ByteArray(CMD_ARGS_LEN).also { it[index] = value.toByte() }

}
