import Foundation

/// What a session is doing right now, read from the tail of its transcript (no LLM, no quota).
struct SessionActivity: Equatable {
    let text: String     // "modifie SessionsView.swift"
    let since: Date
    let working: Bool    // false: the turn is over, waiting for the user
    var detail: String? = nil   // full command, file path or pattern
    var tool = ""               // tool name ("Bash", "Edit"…), empty when not a tool call
    var precision: String? = nil   // short but precise summary ("python3 · build.sh", "+12 −3 lignes")
}

enum ActivityReader {
    private static var cache: [String: (size: UInt64, activity: SessionActivity?, recent: [SessionActivity])] = [:]
    private static let lock = NSLock()

    static func activity(for sessionID: String) -> SessionActivity? { read(sessionID)?.activity }

    /// The session's latest tool actions, most recent first.
    static func recent(for sessionID: String, limit: Int = 4) -> [SessionActivity] { Array((read(sessionID)?.recent ?? []).prefix(limit)) }

    /// Last known activity, instantly; re-read in the background when the transcript grows (views showing it
    /// refresh every second or on `UsageStore.transcriptTick`).
    private static func read(_ sessionID: String) -> (activity: SessionActivity?, recent: [SessionActivity])? {
        guard let path = ChatLog.transcript(for: sessionID) else { return nil }
        let size = TranscriptWork.size(of: path)
        lock.lock(); let hit = cache[path]; lock.unlock()
        if let hit, hit.size == size { return (hit.activity, hit.recent) }
        TranscriptWork.schedule("activity:" + path, evenHidden: hit == nil) { _ = compute(path) }
        return hit.map { ($0.activity, $0.recent) }
    }

