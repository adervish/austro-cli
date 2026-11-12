import Foundation

/// ISO-TP (ISO 15765-2) over classic CAN, ported from the decompiled Wizard `KWP2000.cs`,
/// including the Austro "226-streaming" extension used for bulk sector reads.
///
/// The standard SF/FF/CF/FC path (session, security, status) is fully exercised offline.
/// The 226-streaming bulk path is implemented from the decompiled logic but **must be
/// validated against a live ECU** — it is the field-test item.
public final class IsoTp {
    private let link: CanLink
    private let txId: UInt32
    private let rxId: UInt32
    private var blockSize: UInt8 = 16
    private var stMin: UInt8 = 1
    private let streamSentinel = 226   // MAX_FF_DL — "large/continued transfer" marker

    public init(link: CanLink, txId: UInt32, rxId: UInt32) {
        self.link = link; self.txId = txId; self.rxId = rxId
    }

    /// Send a request and return the response payload (bounded; for session/security/status).
    public func request(_ payload: [UInt8], timeoutMs: Int = 3000) throws -> [UInt8] {
        try sendPayload(payload)
        return try receive(expectedLen: nil, timeoutMs: timeoutMs)
    }

    /// Bulk request (sector read): collect `expectedLen` bytes via 226-streaming.
    public func requestBulk(_ payload: [UInt8], expectedLen: Int, timeoutMs: Int = 20000) throws -> [UInt8] {
        try sendPayload(payload)
        return try receive(expectedLen: expectedLen, timeoutMs: timeoutMs)
    }

    // MARK: - send

    private func sendPayload(_ payload: [UInt8]) throws {
        let len = payload.count
        if len < 8 {
            try link.send(id: txId, data: [UInt8(len)] + payload)   // Single Frame
            return
        }
        // First Frame
        var ff: [UInt8] = [UInt8((len >> 8) | 0x10), UInt8(len & 0xFF)]
        ff.append(contentsOf: payload[0..<6])
        try link.send(id: txId, data: ff)
        guard try waitFlowControl() else { throw DiagError.timeout("no flow control for request") }
        // Consecutive Frames
        var idx = 6, sn: UInt8 = 1, sinceFC = 0
        while idx < len {
            if blockSize != 0 && sinceFC == Int(blockSize) {
                guard try waitFlowControl() else { throw DiagError.timeout("no flow control mid-request") }
                sinceFC = 0
            }
            if stMin > 0 { usleep(UInt32(stMin) * 1000) }
            let take = min(7, len - idx)
            var cf: [UInt8] = [(sn & 0xF) | 0x20]
            cf.append(contentsOf: payload[idx..<idx + take])
            try link.send(id: txId, data: cf)
            idx += take
            sn = sn == 15 ? 0 : sn + 1
            sinceFC += 1
        }
    }

    private func waitFlowControl(timeoutMs: Int = 3000) throws -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            guard let (id, d) = link.recv(timeoutMs: 50), id == rxId, !d.isEmpty else { continue }
            if d[0] & 0xF0 == 0x30 {          // Flow Control
                if d.count > 1 { blockSize = d[1] }
                if d.count > 2 { stMin = d[2] }
                return true
            }
        }
        return false
    }

    // MARK: - receive

    private func receive(expectedLen: Int?, timeoutMs: Int) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var payload: [UInt8] = []
        var ffDl = 0
        var datacount = 0
        var streaming = false
        var packetcount = 0

        func finish() throws -> [UInt8] {
            if payload.count >= 3, payload[0] == 0x7F {         // negative response
                throw DiagError.negative(service: payload[1], nrc: payload[2])
            }
            return payload
        }

        while Date() < deadline {
            guard let (id, d) = link.recv(timeoutMs: 100), id == rxId, !d.isEmpty else { continue }
            switch d[0] & 0xF0 {
            case 0x00:   // Single Frame
                var n = Int(d[0] & 0xF); if n > 7 { n = 7 }
                let p = Array(d[1..<min(d.count, 1 + n)])
                // response-pending (0x7F sid 0x78): keep waiting
                if p.count == 3, p[0] == 0x7F, p[2] == 0x78 { continue }
                payload = p
                return try finish()

            case 0x10:   // First Frame
                if !streaming {
                    payload.removeAll()
                    ffDl = Int(d[1]); streaming = (ffDl == streamSentinel)
                    payload.append(contentsOf: d[2..<min(d.count, 8)])
                    datacount = 6
                } else {
                    // continuation FF during streaming: 4 payload bytes, reset window
                    ffDl = Int(d[1])
                    if d.count > 4 { payload.append(contentsOf: d[4..<min(d.count, 8)]) }
                    datacount = 6
                }
                packetcount = 0
                try sendFlowControl()

            case 0x20:   // Consecutive Frame
                packetcount += 1
                if ffDl - datacount > 7 {
                    payload.append(contentsOf: d[1..<min(d.count, 8)])
                    datacount += 7
                    if blockSize != 0 && packetcount == Int(blockSize) { try sendFlowControl(); packetcount = 0 }
                } else {
                    let rem = max(0, ffDl - datacount)
                    if rem > 0 { payload.append(contentsOf: d[1..<min(d.count, 1 + rem)]) }
                    datacount += rem
                    if !streaming { return try finish() }
                }
                if streaming, let exp = expectedLen, payload.count >= exp {
                    return Array(payload.prefix(exp))
                }

            default:     // Flow Control etc. — ignore here
                break
            }
        }
        if streaming, let exp = expectedLen, !payload.isEmpty {
            return Array(payload.prefix(min(exp, payload.count)))   // best-effort on timeout
        }
        throw DiagError.timeout("incomplete ISO-TP response (\(payload.count) bytes)")
    }

    private func sendFlowControl(_ fs: UInt8 = 0) throws {
        try link.send(id: txId, data: [fs | 0x30, blockSize, stMin])
    }
}
