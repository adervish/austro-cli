import Foundation

/// Decoder for AE300 Wizard `.ae3` data-logger XML (`RECMAN_HEXDUMP_DATLOG`).
/// Ported from the decompiled `RecManDataLogger` + `ConfigLiveView` scaling table.
/// Operates on the *decrypted* XML (see `AE3Crypto` for the decrypt step).
public enum AE3 {

    public struct Signal: Sendable { public let name: String; public let unit: String }

    /// Resolves the `.ae3` passphrase at runtime (never embedded in source):
    /// `AE3_PASSPHRASE` env → `~/.config/austro/ae3.pass` → `AE3_CONFIG` (ConfigSecurity.cs).
    public static func resolvePassphrase() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["AE3_PASSPHRASE"], !p.isEmpty { return p }
        let passFile = (NSHomeDirectory() as NSString).appendingPathComponent(".config/austro/ae3.pass")
        if let s = try? String(contentsOfFile: passFile, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let cfg = env["AE3_CONFIG"], let src = try? String(contentsOfFile: cfg, encoding: .utf8),
           let r = src.range(of: #"string zauberwort\s*=\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
            let match = String(src[r])
            if let q = match.range(of: #""((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
                var lit = String(match[q]); lit.removeFirst(); lit.removeLast()
                return lit.replacingOccurrences(of: "\\\"", with: "\"")
            }
        }
        return nil
    }

    /// The 16 data-logger channels (codes 800–815) with (coef, offset) scaling.
    /// value = raw(int16, big-endian) * coef + offset. Temps: raw 0 → -273.14 = N/A.
    public static let signals: [Signal] = [
        .init(name: "Boost Pressure", unit: "hPa"),
        .init(name: "Ambient Air Pressure", unit: "hPa"),
        .init(name: "Propeller Speed", unit: "rpm"),
        .init(name: "Engine Oil Pressure", unit: "hPa"),
        .init(name: "Rail Pressure", unit: "bar"),
        .init(name: "Power Lever Position", unit: "%"),
        .init(name: "Coolant Temperature", unit: "°C"),
        .init(name: "Intake Air Temperature", unit: "°C"),
        .init(name: "Battery Voltage", unit: "V"),
        .init(name: "Fuel Pressure", unit: "hPa"),
        .init(name: "Gearbox Oil Temperature", unit: "°C"),
        .init(name: "Engine Oil Temperature", unit: "°C"),
        .init(name: "Prop Actuator Duty Cycle", unit: "%"),
        .init(name: "Engine Status", unit: "bin"),
        .init(name: "Engine Oil Level", unit: "mm"),
        .init(name: "Engine Load", unit: "%"),
    ]

    private static let coef: [Double] = [
        1, 1, 1, 1, 0.1, 50.0 / 4096.0, 0.1, 0.1, 20.0 / 1023.0, 1, 0.1, 0.1, 0.01, 1, 0.1, 50.0 / 4096.0,
    ]
    private static let offset: [Double] = [
        0, 0, 0, 0, 0, 0, -273.14, -273.14, 0, 0, -273.14, -273.14, 0, 0, 0, 0,
    ]

    public struct Row: Sendable {
        public let ecu: String
        public let session: Int
        public let date: Date
        public let values: [Double]   // 16 values, aligned to `signals`
        public init(ecu: String, session: Int, date: Date, values: [Double]) {
            self.ecu = ecu; self.session = session; self.date = date; self.values = values
        }
    }

    // MARK: - Engine serial in filename
    //
    // The datalog XML carries no engine serial (only the A/B marker), and the Austro
    // Wizard ignores filenames, so we stamp the serial into the filename of captures we
    // write and read it back on open. Token form: `…_SN<serial>_…`.

    /// Makes an engine serial safe to embed in a filename token (keeps A–Z/0–9/-).
    public static func sanitizeSerialForFilename(_ serial: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        return String(serial.filter { allowed.contains($0) })
    }

