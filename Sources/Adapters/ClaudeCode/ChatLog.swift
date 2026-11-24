import Foundation

/// One entry of a session chat.
struct ChatItem: Identifiable, Equatable {
    enum Role: Equatable {
        /// Older app message sent straight from My Claude Code (before the intermediary agents).
        case me
        /// Sent by this session to another one with SendMessage (`to`).
        case agent
        /// Received from another session (`from`).
        case peer
        /// The app's intermediary agent asking this session, on the user's behalf, to write to `to`.
        case relay
        /// Quick command: the app's intermediary agent passing the user's message to this session.
        case quick
        /// This session's own text in its turn after a relay or a quick command: its answer to a quick command, or
        /// what it said instead of writing (`to` is then the session it did not write to).
        case note
    }
    /// Outcome of a SendMessage, read from its tool result.
    enum Delivery: Equatable { case pending, sent, failed(String) }

    let id: String
    let role: Role
    var text: String
    let date: Date
    var from = ""
    var to = ""
    var delivery: Delivery = .sent
    /// Tag of the chat request this entry belongs to (conversation orchestrated by the app), "" otherwise.
    var ref = ""
}

/// Rebuilds a session's inter-session messaging from its transcript: messages it received through Claude Code's
/// agent messaging (from the app's intermediary agents or from any other session) and the messages it sent with
/// SendMessage, with their outcome. Its terminal output and prompts typed in the terminal are left out.
enum ChatLog {
    /// After a relay or a quick command, what the session does in its turn.
    private struct Watch {
        enum Kind { case quick, relay, compose, deliver }
        let kind: Kind
        let target: String     // the session it was asked to write or answer to
        let date: Date
        var ref = ""
        var texts: [String] = []
        var wrote = false
    }
    /// Parse state of one transcript: the messages so far and where the next read starts. Transcripts only grow,
    /// so each refresh parses the new lines only (a shorter file is read again from the start).
    private struct State {
        var size: UInt64 = 0
        var end: UInt64 = 0
        var items: [ChatItem] = []
        var subagents = Set<String>()    // this session's own subagents (ids and names): internal traffic
        var seen = Set<String>()         // message ids already shown (a queued message is recorded again when delivered)
        var sends: [String: Int] = [:]   // SendMessage tool_use id → item index, until its result is read
        var agentCalls = Set<String>()   // Agent tool_use ids, whose result gives the subagent id
        var watch: Watch?
    }
    private static var cache: [String: State] = [:]
    private static let lock = NSLock()

    static func transcript(for sessionID: String) -> String? {
        UsageLog.transcriptPath(for: sessionID)
    }

    /// The app's intermediary agents run in the app's folder, so Claude Code names them after it.
    static func isApp(_ name: String) -> Bool { name.hasPrefix("my-claude-code") }

