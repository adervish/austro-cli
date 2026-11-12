import Testing
import Foundation
@testable import AustroCore

struct CaptureNameTests {
    private func comps(_ d: Date) -> (Int, Int, Int, Int, Int, Int) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return (c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    @Test func parsesWithSerial() throws {
        let p = try #require(AE3.parseCaptureFilename("DataLog_A_SNE4-B-01234_20261107_165355.ae3"))
        #expect(p.ecu == "A")
        #expect(p.engineSerial == "E4-B-01234")
        #expect(comps(try #require(p.date)) == (2026, 11, 7, 16, 53, 55))
        #expect(AE3.engineSerialFromFilename("DataLog_A_SNE4-B-01234_20261107_165355.ae3") == "E4-B-01234")
    }

    @Test func parsesWithoutSerial() throws {
        let p = try #require(AE3.parseCaptureFilename("DataLog_B_20261107_165750.ae3"))
        #expect(p.ecu == "B")
        #expect(p.engineSerial == nil)
        #expect(comps(try #require(p.date)) == (2026, 11, 7, 16, 57, 50))
    }

    @Test func parsesLegacyDateOnly() throws {
        let p = try #require(AE3.parseCaptureFilename("DataLog_20240819.ae3"))
        #expect(p.ecu == nil)
        #expect(p.engineSerial == nil)
        #expect(comps(try #require(p.date)) == (2024, 8, 19, 0, 0, 0))
    }

    @Test func toleratesUniquingSuffix() throws {
        let p = try #require(AE3.parseCaptureFilename("DataLog_A_SN1234_20261107_165355 (2).ae3"))
        #expect(p.engineSerial == "1234")
        #expect(p.ecu == "A")
    }

    @Test func rejectsForeignNames() {
        #expect(AE3.parseCaptureFilename("random.ae3") == nil)
        #expect(AE3.parseCaptureFilename("Engine_Log_20261107.xml") == nil)
    }
}
