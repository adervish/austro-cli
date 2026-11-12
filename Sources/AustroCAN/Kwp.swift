import Foundation

/// KWP2000 service layer on top of ISO-TP: session control, security access, and
/// ReadDataByLocalId (incl. the bulk sector read). Ported from the decompiled Wizard.
public final class Kwp {
    private let tp: IsoTp
    public init(tp: IsoTp) { self.tp = tp }

    /// SAFETY: the only KWP service IDs this layer is ever permitted to transmit.
    /// All are read / session / unlock — none write, erase, program, reset, or code.
    /// Every outgoing request is checked against this; anything else throws before it
    /// can reach the bus, so the app cannot modify the ECU/flash even by mistake.
    ///   0x81 StartCommunication · 0x10 StartDiagnosticSession · 0x27 SecurityAccess
    ///   0x3E TesterPresent · 0x21 ReadDataByLocalId · 0x20 StopDiagnosticSession
    ///   0x1A ReadEcuIdentification (serial/ident — pure read)
    ///   0x18 ReadDTCByStatus · 0x17 ReadStatusOfDTC (fault codes — pure reads; 0x14 clear stays blocked)
    static let readOnlySIDs: Set<UInt8> = [0x81, 0x10, 0x27, 0x3E, 0x21, 0x20, 0x1A, 0x18, 0x17]

    private func assertReadOnly(_ req: [UInt8]) throws {
        guard let sid = req.first, Self.readOnlySIDs.contains(sid) else {
            throw DiagError.blockedService(req.first ?? 0)
        }
    }

    @discardableResult
    private func service(_ req: [UInt8], timeoutMs: Int = 3000) throws -> [UInt8] {
        try assertReadOnly(req)
        let resp = try tp.request(req, timeoutMs: timeoutMs)
        guard !resp.isEmpty else { throw DiagError.badResponse("empty response") }
        if resp[0] == 0x7F {
            throw DiagError.negative(service: resp.count > 1 ? resp[1] : req[0], nrc: resp.count > 2 ? resp[2] : 0)
        }
        return resp
    }

    public func startCommunication() throws { _ = try service([0x81]) }
    public func startDiagnosticSession(mode: UInt8) throws { _ = try service([0x10, mode]) }
    public func testerPresent() throws { _ = try service([0x3E]) }
    public func stopSession() { _ = try? service([0x20]) }

    public func readDataByLocalId(_ lid: UInt8, _ extra: [UInt8] = []) throws -> [UInt8] {
        try service([0x21, lid] + extra)
    }

    /// Bulk record-manager sector read: `0x21 0xF6 <start32> <end32> 00 00 00 0xE0`.
    public func readSector(start: UInt32, end: UInt32, expectedLen: Int) throws -> [UInt8] {
        var req: [UInt8] = [0x21, 0xF6]
        req += be32(start) + be32(end) + [0, 0, 0, 0xE0]
        try assertReadOnly(req)
        return try tp.requestBulk(req, expectedLen: expectedLen)
    }

