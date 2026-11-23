import Foundation

/// Claude Code setup and live session status, read locally (names and settings only, never secrets).
struct ClaudeStatus {
    var version: String?
    var model: String?
    var effort: String?
    var thinking: Bool?
    var fast: Bool?
    var outputStyle: String?
    var sessionName: String?
    var cwd: String?
    var contextPercent: Double?
    var contextUsed: Int?
    var contextSize: Int?
    var statusDate: Date?

    var permissionMode: String?
    var language: String?
    var hooks: [String] = []
    var mcp: [(name: String, transport: String, scope: String)] = []
    var skills = 0
    var agents = 0
    var commands = 0
    var plugins = 0
    var claudeMdBytes = 0
    var memories = 0

    static func load() -> ClaudeStatus {
        var s = ClaudeStatus()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        func json(_ path: String) -> [String: Any]? {
            (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        // Live session (status line snapshot written by Claude Code).
        let linePath = PlanUsage.snapshotURL.path
        if let line = json(linePath) {
            s.version = line["version"] as? String
            s.model = (line["model"] as? [String: Any])?["display_name"] as? String
            s.effort = (line["effort"] as? [String: Any])?["level"] as? String
            s.thinking = (line["thinking"] as? [String: Any])?["enabled"] as? Bool
            s.fast = line["fast_mode"] as? Bool
            s.outputStyle = (line["output_style"] as? [String: Any])?["name"] as? String
            s.sessionName = line["session_name"] as? String
            s.cwd = line["cwd"] as? String
            if let ctx = line["context_window"] as? [String: Any] {
                s.contextPercent = (ctx["used_percentage"] as? NSNumber)?.doubleValue
                s.contextUsed = (ctx["total_input_tokens"] as? NSNumber)?.intValue
                s.contextSize = (ctx["context_window_size"] as? NSNumber)?.intValue
            }
            s.statusDate = (try? fm.attributesOfItem(atPath: linePath)[.modificationDate]) as? Date
        }

        // User settings.
        if let settings = json("\(home)/.claude/settings.json") {
            s.permissionMode = (settings["permissions"] as? [String: Any])?["defaultMode"] as? String
            s.language = settings["language"] as? String
            s.hooks = ((settings["hooks"] as? [String: Any]) ?? [:]).keys.sorted()
            s.plugins = ((settings["enabledPlugins"] as? [String: Any]) ?? [:]).values.compactMap { $0 as? Bool }.filter { $0 }.count
        }

        // MCP servers: user scope and every project scope (name + transport only).
        if let root = json("\(home)/.claude.json") {
            func add(_ servers: Any?, scope: String) {
                for (name, value) in (servers as? [String: Any]) ?? [:] where !s.mcp.contains(where: { $0.name == name }) {
                    let type = (value as? [String: Any])?["type"] as? String ?? "stdio"
                    s.mcp.append((name, type, scope))
                }
            }
            add(root["mcpServers"], scope: "utilisateur")
            for (path, project) in (root["projects"] as? [String: Any]) ?? [:] {
                add((project as? [String: Any])?["mcpServers"], scope: (path as NSString).lastPathComponent)
            }
            s.mcp.sort { $0.name < $1.name }
        }

        func count(_ dir: String, ext: String? = nil) -> Int {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") && (ext == nil || $0.hasSuffix(ext!)) }.count
        }
        s.skills = count("\(home)/.claude/skills")
        s.agents = count("\(home)/.claude/agents", ext: ".md")
        s.commands = count("\(home)/.claude/commands", ext: ".md")
        s.claudeMdBytes = ((try? fm.attributesOfItem(atPath: "\(home)/.claude/CLAUDE.md")[.size]) as? NSNumber)?.intValue ?? 0
        s.memories = (try? fm.contentsOfDirectory(atPath: "\(home)/.claude/projects"))?.reduce(0) { total, dir in
            total + count("\(home)/.claude/projects/\(dir)/memory", ext: ".md")
        } ?? 0

        return s
    }
}

enum Shell {
    static func run(_ tool: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
