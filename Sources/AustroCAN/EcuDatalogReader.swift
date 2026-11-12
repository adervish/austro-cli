import Foundation
import AustroCore

/// Reads the stored data-logger (previous flight sessions) directly from an ECU over
/// CAN, using the diagnostic session + security access, then decodes it with the shared
/// `AE3` decoder. GROUND / ENGINE-OFF — this transmits to the ECU.
///
/// The session/security/status path is offline-tested; the bulk sector read (ISO-TP
/// 226-streaming) must be validated against a live ECU.
public final class EcuDatalogReader {
    public struct Progress: Sendable { public let message: String; public let fraction: Double }

    private let dataLogFirstIdx = 16     // RecManBase: datalogger band = sector indices 16..139
    private let dataLogLastIdx = 139
    private let sectorBytes = 65538

    public init() {}

    // Record-manager sizing (ConfigRecMan): ~0.5 h of data per flash sector, +3 read offset.
    private let hoursPerSector = 0.5
    private let sectorReadOffset = 3

    /// `hours == nil` or `<= 0` reads all populated sectors; otherwise caps the read to
    /// roughly the last `hours` of data (same formula as Wizard).
    public func read(link: DiagChannel, ecu: String, hours: Int? = nil, verbose: Bool = false,
                     saveAe3To: URL? = nil,
                     log: @escaping @Sendable (String) -> Void = { _ in },
                     progress: @escaping @Sendable (Progress) -> Void = { _ in },
                     onSaved: @escaping @Sendable (URL) -> Void = { _ in },
                     onSerial: @escaping @Sendable (String) -> Void = { _ in }) throws -> [AE3.Row] {
        func step(_ frac: Double, _ msg: String) { progress(.init(message: msg, fraction: frac)); log(msg) }
        func hex(_ d: [UInt8]) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }

        guard let mask = DiagSecurity.resolveMask() else {
            throw DiagError.security("key mask not found at ~/.config/austro/ae3-ukey.json")
        }
        let txId: UInt32 = ecu == "A" ? 0x7E0 : 0x7E1
        let rxId: UInt32 = ecu == "A" ? 0x7E8 : 0x7E9
        log("ECU \(ecu): request 0x\(String(txId, radix: 16)) / response 0x\(String(rxId, radix: 16)), hours=\(hours.map(String.init) ?? "all")")

        if verbose { link.onLog = log }
        try link.open(listenOnly: false)       // diagnostics must transmit + be ACKed
        defer { link.close() }
        let kwp = Kwp(tp: IsoTp(link: link, txId: txId, rxId: rxId))

        let diagnosticMode: UInt8 = 0x84
        let memoryAccessMode: UInt8 = 0x83

        step(0.05, "Starting communication…")
        try kwp.startCommunication()

        // Wizard order: SecurityAccess → StopSession → StartSession(mode) → read.
        step(0.10, "Security access…")
        try kwp.securityAccess(mask: mask)

        // Engine serial (0x1A 0x96, read-only) — best-effort; used only to tag the
        // saved filename / library entry, never required for the read.
        var engineSerial: String? = nil
        if let sn = try? kwp.readEngineSerial() {
            engineSerial = sn
            onSerial(sn)                 // surface it even if the .ae3 save later fails
            log("engine serial: \(sn)")
        } else {
            log("engine serial: unavailable")
        }

        kwp.stopSession()
        try kwp.startDiagnosticSession(mode: diagnosticMode)

        step(0.15, "Reading record-manager status…")
        let status = try kwp.readDataByLocalId(0xF3)
        log("RecMan status: \(hex(status))")
        guard status.count >= 6 else { throw DiagError.badResponse("short RecMan status (\(status.count) bytes)") }
        let activeSector = Int(status[5])
        let entryCount = (Int(status[2]) << 8) | Int(status[3])
        log("entry count \(entryCount), active event-rec sector \(status[4]), active datalog sector \(activeSector)")
        guard (dataLogFirstIdx...dataLogLastIdx).contains(activeSector) else {
            throw DiagError.badResponse("active datalog sector \(activeSector) out of range (16…139)")
        }

        step(0.15, "Entering memory-access session…")
        try kwp.securityAccess(mask: mask)        // no-op if still unlocked
        kwp.stopSession()
        try kwp.startDiagnosticSession(mode: memoryAccessMode)

