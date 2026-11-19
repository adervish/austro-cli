package com.austro.reader.can


/** Minimal CAN link the ISO-TP / KWP layers drive (implemented by PcanUsbSource.asLink()). */
interface CanLink {
    fun send(id: Int, data: ByteArray)
    /** Next received frame as (id, data), or null on timeout. */
    fun recv(timeoutMs: Int): Pair<Int, ByteArray>?
}

/** A diagnostic error; carries the KWP negative-response code when there is one. */
class DiagException(message: String, val nrcService: Int = -1, val nrc: Int = -1) : Exception(message)

private fun IntArray.toBytes(): ByteArray = ByteArray(size) { this[it].toByte() }
private fun ByteArray.toInts(): IntArray = IntArray(size) { this[it].toInt() and 0xFF }

/**
 * ISO-TP (ISO 15765-2) over classic CAN, ported verbatim from the validated macOS
 * `IsoTp.swift`, including the Austro "226-streaming" bulk-read extension. Runs on an
 * IO thread (blocking); `Thread.sleep` for STmin is fine there.
 */
class IsoTp(private val link: CanLink, private val txId: Int, private val rxId: Int) {
    private var blockSize = 16
    private var stMin = 1
    private val streamSentinel = 226

    fun request(payload: IntArray, timeoutMs: Int = 3000): IntArray {
        sendPayload(payload); return receive(null, timeoutMs)
    }

    fun requestBulk(payload: IntArray, expectedLen: Int, timeoutMs: Int = 20000): IntArray {
        sendPayload(payload); return receive(expectedLen, timeoutMs)
    }

    private fun sendPayload(payload: IntArray) {
        val len = payload.size
        if (len < 8) { link.send(txId, (intArrayOf(len) + payload).toBytes()); return }
        val ff = intArrayOf((len shr 8) or 0x10, len and 0xFF) + payload.copyOfRange(0, 6)
        link.send(txId, ff.toBytes())
        if (!waitFlowControl()) throw DiagException("no flow control for request")
        var idx = 6; var sn = 1; var sinceFC = 0
        while (idx < len) {
            if (blockSize != 0 && sinceFC == blockSize) {
                if (!waitFlowControl()) throw DiagException("no flow control mid-request"); sinceFC = 0
            }
            if (stMin > 0) try { Thread.sleep(stMin.toLong()) } catch (_: InterruptedException) {}
            val take = minOf(7, len - idx)
            val cf = intArrayOf((sn and 0xF) or 0x20) + payload.copyOfRange(idx, idx + take)
            link.send(txId, cf.toBytes())
            idx += take; sn = if (sn == 15) 0 else sn + 1; sinceFC++
        }
    }

    private fun waitFlowControl(timeoutMs: Int = 3000): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val (id, dB) = link.recv(50) ?: continue
            if (id != rxId || dB.isEmpty()) continue
            val d = dB.toInts()
            if (d[0] and 0xF0 == 0x30) {
                if (d.size > 1) blockSize = d[1]
                if (d.size > 2) stMin = d[2]
                return true
            }
        }
        return false
    }

    private fun receive(expectedLen: Int?, timeoutMs: Int): IntArray {
        val deadline = System.currentTimeMillis() + timeoutMs
        val payload = ArrayList<Int>()
        var ffDl = 0; var datacount = 0; var streaming = false; var packetcount = 0

        fun finish(): IntArray {
            if (payload.size >= 3 && payload[0] == 0x7F) throw DiagException("negative", payload[1], payload[2])
            return payload.toIntArray()
        }

        while (System.currentTimeMillis() < deadline) {
            val r = link.recv(100) ?: continue
            val (id, dB) = r
            if (id != rxId || dB.isEmpty()) continue
            val d = dB.toInts()
            when (d[0] and 0xF0) {
                0x00 -> {   // Single Frame
                    var n = d[0] and 0xF; if (n > 7) n = 7
                    val p = d.copyOfRange(1, minOf(d.size, 1 + n))
                    if (p.size == 3 && p[0] == 0x7F && p[2] == 0x78) continue   // response pending
                    payload.clear(); for (x in p) payload.add(x)
                    return finish()
                }
                0x10 -> {   // First Frame
                    if (!streaming) {
                        payload.clear(); ffDl = d[1]; streaming = (ffDl == streamSentinel)
                        for (i in 2 until minOf(d.size, 8)) payload.add(d[i]); datacount = 6
                    } else {
                        ffDl = d[1]
                        if (d.size > 4) for (i in 4 until minOf(d.size, 8)) payload.add(d[i]); datacount = 6
                    }
                    packetcount = 0; sendFlowControl()
                }
                0x20 -> {   // Consecutive Frame
                    packetcount++
                    if (ffDl - datacount > 7) {
                        for (i in 1 until minOf(d.size, 8)) payload.add(d[i]); datacount += 7
                        if (blockSize != 0 && packetcount == blockSize) { sendFlowControl(); packetcount = 0 }
                    } else {
                        val rem = maxOf(0, ffDl - datacount)
                        if (rem > 0) for (i in 1 until minOf(d.size, 1 + rem)) payload.add(d[i])
                        datacount += rem
                        if (!streaming) return finish()
                    }
                    if (streaming && expectedLen != null && payload.size >= expectedLen)
                        return payload.subList(0, expectedLen).toIntArray()
                }
            }
        }
        if (streaming && expectedLen != null && payload.isNotEmpty())
            return payload.subList(0, minOf(expectedLen, payload.size)).toIntArray()
        throw DiagException("incomplete ISO-TP response (${payload.size} bytes)")
    }

    private fun sendFlowControl(fs: Int = 0) {
        link.send(txId, intArrayOf(fs or 0x30, blockSize, stMin).toBytes())
    }
}

