import Foundation

/// One priced response, kept for the last 35 days to forecast quotas.
struct CostPoint {
    let t: Double
    let cost: Double
    let family: String   // "opus", "sonnet", "haiku", "fable"… ("" if unknown)
}

struct QuotaForecast {
    /// When the quota runs out, if before its reset.
    let exhaustion: Date?
    /// Projected usage at reset (may exceed 100 when it runs out).
    let atReset: Double
    /// Official percentage plus what was consumed since it was read.
    let livePercent: Double
}

/// Quota forecasts from the user's own consumption:
/// - calibration: quota points per dollar (API-equivalent) consumed in the current window,
///   from /usage samples when available, else from the window total;
/// - weekly windows: hour-of-week activity profile over the last 4 weeks, scaled by this week's intensity
///   (consumption so far vs the profile), integrated hour by hour until the reset;
/// - 5-hour session: recent pace (last 45 min) blended with the window's pace.
enum Forecaster {
    static func family(_ model: String) -> String {
        let m = model.lowercased()
        for f in ["fable", "opus", "sonnet", "haiku"] where m.contains(f) { return f }
        return ""
    }

    static func hourOfWeek(_ t: Double) -> Int {
        let c = Calendar.current.dateComponents([.weekday, .hour], from: Date(timeIntervalSince1970: t))
        return ((c.weekday ?? 1) - 1) * 24 + (c.hour ?? 0)
    }

    /// Average cost per hour-of-week over the last 28 days (or the history available), per family and "all".
    static func profiles(_ series: [CostPoint], now: Double, firstDate: Double?) -> [String: [Double]] {
        let from = now - 28 * 86400
        let weeks = max(1, (now - max(from, firstDate ?? from)) / (7 * 86400))
        var out: [String: [Double]] = [:]
        for p in series where p.t >= from {
            let h = hourOfWeek(p.t)
            out["all", default: [Double](repeating: 0, count: 168)][h] += p.cost / weeks
            if !p.family.isEmpty { out[p.family, default: [Double](repeating: 0, count: 168)][h] += p.cost / weeks }
        }
        return out
    }

    // MARK: Forecast

    static func forecast(_ w: PlanUsage.Window, observedAt: Date, snapshot snap: Snapshot,
                         history: [QuotaSample], now: Date = Date()) -> QuotaForecast? {
        let nowT = now.timeIntervalSince1970
        let reset = w.resetsAt.timeIntervalSince1970
        guard reset > nowT else { return nil }
        let start = reset - w.span
        let fam = w.kind == .scoped ? w.shortName.lowercased() : "all"
        let series = snap.costSeries
        func cost(_ a: Double, _ b: Double) -> Double {
            guard b > a else { return 0 }
            var lo = 0, hi = series.count
            while lo < hi { let mid = (lo + hi) / 2; if series[mid].t < a { lo = mid + 1 } else { hi = mid } }
            var sum = 0.0
            var i = lo
            while i < series.count, series[i].t <= b {
                if fam == "all" || series[i].family == fam { sum += series[i].cost }
                i += 1
            }
            return sum
        }

        let obsT = min(observedAt.timeIntervalSince1970, nowT)
        let pctObs = w.usedPercent

        // Calibration: quota points per dollar. Prefer two /usage samples of this window far enough apart.
        var k: Double?
        let samples = history.filter { $0.label == w.label && abs($0.reset - reset) < 120 && $0.t >= start }
        if let first = samples.first, pctObs - first.pct >= 4 {
            let c = cost(first.t, obsT)
            if c > 0.5 { k = (pctObs - first.pct) / c }
        }
        if k == nil {
            let c = cost(start, obsT)
            if c > 0.5, pctObs >= 1 { k = pctObs / c }
        }
        guard let k, k > 0 else { return linear(w, now: nowT) }

        let live = min(100, pctObs + k * cost(obsT, nowT))
        let elapsedH = max((nowT - start) / 3600, 0.25)
        let remainingH = (reset - nowT) / 3600

        if w.kind == .session {
            let recent = cost(nowT - 45 * 60, nowT) / 0.75
            let average = cost(start, nowT) / elapsedH
            let rate = 0.65 * recent + 0.35 * average            // $ per hour
            let gain = k * rate                                  // points per hour
            let atReset = live + gain * remainingH
            let exhaustion = gain > 0 && atReset >= 100 ? now.addingTimeInterval((100 - live) / gain * 3600) : nil
            return QuotaForecast(exhaustion: exhaustion, atReset: atReset, livePercent: live)
        }

        // Weekly: hour-of-week profile with a small floor so quiet hours aren't exactly zero.
        guard var profile = snap.profiles[fam], profile.reduce(0, +) > 0 else { return linear(w, now: nowT) }
        let mean = profile.reduce(0, +) / 168
        profile = profile.map { 0.9 * $0 + 0.1 * mean }
        func expected(_ a: Double, _ b: Double) -> Double {
            var sum = 0.0, t = a
            while t < b {
                let next = min(b, (floor(t / 3600) + 1) * 3600)
                sum += profile[hourOfWeek(t)] * (next - t) / 3600
                t = next
            }
            return sum
        }
        let clamp: (Double) -> Double = { min(6, max(0.15, $0)) }
        let expWindow = expected(start, nowT), exp24 = expected(nowT - 86400, nowT)
        let rWindow = expWindow > 0.01 ? clamp(cost(start, nowT) / expWindow) : nil
        let r24 = exp24 > 0.01 ? clamp(cost(nowT - 86400, nowT) / exp24) : nil
        // Backtested on past weeks: this week's intensity alone beats blends with the last 24 h (19 % vs 23 % error).
        let intensity = rWindow ?? r24 ?? 1

        var pct = live, t = nowT
        var exhaustion: Date?
        while t < reset {
            let next = min(reset, (floor(t / 3600) + 1) * 3600)
            let gain = k * intensity * profile[hourOfWeek(t)] * (next - t) / 3600
            if exhaustion == nil, pct + gain >= 100, gain > 0 {
                exhaustion = Date(timeIntervalSince1970: t + (100 - pct) / gain * (next - t))
            }
            pct += gain
            t = next
        }
        return QuotaForecast(exhaustion: exhaustion, atReset: pct, livePercent: live)
    }

