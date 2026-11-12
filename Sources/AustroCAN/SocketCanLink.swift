#if os(Linux)
import Foundation
import CSocketCAN

/// Linux/WSL CAN backend over SocketCAN (`can0` by default). Bring the interface up first:
///   sudo ip link set can0 up type can bitrate 500000
/// (on WSL2, attach the PEAK adapter with `usbipd` so the `peak_usb` module exposes `can0`).
/// True controller listen-only is an `ip link` setting; at the socket level we simply never
/// transmit when opened read-only.
public final class SocketCanLink: DiagChannel {
    private let ifname: String
    private var fd: Int32 = -1
    public var onLog: (@Sendable (String) -> Void)?

    public init(ifname: String = "can0") { self.ifname = ifname }

    public func open(listenOnly: Bool = false) throws {
        fd = austro_scan_open(ifname)
        guard fd >= 0 else {
            throw DiagError.open("SocketCAN interface \(ifname) not available — bring it up with "
                + "`sudo ip link set \(ifname) up type can bitrate 500000`")
        }
    }

    public func close() { if fd >= 0 { austro_scan_close(fd); fd = -1 } }

    public func send(id: UInt32, data: [UInt8]) throws {
        guard fd >= 0 else { throw DiagError.notConnected }
        var buf = data
        while buf.count < 8 { buf.append(0xFF) }           // diagnostic frames are DLC 8, 0xFF-padded
        onLog?(String(format: "TX %03X  %@", id, Self.hex(buf)))
        let rc = buf.withUnsafeBufferPointer { austro_scan_send(fd, id, $0.baseAddress, 8) }
        guard rc == 0 else { throw DiagError.send("SocketCAN write failed on \(ifname)") }
    }

    public func recv(timeoutMs: Int) -> (id: UInt32, data: [UInt8])? {
        guard fd >= 0 else { return nil }
        var id: UInt32 = 0, len: UInt8 = 0
        var data = [UInt8](repeating: 0, count: 8)
        let rc = data.withUnsafeMutableBufferPointer {
            austro_scan_recv(fd, &id, $0.baseAddress, &len, Int32(timeoutMs))
        }
        guard rc == 1 else { return nil }
        let out = Array(data.prefix(Int(min(len, 8))))
        onLog?(String(format: "RX %03X  %@", id, Self.hex(out)))
        return (id, out)
    }

    private static func hex(_ d: [UInt8]) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
#endif