        let bandSize = dataLogLastIdx - dataLogFirstIdx + 2
        let sectorBudget: Int = {
            guard let h = hours, h > 0 else { return bandSize }
            return min(124, Int((Double(h) / hoursPerSector).rounded()) + sectorReadOffset - 1)
        }()
        let limit = min(bandSize, sectorBudget)
        log("reading up to \(limit) sector(s) from active sector \(activeSector)")

        var raw: [(ecu: String, id: Int, raw: [UInt8])] = []
        var current = activeSector
        for i in 0..<limit {
            step(0.15 + 0.75 * Double(i) / Double(limit), "Reading sector \(current) (\(i + 1) of ≤\(limit))…")
            try? kwp.testerPresent()
            let r = RecManAddr.ranges[current]
            let bytes = try kwp.readSector(start: r.start, end: r.end, expectedLen: sectorBytes)
            let t = sectorType(bytes)
            log("  sector \(current): \(bytes.count) bytes, type \(t)")

            var prev = current - 1
            if prev == dataLogFirstIdx - 1 { prev = dataLogLastIdx }
            if prev == activeSector { raw.append((ecu, current, bytes)); break }
            if t == "notModified" { log("  reached unwritten sector — stopping"); break }
            raw.append((ecu, current, bytes))
            current = prev
        }
        kwp.stopSession()
        log("read \(raw.count) sector(s) total")

        // Save the raw capture as a .ae3 (best-effort — a failed save must NOT abort the
        // read; e.g. a macOS Downloads-folder permission prompt could otherwise lose the data).
        // Writing .ae3 needs AES (CommonCrypto, Apple-only); on Linux the CLI emits CSV instead.
        #if canImport(CommonCrypto)
        if let dir = saveAe3To {
            if let pass = AE3.resolvePassphrase() {
                let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
                // Serial encoded in the filename only (never the XML) so the capture stays
                // readable by the Austro Wizard, which ignores filenames. Token form: SN<serial>.
                let snTok = engineSerial.map { "_SN\(AE3.sanitizeSerialForFilename($0))" } ?? ""
                let base = "DataLog_\(ecu)\(snTok)_\(df.string(from: Date()))"
                // Never overwrite an existing capture — pick the first free "name" / "name (2)" / …
                let url = Self.uniqueURL(in: dir, base: base, ext: "ae3")
                let name = url.lastPathComponent
                do {
                    let xml = AE3.buildHexdumpXML(sectors: raw, fileName: (name as NSString).deletingPathExtension + ".xml")
                    let enc = try AE3Crypto.encryptAE3(xml: xml, passphrase: pass)
                    // withoutOverwriting fails rather than clobbers if the name appeared between
                    // the uniqueness check and the write (belt-and-suspenders against data loss).
                    try enc.write(to: url, options: [.withoutOverwriting])
                    onSaved(url)
                    step(0.95, "Saved \(name) (\(enc.count / 1024) KB) to \(dir.lastPathComponent)")
                } catch {
                    log("Could not save .ae3 (\(error.localizedDescription)) — continuing to decode.")
                }
            } else {
                log("No passphrase — skipped .ae3 save.")
            }
        }
        #else
        if saveAe3To != nil { log("(.ae3 save needs AES — unavailable on this platform; decode only.)") }
        #endif

        step(0.97, "Decoding \(raw.count) sector(s)…")
        let rows = AE3.decode(rawSectors: raw)
        log("decoded \(rows.count) row(s)")
        return rows
    }

    /// First non-colliding file URL: `base.ext`, then `base (2).ext`, `base (3).ext`, …
    /// Guarantees we never reuse (and thus never overwrite) an existing path.
    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    private func sectorType(_ raw: [UInt8]) -> String {
        guard raw.count >= 4 else { return "unknown" }
        let n = raw.count
        switch (raw[n-1], raw[n-2], raw[n-3], raw[n-4]) {
        case (0xFF,0xFF,0xFF,0xFF): return "notModified"
        case (0xFE,0xFE,0xFE,0xFE): return "erased"
        case (0xAA,0xAA,0xAA,0xAA): return "active"
        case (0xA8,0xA8,0xA8,0xA8): return "fullNotLocked"
        case (0x00,0x00,0x00,0x00): return "locked"
        default: return "unknown"
        }
    }
}