    /// Extracts the engine serial from a filename that carries an `SN<serial>` token
    /// (e.g. `DataLog_A_SNE4-B-01234_20261107_165355.ae3` → `E4-B-01234`). nil if absent.
    public static func engineSerialFromFilename(_ fileName: String) -> String? {
        parseCaptureFilename(fileName)?.engineSerial
    }

    /// Fields recovered from one of our capture filenames.
    public struct CaptureName: Sendable {
        public let ecu: String?           // "A" / "B" if present
        public let engineSerial: String?  // from an SN token, if present
        public let date: Date?            // UTC, from the yyyyMMdd[_HHmmss] tokens
    }

    /// Parses our `DataLog_<ECU>[_SN<serial>]_<yyyyMMdd>[_<HHmmss>]` capture filenames.
    /// Tolerant of the pre-serial form and of a uniquing `" (2)"` suffix. Returns nil
    /// for names that aren't ours (no `DataLog` prefix or no date) so callers can tell
    /// "recognized" from "unknown".
    public static func parseCaptureFilename(_ fileName: String) -> CaptureName? {
        var stem = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        if let r = stem.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) { stem.removeSubrange(r) } // drop " (2)"
        let toks = stem.split(separator: "_").map(String.init)
        guard toks.first == "DataLog" else { return nil }

        var ecu: String? = nil, serial: String? = nil, ymd: String? = nil, hms: String? = nil
        for t in toks.dropFirst() {
            if t == "A" || t == "B" { ecu = t }
            else if t.hasPrefix("SN"), t.count > 2 { serial = String(t.dropFirst(2)) }
            else if t.count == 8, t.allSatisfy(\.isNumber) { ymd = t }
            else if t.count == 6, t.allSatisfy(\.isNumber) { hms = t }
        }
        guard let ymd else { return nil }
        var c = DateComponents()
        c.year = Int(ymd.prefix(4)); c.month = Int(ymd.dropFirst(4).prefix(2)); c.day = Int(ymd.dropFirst(6).prefix(2))
        if let hms { c.hour = Int(hms.prefix(2)); c.minute = Int(hms.dropFirst(2).prefix(2)); c.second = Int(hms.dropFirst(4).prefix(2)) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return CaptureName(ecu: ecu, engineSerial: serial, date: cal.date(from: c))
    }

    /// Decodes both ECUs from decrypted `.ae3` XML. Returns rows in file order.
    public static func decode(xml: Data) -> [Row] {
        let parser = SectorParser()
        var out: [Row] = []
        for ecu in ["A", "B"] {
            guard let sectors = parser.parse(xml: xml, ecu: ecu), !sectors.isEmpty else { continue }
            out.append(contentsOf: decodeECU(ecu: ecu, sectors: sectors))
        }
        return out
    }

    /// Decodes raw flash sectors read directly from the ECU over CAN (same byte
    /// layout as the `.ae3` hexdump). `raw` is one full sector (incl. 2-byte header +
    /// trailing type code), as returned by the ECU sector-read.
    public static func decode(rawSectors: [(ecu: String, id: Int, raw: [UInt8])]) -> [Row] {
        var byEcu: [String: [Sector]] = [:]
        for s in rawSectors where s.raw.count > 10 {
            byEcu[s.ecu, default: []].append(makeSector(id: s.id, raw: s.raw))
        }
        var out: [Row] = []
        for ecu in ["A", "B"] {
            if let secs = byEcu[ecu], !secs.isEmpty { out.append(contentsOf: decodeECU(ecu: ecu, sectors: secs)) }
        }
        return out
    }

