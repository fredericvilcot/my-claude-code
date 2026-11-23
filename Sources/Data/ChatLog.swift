import Foundation

/// One bubble of a session chat.
struct ChatItem: Identifiable, Equatable {
    /// me: sent from My Claude Code · agent: sent by this session · peer: received from another session.
    enum Role { case me, agent, peer }
    let id: String
    let role: Role
    let text: String
    let date: Date
    var from = ""
    var to = ""
}

/// Rebuilds a session's inter-session messaging from its transcript: messages it received through Claude Code's
/// agent messaging (from the app or from any other session) and the messages it sent with SendMessage.
/// Its terminal output and prompts typed in the terminal are left out.
enum ChatLog {
    /// Parse state of one transcript: the messages so far and where the next read starts. Transcripts only grow,
    /// so each refresh parses the new lines only (a shorter file is read again from the start).
    private struct State {
        var size: UInt64 = 0
        var end: UInt64 = 0
        var items: [ChatItem] = []
        var appSenders = Set<String>()   // relay addresses, to recognize replies sent back to the app
        var subagents = Set<String>()    // this session's own subagents: their traffic is not inter-session chat
    }
    private static var cache: [String: State] = [:]
    private static let lock = NSLock()

    static func transcript(for sessionID: String) -> String? {
        UsageLog.transcriptPath(for: sessionID)
    }

    static func isApp(_ name: String) -> Bool { name.hasPrefix("my-claude-code") }

    /// Subagent task ids look like "a" + 16 hex digits; sessions are addressed by name or UUID.
    static func isSubagentID(_ id: String) -> Bool {
        id.count == 17 && id.first == "a" && id.dropFirst().allSatisfy(\.isHexDigit)
    }

    static func items(for sessionID: String, appPrompts: Set<String>) -> [ChatItem] {
        guard let path = transcript(for: sessionID) else { return [] }
        let size = TranscriptWork.size(of: path)
        lock.lock(); let cached = cache[path]; lock.unlock()
        if let cached, cached.size == size { return cached.items }
        var state = cached ?? State()
        if size < state.end { state = State() }
        guard let handle = FileHandle(forReadingAtPath: path) else { return state.items }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.end)
        let data = handle.readDataToEndOfFile()
        if let lastNewline = data.lastIndex(of: 0x0A) {
            let complete = data[data.startIndex...lastNewline]
            state.end += UInt64(complete.count)
            parse(complete, into: &state)
        }
        state.size = size
        lock.lock(); cache[path] = state; lock.unlock()
        return state.items
    }

    private static func parse(_ data: Data, into state: inout State) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            guard type == "user" || type == "assistant", obj["isSidechain"] as? Bool != true else { continue }
            let date = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            let uuid = obj["uuid"] as? String ?? UUID().uuidString
            let content = (obj["message"] as? [String: Any])?["content"]

            if type == "user" {
                // Messages this session received through agent messaging (never prompts typed by a human).
                // Subagent hand-backs share the "peer" origin but carry a task id: they are internal, skip them.
                if let origin = obj["origin"] as? [String: Any], origin["kind"] as? String == "peer",
                   origin["senderTaskId"] == nil, origin["handback"] == nil,
                   let body = origin["body"] as? String {
                    let name = origin["name"] as? String ?? (origin["from"] as? String ?? "session")
                    if isApp(name), let addr = origin["from"] as? String { state.appSenders.insert(addr) }
                    let quick = body.contains(PromptSender.quickMarker)
                    state.items.append(ChatItem(id: uuid, role: isApp(name) && !quick ? .me : .peer, text: PromptSender.stripFooter(body),
                                                date: date, from: quick ? "agent éphémère" : name))
                } else if let origin = obj["origin"] as? [String: Any], let task = origin["senderTaskId"] as? String {
                    state.subagents.insert(task)
                }
                continue
            }
            // Messages this session sent with SendMessage (its terminal text is never shown).
            guard let blocks = content as? [[String: Any]] else { continue }
            for (i, b) in blocks.enumerated() where b["type"] as? String == "tool_use" && b["name"] as? String == "SendMessage" {
                let input = b["input"] as? [String: Any] ?? [:]
                guard let message = input["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let to = input["to"] as? String ?? ""
                // Instructions to this session's own subagents are internal, not inter-session messages.
                if state.subagents.contains(to) || isSubagentID(to) { continue }
                let toApp = isApp(to) || state.appSenders.contains(to)
                state.items.append(ChatItem(id: "\(uuid)-\(i)", role: .agent, text: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                            date: date, to: toApp ? "My Claude Code" : to))
            }
        }
    }
}
