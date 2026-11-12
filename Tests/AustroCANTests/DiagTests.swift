import Testing
@testable import AustroCAN

/// Scripted CAN link: `recv` returns queued frames in order; `send` is recorded.
private final class MockLink: CanLink {
    var inbox: [(UInt32, [UInt8])]
    var sent: [(UInt32, [UInt8])] = []
    init(_ frames: [(UInt32, [UInt8])]) { inbox = frames }
    func send(id: UInt32, data: [UInt8]) throws { sent.append((id, data)) }
    func recv(timeoutMs: Int) -> (id: UInt32, data: [UInt8])? { inbox.isEmpty ? nil : inbox.removeFirst() }
}

struct DiagTests {
    let tx: UInt32 = 0x7E0, rx: UInt32 = 0x7E8

    @Test func singleFrameRoundTrip() throws {
        // Response: SF len=3, payload 61 F3 2A
        let link = MockLink([(0x7E8, [0x03, 0x61, 0xF3, 0x2A, 0xFF, 0xFF, 0xFF, 0xFF])])
        let tp = IsoTp(link: link, txId: tx, rxId: rx)
        let resp = try tp.request([0x21, 0xF3])
        #expect(resp == [0x61, 0xF3, 0x2A])
        // request went out as a single frame with the correct length prefix
        #expect(link.sent.first?.1.prefix(3).elementsEqual([0x02, 0x21, 0xF3]) == true)
    }

    @Test func multiFrameResponseReassembles() throws {
        // FF declares 10 bytes (6 in FF) + one CF with the last 4.
        let ff: [UInt8] = [0x10, 0x0A, 0x61, 0xF3, 0x01, 0x02, 0x03, 0x04]
        let cf: [UInt8] = [0x21, 0x05, 0x06, 0x07, 0x08, 0xFF, 0xFF, 0xFF]
        let link = MockLink([(0x7E8, ff), (0x7E8, cf)])
        let tp = IsoTp(link: link, txId: tx, rxId: rx)
        let resp = try tp.request([0x21, 0xF3])
        #expect(resp == [0x61, 0xF3, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        // we must have sent a flow-control frame (0x30) after the first frame
        #expect(link.sent.contains { $0.1.first.map { $0 & 0xF0 } == 0x30 })
    }

    @Test func negativeResponseThrows() throws {
        // 0x7F <sid> <nrc=0x33 securityAccessDenied>
        let link = MockLink([(0x7E8, [0x03, 0x7F, 0x27, 0x33, 0xFF, 0xFF, 0xFF, 0xFF])])
        let tp = IsoTp(link: link, txId: tx, rxId: rx)
        #expect(throws: DiagError.self) { _ = try tp.request([0x27, 0x01]) }
    }

    @Test func pendingThenPositive() throws {
        // response-pending (0x7F 27 0x78) is skipped, then the real positive arrives
        let link = MockLink([
            (0x7E8, [0x03, 0x7F, 0x27, 0x78, 0xFF, 0xFF, 0xFF, 0xFF]),
            (0x7E8, [0x02, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ])
        let tp = IsoTp(link: link, txId: tx, rxId: rx)
        let resp = try tp.request([0x27, 0x01])
        #expect(resp == [0x67, 0x01])
    }

    @Test func seedKeyTransformIsDeterministic() {
        // Dummy mask: mask[0][0] = 0xAB, rest 0.
        var mask = [[UInt32]](repeating: [0, 0, 0, 0], count: 8)
        mask[0][0] = 0xAB
        // All four derived bytes index mask[0][0]=0xAB: 0x08^0xAB=0xA3, 0x00^0xAB=0xAB.
        let key = Kwp.computeKey(seed: [0x08, 0x00, 0x00, 0x00], mask: mask)
        #expect(key == [0xA3, 0xAB, 0xAB, 0xAB])
    }

    @Test func onlyReadOnlyServicesAreAllowed() {
        // The transmit whitelist must be exactly the read/session/unlock services
        // (0x1A ReadEcuIdentification for the engine serial; 0x18/0x17 DTC reads — all pure reads)…
        #expect(Kwp.readOnlySIDs == [0x81, 0x10, 0x27, 0x3E, 0x21, 0x20, 0x1A, 0x18, 0x17])
        // …and must NOT include any write/erase/program/reset/code/clear service.
        // 0x3B in particular is Engine_Serial_Write — the write counterpart we never send.
        for writeSid: UInt8 in [0x3B, 0x36, 0x31, 0x34, 0x14, 0x11, 0x2E, 0x3D, 0x2C] {
            #expect(!Kwp.readOnlySIDs.contains(writeSid))
        }
    }

    @Test func readsDTCsListThenDetail() throws {
        // List (0x58): count 1, id 0x1234, status 0x60. Detail (0x57): state 1, flags 0xE0 (active+stored).
        let list: [UInt8]   = [0x05, 0x58, 0x01, 0x12, 0x34, 0x60, 0xFF, 0xFF]
        let detail: [UInt8] = [0x05, 0x57, 0x01, 0x12, 0x34, 0xE0, 0xFF, 0xFF]
        let link = MockLink([(0x7E8, list), (0x7E8, detail)])
        let kwp = Kwp(tp: IsoTp(link: link, txId: tx, rxId: rx))
        let dtcs = try kwp.readDTCs()
        #expect(dtcs.count == 1)
        #expect(dtcs[0].id == 0x1234)
        #expect(dtcs[0].active == true)
        #expect(dtcs[0].stored == true)
        // ReadDTCByStatus request went out as 0x18 0x02 0xFF 0x00.
        #expect(link.sent.first?.1.prefix(5).elementsEqual([0x04, 0x18, 0x02, 0xFF, 0x00]) == true)
    }

    @Test func emptyDTCListReturnsNone() throws {
        let link = MockLink([(0x7E8, [0x02, 0x58, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])])
        let kwp = Kwp(tp: IsoTp(link: link, txId: tx, rxId: rx))
        #expect(try kwp.readDTCs().isEmpty)
    }

    @Test func seedKeyShiftUsesNextByte() {
        let mask = [[UInt32]](repeating: [0, 0, 0, 0], count: 8)
        // seed 20 02 00 00: j0 base = 0x20 >> (0x02 & 3 = 2) = 0x08; mask 0 -> 0x08.
        let key = Kwp.computeKey(seed: [0x20, 0x02, 0x00, 0x00], mask: mask)
        #expect(key[0] == 0x08)
    }
}
