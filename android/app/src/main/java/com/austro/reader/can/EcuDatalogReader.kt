package com.austro.reader.can

/**
 * Reads the stored data-logger (previous flight sessions) directly from an ECU over the
 * PCAN-USB, then decodes it with [Ae3Decoder]. Ported from the validated macOS
 * `EcuDatalogReader.swift`. GROUND / ENGINE-OFF — this transmits to the ECU (read-only
 * services only). Caller must open the transport with listenOnly = false.
 */
class EcuDatalogReader {
    data class Progress(val message: String, val fraction: Double)
    data class Result(val rows: List<Ae3Decoder.Row>, val rawSectors: List<Triple<String, Int, IntArray>>, val engineSerial: String?)

    private val dataLogFirstIdx = 16      // datalogger band = sector indices 16..139
    private val dataLogLastIdx = 139
    private val sectorBytes = 65538
    private val hoursPerSector = 0.5      // ConfigRecMan sizing
    private val sectorReadOffset = 3

    /**
     * @param hours null / <=0 reads all populated sectors; otherwise ~last `hours`.
     * Returns decoded rows + the raw sectors (so the caller can also save a .ae3).
     */
    fun read(link: PcanUsbSource, ecu: String, hours: Int?,
             log: (String) -> Unit = {}, progress: (Progress) -> Unit = {}): Result {
        fun step(f: Double, m: String) { progress(Progress(m, f)); log(m) }

        val mask = DiagSecurity.resolveMask()
            ?: throw DiagException("the security key mask is not set. Add it on the Keys tab.")
        val txId = if (ecu == "A") 0x7E0 else 0x7E1
        val rxId = if (ecu == "A") 0x7E8 else 0x7E9
        val kwp = Kwp(IsoTp(link.asLink(), txId, rxId))
        val diagnosticMode = 0x84
        val memoryAccessMode = 0x83

        step(0.05, "Starting communication…"); kwp.startCommunication()

        step(0.10, "Security access…"); kwp.securityAccess(mask)
        var serial: String? = null
        runCatching { kwp.readEngineSerial() }.getOrNull()?.let { serial = it; log("engine serial: $it") }
        kwp.stopSession(); kwp.startDiagnosticSession(diagnosticMode)

        step(0.15, "Reading record-manager status…")
        val status = kwp.readDataByLocalId(0xF3)
        if (status.size < 6) throw DiagException("short RecMan status (${status.size} bytes)")
        val activeSector = status[5]
        log("entry count ${(status[2] shl 8) or status[3]}, active datalog sector $activeSector")
        if (activeSector !in dataLogFirstIdx..dataLogLastIdx)
            throw DiagException("active datalog sector $activeSector out of range (16…139)")

        step(0.15, "Entering memory-access session…")
        kwp.securityAccess(mask); kwp.stopSession(); kwp.startDiagnosticSession(memoryAccessMode)

        val bandSize = dataLogLastIdx - dataLogFirstIdx + 2
        val budget = if (hours == null || hours <= 0) bandSize
            else minOf(124, Math.round(hours / hoursPerSector).toInt() + sectorReadOffset - 1)
        val limit = minOf(bandSize, budget)
        log("reading up to $limit sector(s) from active sector $activeSector")

        val raw = ArrayList<Triple<String, Int, IntArray>>()
        var current = activeSector
        for (i in 0 until limit) {
            step(0.15 + 0.75 * i / limit, "Reading sector $current (${i + 1} of ≤$limit)…")
            runCatching { kwp.testerPresent() }
            val r = RecManAddr.ranges[current]
            val bytes = kwp.readSector(r[0], r[1], sectorBytes)
            val t = sectorType(bytes)
            log("  sector $current: ${bytes.size} bytes, type $t")
            var prev = current - 1
            if (prev == dataLogFirstIdx - 1) prev = dataLogLastIdx
            if (prev == activeSector) { raw.add(Triple(ecu, current, bytes)); break }
            if (t == "notModified") { log("  reached unwritten sector — stopping"); break }
            raw.add(Triple(ecu, current, bytes))
            current = prev
        }
        kwp.stopSession()
        log("read ${raw.size} sector(s) total")

        step(0.97, "Decoding ${raw.size} sector(s)…")
        val rows = Ae3Decoder.decode(raw)
        log("decoded ${rows.size} row(s)")
        return Result(rows, raw, serial)
    }

    private fun sectorType(raw: IntArray): String {
        if (raw.size < 4) return "unknown"
        val n = raw.size
        val c = intArrayOf(raw[n - 1], raw[n - 2], raw[n - 3], raw[n - 4])
        return when {
            c.all { it == 0xFF } -> "notModified"
            c.all { it == 0xFE } -> "erased"
            c.all { it == 0xAA } -> "active"
            c.all { it == 0xA8 } -> "fullNotLocked"
            c.all { it == 0x00 } -> "locked"
            else -> "unknown"
        }
    }
}
