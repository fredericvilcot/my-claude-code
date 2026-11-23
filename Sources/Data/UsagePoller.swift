import Foundation

/// Polls `claude -p /usage` in the background (no model call, zero cost, no session saved)
/// to get the exact /usage figures even when no Claude Code session is active.
enum UsagePoller {
    struct Result {
        var windows: [PlanUsage.Window] = []
        var header: String?
        var contributors: [(Int, String)] = []
        var date = Date()
    }

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func fetch() -> Result? {
        guard let claude = claudePath, !Demo.isOn else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: claude)
        task.arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence"]
        task.currentDirectoryURL = PlanUsage.directory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        task.environment = env
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let timer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        timer.cancel()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = root["result"] as? String else { return nil }
        return parse(text)
    }

    /// Parses lines such as "Current week (Fable): 41% used · resets Nov 23 at 5:59pm (Europe/Paris)".
    static func parse(_ text: String) -> Result {
        var result = Result()
        let line = try! NSRegularExpression(pattern: #"^(Current [^:]+):\s*(\d+(?:\.\d+)?)%\s*used\s*·\s*resets\s+(.+?)\s*\(([^)]+)\)\s*$"#)
        let tip = try! NSRegularExpression(pattern: #"^\s+(\d+)%\s+(.+)$"#)
        var inContributors = false
        for raw in text.components(separatedBy: "\n") {
            let ns = raw as NSString
            if let m = line.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let label = ns.substring(with: m.range(at: 1))
                let pct = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let reset = parseDate(ns.substring(with: m.range(at: 3)), tz: ns.substring(with: m.range(at: 4)))
                result.windows.append(PlanUsage.Window(usedPercent: pct, resetsAt: reset ?? Date().addingTimeInterval(3600),
                                                       kind: kind(for: label), label: label))
                continue
            }
            if raw.hasPrefix("Last 24h") { result.header = raw; inContributors = true; continue }
            if inContributors, let m = tip.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                result.contributors.append((Int(ns.substring(with: m.range(at: 1))) ?? 0, ns.substring(with: m.range(at: 2))))
            }
        }
        return result
    }

    static func kind(for label: String) -> PlanUsage.Kind {
        let l = label.lowercased()
        if l.contains("session") { return .session }
        if l.contains("all models") { return .week }
        return .scoped
    }

    /// "Nov 23 at 5:59pm" / "Nov 20 at 12am" in the given time zone; the year is the next occurrence.
    static func parseDate(_ s: String, tz: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz) ?? .current
        let year = Calendar.current.component(.year, from: Date())
        for format in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy", "MMM d, yyyy 'at' h:mma", "h:mma yyyy", "ha yyyy"] {
            f.dateFormat = format
            for y in [year, year + 1] {
                let candidate = format.contains("yyyy 'at'") ? s : "\(s) \(y)"
                if let d = f.date(from: candidate.replacingOccurrences(of: "am", with: "AM").replacingOccurrences(of: "pm", with: "PM")),
                   d > Date().addingTimeInterval(-3600) { return d }
            }
        }
        return nil
    }
}
