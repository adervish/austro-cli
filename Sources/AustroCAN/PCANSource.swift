#if os(macOS)
import Foundation
import CPCBUSB
import AustroCore

/// Identity read back from the adapter after a channel is opened.
public struct PCANDeviceInfo: Sendable, Equatable {
    public let hardwareName: String
    public let firmware: String
    public let partNumber: String
    public let controllerNumber: UInt32
}

/// A received CAN frame with the host arrival time.
public struct TimedFrame: Sendable {
    public let frame: CANFrame
    public let received: Date
}

public enum PCANError: Error, LocalizedError {
    case openFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let text): "Could not open the PCAN-USB channel: \(text)."
        }
    }
}

/// Receive-only transport over the MacCAN/PCBUSB library for the AE300 adapter.
///
/// Opens PCAN-USB channel 1 at 500 kbit/s in listen-only mode (never transmits
/// or ACKs, safe on a live engine bus). Received frames and bus errors are
/// delivered through `AsyncStream`s; hardware access is kept out of `AustroCore`
/// so the decoder stays portable.
public final class PCANSource: @unchecked Sendable {
    // PCAN-Basic constants (stable ABI values from PCBUSB.h).
    private static let channel: UInt16 = 0x51       // PCAN_USBBUS1
    private static let baud500k: UInt16 = 0x001C    // PCAN_BAUD_500K
    private static let statusOK: UInt32 = 0x0       // PCAN_ERROR_OK
    private static let statusEmpty: UInt32 = 0x20   // PCAN_ERROR_QRCVEMPTY
    private static let paramHardwareName: UInt8 = 0x0E
    private static let paramControllerNumber: UInt8 = 0x10
    private static let paramFirmware: UInt8 = 0x29
    private static let paramPartNumber: UInt8 = 0x2D
    private static let msgRTR: UInt8 = 0x01
    private static let msgExtended: UInt8 = 0x02
    private static let msgErrFrame: UInt8 = 0x40
    private static let msgStatus: UInt8 = 0x80

    public let frames: AsyncStream<TimedFrame>
    public let errors: AsyncStream<String>
    private let frameContinuation: AsyncStream<TimedFrame>.Continuation
    private let errorContinuation: AsyncStream<String>.Continuation

    private let lock = NSLock()
    private var running = false
    private var thread: Thread?

    public init() {
        (frames, frameContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        (errors, errorContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Opens the channel and starts receiving on a background thread.
    /// Returns the adapter identity. Throws `PCANError.openFailed` on failure.
    @discardableResult
    public func start(listenOnly: Bool = true) throws -> PCANDeviceInfo {
        lock.lock()
        if running { lock.unlock(); return currentInfo() }
        lock.unlock()

        let st = austro_pcan_open(Self.channel, Self.baud500k, listenOnly ? 1 : 0)
        guard st == Self.statusOK else {
            throw PCANError.openFailed(Self.errorText(st))
        }
        let info = currentInfo()

        lock.lock(); running = true; lock.unlock()
        let worker = Thread { [weak self] in self?.loop() }
        worker.name = "AustroPCANReceive"
        worker.stackSize = 512 * 1024
        thread = worker
        worker.start()
        return info
    }

    /// Stops receiving and closes the channel.
    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        while thread?.isExecuting == true { usleep(5_000) }
        thread = nil
        _ = austro_pcan_close(Self.channel)
    }

    private func loop() {
        var id: UInt32 = 0
        var type: UInt8 = 0
        var len: UInt8 = 0
        var millis: UInt32 = 0
        var micros: UInt16 = 0
        var data = [UInt8](repeating: 0, count: 8)

        while true {
            lock.lock(); let go = running; lock.unlock()
            if !go { break }

            let st = data.withUnsafeMutableBufferPointer { buf in
                austro_pcan_read(Self.channel, &id, &type, &len, buf.baseAddress, &millis, &micros)
            }

            if st == Self.statusOK {
                // Skip status and error frames; forward data/remote frames only.
                if (type & Self.msgStatus) != 0 || (type & Self.msgErrFrame) != 0 { continue }
                let count = Int(min(len, 8))
                let frame = CANFrame(
                    id: id,
                    data: Array(data.prefix(count)),
                    isExtended: (type & Self.msgExtended) != 0,
                    isRemote: (type & Self.msgRTR) != 0
                )
                frameContinuation.yield(TimedFrame(frame: frame, received: Date()))
            } else if st == Self.statusEmpty {
                usleep(2_000)
            } else {
                errorContinuation.yield(Self.errorText(st))
                usleep(10_000)
            }
        }
    }

    // MARK: - parameter helpers

    private func currentInfo() -> PCANDeviceInfo {
        PCANDeviceInfo(
            hardwareName: Self.string(Self.paramHardwareName),
            firmware: Self.string(Self.paramFirmware),
            partNumber: Self.string(Self.paramPartNumber),
            controllerNumber: Self.u32(Self.paramControllerNumber)
        )
    }

    private static func string(_ param: UInt8) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let st = austro_pcan_get_string(channel, param, &buf, UInt32(buf.count))
        guard st == statusOK else { return "" }
        return cString(buf)
    }

    private static func u32(_ param: UInt8) -> UInt32 {
        var value: UInt32 = 0
        _ = austro_pcan_get_u32(channel, param, &value)
        return value
    }

    static func errorText(_ status: UInt32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        austro_pcan_errtext(status, &buf, UInt32(buf.count))
        return cString(buf)
    }

    private static func cString(_ buf: [CChar]) -> String {
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
#endif
