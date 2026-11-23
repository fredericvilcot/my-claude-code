import Foundation

// Usage statistics: totals, days, sessions, projects, models, the whole snapshot shown by the app.

struct Totals {
    var cost = Pricing.Breakdown()
    var input = 0, output = 0, write = 0, read = 0
    var messages = 0
    var sessions = Set<Int>()
    var tokens: Int { input + output + write + read }
}

struct DayPoint: Identifiable {
    let day: Date
    var cost: Double
    var id: Date { day }
}

struct SessionStat: Identifiable {
    let index: Int
    let info: SessionInfo
    var totals = Totals()
    /// Cost reported by Claude Code itself, when the status line saw this session.
    var official: Double?
    /// Context filled on the last main-thread turn, and the model's window.
    var lastContext = 0
    var contextWindow = 1_000_000
    var lastModel = ""
    var contextFraction: Double { contextWindow > 0 ? Double(lastContext) / Double(contextWindow) : 0 }
    var models: [String: Double] = [:]
    var id: Int { index }
    var name: String { info.project.isEmpty ? "Sans dossier" : (info.project as NSString).lastPathComponent }
    var duration: TimeInterval { info.last - info.first }
}

struct ProjectStat: Identifiable {
    let path: String
    var totals = Totals()
    var sessionCount = 0
    var last: Double = 0
    var id: String { path }
    var name: String { path.isEmpty ? "Sans dossier" : (path as NSString).lastPathComponent }
}

struct ModelStat: Identifiable {
    let name: String
    var cost: Double
    var tokens: Int
    var estimated: Bool
    var id: String { name }
}

struct WindowStat {
    let start: Date
    var cost: Double
    var tokens: Int
    var typicalPeak: Double?      // 90th percentile of past windows (30 days)
    var reset: Date { start.addingTimeInterval(5 * 3600) }
}

struct Snapshot {
    var today = Totals(), yesterday = Totals(), week = Totals(), month = Totals(), all = Totals()
    var last30: [DayPoint] = []
    var heat: [DayPoint] = []          // last 18 weeks
    var hours = [Double](repeating: 0, count: 24)
    var todayHours = [Int](repeating: 0, count: 24)
    var todayTopProject: String?
    var weekdays = [Double](repeating: 0, count: 7)
    var models: [ModelStat] = []
    var weekModels: [ModelStat] = []
    var projects: [ProjectStat] = []
    var sessions: [SessionStat] = []
    var current: SessionStat?
    var window: WindowStat?
    var lastHourCost = 0.0
    var cacheSavings = 0.0
    var streak = 0
    var activeDays = 0
    var biggestDay: DayPoint?
    var firstDate: Date?
    var costSeries: [CostPoint] = []          // last 35 days, for quota forecasts
    var profiles: [String: [Double]] = [:]    // hour-of-week cost profile per model family
}
