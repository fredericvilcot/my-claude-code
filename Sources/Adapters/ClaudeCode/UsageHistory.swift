import Foundation

/// /usage readings over time (one line per change), to calibrate forecasts from real quota movements.
enum UsageHistory {
    typealias Sample = QuotaSample

    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyClaudeCode/usage-history.json")
    private(set) static var samples: [Sample] = load()

    private static func load() -> [Sample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }

    static func record(_ windows: [PlanUsage.Window], at date: Date) {
        var changed = false
        for w in windows {
            let last = samples.last { $0.label == w.label }
            if last == nil || last!.pct != w.usedPercent || abs(last!.reset - w.resetsAt.timeIntervalSince1970) > 120 {
                samples.append(Sample(t: date.timeIntervalSince1970, label: w.label, pct: w.usedPercent, reset: w.resetsAt.timeIntervalSince1970))
                changed = true
            }
        }
        guard changed else { return }
        let cutoff = date.timeIntervalSince1970 - 60 * 86400
        samples.removeAll { $0.t < cutoff }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(samples) { try? data.write(to: url, options: .atomic) }
    }
}