    /// Subagent task ids look like "a" + 16 hex digits; sessions are addressed by name or UUID.
    static func isSubagentID(_ id: String) -> Bool {
        id.count == 17 && id.first == "a" && id.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// The session a relay asks to write to, from the footer the app's agent copies verbatim.
    static func relayTarget(_ body: String) -> String {
        guard let start = body.range(of: "le message pour « "),
              let end = body.range(of: " »", range: start.upperBound..<body.endIndex) else { return "" }
        return String(body[start.upperBound..<end.lowerBound])
    }

    static func items(for sessionID: String) -> [ChatItem] {
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

    /// End of the session's turn after a relay or a quick command: its answer to a quick command, or — when asked to
    /// write and it did not — what it said instead.
    private static func closeWatch(_ state: inout State, at date: Date) {
        guard let w = state.watch else { return }
        state.watch = nil
        let text = (w.texts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let all = w.texts.joined(separator: "\n\n")
        let id = "note-\(w.date.timeIntervalSince1970)"
        switch w.kind {
        case .quick:
            if !text.isEmpty { state.items.append(ChatItem(id: id, role: .note, text: text, date: date)) }
        case .relay:
            if !w.wrote {
                state.items.append(ChatItem(id: id, role: .note, text: text.isEmpty ? "(aucune réponse)" : text, date: date, to: w.target))
            }
        case .compose:
            // Its message for the other session, between <message> tags; without them it did not write one.
            if let message = PromptSender.between("message", in: all), !message.isEmpty {
                state.items.append(ChatItem(id: id, role: .agent, text: message, date: date, to: w.target, ref: w.ref))
            } else {
                state.items.append(ChatItem(id: id, role: .note, text: text.isEmpty ? "(aucune réponse)" : text, date: date, to: w.target, ref: w.ref))
            }
        case .deliver:
            // Its answer, between <réponse> tags (empty: nothing to answer); without them, its whole reply.
            let answer = PromptSender.between("réponse", in: all) ?? text
            state.items.append(ChatItem(id: id, role: .agent, text: answer.isEmpty ? "(rien à répondre)" : answer,
                                        date: date, to: w.target, ref: w.ref))
        }
    }

    /// A message this session received through agent messaging (never a prompt typed by a human), shown once even
    /// when Claude Code records it both queued and delivered. Subagent hand-backs share the "peer" origin but carry a
    /// task id: they are internal, skipped.
    private static func received(_ origin: [String: Any], id: String, date: Date, into state: inout State) {
        if let task = origin["senderTaskId"] as? String { state.subagents.insert(task); return }
        guard origin["kind"] as? String == "peer", origin["handback"] == nil, let body = origin["body"] as? String else { return }
        if let msg = origin["msg_id"] as? String, !state.seen.insert(msg).inserted { return }
        let name = origin["name"] as? String ?? (origin["from"] as? String ?? "session")
        var text = PromptSender.stripFooter(body)
        if let leg = PromptSender.leg(of: body) {
            closeWatch(&state, at: date)
            switch leg.leg {
            case .compose:
                state.items.append(ChatItem(id: id, role: .relay, text: text, date: date, from: name, to: leg.name, ref: leg.tag))
                state.watch = Watch(kind: .compose, target: leg.name, date: date, ref: leg.tag)
            case .deliver, .answer:
                // "Message de la session « A » :" / "Réponse de la session « B » :" then the text itself.
                if text.hasPrefix("Message de la session") || text.hasPrefix("Réponse de la session"),
                   let r = text.range(of: "\n\n") { text = String(text[r.upperBound...]) }
                state.items.append(ChatItem(id: id, role: .peer, text: text, date: date, from: leg.name, ref: leg.tag))
                if leg.leg == .deliver { state.watch = Watch(kind: .deliver, target: leg.name, date: date, ref: leg.tag) }
            }
        } else if body.contains(PromptSender.relayMarker) {
            closeWatch(&state, at: date)
            let target = relayTarget(body)
            state.items.append(ChatItem(id: id, role: .relay, text: text, date: date, from: name, to: target))
            state.watch = Watch(kind: .relay, target: target, date: date)
        } else if body.contains(PromptSender.quickMarker) || (isApp(name) && body.contains(PromptSender.chatMarker)) {
            closeWatch(&state, at: date)
            state.items.append(ChatItem(id: id, role: isApp(name) && !body.contains(PromptSender.quickMarker) ? .me : .quick,
                                        text: text, date: date, from: name))
            state.watch = Watch(kind: .quick, target: "", date: date)
        } else {
            state.items.append(ChatItem(id: id, role: .peer, text: text, date: date, from: name))
        }
    }

    /// Why a SendMessage did not go through, from its tool result ("" when it did).
    private static func failure(_ block: [String: Any], _ result: Any?) -> String? {
        var text = ""
        if let s = block["content"] as? String { text = s }
        else if let parts = block["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        let error = block["is_error"] as? Bool == true || text.hasPrefix("Permission for this action was denied")
            || (result as? String)?.hasPrefix("Error") == true || text.contains("\"success\":false")
        guard error else { return nil }
        if text.contains("auto mode classifier") {
            let reason = text.range(of: "Reason: [").flatMap { r in text[r.upperBound...].split(separator: "]").first.map(String.init) }
            return "refusé par le mode automatique de Claude Code" + (reason.map { " (\($0))" } ?? "")
        }
        if text.contains("denied") || text.contains("rejected") { return "refusé" }
        return String(text.split(separator: "\n").first ?? "échec").prefix(160).description
    }

    private static func parse(_ data: Data, into state: inout State) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            guard obj["isSidechain"] as? Bool != true else { continue }
            let date = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            let uuid = obj["uuid"] as? String ?? UUID().uuidString
            let content = (obj["message"] as? [String: Any])?["content"]

            switch type {
            case "system":
                // End of a turn: what the session said after a relay or a quick command is known.
                if obj["subtype"] as? String == "turn_duration" { closeWatch(&state, at: date) }
            case "attachment":
                // A message received while the session was working is queued as an attachment, not as a user entry.
                if let a = obj["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
                   let origin = a["origin"] as? [String: Any] { received(origin, id: uuid, date: date, into: &state) }
            case "user":
                if let origin = obj["origin"] as? [String: Any] {
                    // A prompt typed in the terminal starts another turn: the watched one is over.
                    if origin["kind"] as? String == "human" { closeWatch(&state, at: date) }
                    received(origin, id: uuid, date: date, into: &state)
                }
                // Tool results: outcome of this session's SendMessage calls, ids of the subagents it launched.
                for b in content as? [[String: Any]] ?? [] where b["type"] as? String == "tool_result" {
                    guard let use = b["tool_use_id"] as? String else { continue }
                    if let i = state.sends.removeValue(forKey: use) {
                        let why = failure(b, obj["toolUseResult"])
                        state.items[i].delivery = why.map { .failed($0) } ?? .sent
                    } else if state.agentCalls.remove(use) != nil,
                              let agent = (obj["toolUseResult"] as? [String: Any])?["agentId"] as? String {
                        state.subagents.insert(agent)
                    }
                }
            case "assistant":
                guard let blocks = content as? [[String: Any]] else { continue }
                if state.watch != nil,
                   let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.watch?.texts.append(text)
                }
                for (i, b) in blocks.enumerated() where b["type"] as? String == "tool_use" {
                    let input = b["input"] as? [String: Any] ?? [:]
                    let name = b["name"] as? String
                    if name == "Agent" || name == "Task" {
                        if let id = b["id"] as? String { state.agentCalls.insert(id) }
                        if let n = input["name"] as? String { state.subagents.insert(n) }
                        continue
                    }
                    guard name == "SendMessage", let message = input["message"] as? String,
                          !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let to = input["to"] as? String ?? ""
                    // Instructions to this session's own subagents (or back to its lead) are internal.
                    if state.subagents.contains(to) || isSubagentID(to) || to == "main" { continue }
                    if state.watch != nil { state.watch?.wrote = true }
                    if let use = b["id"] as? String { state.sends[use] = state.items.count }
                    state.items.append(ChatItem(id: "\(uuid)-\(i)", role: .agent,
                                                text: PromptSender.stripFooter(message.trimmingCharacters(in: .whitespacesAndNewlines)),
                                                date: date, to: to, delivery: b["id"] == nil ? .sent : .pending))
                }
            default: break
            }
        }
    }
}
