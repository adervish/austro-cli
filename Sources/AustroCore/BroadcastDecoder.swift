import Foundation

public enum ECUSide: String, Codable, CaseIterable, Sendable {
    case a = "A", b = "B"
}

public enum BroadcastGroup: String, Codable, Sendable {
    case engine1, engine2
}

public enum DecodeError: Error, LocalizedError, Equatable {
    case invalidNode, invalidLength(Int), malformedLine(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidNode: "Engine node must be between 0 and 3."
        case .invalidLength(let count): "Engine broadcast requires 8 bytes; received \(count)."
        case .malformedLine(let line): "Invalid capture line \(line). Expected a three-digit CAN ID, #, and 16 hex digits."
        }
    }
}

public struct CANFrame: Sendable {
    public let id: UInt32
    public let data: [UInt8]
    public let isExtended: Bool
    public let isRemote: Bool

    public init(id: UInt32, data: [UInt8], isExtended: Bool = false, isRemote: Bool = false) {
        self.id = id
        self.data = data
        self.isExtended = isExtended
        self.isRemote = isRemote
    }
}

public struct Reading: Codable, Equatable, Sendable {
    public let name: String
    public let unit: String
    public let value: Double?
    public let status: String?

    public var display: String {
        if let status { return status }
        guard let value else { return "Not available" }
        return String(format: "%.1f", value) + (unit.isEmpty ? "" : " \(unit)")
    }
}

/// A single frame's readings, not a merged snapshot. Keeping the groups separate
/// lets a live transport expire each group independently when frames stop arriving.
public struct Broadcast: Codable, Equatable, Sendable {
    public let ecu: ECUSide
    public let node: Int
    public let group: BroadcastGroup
    public let canID: UInt32
    public let readings: [Reading]
}

/// Recovered from Wizard 1.3.7.438, Engine12.EngFunc1/EngFunc2 and
/// ServiceLayer's constructor. No hardware access or CAN transmit operations.
public struct BroadcastDecoder: Sendable {
    public let node: Int

    public init(node: Int = 0) throws {
        guard (0...3).contains(node) else { throw DecodeError.invalidNode }
        self.node = node
    }

    public func decode(_ frame: CANFrame) throws -> Broadcast? {
        guard !frame.isExtended, !frame.isRemote else { return nil }
        let ecu: ECUSide
        let group: BroadcastGroup
        switch frame.id {
        case 0x300 + UInt32(node): ecu = .a; group = .engine1
        case 0x310 + UInt32(node): ecu = .a; group = .engine2
        case 0x400 + UInt32(node): ecu = .b; group = .engine1
        case 0x410 + UInt32(node): ecu = .b; group = .engine2
        default: return nil
        }
        guard frame.data.count == 8 else { throw DecodeError.invalidLength(frame.data.count) }
        let b = frame.data.map(Int.init)
        func numeric(_ name: String, _ unit: String, _ raw: Int, _ unavailable: Int,
                     scale: Double = 1, offset: Double = 0) -> Reading {
            Reading(name: name, unit: unit,
                    value: raw == unavailable ? nil : Double(raw) * scale + offset,
                    status: nil)
        }
        func state(_ name: String, _ raw: Int, _ zero: String, _ one: String) -> Reading {
            Reading(name: name, unit: "", value: nil,
                    status: raw == 0 ? zero : raw == 1 ? one : "Not available")
        }
        let readings: [Reading]
        switch group {
        case .engine1:
            readings = [
                numeric("Propeller speed", "rpm", b[0] | (b[1] << 8), 0xFFFF),
                numeric("Oil pressure", "hPa", b[2] | ((b[3] & 0xF) << 8), 0xFFF, scale: 5),
                numeric("Oil temperature", "°C", b[4], 0xFF, offset: -50),
                numeric("Coolant temperature", "°C", b[5], 0xFF, offset: -50),
                numeric("Gearbox oil temperature", "°C", b[6], 0xFF, offset: -50)
            ]
        case .engine2:
            readings = [
                numeric("Battery voltage", "V", b[0], 0xFF, scale: 0.2),
                numeric("Engine performance", "%", b[4], 0xFF, scale: 0.5),
                numeric("Fuel flow", "L/h", b[5] | ((b[6] & 0xF) << 8), 0xFFF, scale: 0.1),
                state("Caution lamp", b[3] & 3, "Off", "On"),
                state("Fuel pressure warning", (b[2] >> 4) & 3, "OK", "Too low"),
                state("ECU status", (b[3] >> 2) & 3, "Active", "Passive"),
                state("Voter output", (b[3] >> 4) & 3, "ECU A", "ECU B")
            ]
        }
        return Broadcast(ecu: ecu, node: node, group: group, canID: frame.id, readings: readings)
    }
}
