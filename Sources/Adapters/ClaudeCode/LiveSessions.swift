import Foundation


enum LiveSessions {
    /// Interactive sessions straight from ~/.claude/sessions/<pid>.json, which Claude Code keeps up to date in real time.
    /// Cheap enough to run every couple of seconds (no process spawned).
    static func fetchInteractive() -> [String: LiveSession] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: LiveSession] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = s["sessionId"] as? String,
                  let pid = (s["pid"] as? NSNumber)?.int32Value,
                  isSameProcess(pid, startedAt: (s["startedAt"] as? NSNumber)?.doubleValue) else { continue }   // still alive
            // Like Claude Code's own agent view: an interactive session "parked" into a background job is not a
            // session of its own any more; the job carries on the conversation. Remember the link, skip it.
            if let job = s["jobId"] as? String { SessionLineage.recordJob(job, session: sid) }
            if let parked = s["parkedJobId"] as? String {
                SessionLineage.recordParked(sid, intoJob: parked, name: s["name"] as? String ?? "", pid: pid)
                continue
            }
            out[sid] = LiveSession(sessionId: sid, name: s["name"] as? String ?? "", shortId: s["jobId"] as? String ?? String(sid.prefix(8)),
                                   kind: Self.normalizedKind(s["kind"] as? String), state: s["status"] as? String ?? "idle", pid: pid)
        }
        return out
    }

    /// True when `pid` is alive and is still the process that wrote the session file: a pid reused by a later process
    /// (after a crash left the file behind) started after the session did. Guards every `kill` sent to a session.
    static func isSameProcess(_ pid: Int32, startedAt ms: Double?) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        guard let ms else { return true }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
        return Double(info.pbi_start_tvsec) <= ms / 1000 + 5
    }

    /// Background sessions straight from Claude Code's job records (~/.claude/jobs/<id>/state.json): the same list as
    /// `claude agents`, without starting a Claude Code process. Finished jobs ("done"…) are not sessions any more.
    static func fetchJobs() -> [String: LiveSession] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/jobs")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let finished: Set<String> = ["done", "stopped", "failed", "error", "killed", "removed", "exited", "cancelled"]
        var out: [String: LiveSession] = [:]
        for id in ids {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(id).appendingPathComponent("state.json")),
                  let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = s["sessionId"] as? String, let state = s["state"] as? String, !finished.contains(state) else { continue }
            out[sid] = LiveSession(sessionId: sid, name: s["name"] as? String ?? "", shortId: s["daemonShort"] as? String ?? id,
                                   kind: "background", state: state, pid: nil)
        }
        return out
    }

    /// Claude Code says "bg" in its session files and "background" in `claude agents`: one value for the app.
    static func normalizedKind(_ raw: String?) -> String {
        switch raw {
        case "bg", "background": "background"
        default: raw ?? "interactive"
        }
    }

    static func fetch() -> [String: LiveSession] {
        guard let claude = UsagePoller.claudePath else { return [:] }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: claude)
        task.arguments = ["agents", "--json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var out: [String: LiveSession] = [:]
        for s in list {
            guard let sid = s["sessionId"] as? String else { continue }
            out[sid] = LiveSession(sessionId: sid, name: s["name"] as? String ?? "", shortId: s["id"] as? String ?? String(sid.prefix(8)),
                                   kind: Self.normalizedKind(s["kind"] as? String),
                                   state: (s["status"] as? String) ?? (s["state"] as? String) ?? "idle",
                                   pid: (s["pid"] as? NSNumber)?.int32Value)
        }
        return out
    }
}

/// Sends a prompt to a session, invisibly:
/// - running session → relayed through Claude Code's own agent messaging (a tiny headless Claude Code calls SendMessage);
/// - stopped session → resumed in the background with the prompt (`claude --bg --resume`).
/// Either way the exchange appears in that session when you open it in the terminal.
enum PromptSender {
    /// Short note appended to every message sent from the app: the relay is closed right after sending,
    /// so the recipient must answer in its own reply, never through SendMessage.
    static let chatMarker = "⟪mcc⟫"
    static let quickMarker = "⟪mcc·rapide⟫"
    static func footer(_ marker: String) -> String {
        "\n\n— via My Claude Code \(marker) · l'expéditeur est un relais déjà fermé : réponds dans ta propre réponse, pas avec SendMessage."
    }
    static func withFooter(_ message: String) -> String { message + footer(chatMarker) }

