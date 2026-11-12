import Foundation

/// Minimal CAN link abstraction so the ISO-TP/KWP layers are unit-testable with a mock.
public protocol CanLink {
    func send(id: UInt32, data: [UInt8]) throws
    /// Returns the next received frame, or nil on timeout.
    func recv(timeoutMs: Int) -> (id: UInt32, data: [UInt8])?
}

/// A `CanLink` that can be opened/closed and optionally log frames — the concrete 500 kbit/s
/// adapter the diagnostic reader drives. Platform backends: macOS → `DiagTransport` (PCBUSB),
/// Linux/WSL → `SocketCanLink` (SocketCAN). `listenOnly` opens receive-only (no TX/ACK) for
/// passive monitoring; diagnostics open with `listenOnly: false` so the ECU can be queried.
public protocol DiagChannel: CanLink, AnyObject {
    func open(listenOnly: Bool) throws
    func close()
    var onLog: (@Sendable (String) -> Void)? { get set }
}

public enum DiagError: Error, LocalizedError {
    case open(String), send(String), timeout(String), negative(service: UInt8, nrc: UInt8)
    case security(String), badResponse(String), notConnected, blockedService(UInt8)

    public var errorDescription: String? {
        switch self {
        case .blockedService(let sid):
            "Refused to transmit non-read-only service 0x\(String(sid, radix: 16)) to the ECU (safety guard)."
        case .open(let s): "Could not open the CAN channel for diagnostics: \(s)."
        case .send(let s): "CAN send failed: \(s)."
        case .timeout(let s): "No response from the ECU (\(s)). Check power, connector, 500 kbit/s."
        case .negative(let service, let nrc):
            "ECU rejected service 0x\(String(service, radix: 16)) — \(Self.nrcName(nrc)) (NRC 0x\(String(nrc, radix: 16)))."
        case .security(let s): "Security access failed: \(s)."
        case .badResponse(let s): "Unexpected ECU response: \(s)."
        case .notConnected: "Diagnostic transport not open."
        }
    }

    static func nrcName(_ nrc: UInt8) -> String {
        switch nrc {
        case 0x10: "general reject"
        case 0x11: "service not supported"
        case 0x12: "sub-function not supported"
        case 0x22: "conditions not correct"
        case 0x31: "request out of range"
        case 0x33: "security access denied"
        case 0x35: "invalid key"
        case 0x36: "exceeded number of attempts"
        case 0x37: "required time delay not expired"
        case 0x78: "response pending"
        default: "negative response"
        }
    }
}

#if os(macOS)
import CPCBUSB

/// Real transport over MacCAN/PCBUSB. Opens the channel **not** listen-only (diagnostics
/// must transmit and be ACKed by the ECU). Ground/engine-off operation.
public final class DiagTransport: DiagChannel {
    private static let channel: UInt16 = 0x51       // PCAN_USBBUS1
    private static let baud500k: UInt16 = 0x001C
    private static let statusOK: UInt32 = 0x0
    private static let statusEmpty: UInt32 = 0x20
    private static let msgExtended: UInt8 = 0x02
    private static let msgErr: UInt8 = 0x40
    private static let msgStatus: UInt8 = 0x80
    private var opened = false

    /// Optional verbose frame logger (TX/RX). Set for CLI/debug.
    public var onLog: (@Sendable (String) -> Void)?

    public init() {}

    private static func hex(_ d: [UInt8]) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }

    public func open(listenOnly: Bool = false) throws {
        let st = austro_pcan_open(Self.channel, Self.baud500k, listenOnly ? 1 : 0)
        guard st == Self.statusOK else { throw DiagError.open(Self.err(st)) }
        opened = true
    }

    public func close() {
        if opened { _ = austro_pcan_close(Self.channel); opened = false }
    }

    public func send(id: UInt32, data: [UInt8]) throws {
        guard opened else { throw DiagError.notConnected }
        var buf = data
        while buf.count < 8 { buf.append(0xFF) }          // diagnostic frames are DLC 8, 0xFF-padded
        onLog?(String(format: "TX %03X  %@", id, Self.hex(buf)))
        let st = buf.withUnsafeBufferPointer { austro_pcan_write(Self.channel, id, 8, $0.baseAddress) }
        guard st == Self.statusOK else { throw DiagError.send(Self.err(st)) }
    }

    public func recv(timeoutMs: Int) -> (id: UInt32, data: [UInt8])? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var id: UInt32 = 0, millis: UInt32 = 0
        var type: UInt8 = 0, len: UInt8 = 0
        var micros: UInt16 = 0
        var data = [UInt8](repeating: 0, count: 8)
        while Date() < deadline {
            let st = data.withUnsafeMutableBufferPointer {
                austro_pcan_read(Self.channel, &id, &type, &len, $0.baseAddress, &millis, &micros)
            }
            if st == Self.statusOK {
                if (type & Self.msgStatus) != 0 || (type & Self.msgErr) != 0 || (type & Self.msgExtended) != 0 { continue }
                let out = Array(data.prefix(Int(min(len, 8))))
                onLog?(String(format: "RX %03X  %@", id, Self.hex(out)))
                return (id, out)
            } else if st == Self.statusEmpty {
                usleep(200)
            } else {
                usleep(500)
            }
        }
        return nil
    }

    static func err(_ s: UInt32) -> String {
        var b = [CChar](repeating: 0, count: 256)
        austro_pcan_errtext(s, &b, UInt32(b.count))
        return b.prefix { $0 != 0 }.map { Character(UnicodeScalar(UInt8(bitPattern: $0))) }.reduce(into: "") { $0.append($1) }
    }
}
#endif
