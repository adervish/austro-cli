import Testing
import Foundation
@testable import AustroCore

struct HealthTests {
    /// Builds `n` rows; `cruise` controls lever/rpm so samples count as cruise, and a few
    /// signals get fixed values for predictable stats.
    private func flight(ecu: String, n: Int, cruise: Bool,
                        rail: Double = 1500, oilP: Double = 4000, batt: Double = 27) -> [AE3.Row] {
        let base = Date(timeIntervalSince1970: 1_000_000)
        return (0..<n).map { i in
            var v = [Double](repeating: 0, count: 16)
            v[AE3.Sig.lever] = cruise ? 70 : 0
            v[AE3.Sig.rpm]   = cruise ? 2000 : 0      // in the 1900–2200 oil band
            v[AE3.Sig.rail]  = rail
            v[AE3.Sig.oilP]  = oilP
            v[AE3.Sig.battery] = batt
            v[AE3.Sig.ambient] = 1000; v[AE3.Sig.boost] = 2500   // boost ratio 2.5
            v[AE3.Sig.coolant] = 80; v[AE3.Sig.load] = 70
            return AE3.Row(ecu: ecu, session: 0, date: base.addingTimeInterval(Double(i)), values: v)
        }
    }

    @Test func scoresASteadyCruiseFlight() throws {
        let h = try #require(AE3.health(a: flight(ecu: "A", n: 400, cruise: true), b: []))
        #expect(h.cruiseSamples == 400)
        #expect(abs(h.railMean - 1500) < 0.001)
        #expect(h.railStd < 0.001)                 // constant rail ⇒ zero spread
        #expect(abs(h.oilPMedian - 4000) < 0.001)
        #expect(abs(h.batteryMin - 27) < 0.001)
        #expect(abs(h.boostRatioMean - 2.5) < 0.001)
        #expect(h.divOilP == nil)                  // no B ⇒ no divergence
    }

    @Test func rejectsTooShortOrNoCruise() {
        #expect(AE3.health(a: flight(ecu: "A", n: 200, cruise: true), b: []) == nil)  // < 300 samples
        #expect(AE3.health(a: flight(ecu: "A", n: 400, cruise: false), b: []) == nil) // no cruise
    }

    @Test func computesABDivergence() throws {
        let a = flight(ecu: "A", n: 400, cruise: true, oilP: 4000)
        let b = flight(ecu: "B", n: 400, cruise: true, oilP: 4050)   // B reads 50 higher
        let h = try #require(AE3.health(a: a, b: b))
        let div = try #require(h.divOilP)
        #expect(abs(div - 50) < 0.001)
    }
}