    /// Rebuilds the `RECMAN_HEXDUMP_DATLOG` XML from raw ECU sectors, for writing a `.ae3`
    /// (encrypt with `AE3Crypto.encryptAE3`). Readable by Wizard and by `decode(xml:)`.
    public static func buildHexdumpXML(sectors: [(ecu: String, id: Int, raw: [UInt8])],
                                       fileName: String) -> Data {
        let bTable: [Data] = (0...255).map { Data("<B>\($0)</B>".utf8) }
        var out = Data()
        out.reserveCapacity(sectors.reduce(0) { $0 + $1.raw.count * 9 } + 2048)
        func s(_ str: String) { out.append(contentsOf: str.utf8) }
        s("\u{FEFF}<?xml version=\"1.0\" encoding=\"utf-8\"?><RECMAN_HEXDUMP_DATLOG>")
        s("<FILE_ID><FILE_NAME>\(fileName)</FILE_NAME></FILE_ID>")
        for ecu in ["A", "B"] {
            let secs = sectors.filter { $0.ecu == ecu }.sorted { $0.id < $1.id }
            if secs.isEmpty { continue }
            s("<SECTORS xmlns=\"\(ecu)\">")
            for sec in secs {
                s("<SECTOR><ID>\(sec.id)</ID><DATA>")
                for b in sec.raw { out.append(bTable[Int(b)]) }
                s("</DATA></SECTOR>")
            }
            s("</SECTORS>")
        }
        s("</RECMAN_HEXDUMP_DATLOG>")
        return out
    }

    /// Builds a Sector from one raw flash-sector dump (shared by the XML and ECU paths).
    static func makeSector(id: Int, raw: [UInt8]) -> Sector {
        let n = raw.count
        let data = Array(raw[2..<(n - 8)])   // raw[2 .. n-8)
        let c = (raw[n-1], raw[n-2], raw[n-3], raw[n-4])
        let type: String
        switch c {
        case (0xFF, 0xFF, 0xFF, 0xFF): type = "notModified"
        case (0xFE, 0xFE, 0xFE, 0xFE): type = "erased"
        case (0xAA, 0xAA, 0xAA, 0xAA): type = "active"
        case (0xA8, 0xA8, 0xA8, 0xA8): type = "fullNotLocked"
        case (0x00, 0x00, 0x00, 0x00): type = "locked"
        default: type = "unknown"
        }
        return Sector(id: id, data: data, type: type)
    }

    // MARK: - per-ECU decode

    private static let PAY = 65528

    struct Sector { let id: Int; let data: [UInt8]; let type: String }

    private static func decodeECU(ecu: String, sectors rawSectors: [Sector]) -> [Row] {
        var keep = rawSectors.filter {
            $0.id > 15 && $0.id < 140 && $0.type != "notModified" && $0.type != "erased" && $0.type != "unknown"
        }
        guard !keep.isEmpty else { return [] }
        keep.sort { $0.id < $1.id }
        var activeIdx = keep.firstIndex { $0.type == "active" } ?? (keep.count - 1)
        if activeIdx < keep.count - 1 {
            let moved = Array(keep[(activeIdx + 1)...])
            keep.removeSubrange((activeIdx + 1)...)
            keep.insert(contentsOf: moved, at: 0)
        }
        activeIdx = 0
        var P: [UInt8] = []
        P.reserveCapacity(PAY * keep.count)
        // Each flash page is exactly PAY usable bytes; the page math (byteIndex / PAY ==
        // sector) depends on that. Normalize so a short/partial sector (e.g. a truncated
        // ECU read) can't shift every subsequent page boundary — pad with 0xFF (fill).
        for s in keep {
            if s.data.count == PAY { P.append(contentsOf: s.data) }
            else if s.data.count > PAY { P.append(contentsOf: s.data.prefix(PAY)) }
            else { P.append(contentsOf: s.data); P.append(contentsOf: [UInt8](repeating: 0xFF, count: PAY - s.data.count)) }
        }

        let sessions = decodeLeadInLeadOut(P)
        var rows: [Row] = []
        for (si, s) in sessions.enumerated() {
            rows.append(contentsOf: extractValues(P, s, ecu: ecu, session: si))
        }
        return rows
    }

    private struct Session { var leadInIx = 0; var leadOutIx = 0; var dtLeadIn = Date.distantPast; var dtLeadOut = Date.distantPast; var channels: [UInt16]? }

    private static func bcd(_ b: UInt8) -> Int { Int(b >> 4) * 10 + Int(b & 0xF) }

    private static func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")! ; return c }

