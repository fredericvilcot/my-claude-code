import Foundation

/// A Claude Code session currently running (from `claude agents --json`), with its messaging name.
struct LiveSession {
    let sessionId: String
    let name: String          // messaging name used by SendMessage, e.g. "my-project-42"
    let shortId: String
    let kind: String          // "interactive" or "background"
    let state: String         // busy, idle, blocked…
    var pid: Int32? = nil     // process of an interactive session (to stop it)

    /// Sort/display phase: 0 working, 1 waiting for the user, 2 open but idle.
    var phase: Int {
        switch state {
        case "busy", "running": return 0
        case "idle": return 2
        default: return 1
        }
    }

    var label: String {
        switch state {
        case "busy", "running": return "en cours"
        case "idle": return "au repos"
        case "blocked", "waiting": return "attend votre réponse"
        default: return state
        }
    }
}

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
                  let pid = (s["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 else { continue }   // process still alive
            out[sid] = LiveSession(sessionId: sid, name: s["name"] as? String ?? "", shortId: String(sid.prefix(8)),
                                   kind: s["kind"] as? String ?? "interactive", state: s["status"] as? String ?? "idle", pid: pid)
        }
        return out
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
                                   kind: s["kind"] as? String ?? "interactive",
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
        "\n\n— via My Claude Code \(marker) · réponds avec SendMessage à l'expéditeur de ce message."
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
                    typed in the My Claude Code menu bar app. After sending, wait for the reply: run the Bash command `sleep 15`, then check whether a <cross-session-message> \
                    from that session arrived; repeat at most 12 times. Never answer the session yourself. Finally, if SendMessage succeeded, \
                    reply with the exact token RELAY_DELIVERED then, on a new line, "Réponse : " followed by their reply verbatim \
                    (or "Réponse : aucune" if none came); otherwise give the exact error and never write that token.
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
        Then wait for their replies: run the Bash command `sleep 15`, then check whether <cross-session-message> replies \
        arrived; repeat at most 12 times or until every session replied. Never answer them yourself.
        Finally reply with the exact token RELAY_DELIVERED, then "Message envoyé : " with the message you sent (without its \
        last line), then "Réponse de <session> : " with each reply verbatim (or "aucune"). If a send failed, say which one \
        and why, without that token.
        <instruction>
        \(instruction)
        </instruction>
        """
        let r = await runEphemeral(relay, model: "claude-sonnet-5-5")
        let report = stripFooter(r.text.replacingOccurrences(of: "RELAY_DELIVERED", with: "")).trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.text.contains("RELAY_DELIVERED"), report)
    }
}