/**
 * KWP2000 over ISO-TP, ported from the validated macOS `Kwp.swift`. Read-only: the
 * transmit allowlist blocks every write/erase/clear service before a frame is sent.
 */
class Kwp(private val tp: IsoTp) {
    companion object {
        // start/stop comm, session, security read, tester-present, read-by-local-id,
        // read ident, DTC list/detail. Writes (0x3B/0x14/...) are never allowed.
        val readOnlySIDs = setOf(0x81, 0x10, 0x27, 0x3E, 0x21, 0x20, 0x1A, 0x18, 0x17)

        fun computeKey(seed: IntArray, mask: Array<IntArray>): IntArray {
            val key = IntArray(4)
            for (j in 0 until 4) {
                var b = if (j < 3) seed[j] shr (seed[j + 1] and 3) else seed[j]
                b = (b xor mask[b and 7][b and 3]) and 0xFF
                key[j] = b
            }
            return key
        }
    }

    data class Dtc(val id: Int, val active: Boolean, val stored: Boolean, val frequency: Int)

    private fun assertReadOnly(req: IntArray) {
        val sid = req.getOrElse(0) { -1 }
        if (sid !in readOnlySIDs) throw DiagException("Refused non-read-only service 0x%02X (safety guard)".format(sid))
    }

    private fun service(req: IntArray, timeoutMs: Int = 3000): IntArray {
        assertReadOnly(req)
        val resp = tp.request(req, timeoutMs)
        if (resp.isEmpty()) throw DiagException("empty response")
        if (resp[0] == 0x7F) throw DiagException("ECU rejected 0x%02X".format(req[0]),
            if (resp.size > 1) resp[1] else req[0], if (resp.size > 2) resp[2] else 0)
        return resp
    }

    fun startCommunication() { service(intArrayOf(0x81)) }
    fun startDiagnosticSession(mode: Int) { service(intArrayOf(0x10, mode)) }
    fun testerPresent() { service(intArrayOf(0x3E)) }
    fun stopSession() { runCatching { service(intArrayOf(0x20)) } }

    fun readDataByLocalId(lid: Int, extra: IntArray = IntArray(0)): IntArray =
        service(intArrayOf(0x21, lid) + extra)

    fun readSector(start: Long, end: Long, expectedLen: Int): IntArray {
        val req = intArrayOf(0x21, 0xF6) + be32(start) + be32(end) + intArrayOf(0, 0, 0, 0xE0)
        assertReadOnly(req)
        return tp.requestBulk(req, expectedLen)
    }

    /** Engine serial from ECU identification (0x1A 0x96, pure read). nil if unavailable. */
    fun readEngineSerial(): String? {
        val r = service(intArrayOf(0x1A, 0x96))
        if (r.size <= 2) return null
        val s = r.copyOfRange(2, minOf(r.size, 18)).filter { it in 0x20..0x7E }
            .map { it.toChar() }.joinToString("").trim()
        return if (s.length >= 3) s else null
    }

    fun securityAccess(mask: Array<IntArray>) {
        val seedResp = service(intArrayOf(0x27, 0x01))
        if (seedResp.size < 6) throw DiagException("short seed response")
        val seed = seedResp.copyOfRange(2, 6)
        if (seed.all { it == 0 }) return                 // already unlocked
        val key = computeKey(seed, mask)
        val keyResp = service(intArrayOf(0x27, 0x02) + key)
        if (keyResp.size < 3 || keyResp[2] != 0x34) throw DiagException("key rejected by ECU")
    }

    // --- Fault codes (DTCs) ---

    fun readDTCList(): List<Pair<Int, Int>> {
        val r = service(intArrayOf(0x18, 0x02, 0xFF, 0x00))
        if (r.size < 2 || r[0] != 0x58) throw DiagException("unexpected DTC list response")
        val out = ArrayList<Pair<Int, Int>>(); var i = 2
        repeat(r[1]) { if (i + 2 < r.size) { out.add(((r[i] shl 8) or r[i + 1]) to r[i + 2]); i += 3 } }
        return out
    }

    fun readDTCDetail(id: Int): Dtc? {
        val r = service(intArrayOf(0x17, (id shr 8) and 0xFF, id and 0xFF))
        if (r.size < 5 || r[0] != 0x57 || r[1] == 0) return null
        val flags = r[4]
        return Dtc((r[2] shl 8) or r[3], (flags and 0x60) == 0x60, (flags and 0x80) != 0, if (r.size > 8) r[8] else 0)
    }

    fun readDTCs(): List<Dtc> {
        val out = ArrayList<Dtc>()
        for ((id, status) in readDTCList()) {
            try { readDTCDetail(id)?.let { out.add(it) } }
            catch (_: Exception) { out.add(Dtc(id, (status and 0x60) == 0x60, (status and 0x80) != 0, 0)) }
        }
        return out
    }

    private fun be32(v: Long) = intArrayOf(
        ((v shr 24) and 0xFF).toInt(), ((v shr 16) and 0xFF).toInt(),
        ((v shr 8) and 0xFF).toInt(), (v and 0xFF).toInt()
    )
}

/** The 8x4 security key mask: entered on the Keys tab, or compiled in as a fallback. */
object DiagSecurity {
    fun resolveMask(): Array<IntArray>? = Keys.mask()
}
