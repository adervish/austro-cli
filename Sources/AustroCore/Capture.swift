import Foundation

/// Minimal offline fixture format: `300#FC088403827D7800` (one frame per line).
/// This is not a PCAN .trc or Wizard .ae3/.aew parser. All IDs are hex, standard CAN.
public enum Capture {
    public static func parse(_ text: String) throws -> [CANFrame] {
        var frames: [CANFrame] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            let parts = line.split(separator: "#", omittingEmptySubsequences: false)
            let hex = Set("0123456789abcdefABCDEF")
            guard parts.count == 2, parts[0].count == 3, parts[1].count == 16,
                  parts[0].allSatisfy({ hex.contains($0) }),
                  parts[1].allSatisfy({ hex.contains($0) }),
                  let id = UInt32(parts[0], radix: 16), id <= 0x7FF else {
                throw DecodeError.malformedLine(index + 1)
            }
            let chars = Array(parts[1])
            let bytes = stride(from: 0, to: 16, by: 2).map {
                UInt8(String(chars[$0...$0 + 1]), radix: 16)!
            }
            frames.append(CANFrame(id: id, data: bytes))
        }
        return frames
    }

    public static let syntheticExample = """
    ; Synthetic example. Not captured from an engine.
    300#FC088403827D7800
    310#8C00000096FA0000
    400#FC088403827D7800
    410#8C00000496FA0000
    """
}
