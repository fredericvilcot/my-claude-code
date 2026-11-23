import Foundation

/// Session costs as computed by Claude Code itself (status line `cost.total_cost_usd`), persisted per session.
enum OfficialCosts {
    private static let lock = NSLock()
    private static var cache: [String: Double]?
    private static var url: URL { PlanUsage.directory.appendingPathComponent("official-costs.json") }

    static func all() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let loaded = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: url))) ?? [:]
        cache = loaded
        return loaded
    }

    static func record(session: String, cost: Double) {
        var map = all()
        guard cost > (map[session] ?? 0) + 0.0001 else { return }   // a session's cost only grows
        map[session] = cost
        lock.lock(); cache = map; lock.unlock()
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: url, options: .atomic) }
    }
}
