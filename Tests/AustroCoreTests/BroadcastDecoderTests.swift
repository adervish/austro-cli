import Testing
@testable import AustroCore

struct BroadcastDecoderTests {
    @Test func testEngineeringUnitsAndBothSides() throws {
        let decoder = try BroadcastDecoder()
        let frames = try Capture.parse(Capture.syntheticExample)
        let result = try frames.compactMap { try decoder.decode($0) }
        #expect(result.count == 4)
        #expect(result.map(\.ecu) == [.a, .a, .b, .b])
        #expect(result[0].readings.compactMap(\.value) == [2300, 4500, 80, 75, 70])
        #expect(result[1].readings.compactMap(\.value) == [28, 75, 25])
        #expect(result[1].readings.compactMap(\.status) == ["Off", "OK", "Active", "ECU A"])
        #expect(result[3].readings.first { $0.name == "ECU status" }?.status == "Passive")
    }

    @Test func testUnavailableSentinelsDoNotBecomeMeasurements() throws {
        let decoder = try BroadcastDecoder()
        for id: UInt32 in [0x300, 0x310, 0x400, 0x410] {
            let result = try #require(try decoder.decode(CANFrame(id: id, data: Array(repeating: 0xFF, count: 8))))
            #expect(result.readings.allSatisfy { $0.value == nil })
            #expect(result.readings.allSatisfy { $0.display == "Not available" })
        }
    }

    @Test func testPackedFieldsIgnoreAdjacentBits() throws {
        let decoder = try BroadcastDecoder()
        let one = try #require(try decoder.decode(CANFrame(id: 0x300, data: [0, 1, 1, 0xF1, 0, 49, 50, 0xFF])))
        #expect(one.readings.compactMap(\.value) == [256, 1285, -50, -1, 0])
        let two = try #require(try decoder.decode(CANFrame(id: 0x310, data: [1, 255, 0xDF, 0xD5, 1, 1, 0xF1, 255])))
        #expect(abs(two.readings[2].value! - 25.7) < 0.0001)
        #expect(two.readings.compactMap(\.status) == ["On", "Too low", "Passive", "ECU B"])
    }

    @Test func testReservedStatusValues() throws {
        let decoder = try BroadcastDecoder()
        for raw: UInt8 in [2, 3] {
            let result = try #require(try decoder.decode(CANFrame(id: 0x310,
                data: [0, 0, raw << 4, raw | (raw << 2) | (raw << 4), 0, 0, 0, 0])))
            #expect(result.readings.compactMap(\.status) == Array(repeating: "Not available", count: 4))
        }
    }

    @Test func testNodesAndUnrelatedFrames() throws {
        let bytes = Array(repeating: UInt8(0), count: 8)
        for node in 0...3 {
            let decoder = try BroadcastDecoder(node: node)
            for base: UInt32 in [0x300, 0x310, 0x400, 0x410] {
                #expect(try decoder.decode(CANFrame(id: base + UInt32(node), data: bytes)) != nil)
            }
            #expect(try decoder.decode(CANFrame(id: 0x7E8, data: bytes)) == nil)
        }
        let decoder = try BroadcastDecoder()
        #expect(try decoder.decode(CANFrame(id: 0x301, data: bytes)) == nil)
        #expect(throws: DecodeError.self) { try BroadcastDecoder(node: -1) }
        #expect(throws: DecodeError.self) { try BroadcastDecoder(node: 4) }
    }

    @Test func testRejectsWrongFrameTypesAndMalformedLengths() throws {
        let decoder = try BroadcastDecoder()
        let bytes = Array(repeating: UInt8(0), count: 8)
        #expect(try decoder.decode(CANFrame(id: 0x300, data: bytes, isExtended: true)) == nil)
        #expect(try decoder.decode(CANFrame(id: 0x300, data: bytes, isRemote: true)) == nil)
        for length in [0, 6, 7, 9, 64] {
            #expect(throws: DecodeError.self) { try decoder.decode(CANFrame(id: 0x300, data: Array(repeating: 0, count: length))) }
        }
    }

    @Test func testCaptureParsingIsStrictAndReportsLine() throws {
        #expect(try Capture.parse("; comment\r\n300#fc088403827d7800\r\n").count == 1)
        for invalid in ["800#0000000000000000", "300#0", "300#000000000000000G", "300##0000000000000000", "300#0000 00000000000", "300#+000000000000000"] {
            #expect(throws: DecodeError.malformedLine(2)) {
                try Capture.parse("; heading\n" + invalid)
            }
        }
    }
}

#if canImport(CommonCrypto)
struct AE3WriteTests {
    @Test func encryptDecryptRoundTrips() throws {
        let sectors: [(ecu: String, id: Int, raw: [UInt8])] = [
            ("A", 61, (0..<65538).map { UInt8($0 & 0xFF) }),
        ]
        let xml = AE3.buildHexdumpXML(sectors: sectors, fileName: "RoundTrip.xml")
        let pass = "unit-test-pass"
        let enc = try AE3Crypto.encryptAE3(xml: xml, passphrase: pass)
        let dec = try AE3Crypto.decryptAE3(enc, passphrase: pass)
        #expect(dec == xml)
        // and the rebuilt XML decodes to the same sectors the raw path would
        #expect(String(decoding: xml, as: UTF8.self).contains("<SECTORS xmlns=\"A\">"))
    }
}
#endif
