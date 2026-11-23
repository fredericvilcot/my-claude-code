import Foundation

/// Real plan limits as reported by Claude Code to its status line (same figures as /usage).
struct PlanUsage {
    enum Kind { case session, week, scoped }

    struct Window {
        let usedPercent: Double
        let resetsAt: Date
        var kind: Kind = .session
        var label: String = ""
        var expired: Bool { resetsAt < Date() }
        /// "Fable" from "Current week (Fable)".
        var shortName: String {
            switch kind {
            case .session: return "Session"
            case .week: return "Semaine"
            case .scoped:
                if let a = label.firstIndex(of: "("), let b = label.firstIndex(of: ")"), a < b {
                    return String(label[label.index(after: a)..<b])
                }
                return label
            }
        }
    }
    var session: Window?
    var week: Window?
    var scoped: [Window] = []
    var updatedAt: Date
    var header: String?
    var contributors: [(Int, String)] = []

    var all: [Window] { [session, week].compactMap { $0 } + scoped }

    /// Combines the live status line (fresh while working) with the /usage poll (always running, includes per-model weeks).
    static func merge(statusLine: PlanUsage?, poll: UsageReading?) -> PlanUsage? {
        guard statusLine != nil || poll != nil else { return nil }
        let pollDate = poll?.date ?? .distantPast
        let lineDate = statusLine?.updatedAt ?? .distantPast
        var out = PlanUsage(updatedAt: max(pollDate, lineDate))
        let pollSession = poll?.windows.first { $0.kind == .session && !$0.expired }
        let pollWeek = poll?.windows.first { $0.kind == .week && !$0.expired }
        // Within one window usage only grows: the higher figure is the fresher one.
        // A different reset time means a new window: then the most recent source wins.
        // Returns the chosen window and the date of the source it came from (a = status line, b = /usage).
        func pick(_ a: Window?, _ b: Window?, aIsNewer: Bool) -> (Window?, Date?) {
            guard let a else { return (b, b == nil ? nil : pollDate) }
            guard let b else { return (a, lineDate) }
            if abs(a.resetsAt.timeIntervalSince(b.resetsAt)) < 600 { return a.usedPercent >= b.usedPercent ? (a, lineDate) : (b, pollDate) }
            return aIsNewer ? (a, lineDate) : (b, pollDate)
        }
        let (session, sessionDate) = pick(statusLine?.session, pollSession, aIsNewer: lineDate > pollDate)
        let (week, weekDate) = pick(statusLine?.week, pollWeek, aIsNewer: lineDate > pollDate)
        out.session = session
        out.week = week
        out.scoped = poll?.windows.filter { $0.kind == .scoped && !$0.expired } ?? []
        // The date shown is the one of the figures shown: a fresh status line without quota figures must not make
        // older /usage figures look current.
        let used = [sessionDate, weekDate, out.scoped.isEmpty ? nil : pollDate].compactMap { $0 }
        out.updatedAt = used.max() ?? max(pollDate, lineDate)
        out.header = poll?.header
        out.contributors = poll?.contributors ?? []
        return out
    }
}

/// One reading of `/usage`: the windows, the header and who is using the quota.
struct UsageReading {
    var windows: [PlanUsage.Window] = []
    var header: String?
    var contributors: [(Int, String)] = []
    var date = Date()
}

extension PlanUsage.Window {
    /// Length of the quota window.
    var span: TimeInterval { kind == .session ? 5 * 3600 : 7 * 86400 }
}

/// One recorded /usage figure, to calibrate forecasts from real quota movements.
struct QuotaSample: Codable {
    let t: Double
    let label: String
    let pct: Double
    let reset: Double
}