    /// Reads the engine serial from the ECU identification block: `0x1A 0x96`
    /// (Wizard `Engine_Serial_Read`, a pure read). Response is `0x5A 0x96` + ASCII;
    /// the Wizard takes 16 chars at offset 2, formatted like `E4-B-01234`. Requires
    /// security access first (same as the Wizard). Returns nil if the ECU reports
    /// nothing usable.
    public func readEngineSerial() throws -> String? {
        let resp = try service([0x1A, 0x96])          // 0x5A 0x96 <ascii…>
        guard resp.count > 2 else { return nil }
        let ascii = resp.dropFirst(2).prefix(16)
        let s = String(decoding: ascii.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return s.count >= 3 ? s : nil
    }

    // MARK: - Fault codes (DTCs) — read-only

    public struct Dtc: Sendable {
        public let id: UInt16       // raw DTC id (2 bytes)
        public let active: Bool     // currently present this session
        public let stored: Bool     // stored/confirmed in fault memory
        public let frequency: Int   // occurrence counter (0 if detail unavailable)
    }

    /// ReadDTCByStatus (0x18 0x02 0xFF 0x00): returns `[(id, statusByte)]`. Mirrors the
    /// Wizard `DTC_List` request; response is `0x58 <count> (id_hi id_lo status)*count`.
    public func readDTCList() throws -> [(id: UInt16, status: UInt8)] {
        let r = try service([0x18, 0x02, 0xFF, 0x00])
        guard r.count >= 2, r[0] == 0x58 else { throw DiagError.badResponse("unexpected DTC list response") }
        let count = Int(r[1])
        var out: [(UInt16, UInt8)] = []
        var i = 2
        for _ in 0..<count where i + 2 < r.count {
            out.append(((UInt16(r[i]) << 8) | UInt16(r[i + 1]), r[i + 2]))
            i += 3
        }
        return out
    }

    /// ReadStatusOfDTC detail (0x17 id_hi id_lo). `0x57 <state> id_hi id_lo <flags> … freq@8`.
    /// `state == 0` means the code isn't actually stored. Returns nil in that case.
    public func readDTCDetail(id: UInt16) throws -> Dtc? {
        let r = try service([0x17, UInt8(id >> 8), UInt8(id & 0xFF)])
        guard r.count >= 5, r[0] == 0x57, r[1] != 0 else { return nil }
        let realId = (UInt16(r[2]) << 8) | UInt16(r[3])
        let flags = r[4]
        return Dtc(id: realId,
                   active: (flags & 0x60) == 0x60,
                   stored: (flags & 0x80) != 0,
                   frequency: r.count > 8 ? Int(r[8]) : 0)
    }

    /// Full fault read: list every DTC, then pull each one's detail (active/stored/frequency).
    /// A code whose detail reports state 0 ("not actually stored") is dropped; only if the
    /// detail request *fails* do we fall back to the list's status byte.
    public func readDTCs() throws -> [Dtc] {
        var out: [Dtc] = []
        for entry in try readDTCList() {
            do {
                if let d = try readDTCDetail(id: entry.id) { out.append(d) }
                // nil ⇒ detail says not stored ⇒ skip (don't surface a phantom fault)
            } catch {
                out.append(Dtc(id: entry.id,
                               active: (entry.status & 0x60) == 0x60,
                               stored: (entry.status & 0x80) != 0,
                               frequency: 0))
            }
        }
        return out
    }

    /// SecurityAccess seed/key (diagnostic). `mask` is the recovered 8×4 key table.
    public func securityAccess(mask: [[UInt32]]) throws {
        let seedResp = try service([0x27, 0x01])            // 0x67 0x01 s0 s1 s2 s3
        guard seedResp.count >= 6 else { throw DiagError.security("short seed response") }
        let seed = Array(seedResp[2..<6])
        if seed.allSatisfy({ $0 == 0 }) { return }          // all-zero seed ⇒ already unlocked
        let key = Self.computeKey(seed: seed, mask: mask)
        let keyResp = try service([0x27, 0x02] + key)       // 0x67 0x02 0x34 on success
        guard keyResp.count >= 3, keyResp[2] == 0x34 else { throw DiagError.security("key rejected by ECU") }
    }

    /// Seed→key transform recovered from `BaseService.SecuritySeedKey` (diagnostic mode).
    static func computeKey(seed: [UInt8], mask: [[UInt32]]) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 4)
        for j in 0..<4 {
            var b = seed[j]
            if j < 3 { b = seed[j] >> (seed[j + 1] & 3) }
            b = UInt8((UInt32(b) ^ mask[Int(b) & 7][Int(b) & 3]) & 0xFF)
            key[j] = b
        }
        return key
    }

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}

/// Loads the 8×4 security key mask at runtime (never committed): `$AE3_UKEY` path or
/// `~/.config/austro/ae3-ukey.json` (a JSON 8×4 integer array).
public enum DiagSecurity {
    public static func resolveMask() -> [[UInt32]]? {
        let env = ProcessInfo.processInfo.environment
        let path = env["AE3_UKEY"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/austro/ae3-ukey.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let grid = try? JSONSerialization.jsonObject(with: data) as? [[Int]], grid.count == 8 else {
            return nil
        }
        return grid.map { $0.map { UInt32(truncatingIfNeeded: $0) } }
    }
}