    /// Fallback without consumption data: average pace since the window started.
    private static func linear(_ w: PlanUsage.Window, now: Double) -> QuotaForecast? {
        let start = w.resetsAt.timeIntervalSince1970 - w.span
        let elapsed = now - start
        guard elapsed > 3600, w.usedPercent > 1 else { return nil }
        let rate = w.usedPercent / elapsed
        let atReset = w.usedPercent + rate * (w.resetsAt.timeIntervalSince1970 - now)
        let exhaustion = atReset >= 100 ? Date(timeIntervalSince1970: now + (100 - w.usedPercent) / rate) : nil
        return QuotaForecast(exhaustion: exhaustion, atReset: atReset, livePercent: w.usedPercent)
    }
}


// MARK: Backtest

extension Forecaster {
    /// Replays the weekly method on past weeks: at several checkpoints, predicts the week's total consumption
    /// with only the data known then, and compares with what really happened (and with the plain average pace).
    static func backtest(series: [CostPoint], weekEnd: Double) -> String {
        func cost(_ a: Double, _ b: Double) -> Double { series.lazy.filter { $0.t >= a && $0.t < b }.reduce(0) { $0 + $1.cost } }
        var lines = ["semaine         point   réel $   profil $  err    moyenne $  err"]
        var errsP: [Double] = [], errsL: [Double] = []
        for back in 1...3 {
            let end = weekEnd - Double(back) * 7 * 86400, start = end - 7 * 86400
            guard series.first.map({ $0.t < start - 86400 }) ?? false else { continue }
            let actual = cost(start, end)
            guard actual > 1 else { continue }
            for day in 1...5 {
                let cp = start + Double(day) * 86400
                let past = series.filter { $0.t < cp }
                guard var profile = profiles(past, now: cp, firstDate: series.first?.t)["all"], profile.reduce(0, +) > 0 else { continue }
                let mean = profile.reduce(0, +) / 168
                profile = profile.map { 0.9 * $0 + 0.1 * mean }
                func expected(_ a: Double, _ b: Double) -> Double {
                    var sum = 0.0, t = a
                    while t < b { let n = min(b, (floor(t / 3600) + 1) * 3600); sum += profile[hourOfWeek(t)] * (n - t) / 3600; t = n }
                    return sum
                }
                let clamp: (Double) -> Double = { min(6, max(0.15, $0)) }
                let soFar = cost(start, cp)
                let rW = clamp(soFar / max(expected(start, cp), 0.01))
                let predicted = soFar + rW * expected(cp, end)
                let linear = soFar / (cp - start) * (end - start)
                let eP = (predicted - actual) / actual, eL = (linear - actual) / actual
                errsP.append(abs(eP)); errsL.append(abs(eL))
                let d = Date(timeIntervalSince1970: start).formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
                lines.append(String(format: "%-14@  J+%d   %7.0f   %7.0f  %+5.0f%%   %7.0f  %+5.0f%%", d as NSString, day, actual, predicted, eP * 100, linear, eL * 100))
            }
        }
        if !errsP.isEmpty {
            lines.append(String(format: "erreur moyenne : profil %.0f %% · moyenne simple %.0f %%",
                                errsP.reduce(0, +) / Double(errsP.count) * 100, errsL.reduce(0, +) / Double(errsL.count) * 100))
        }
        return lines.joined(separator: "\n")
    }
}
