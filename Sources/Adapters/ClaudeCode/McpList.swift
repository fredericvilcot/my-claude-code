import Foundation

/// MCP servers grouped like Claude Code's /mcp: project, user, claude.ai (used connectors only) and built-in.
struct McpServer: Identifiable {
    enum Health { case connected, needsAuth, failed, unknown }
    enum Scope: Int, CaseIterable { case project, user, claudeAI, builtIn }
    let name: String
    let scope: Scope
    var detail: String = ""
    var health: Health = .unknown
    var id: String { "\(scope.rawValue)-\(name)" }
}

struct McpInventory {
    var servers: [McpServer] = []
    var hiddenConnectors = 0
}

enum McpList {
    /// `claude mcp list`: health of every configured server ("name: target - status").
    private static func health() -> [String: McpServer.Health] {
        guard let claude = UsagePoller.claudePath, !Demo.isOn else { return [:] }   // demo: never ask the real Claude Code
        let task = Process()
        task.executableURL = URL(fileURLWithPath: claude)
        task.arguments = ["mcp", "list"]
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()
        var out: [String: McpServer.Health] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "\n") {
            guard let colon = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards) else { continue }
            let status = line[dash.upperBound...].lowercased()
            out[String(line[..<colon.lowerBound])] = status.contains("connected") ? .connected
                : status.contains("auth") ? .needsAuth : status.contains("fail") ? .failed : .unknown
        }
        return out
    }

    /// Servers whose tools were called in recent transcripts (finds built-in ones such as easel).
    private static func recentlyUsed() -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #""name":"mcp__([A-Za-z0-9_\-]+?)__"#)
        var names = Set<String>()
        let limit = Date().addingTimeInterval(-2 * 86400)
        for file in UsageLog.listFiles() {
            let url = URL(fileURLWithPath: file.path)
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date > limit,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                names.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return names
    }

    static func fetch(activeProjects: [String]) -> McpInventory {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let root = (try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.claude.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let status = health()
        var inv = McpInventory()
        var known = Set<String>()

        // Project scope: .mcp.json and per-project servers of the folders where sessions are active.
        for dir in Set(activeProjects) where !dir.isEmpty {
            var names: [String] = []
            if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/.mcp.json")),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                names += ((json["mcpServers"] as? [String: Any]) ?? [:]).keys
            }
            names += (((root["projects"] as? [String: Any])?[dir] as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]).keys
            for n in Set(names).sorted() where known.insert(n).inserted {
                inv.servers.append(McpServer(name: n, scope: .project, detail: (dir as NSString).lastPathComponent, health: status[n] ?? .connected))
            }
        }
        // User scope.
        for n in ((root["mcpServers"] as? [String: Any]) ?? [:]).keys.sorted() where known.insert(n).inserted {
            inv.servers.append(McpServer(name: n, scope: .user, health: status[n] ?? .unknown))
        }
        // claude.ai connectors: only those Claude Code has used, like /mcp; the rest are counted as hidden.
        let used = Set((root["claudeAiMcpEverConnected"] as? [String]) ?? [])
        let allConnectors = status.keys.filter { $0.hasPrefix("claude.ai ") }
        for key in allConnectors.sorted() {
            if used.contains(key), let h = status[key], h == .connected {
                let n = String(key.dropFirst(10))
                known.insert(n)
                inv.servers.append(McpServer(name: n, scope: .claudeAI, health: h))
            } else {
                inv.hiddenConnectors += 1
            }
        }
        // Built-in servers: called recently but not configured anywhere above.
        let configuredIDs = Set(inv.servers.map { $0.name.replacingOccurrences(of: " ", with: "_") }).union(known)
        for n in recentlyUsed().sorted() where !n.hasPrefix("claude_ai_") && !configuredIDs.contains(n) && !known.contains(n) {
            inv.servers.append(McpServer(name: n, scope: .builtIn, health: .connected))
        }
        return inv
    }
}
