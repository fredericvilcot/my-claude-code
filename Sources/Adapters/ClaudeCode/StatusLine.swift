import Foundation

/// Where the status line snapshot lives and how it is read.
extension PlanUsage {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("My Claude Code", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var snapshotURL: URL { directory.appendingPathComponent("statusline.json") }

    static func load() -> PlanUsage? {
        let url = snapshotURL
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        var usage = PlanUsage(updatedAt: date)
        if let id = root["session_id"] as? String, let cost = (root["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber {
            OfficialCosts.record(session: id, cost: cost.doubleValue)
        }
        if let limits = root["rate_limits"] as? [String: Any] {
            func window(_ key: String) -> Window? {
                guard let w = limits[key] as? [String: Any],
                      let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                      let reset = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
                let win = Window(usedPercent: pct, resetsAt: Date(timeIntervalSince1970: reset), kind: key == "five_hour" ? .session : .week)
                return win.expired ? nil : win
            }
            usage.session = window("five_hour")
            usage.week = window("seven_day")
        }
        return usage
    }
}

/// Installs / removes the status line command that forwards Claude Code's status JSON to the app.
enum ClaudeCodeLink {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    static var scriptURL: URL { PlanUsage.directory.appendingPathComponent("statusline.sh") }

    enum State: Equatable { case connected, notConnected, otherStatusLine(String) }

    static var state: State {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let line = root["statusLine"] as? [String: Any] else { return .notConnected }
        let command = line["command"] as? String ?? ""
        return command.contains("My Claude Code") ? .connected : .otherStatusLine(command)
    }

    private static let script = #"""
    #!/bin/sh
    # Installed by My Claude Code: forwards Claude Code's status JSON to the menu bar app,
    # then prints a short status line. Remove it from My Claude Code > Réglages.
    DIR="$HOME/Library/Application Support/My Claude Code"
    mkdir -p "$DIR"
    cat > "$DIR/statusline.tmp" && mv "$DIR/statusline.tmp" "$DIR/statusline.json"
    F="$DIR/statusline.json"
    SID=$(plutil -extract session_id raw -o - "$F" 2>/dev/null)
    [ -n "$SID" ] && mkdir -p "$DIR/sessions" && cp "$F" "$DIR/sessions/$SID.json"
    M=$(plutil -extract model.display_name raw -o - "$F" 2>/dev/null)
    S=$(plutil -extract rate_limits.five_hour.used_percentage raw -o - "$F" 2>/dev/null)
    W=$(plutil -extract rate_limits.seven_day.used_percentage raw -o - "$F" 2>/dev/null)
    printf '%s' "$M"
    [ -n "$S" ] && printf ' · session %.0f%%' "$S"
    [ -n "$W" ] && printf ' · semaine %.0f%%' "$W"
    exit 0
    """#

    /// Rewrites the script when the app ships a newer version (settings.json untouched).
    static func refreshScriptIfNeeded() {
        guard state == .connected, (try? String(contentsOf: scriptURL)) != script else { return }
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Exact context reported by the status line, per session id (last 24 h).
    static func sessionContexts() -> [String: (percent: Double, date: Date)] {
        let dir = PlanUsage.directory.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [String: (Double, Date)] = [:]
        for url in files where url.pathExtension == "json" {
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(date) < 86400,
                  let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pct = ((root["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            out[url.deletingPathExtension().lastPathComponent] = (pct, date)
        }
        return out
    }

    /// Writes the script and adds `statusLine` to ~/.claude/settings.json (a backup is kept).
    static func connect() throws {
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            try data.write(to: settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.bak-myclaudecode"))
            root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        root["statusLine"] = ["type": "command", "command": "'\(scriptURL.path)'"]
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }

    static func disconnect() throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              case .connected = state else { return }
        root.removeValue(forKey: "statusLine")
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }
}
