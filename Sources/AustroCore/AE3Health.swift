import Foundation

// Per-flight engine-health snapshot, ported verbatim from scripts/ae3-metrics.py so the
// in-app numbers match the offline analysis. Signal indices are the fixed `AE3.signals`
// order; `Row.values` are already engineering units, so thresholds carry over directly.

extension AE3 {
    /// Named signal indices used by the health math (matches `AE3.signals` order).
    enum Sig {
        static let boost = 0, ambient = 1, rpm = 2, oilP = 3, rail = 4, lever = 5
        static let coolant = 6, battery = 8, fuelLP = 9, gearbox = 10, oilTemp = 11
        static let load = 15
    }

    public struct FlightHealth: Sendable {
        public let ecu: String
        public let session: Int
        public let start: Date
        public let durationMin: Int
        public let cruiseSamples: Int
        public let railMean: Double, railStd: Double
        public let boostRatioMean: Double, boostRatioMax: Double
        public let oilPMedian: Double, oilPp5: Double, oilPMin: Double   // @1900–2200 rpm
        public let loadMean: Double, loadMax: Double
        public let coolantMax: Double, oilTempMax: Double, gearboxMax: Double
        public let batteryMin: Double, batteryMean: Double
        public let fuelLPMean: Double, fuelLPMin: Double
        /// mean |A−B| (rail-aligned) for a few sensors; nil when there's no paired B flight.
        public let divOilP: Double?, divRail: Double?, divBoost: Double?, divCoolant: Double?
    }

    /// Computes a health snapshot for one flight from its ECU-A rows (primary) and, when
    /// available, the paired ECU-B rows (for A/B sensor divergence). Returns nil if the
    /// session isn't a real flight: < 300 logged samples or < 120 cruise samples.
    public static func health(a: [Row], b: [Row]) -> FlightHealth? {
        guard a.count >= 300, let first = a.first else { return nil }
        // Every accessor below indexes up to Sig.load (15); bail if any row is short
        // (a truncated/malformed sector) rather than crash on an out-of-range subscript.
        guard a.allSatisfy({ $0.values.count > Sig.load }),
              b.allSatisfy({ $0.values.count > Sig.load }) else { return nil }
        func col(_ rows: [Row], _ i: Int) -> [Double] { rows.map { $0.values[i] } }
        func clean(_ xs: [Double]) -> [Double] { xs.filter { $0 > -273 } }

        let lever = col(a, Sig.lever), rpm = col(a, Sig.rpm)
        let cruiseIx = (0..<a.count).filter { lever[$0] > 60 && rpm[$0] > 1800 }
        guard cruiseIx.count >= 120 else { return nil }
        let cruise = cruiseIx.map { a[$0] }

        func cv(_ i: Int) -> [Double] { clean(cruise.map { $0.values[i] }) }
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count) }
        func pstdev(_ xs: [Double]) -> Double {
            guard xs.count > 1 else { return 0 }
            let m = mean(xs); return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)).squareRoot()
        }
        func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
        func pct(_ xs: [Double], _ p: Double) -> Double {   // same indexing as ae3-metrics.py
            let s = xs.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(p / 100 * Double(s.count)))]
        }

        let rail = cv(Sig.rail)
        let boostr = cruise.filter { $0.values[Sig.ambient] > 0 }.map { $0.values[Sig.boost] / $0.values[Sig.ambient] }
        let oilBand = cruise.filter { (1900...2200).contains($0.values[Sig.rpm]) && $0.values[Sig.oilP] > -273 }
            .map { $0.values[Sig.oilP] }
        let load = cv(Sig.load), coolant = cv(Sig.coolant), oilTemp = cv(Sig.oilTemp)
        let gearbox = cv(Sig.gearbox), battery = cv(Sig.battery), fuel = cv(Sig.fuelLP)

        // A/B divergence, aligned on rail pressure (cross-correlation lag).
        var dOil: Double?, dRail: Double?, dBoost: Double?, dCool: Double?
        if !b.isEmpty {
            let lag = bestLag(col(a, Sig.rail), col(b, Sig.rail))
            func diverge(_ i: Int) -> Double? {
                var acc: [Double] = []
                for j in max(0, -lag)..<min(b.count, a.count - lag) {
                    let x = a[j + lag].values[i], y = b[j].values[i]
                    if x > -273 && y > -273 { acc.append(abs(x - y)) }
                }
                return acc.isEmpty ? nil : mean(acc)
            }
            dOil = diverge(Sig.oilP); dRail = diverge(Sig.rail); dBoost = diverge(Sig.boost); dCool = diverge(Sig.coolant)
        }

        return FlightHealth(
            ecu: first.ecu, session: first.session, start: first.date,
            durationMin: a.count / 60, cruiseSamples: cruise.count,
            railMean: mean(rail), railStd: pstdev(rail),
            boostRatioMean: mean(boostr), boostRatioMax: boostr.max() ?? .nan,
            oilPMedian: median(oilBand), oilPp5: pct(oilBand, 5), oilPMin: oilBand.min() ?? .nan,
            loadMean: mean(load), loadMax: load.max() ?? .nan,
            coolantMax: coolant.max() ?? .nan, oilTempMax: oilTemp.max() ?? .nan, gearboxMax: gearbox.max() ?? .nan,
            batteryMin: battery.min() ?? .nan, batteryMean: mean(battery),
            fuelLPMean: mean(fuel), fuelLPMin: fuel.min() ?? .nan,
            divOilP: dOil, divRail: dRail, divBoost: dBoost, divCoolant: dCool)
    }

    /// Cross-correlation lag (in samples) that best aligns `b` to `a`. Ported from
    /// ae3-metrics.py `xcorr_lag`.
    static func bestLag(_ a: [Double], _ b: [Double], maxLag: Int = 300) -> Int {
        var best = 0, bestC = -9.0
        for d in -maxLag...maxLag {
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, n = 0.0
            var j = max(0, -d); let jEnd = min(b.count, a.count - d)
            while j < jEnd {
                let x = a[j + d], y = b[j]
                if x > -273 && y > -273 { sx += x; sy += y; sxx += x*x; syy += y*y; sxy += x*y; n += 1 }
                j += 1
            }
            if n < 30 { continue }
            let cov = sxy - sx*sy/n, vx = sxx - sx*sx/n, vy = syy - sy*sy/n
            if vx <= 0 || vy <= 0 { continue }
            let c = cov / (vx.squareRoot() * vy.squareRoot())
            if c > bestC { bestC = c; best = d }
        }
        return best
    }
}
