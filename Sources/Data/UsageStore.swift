import AppKit
import Foundation
import Observation

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

@Observable
final class UsageStore {
    static let shared = UsageStore()

    var snapshot = Snapshot()
    var account = AccountInfo.load()
    var loading = true
    var status = "Analyse des sessions…"
    var lastUpdate = Date()
    var plan: PlanUsage?
    var link = ClaudeCodeLink.state
    var claude = ClaudeStatus()
    var exactContexts: [String: (percent: Double, date: Date)] = [:]
    var mcp: McpInventory?
    var live: [String: LiveSession] = [:]
    @ObservationIgnored private var background: [String: LiveSession] = [:]
    @ObservationIgnored private var liveTimer: Timer?

    private func mergeLive(_ interactive: [String: LiveSession]) {
        let merged = interactive.merging(background) { a, _ in a }
        let changed = merged.count != live.count || merged.contains { live[$0.key]?.state != $0.value.state || live[$0.key]?.name != $0.value.name }
        if changed {
            let old = live
            live = merged
            Task { @MainActor in AttentionCenter.shared.observe(old: old, new: merged) }
        }
        Task { @MainActor in AttentionCenter.shared.observeContexts(self) }
    }
    @ObservationIgnored private var mcpTimer: Timer?

    func refreshMcp() {
        let now = Date().timeIntervalSince1970
        let projects = snapshot.sessions.filter { now - $0.info.last < 3600 }.map(\.info.project)
        DispatchQueue.global(qos: .utility).async {
            let inv = McpList.fetch(activeProjects: projects)
            DispatchQueue.main.async { self.mcp = inv }
        }
    }

    /// Context fraction of a session: exact from the status line when recent, else from its transcript.
    func context(of s: SessionStat) -> (fraction: Double, exact: Bool) {
        if let e = exactContexts[s.info.id], e.date.timeIntervalSince1970 >= s.info.last - 120 { return (e.percent / 100, true) }
        return (s.contextFraction, false)
    }
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var planTimer: Timer?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var lastPoll: UsagePoller.Result?
    @ObservationIgnored private var polling = false

    @ObservationIgnored private var cache = UsageCache()
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var sessionIndex: [String: Int] = [:]
    @ObservationIgnored private var modelIndex: [String: Int] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "app.myclaudecode.scan", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var pollStarted = Date.distantPast

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("My Claude Code", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-cache.json")
    }