    @discardableResult
    private static func compute(_ path: String) -> (activity: SessionActivity?, recent: [SessionActivity])? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 1536 * 1024   // big tool calls (scripts) make a few entries weigh hundreds of KB
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let data = handle.readDataToEndOfFile()
        let result = parse(data), recent = actions(data)
        lock.lock(); cache[path] = (size, result, recent); lock.unlock()
        return (result, recent)
    }

    private static func actions(_ data: Data) -> [SessionActivity] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [SessionActivity] = []
        for line in data.split(separator: 0x0A).reversed() {
            guard line.contains(Array("tool_use".utf8)),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
                  let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let date = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            for tool in blocks.reversed() where tool["type"] as? String == "tool_use" {
                let d = describe(tool)
                out.append(SessionActivity(text: d.text, since: date, working: true, detail: d.detail, tool: tool["name"] as? String ?? "",
                                           precision: precision(tool)))
            }
            if out.count >= 20 { break }
        }
        return out
    }

    private static func parse(_ data: Data) -> SessionActivity? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Walk back to the latest main-thread user/assistant entry.
        for line in data.split(separator: 0x0A).reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  obj["isSidechain"] as? Bool != true else { continue }
            let date = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            let content = (obj["message"] as? [String: Any])?["content"]
            let blocks = content as? [[String: Any]] ?? []
            if type == "assistant" {
                if let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                    let d = describe(tool)
                    return SessionActivity(text: d.text, since: date, working: true, detail: d.detail, tool: tool["name"] as? String ?? "",
                                           precision: precision(tool))
                }
                if blocks.contains(where: { $0["type"] as? String == "thinking" }) {
                    return SessionActivity(text: "réfléchit", since: date, working: true)
                }
                return SessionActivity(text: "a répondu", since: date, working: false)
            }
            // user entry: a tool result (the model is thinking about it) or a new prompt.
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                // The next answer is only written once complete: until then, the model is preparing it.
                return SessionActivity(text: "prépare sa prochaine action", since: date, working: true)
            }
            return SessionActivity(text: "réfléchit à votre demande", since: date, working: true)
        }
        return nil
    }

    /// One short, precise line per action, without dumping the whole command.
    static func precision(_ tool: [String: Any]) -> String? {
        let name = tool["name"] as? String ?? ""
        let input = tool["input"] as? [String: Any] ?? [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func place(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            let parts = path.split(separator: "/")
            let tail = parts.suffix(2).joined(separator: "/")
            return path.hasPrefix(home) && parts.count <= 3 ? "~/" + tail : tail
        }
        func lines(_ s: Any?) -> Int { (s as? String).map { $0.isEmpty ? 0 : $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0 }
        switch name {
        case "Edit":
            let added = lines(input["new_string"]), removed = lines(input["old_string"])
            return [place(input["file_path"] as? String), "+\(added) −\(removed) lignes"].compactMap { $0 }.joined(separator: " · ")
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return [place(input["file_path"] as? String), "\(edits.count) modifications"].compactMap { $0 }.joined(separator: " · ")
        case "Write":
            return [place(input["file_path"] as? String), "\(lines(input["content"])) lignes"].compactMap { $0 }.joined(separator: " · ")
        case "Read":
            var range = "fichier entier"
            if let offset = input["offset"] as? Int {
                let limit = input["limit"] as? Int ?? 2000
                range = "lignes \(offset)–\(offset + limit)"
            } else if let limit = input["limit"] as? Int { range = "\(limit) premières lignes" }
            return [place(input["file_path"] as? String), range].compactMap { $0 }.joined(separator: " · ")
        case "Bash":
            guard var command = input["command"] as? String else { return nil }
            // Drop heredoc bodies (inline scripts): only the commands themselves matter here.
            if let regex = try? NSRegularExpression(pattern: "<<-?\\s*['\"]?(\\w+)['\"]?[^\\n]*\\n.*?\\n\\1(?=\\s|$)", options: [.dotMatchesLineSeparators]) {
                command = regex.stringByReplacingMatches(in: command, range: NSRange(command.startIndex..., in: command), withTemplate: "")
            }
            var folder: String?
            if let cd = command.range(of: #"(^|&&|;)\s*cd\s+([^\s;&|]+)"#, options: .regularExpression) {
                let target = command[cd].split(separator: " ").last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                folder = target.map { ($0 as NSString).lastPathComponent }
            }
            // Programs run, in order, without their arguments: "cd · python3 · build.sh · grep".
            var programs: [String] = []
            let separators = CharacterSet(charactersIn: "|;&\n")
            for segment in command.components(separatedBy: separators) {
                var words = segment.split(separator: " ").map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
                while let w = words.first, ["sudo", "env", "time", "until", "while", "do", "then", "if", "!", "(", "{", "done", "fi", "else"].contains(w) {
                    words.removeFirst()
                }
                guard let first = words.first, !first.hasPrefix("<"), !first.hasPrefix(">"), !first.hasPrefix("'"), !first.hasPrefix("\""),
                      !first.hasPrefix("-"), !first.hasPrefix("$") else { continue }
                let program = (first as NSString).lastPathComponent
                let noise: Set<String> = ["cd", "sleep", "true", "false", "echo", "export", "set", "exit", "S", "B"]
                if program.count > 1, program.count < 28, !noise.contains(program), !program.contains("'"), !program.contains("\""),
                   !programs.contains(program) { programs.append(program) }
            }
            var out = programs.prefix(5).joined(separator: " · ")
            if let folder, !folder.isEmpty, folder != "~" { out += (out.isEmpty ? "" : " ") + "dans \(folder)" }
            if input["run_in_background"] as? Bool == true { out += " · en arrière-plan" }
            return out.isEmpty ? nil : out
        case "Grep", "Glob":
            let pattern = (input["pattern"] as? String).map { "« \($0.count > 40 ? String($0.prefix(40)) + "…" : $0) »" }
            let scope = place(input["path"] as? String) ?? (input["glob"] as? String)
            return [pattern, scope.map { "dans " + $0 }].compactMap { $0 }.joined(separator: " ")
        case "Agent", "Task":
            return [input["subagent_type"] as? String, input["description"] as? String].compactMap { $0 }.joined(separator: " · ")
        case "WebFetch": return (input["url"] as? String).flatMap { URL(string: $0)?.host }
        case "WebSearch": return (input["query"] as? String).map { "« \($0) »" }
        case "Skill": return input["skill"] as? String
        case "SendMessage": return (input["to"] as? String).map { "à " + $0 }
        case "TodoWrite": return (input["todos"] as? [Any]).map { "\($0.count) tâches" }
        default: return nil
        }
    }

    private static func describe(_ tool: [String: Any]) -> (text: String, detail: String?) {
        let name = tool["name"] as? String ?? ""
        let input = tool["input"] as? [String: Any] ?? [:]
        let fullPath = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
        let file = fullPath.map { ($0 as NSString).lastPathComponent }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shownPath = fullPath.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        func short(_ s: String, _ n: Int = 60) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        switch name {
        case "Edit", "MultiEdit", "NotebookEdit": return ("modifie \(file ?? "un fichier")", shownPath)
        case "Write": return ("écrit \(file ?? "un fichier")", shownPath)
        case "Read": return ("lit \(file ?? "un fichier")", shownPath)
        case "Bash":
            let command = input["command"] as? String
            if let d = input["description"] as? String, !d.isEmpty { return (short(d), command) }
            return ("lance une commande", command)
        case "Grep", "Glob":
            return ("cherche « \(short(input["pattern"] as? String ?? "", 30)) »", [input["pattern"] as? String, shownPath].compactMap { $0 }.joined(separator: "  dans  "))
        case "Agent", "Task": return ("délègue à un sous-agent", (input["description"] as? String) ?? (input["prompt"] as? String).map { short($0, 200) })
        case "Workflow": return ("orchestre un workflow", nil)
        case "WebFetch": return ("consulte le web", input["url"] as? String)
        case "WebSearch": return ("cherche sur le web", input["query"] as? String)
        case "TodoWrite": return ("met à jour sa liste de tâches", nil)
        case "SendMessage": return ("envoie un message", (input["to"] as? String).map { "à " + $0 })
        case "AskUserQuestion": return ("vous pose une question", nil)
        case "Skill": return ("charge un skill", input["skill"] as? String)
        default:
            if name.hasPrefix("mcp__") { return ("utilise \(name.split(separator: "_").dropFirst(2).first.map(String.init) ?? "un MCP")", name) }
            return ("utilise \(name)", nil)
        }
    }
}