    private static func mkTime(_ P: [UInt8], _ ix: Int) -> Date? {
        guard ix >= 0, ix + 5 < P.count else { return nil }
        let y = bcd(P[ix]), mo = bcd(P[ix+1]), d = bcd(P[ix+2]), h = bcd(P[ix+3]), mi = bcd(P[ix+4]), s = bcd(P[ix+5])
        guard y >= 0, y < 120, mo > 0, mo < 13, d > 0, d < 32, h >= 0, h < 24, mi >= 0, mi < 60, s >= 0, s < 60 else { return nil }
        var comps = DateComponents()
        comps.year = 2000 + y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi; comps.second = s
        return cal().date(from: comps)
    }

    private static func mkChanConf(_ P: [UInt8], _ ix: Int) -> [UInt16]? {
        guard ix >= 0, ix + 24 <= P.count else { return nil }
        var nib: [UInt8] = []; nib.reserveCapacity(48)
        for i in ix..<(ix + 24) { nib.append(P[i] >> 4); nib.append(P[i] & 0xF) }
        var ch: [UInt16] = []
        var j = 0
        while j + 2 < nib.count {
            var num = UInt16(nib[j]) << 8
            num |= UInt16(nib[j+1] & 0xF) << 4
            num |= UInt16(nib[j+2] & 0xF)
            ch.append(num); j += 3
        }
        return ch
    }

    private static func getLeadOutIndex(_ P: [UInt8], _ startIndex: Int) -> Int {
        var result = 0
        var num = startIndex
        while num > 25 {
            if P[num] == 0 {
                var b: UInt8 = 0; var broke = false
                var num2 = num
                while num2 > num - 25 { b = b &+ P[num2]; if b > 0 { broke = true; break }; num2 -= 1 }
                if !broke && b == 0 {
                    result = num + 7; b = 0
                    var num3 = result
                    while num3 > result - 32 { if num3 >= 0 && num3 < P.count { b = b &+ P[num3] }; num3 -= 1 }
                    if b == 0xFF {
                        result = num - 25 + 1
                        break
                    }
                    result = 0
                }
            }
            num -= 1
        }
        return result
    }

    private static func recLen(_ ch: [UInt16]) -> Int { let c = ch.count; return (c % 2 != 0) ? (c + 1) * 2 : c * 2 }

    private static func decodeLeadInLeadOut(_ P: [UInt8]) -> [Session] {
        var list: [Session] = []
        var num = P.count - 1
        if num <= 32 { return list }
        num = getLeadOutIndex(P, num)
        if num <= 32 { return list }
        list.append(Session(leadInIx: num + 64))
        var item = Session(leadOutIx: num)
        while num > 32 {
            num = getLeadOutIndex(P, num)
            item.leadInIx = num + 64
            list.append(item)
            item = Session(leadOutIx: num)
            if num <= 32 { break }
        }
        for i in 0..<list.count {
            var it = list[i]
            if i != list.count - 1 {
                it.dtLeadIn = mkTime(P, it.leadInIx - 32) ?? Date.distantPast
                it.channels = mkChanConf(P, it.leadInIx - 26)
            }
            if i != 0 {
                it.dtLeadOut = mkTime(P, it.leadOutIx + 25) ?? Date.distantPast
            }
            list[i] = it
        }
        if list.count > 1 {
            var last = list[list.count - 1]
            last.channels = list[list.count - 2].channels
            list[list.count - 1] = last
            var first = list[0]; findLeadOutFirst(P, &first); list[0] = first
            var l = list[list.count - 1]; findLeadInLast(P, &l); list[list.count - 1] = l
        }
        return list.filter { $0.leadOutIx - $0.leadInIx > 32 }
    }

    private static func findLeadOutFirst(_ P: [UInt8], _ it: inout Session) {
        guard let ch = it.channels else { return }
        let count = recLen(ch); var num = 0; var flag = false
        var i = it.leadInIx
        while i < P.count && !flag {
            if i + count < P.count - 1 {
                var st = i
                if scUp(&st, i + count) { i = st; continue }
                num += 1
                var j = 0
                while j < count && i + j < P.count && P[i + j] == 0xFF {
                    if j == count - 1 { flag = true; it.leadOutIx = i - count + 1; it.dtLeadOut = it.dtLeadIn.addingTimeInterval(Double(num - 1)) }
                    j += 1
                }
            } else {
                it.leadOutIx = i - count + 1; it.dtLeadOut = it.dtLeadIn.addingTimeInterval(Double(num - 1)); break
            }
            i += count
        }
    }

