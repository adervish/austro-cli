import AustroCore
import AustroCAN
import Foundation

// austro — portable, read-only Austro AE300 CAN tool. Three modes:
//   dump   — pull the datalogger flash (last N hours) and emit CSV
//   live   — stream live engine telemetry (listen-only)
//   faults — read stored fault codes (DTCs)
// Backend is chosen at compile time: macOS → PCAN-USB (PCBUSB); Linux/WSL → SocketCAN.

func errln(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// The platform CAN backend. On Linux the interface comes from $CAN_IF (default can0).
func makeChannel() -> DiagChannel {
    #if os(macOS)
    return DiagTransport()
    #elseif os(Linux)
    return SocketCanLink(ifname: ProcessInfo.processInfo.environment["CAN_IF"] ?? "can0")
    #else
    fatalError("austro: unsupported platform (need macOS/PCBUSB or Linux/SocketCAN)")
    #endif
}

func diagMessage(_ e: Error) -> String { (e as? DiagError)?.errorDescription ?? e.localizedDescription }

func usage() {
    errln("""
    austro — Austro AE300 CAN tool (read-only)

    Usage:
      austro dump [A|B] [hours|all] [--csv FILE] [--no-ae3]
                                                   Read datalogger flash. Writes a .ae3 to the
                                                   current dir (--no-ae3 to skip) + CSV (stdout/FILE).
      austro live [seconds] [node]                 Stream live engine telemetry (listen-only)
      austro faults [A|B]                          Read stored fault codes (DTCs)

    Backend: macOS = PCAN-USB (PCBUSB);  Linux/WSL = SocketCAN ($CAN_IF, default can0).
    dump & faults transmit diagnostic requests — ground, engine off. Never writes ECU flash.
    (.ae3 writing is macOS-only; on Linux, dump emits CSV only.)
    """)
}

// MARK: - CSV

func csvNum(_ v: Double) -> String {
    let r = (v * 1000).rounded() / 1000
    if r == r.rounded() { return String(Int(r)) }
    var s = String(format: "%.3f", r)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

func toCSV(_ rows: [AE3.Row]) -> String {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"; df.timeZone = TimeZone(identifier: "UTC")
    var s = "ecu,session,timestamp"
    for sig in AE3.signals { s += ",\(sig.name) [\(sig.unit)]" }
    s += "\n"
    for r in rows {
        s += "\(r.ecu),\(r.session),\(df.string(from: r.date))"
        for v in r.values { s += ",\(csvNum(v))" }
        s += "\n"
    }
    return s
}

// MARK: - modes

func runDump(_ a: [String]) {
    let ecu = (a.first?.uppercased() == "B") ? "B" : "A"
    let hoursArg = a.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 }
    let hours: Int? = hoursArg == nil ? 1 : (hoursArg!.lowercased() == "all" ? nil : Int(hoursArg!))
    var csvPath: String?
    if let i = a.firstIndex(of: "--csv"), i + 1 < a.count { csvPath = a[i + 1] }
    // By default also save the encrypted .ae3 (serial-tagged, never-overwriting) to the
    // current directory; --no-ae3 skips it. (.ae3 writing is macOS-only; Linux emits CSV only.)
    let saveDir: URL? = a.contains("--no-ae3") ? nil : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    do {
        let rows = try EcuDatalogReader().read(
            link: makeChannel(), ecu: ecu, hours: hours, verbose: true, saveAe3To: saveDir,
            log: { errln($0) },
            onSaved: { errln("Saved \($0.path)") })
        let csv = toCSV(rows)
        if let p = csvPath {
            try csv.write(toFile: p, atomically: true, encoding: .utf8)
            errln("Wrote \(rows.count) row(s) to \(p)")
        } else {
            FileHandle.standardOutput.write(Data(csv.utf8))
        }
    } catch {
        errln("ERROR: \(diagMessage(error))"); exit(1)
    }
}

func runLive(_ a: [String]) {
    let seconds = a.first.flatMap { Double($0) } ?? 5
    let node = a.dropFirst().first.flatMap { Int($0) } ?? 0
    let ch = makeChannel()
    do { try ch.open(listenOnly: true) }
    catch { errln("ERROR: \(diagMessage(error))"); exit(1) }
    defer { ch.close() }
    guard let dec = try? BroadcastDecoder(node: node) else { errln("decoder init failed"); exit(1) }
    errln("Listening \(Int(seconds))s at 500 kbit/s (listen-only), node \(node)…")
    let deadline = Date().addingTimeInterval(seconds)
    var count = 0
    while Date() < deadline {
        guard let (id, data) = ch.recv(timeoutMs: 200) else { continue }
        count += 1
        if let b = try? dec.decode(CANFrame(id: id, data: data)) {
            let vals = b.readings.map { "\($0.name)=\($0.display)" }.joined(separator: ", ")
            print(String(format: "ECU %@ %@ 0x%03X: %@",
                         b.ecu.rawValue, b.group == .engine1 ? "ENG1" : "ENG2", b.canID, vals))
        }
    }
    errln("\(count) frame(s) in \(Int(seconds))s")
}

func runFaults(_ a: [String]) {
    let ecu = (a.first?.uppercased() == "B") ? "B" : "A"
    let txId: UInt32 = ecu == "A" ? 0x7E0 : 0x7E1
    let rxId: UInt32 = ecu == "A" ? 0x7E8 : 0x7E9
    let ch = makeChannel()
    do { try ch.open(listenOnly: false) }
    catch { errln("ERROR: \(diagMessage(error))"); exit(1) }
    defer { ch.close() }
    let kwp = Kwp(tp: IsoTp(link: ch, txId: txId, rxId: rxId))
    do {
        try kwp.startCommunication()
        try kwp.startDiagnosticSession(mode: 0x84)       // diagnostic session
        var dtcs: [Kwp.Dtc]
        do {
            dtcs = try kwp.readDTCs()
        } catch DiagError.negative(_, let nrc) where nrc == 0x33 {   // security required
            guard let mask = DiagSecurity.resolveMask() else {
                throw DiagError.security("fault read needs security access, but no key mask at ~/.config/austro/ae3-ukey.json")
            }
            errln("ECU requires security access for DTCs — unlocking…")
            try kwp.securityAccess(mask: mask)
            dtcs = try kwp.readDTCs()
        }
        kwp.stopSession()
        if dtcs.isEmpty {
            print("No fault codes stored on ECU \(ecu).")
        } else {
            print("ECU \(ecu) — \(dtcs.count) fault code(s):")
            for d in dtcs {
                let state = [d.active ? "active" : nil, d.stored ? "stored" : nil].compactMap { $0 }.joined(separator: "+")
                print(String(format: "  0x%04X  %@  freq=%d", d.id, state.isEmpty ? "—" : state, d.frequency))
            }
        }
    } catch {
        errln("ERROR: \(diagMessage(error))"); exit(1)
    }
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage(); exit(2) }
let rest = Array(args.dropFirst())
switch cmd {
case "dump":   runDump(rest)
case "live":   runLive(rest)
case "faults": runFaults(rest)
case "-h", "--help", "help": usage()
default: errln("austro: unknown command '\(cmd)'"); usage(); exit(2)
}