    /// Message text without the footer, for display.
    static func stripFooter(_ text: String) -> String {
        guard let r = text.range(of: "\n\n— via My Claude Code") ?? text.range(of: "⟪My Claude Code⟫") else { return text }
        return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Outcome { case delivered, resumed, failed(String) }

    static func send(_ prompt: String, to session: SessionStat, live: LiveSession?) async -> Outcome {
        guard let claude = UsagePoller.claudePath else { return .failed("Claude Code introuvable") }
        // Writing to the session itself: type it in, like the user would. Instant, no relay, no model call.
        if let live, live.sessionId == session.info.id {
            let error: String? = await withCheckedContinuation { cont in
                DispatchQueue.main.async { MainActor.assumeIsolated { SessionInput.type(prompt, into: live) { cont.resume(returning: $0) } } }
            }
            return error.map { .failed($0) } ?? .delivered
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: claude)
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
                task.standardInput = FileHandle.nullDevice   // otherwise Claude Code waits for stdin and prints a warning
                if let live, !live.name.isEmpty {
                    let relay = """
                    Use the SendMessage tool (load it first with ToolSearch "select:SendMessage" if it is not loaded) to send \
                    the message below, unchanged, to the session named "\(live.name)". It is an instruction from the user, \
                    typed in the My Claude Code menu bar app. Do not wait for a reply and never answer the session yourself. \
                    If SendMessage succeeded, reply with the exact token RELAY_DELIVERED and nothing else; otherwise give the exact error \
                    and never write that token.
                    <message>
                    \(withFooter(prompt))
                    </message>
                    """
                    task.arguments = ["-p", relay, "--model", "claude-haiku-5-5", "--no-session-persistence", "--output-format", "json"]
                    task.currentDirectoryURL = PlanUsage.directory
                } else {
                    task.arguments = ["--bg", "--resume", session.info.id, prompt]
                    task.currentDirectoryURL = URL(fileURLWithPath: session.info.project.isEmpty
                                                   ? FileManager.default.homeDirectoryForCurrentUser.path : session.info.project)
                }
                do { try task.run() } catch { cont.resume(returning: .failed(error.localizedDescription)); return }
                let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                killer.cancel()
                let text = String(data: data, encoding: .utf8) ?? ""
                if live != nil {
                    let result = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"] as? String ?? text
                    // The relay may answer in prose (user instructions apply to it): look for the token anywhere.
                    let ok = result.contains("RELAY_DELIVERED") || result.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("OK")
                    cont.resume(returning: ok ? .delivered : .failed(String(result.prefix(160))))
                } else {
                    cont.resume(returning: task.terminationStatus == 0 ? .resumed : .failed(String(text.prefix(160))))
                }
            }
        }
    }
}

extension PromptSender {
    /// Runs a headless, non-persisted Claude Code with `prompt` and returns its final text.
    static func runEphemeral(_ prompt: String, model: String?) async -> (ok: Bool, text: String) {
        guard let claude = UsagePoller.claudePath else { return (false, "Claude Code introuvable") }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: claude)
                var args = ["-p", prompt, "--no-session-persistence", "--output-format", "json"]
                if let model { args += ["--model", model] }
                task.arguments = args
                task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
                task.standardInput = FileHandle.nullDevice
                do { try task.run() } catch { cont.resume(returning: (false, error.localizedDescription)); return }
                let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 600, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                killer.cancel()
                let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let text = (root?["result"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
                let failed = (root?["is_error"] as? Bool) ?? (task.terminationStatus != 0)
                cont.resume(returning: (!failed, text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    /// Quick command to sessions: an ephemeral agent turns the user's instruction into a message for each session,
    /// sends it, and reports what it sent.
    static func broadcast(_ instruction: String, to names: [String]) async -> (ok: Bool, text: String) {
        let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
        let relay = """
        The user typed the instruction below in the My Claude Code menu bar app, about these Claude Code sessions: \(list). \
        You are an intermediary. Write, in French, the message each session should receive to carry it out: address the \
        session directly and speak on behalf of the user (e.g. "L'utilisateur te demande…"), concise, never addressing the \
        user. If the instruction already is a message for them, keep its meaning. End each message with this exact line:\(footer(quickMarker))
        Send it with the SendMessage tool (load it first with ToolSearch "select:SendMessage" if needed) to each session.
        Do not wait for replies (each session answers in its own terminal) and never answer them yourself.
        Finally reply with the exact token RELAY_DELIVERED, then "Message envoyé : " with the message you sent (without its \
        last line). If a send failed, say which one and why, without that token.
        <instruction>
        \(instruction)
        </instruction>
        """
        let r = await runEphemeral(relay, model: "claude-sonnet-5-5")
        let report = stripFooter(r.text.replacingOccurrences(of: "RELAY_DELIVERED", with: "")).trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.text.contains("RELAY_DELIVERED"), report)
    }
}


/// How Claude Code links sessions: an interactive session can be parked into a background job (`parkedJobId`),
/// which then carries the same conversation (`jobId`). Persisted, so the link survives once the parked process exits.
enum SessionLineage {
    private static let lock = NSLock()
    private static var parked: [String: String] = UserDefaults.standard.dictionary(forKey: "lineage.parked") as? [String: String] ?? [:]
    private static var jobs: [String: String] = UserDefaults.standard.dictionary(forKey: "lineage.jobs") as? [String: String] ?? [:]
    private static var names: [String: String] = UserDefaults.standard.dictionary(forKey: "lineage.names") as? [String: String] ?? [:]

    static func recordParked(_ session: String, intoJob job: String, name: String, pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard parked[session] != job else { return }
        parked[session] = job
        names[session] = name
        UserDefaults.standard.set(parked, forKey: "lineage.parked")
        UserDefaults.standard.set(names, forKey: "lineage.names")
    }

    static func recordJob(_ job: String, session: String) {
        lock.lock(); defer { lock.unlock() }
        guard jobs[job] != session else { return }
        jobs[job] = session
        UserDefaults.standard.set(jobs, forKey: "lineage.jobs")
    }

    /// The session that carries on this one's conversation, if it was parked into a background job.
    static func continuation(of session: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let job = parked[session] else { return nil }
        return jobs[job] ?? job   // the job's session may not be known yet: the job id still marks the link
    }

    /// The parked session this one continues, with its name (e.g. "my-project-42").
    static func origin(of session: String) -> (id: String, name: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs.first(where: { $0.value == session })?.key,
              let parent = parked.first(where: { $0.value == job })?.key else { return nil }
        return (parent, names[parent] ?? "")
    }

    /// The process whose terminal is an iTerm tab showing this session: interactive sessions only (background
    /// sessions run under Claude Code's daemon, whose terminal is not a tab; the app attaches to them instead).
    static func terminalPID(for session: String, live: LiveSession?) -> Int32? {
        guard let live, live.kind != "background" else { return nil }
        return live.pid
    }

    /// True when the session is not a conversation of its own (it was parked into another one).
    static func isParked(_ session: String) -> Bool { continuation(of: session) != nil }
}