    private static func scUp(_ posStart: inout Int, _ posEnd: Int) -> Bool {
        let n = posEnd / PAY
        if posStart / PAY != n { posStart = n * PAY; return true }
        return false
    }

    private static func findLeadInLast(_ P: [UInt8], _ it: inout Session) {
        guard let ch = it.channels else { return }
        let count = recLen(ch); var num = 0; var num2 = it.leadOutIx - count
        while num2 > 31 {
            if scDown(num2, num2 + count) {
                var n3 = num2 + count
                while n3 >= num2 { n3 -= 1; if n3 < 0 || n3 >= P.count || P[n3] != 0xFF { break } }
                num2 = n3 - count + 1
            } else {
                num2 -= count
            }
            num += 1
        }
        it.leadInIx = num2; it.dtLeadIn = it.dtLeadOut.addingTimeInterval(Double(-num))
    }

    private static func scDown(_ lastVal: Int, _ firstVal: Int) -> Bool { (lastVal + 1) / PAY != firstVal / PAY }

    private static func extractValues(_ P: [UInt8], _ s: Session, ecu: String, session: Int) -> [Row] {
        guard let ch = s.channels else { return [] }
        let num = recLen(ch)
        var rows: [Row] = []
        var num3 = s.leadInIx
        var k = 0
        while num3 <= s.leadOutIx - (num - 1) {
            var i = num3 + 1
            let num4 = num3 + 1 + num
            if i / PAY != num4 / PAY {
                while i < num4 && i < s.leadOutIx && (i == s.leadInIx || i == s.leadOutIx || i % PAY != 0) { i += 1 }
                num3 = i; continue
            }
            var vals = [Double](repeating: 0, count: 16)
            var j = 0
            while j < num {
                let b = j >> 1
                let p = num3 + j
                if p + 1 >= P.count { break }
                let v = Int16(bitPattern: (UInt16(P[p]) << 8) | UInt16(P[p + 1]))
                if b < 16 { vals[b] = Double(v) * coef[b] + offset[b] }
                j += 2
            }
            rows.append(Row(ecu: ecu, session: session, date: s.dtLeadIn.addingTimeInterval(Double(k)), values: vals))
            k += 1; num3 += num
        }
        return rows
    }

    // MARK: - XML sector parsing (SAX)

    private final class SectorParser: NSObject, XMLParserDelegate {
        private var wantEcu = ""
        private var curEcu: String?
        private var curId: Int?
        private var curBytes: [UInt8] = []
        private var inB = false
        private var charBuf = ""
        private var sectors: [Sector] = []

        func parse(xml: Data, ecu: String) -> [Sector]? {
            wantEcu = ecu; curEcu = nil; sectors = []
            let p = XMLParser(data: xml)
            p.delegate = self
            guard p.parse() else { return sectors.isEmpty ? nil : sectors }
            return sectors
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            switch elementName {
            case "SECTORS":
                curEcu = attributeDict["xmlns"]
            case "SECTOR":
                curId = nil; curBytes = []; curBytes.reserveCapacity(65538)
            case "ID":
                charBuf = ""
            case "B":
                inB = true; charBuf = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            charBuf += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard curEcu == wantEcu else {
                if elementName == "SECTORS" { curEcu = nil }
                return
            }
            switch elementName {
            case "ID":
                curId = Int(charBuf.trimmingCharacters(in: .whitespacesAndNewlines))
            case "B":
                if let v = UInt8(charBuf.trimmingCharacters(in: .whitespacesAndNewlines)) { curBytes.append(v) }
                inB = false
            case "SECTOR":
                if let id = curId, curBytes.count > 10 { sectors.append(AE3.makeSector(id: id, raw: curBytes)) }
                curBytes = []
            case "SECTORS":
                curEcu = nil
            default: break
            }
            charBuf = ""
        }
    }
}