    /// Runs `claude -p /usage` in the background; reschedules itself with the chosen interval.
    func pollUsage() {
        if polling, Date().timeIntervalSince(pollStarted) < 90 { return }
        polling = true
        pollStarted = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = UsagePoller.fetch()
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                if let result, !result.windows.isEmpty {
                    self.lastPoll = result
                    Self.saveWindows(result)
                    UsageHistory.record(result.windows, at: result.date)
                }
                self.refreshPlan()
            }
        }
    }

    func refreshStatus() {
        DispatchQueue.global(qos: .utility).async {
            let s = ClaudeStatus.load()
            let contexts = ClaudeCodeLink.sessionContexts()
            let all = LiveSessions.fetch()   // includes background sessions (slower, every 15 s)
            DispatchQueue.main.async {
                self.claude = s; self.exactContexts = contexts
                self.background = all.filter { $0.value.kind == "background" }
                self.mergeLive(LiveSessions.fetchInteractive())
            }
        }
    }

    private static var windowsURL: URL { PlanUsage.directory.appendingPathComponent("last-usage.json") }

    /// Last /usage windows, saved so the next launch shows complete figures immediately (no layout shift).
    static func saveWindows(_ r: UsagePoller.Result) {
        let rows = r.windows.map { ["label": $0.label, "pct": $0.usedPercent, "reset": $0.resetsAt.timeIntervalSince1970] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: ["date": r.date.timeIntervalSince1970, "windows": rows]) {
            try? data.write(to: windowsURL, options: .atomic)
        }
        UserDefaults.standard.set(r.windows.filter { $0.kind == .scoped }.map(\.shortName), forKey: "knownScopedQuotas")
    }

    static func loadWindows() -> UsagePoller.Result? {
        guard let data = try? Data(contentsOf: windowsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["windows"] as? [[String: Any]] else { return nil }
        var r = UsagePoller.Result()
        r.date = Date(timeIntervalSince1970: root["date"] as? Double ?? 0)
        r.windows = rows.compactMap { row in
            guard let label = row["label"] as? String, let pct = row["pct"] as? Double, let reset = row["reset"] as? Double else { return nil }
            return PlanUsage.Window(usedPercent: pct, resetsAt: Date(timeIntervalSince1970: reset), kind: UsagePoller.kind(for: label), label: label)
        }
        return r
    }

    func schedulePolling() {
        pollTimer?.invalidate()
        let interval = max(60, UserDefaults.standard.double(forKey: "usagePollInterval"))
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.pollUsage() }
        if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
        pollUsage()
    }

    func refreshPlan() {
        plan = PlanUsage.merge(statusLine: PlanUsage.load(), poll: lastPoll)
        link = ClaudeCodeLink.state
        LimitAlerts.shared.evaluate(plan)
        onUpdate?()
    }

    /// Everything at once: used at wake, session unlock and day change.
    func refreshAll() {
        queue.async { [self] in lastPublish = .distantPast; scan() }
        pollUsage()
        refreshStatus()
        refreshPlan()
    }

    func start() {
        if lastPoll == nil { lastPoll = Self.loadWindows() }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Network may need a moment after wake: refresh now and again a bit later.
                self?.refreshAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self?.refreshAll() }
            }
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshAll() }
        refreshPlan()
        planTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshPlan() }
        if let t = planTimer { RunLoop.main.add(t, forMode: .common) }
        schedulePolling()
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshStatus() }
        if let t = statusTimer { RunLoop.main.add(t, forMode: .common) }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let interactive = LiveSessions.fetchInteractive()
                DispatchQueue.main.async { self?.mergeLive(interactive) }
            }
        }
        if let t = liveTimer { RunLoop.main.add(t, forMode: .common) }
        refreshMcp()
        mcpTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.refreshMcp() }
        if let t = mcpTimer { RunLoop.main.add(t, forMode: .common) }
        queue.async { [self] in
            loadCache()
            scan()
        }
        let interval = max(5, UserDefaults.standard.double(forKey: "refreshInterval"))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    func rebuild() {
        queue.async { [self] in
            cache = UsageCache(); seen = []; sessionIndex = [:]; modelIndex = [:]
            try? FileManager.default.removeItem(at: cacheURL)
            DispatchQueue.main.async { self.loading = true; self.status = "Recalcul complet…" }
            scan()
        }
    }

    func records(ofSession index: Int) -> [UsageRecord] {
        queue.sync { cache.records.filter { $0.s == index } }
    }

    func modelName(_ index: Int) -> String { queue.sync { cache.models[index] } }

    // MARK: Scanning (background queue)

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(UsageCache.self, from: data), decoded.version == UsageCache().version else { return }
        cache = decoded
        seen = Set(decoded.seen)
        for (i, s) in cache.sessions.enumerated() { sessionIndex[s.id] = i }
        for (i, m) in cache.models.enumerated() { modelIndex[m] = i }
        publish()
    }

    private func scan() {
        let files = UsageLog.listFiles()
        let pending = files.filter { file in
            guard let mark = cache.files[file.path] else { return true }
            return file.size != mark.size
        }
        // Recompute at least every minute even without new records (day change, "x min ago", active sessions).
        guard !pending.isEmpty || loading || Date().timeIntervalSince(lastPublish) > 55 else { return }

        var results = [(path: String, size: UInt64, records: [UsageLog.Parsed], end: UInt64)?](repeating: nil, count: pending.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pending.count) { i in
            let file = pending[i]
            var from = cache.files[file.path]?.offset ?? 0
            if from > file.size { from = 0 } // file was rewritten
            let parsed = UsageLog.parse(path: file.path, from: from)
            lock.lock(); results[i] = (file.path, file.size, parsed.records, parsed.end); lock.unlock()
        }

        var added = false
        for case let r? in results {
            for p in r.records where !seen.contains(p.key) {
                seen.insert(p.key)
                let s: Int
                if let existing = sessionIndex[p.session] {
                    s = existing
                    cache.sessions[s].first = min(cache.sessions[s].first, p.t)
                    cache.sessions[s].last = max(cache.sessions[s].last, p.t)
                    if let b = p.branch, !b.isEmpty { cache.sessions[s].branch = b }
                    if cache.sessions[s].project.isEmpty { cache.sessions[s].project = p.cwd }
                } else {
                    s = cache.sessions.count
                    cache.sessions.append(SessionInfo(id: p.session, project: p.cwd, branch: p.branch, first: p.t, last: p.t))
                    sessionIndex[p.session] = s
                }
                let m: Int
                if let existing = modelIndex[p.model] { m = existing } else {
                    m = cache.models.count; cache.models.append(p.model); modelIndex[p.model] = m
                }
                cache.records.append(UsageRecord(t: p.t, s: s, m: m, i: p.i, o: p.o, w5: p.w5, w1: p.w1, r: p.r, f: p.fast, sc: p.sidechain))
                added = true
            }
            cache.files[r.path] = FileMark(offset: r.end, size: r.size)
        }
        if added { cache.records.sort { $0.t < $1.t } }
        if added || loading {
            cache.seen = Array(seen)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        }
        publish()
    }

    // MARK: Aggregation

    private func publish() {
        lastPublish = Date()
        let snap = Self.aggregate(cache)
        DispatchQueue.main.async { [self] in
            snapshot = snap
            account = AccountInfo.load()
            loading = false
            status = ""
            lastUpdate = Date()
            onUpdate?()
        }
    }

    static func aggregate(_ c: UsageCache) -> Snapshot {
        var snap = Snapshot()
        let cal = Calendar.current
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday)!
        let start7 = cal.date(byAdding: .day, value: -6, to: startToday)!
        let start30 = cal.date(byAdding: .day, value: -29, to: startToday)!
        let startHeat = cal.date(byAdding: .day, value: -125, to: startToday)!

        var byDay: [Date: Double] = [:]
        var sessions = c.sessions.enumerated().map { SessionStat(index: $0.offset, info: $0.element) }
        var models: [Int: ModelStat] = [:]
        var weekModels: [Int: ModelStat] = [:]
        var projects: [String: ProjectStat] = [:]

        func add(_ t: inout Totals, _ r: UsageRecord, _ cost: Pricing.Breakdown) {
            t.cost = t.cost + cost
            t.input += r.i; t.output += r.o; t.write += r.w5 + r.w1; t.read += r.r
            t.messages += 1; t.sessions.insert(r.s)
        }

        var windows: [WindowStat] = []
        let seriesFrom = now.timeIntervalSince1970 - 35 * 86400
        let families = c.models.map(Forecaster.family)
        for r in c.records {
            let model = c.models[r.m]
            let cost = Pricing.cost(model: model, fast: r.f, input: r.i, output: r.o, write5m: r.w5, write1h: r.w1, read: r.r)
            let date = Date(timeIntervalSince1970: r.t)
            if r.t >= seriesFrom { snap.costSeries.append(CostPoint(t: r.t, cost: cost.total, family: families[r.m])) }
            add(&snap.all, r, cost)
            if date >= startToday {
                add(&snap.today, r, cost)
                snap.todayHours[cal.component(.hour, from: date)] += r.tokens
            }
            else if date >= startYesterday { add(&snap.yesterday, r, cost) }
            if date >= start7 { add(&snap.week, r, cost) }
            if date >= start30 { add(&snap.month, r, cost) }
            if now.timeIntervalSince(date) < 3600 { snap.lastHourCost += cost.total }
            let day = cal.startOfDay(for: date)
            byDay[day, default: 0] += cost.total
            snap.hours[cal.component(.hour, from: date)] += cost.total
            snap.weekdays[(cal.component(.weekday, from: date) + 5) % 7] += cost.total
            snap.cacheSavings += Pricing.cacheSavings(model: model, fast: r.f, read: r.r)

            add(&sessions[r.s].totals, r, cost)
            if r.sc != true {
                sessions[r.s].lastContext = r.context
                sessions[r.s].lastModel = model
                sessions[r.s].contextWindow = model.contains("haiku-4-5") ? 200_000 : 1_000_000
            }
            sessions[r.s].models[model, default: 0] += cost.total

            var ms = models[r.m] ?? ModelStat(name: model, cost: 0, tokens: 0, estimated: !Pricing.isKnown(model))
            ms.cost += cost.total; ms.tokens += r.tokens
            models[r.m] = ms
            if date >= start7 {
                var wm = weekModels[r.m] ?? ModelStat(name: model, cost: 0, tokens: 0, estimated: !Pricing.isKnown(model))
                wm.cost += cost.total; wm.tokens += r.tokens
                weekModels[r.m] = wm
            }

            // 5-hour windows start at the first message after the previous one expired.
            if let last = windows.last, date < last.reset {
                windows[windows.count - 1].cost += cost.total
                windows[windows.count - 1].tokens += r.tokens
            } else {
                windows.append(WindowStat(start: date, cost: cost.total, tokens: r.tokens))
            }
        }

        let official = OfficialCosts.all()
        for i in sessions.indices {
            guard let cost = official[sessions[i].info.id] else { continue }
            sessions[i].official = cost
            let delta = cost - sessions[i].totals.cost.total
            guard delta > 0 else { continue }
            sessions[i].totals.cost.other += delta
            let date = Date(timeIntervalSince1970: sessions[i].info.last)
            snap.all.cost.other += delta
            if date >= startToday { snap.today.cost.other += delta } else if date >= startYesterday { snap.yesterday.cost.other += delta }
            if date >= start7 { snap.week.cost.other += delta }
            if date >= start30 { snap.month.cost.other += delta }
            byDay[cal.startOfDay(for: date), default: 0] += delta
        }

        for s in sessions where s.totals.messages > 0 {
            var p = projects[s.info.project] ?? ProjectStat(path: s.info.project)
            p.totals.cost = p.totals.cost + s.totals.cost
            p.totals.input += s.totals.input; p.totals.output += s.totals.output
            p.totals.write += s.totals.write; p.totals.read += s.totals.read
            p.totals.messages += s.totals.messages
            p.sessionCount += 1
            p.last = max(p.last, s.info.last)
            projects[s.info.project] = p
        }

        let todayByProject = Dictionary(grouping: sessions.filter { $0.info.last >= startToday.timeIntervalSince1970 }) { $0.info.project }
            .mapValues { $0.reduce(0) { $0 + $1.totals.messages } }
        snap.todayTopProject = todayByProject.max { $0.value < $1.value }.map { ($0.key as NSString).lastPathComponent }
        snap.sessions = sessions.filter { $0.totals.messages > 0 }.sorted { $0.info.last > $1.info.last }
        snap.projects = projects.values.sorted { $0.totals.cost.total > $1.totals.cost.total }
        snap.models = models.values.sorted { $0.cost > $1.cost }
        snap.weekModels = weekModels.values.sorted { $0.cost > $1.cost }
        if let top = snap.sessions.first, now.timeIntervalSince1970 - top.info.last < 30 * 60 { snap.current = top }

        if let current = windows.last, now < current.reset {
            let past = windows.dropLast().filter { $0.start >= start30 }.map(\.cost).sorted()
            var w = current
            if past.count >= 3 { w.typicalPeak = past[min(past.count - 1, Int(Double(past.count) * 0.9))] }
            snap.window = w
        }

        snap.last30 = (0..<30).map { i in
            let d = cal.date(byAdding: .day, value: i, to: start30)!
            return DayPoint(day: d, cost: byDay[d] ?? 0)
        }
        let heatStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: startHeat)) ?? startHeat
        var d = heatStart
        while d <= startToday {
            snap.heat.append(DayPoint(day: d, cost: byDay[d] ?? 0))
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        snap.activeDays = byDay.values.filter { $0 > 0 }.count
        snap.biggestDay = byDay.max { $0.value < $1.value }.map { DayPoint(day: $0.key, cost: $0.value) }
        var streakDay = byDay[startToday] ?? 0 > 0 ? startToday : startYesterday
        while (byDay[streakDay] ?? 0) > 0 {
            snap.streak += 1
            streakDay = cal.date(byAdding: .day, value: -1, to: streakDay)!
        }
        snap.firstDate = c.records.first.map { Date(timeIntervalSince1970: $0.t) }
        snap.profiles = Forecaster.profiles(snap.costSeries, now: now.timeIntervalSince1970, firstDate: snap.firstDate?.timeIntervalSince1970)
        return snap
    }
}
