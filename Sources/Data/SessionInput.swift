import AppKit
import SwiftTerm

/// One serial queue for every AppleScript sent to iTerm (NSAppleScript is not thread-safe, and concurrent scripts
/// would interleave keystrokes).
enum ITermScript {
    static let queue = DispatchQueue(label: "mcc.iterm")

    /// Runs `source` on the iTerm queue; calls back on the main queue with the result string or the error.
    static func run(_ source: String, completion: @escaping (_ result: String?, _ error: NSDictionary?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            DispatchQueue.main.async { completion(result, error) }
        }
    }

    /// AppleScript string literal (quotes and backslashes escaped).
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Types a message into a running session, as if the user typed it, then presses Return:
/// - background sessions: through a short-lived `claude attach` client in a hidden pseudo-terminal;
/// - interactive sessions: into their own iTerm tab.
/// No model call, no relay: instant and free.
@MainActor
enum SessionInput {
    static func type(_ text: String, into live: LiveSession, completion: @escaping (String?) -> Void) {
        if live.kind == "background" {
            AttachTyper.type(text, job: live.shortId, completion: completion)
        } else if let pid = live.pid, let tty = Compactor.tty(of: pid) {
            typeInITerm(text, tty: tty, completion: completion)
        } else {
            completion("Session sans terminal joignable.")
        }
    }

    /// Writes `text` + Return into the iTerm session attached to `tty` (hotkey window first: it isn't in `windows`).
    static func typeInITerm(_ text: String, tty: String, completion: @escaping (String?) -> Void) {
        // Control characters out (an Escape could end the paste and run as keys); newlines stay inside the message.
        let safe = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }))
        if ITermAPI.isEnabled {
            ITermScript.queue.async {
                let api = ITermAPI.shared
                // Bracketed paste: a multi-line message stays one message; Return is sent once it has landed.
                let ok = api.session(tty: tty).map { s -> Bool in
                    guard api.send("\u{1B}[200~" + safe + "\u{1B}[201~", session: s.id) else { return false }
                    Thread.sleep(forTimeInterval: 0.3)
                    return api.send("\r", session: s.id)
                } ?? false
                DispatchQueue.main.async {
                    if ok { completion(nil) } else { typeWithAppleScript(safe, tty: tty, completion: completion) }
                }
            }
            return
        }
        typeWithAppleScript(safe, tty: tty, completion: completion)
    }

    /// AppleScript `write text` presses Return at every newline: the message is sent as one line.
    private static func typeWithAppleScript(_ text: String, tty: String, completion: @escaping (String?) -> Void) {
        let oneLine = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let t = ITermScript.literal(tty), x = ITermScript.literal(oneLine)
        let source = """
        tell application "iTerm"
            try
                repeat with t in tabs of current window
                    repeat with s in sessions of t
                        if tty of s is \(t) then
                            tell s to write text \(x)
                            return "ok"
                        end if
                    end repeat
                end repeat
            end try
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(t) then
                            tell s to write text \(x)
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        ITermScript.run(source) { result, error in
            if let error { completion("iTerm n'a pas accepté la saisie (\(error[NSAppleScript.errorMessage] as? String ?? "erreur")).") }
            else { completion(result == "notfound" ? "Onglet iTerm de la session introuvable." : nil) }
        }
    }

    /// Closes the iTerm session attached to `tty` (after its process has exited).
    static func closeITermTab(tty: String) {
        let t = ITermScript.literal(tty)
        ITermScript.run("""
        tell application "iTerm"
            try
                repeat with t in tabs of current window
                    repeat with s in sessions of t
                        if tty of s is \(t) then
                            close s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end try
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is \(t) then
                            close s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """) { _, _ in }
    }
}

/// A hidden `claude attach <job>` client: waits for the screen to settle, pastes the text (bracketed paste, so
/// newlines stay inside the message), presses Return, then detaches. The background session keeps running.
final class AttachTyper: LocalProcessDelegate {
    private var process: LocalProcess!
    private let queue = DispatchQueue(label: "mcc.attach")
    private var lastData = Date()
    private let started = Date()
    private var finished = false
    private var sent = false
    private let text: String
    private let completion: (String?) -> Void
    private static var running: [ObjectIdentifier: AttachTyper] = [:]   // keeps typers alive until done (main queue)

    private init(text: String, completion: @escaping (String?) -> Void) {
        self.text = text
        self.completion = completion
    }

    @MainActor
    static func type(_ text: String, job: String, completion: @escaping (String?) -> Void) {
        guard let claude = UsagePoller.claudePath else { completion("Claude Code introuvable."); return }
        let typer = AttachTyper(text: text, completion: completion)
        running[ObjectIdentifier(typer)] = typer
        typer.process = LocalProcess(delegate: typer, dispatchQueue: typer.queue)
        typer.process.startProcess(executable: claude, args: ["attach", job], environment: Terminals.environment(),
                                   currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        typer.queue.asyncAfter(deadline: .now() + 0.5) { typer.tick() }
    }

    /// Sends once the screen has been quiet for 0.6 s (at least 1.5 s after start, at most 8 s).
    private func tick() {
        guard !finished else { return }
        let age = Date().timeIntervalSince(started), quiet = Date().timeIntervalSince(lastData)
        if !sent, age > 1.5 && quiet > 0.6 || age > 8 {
            sent = true
            // Control characters (Esc above all) could end the bracketed paste early and be read as keys.
            let safe = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }))
            let paste = "\u{1B}[200~" + safe + "\u{1B}[201~"
            process.send(data: ArraySlice(Array(paste.utf8)))
            queue.asyncAfter(deadline: .now() + 0.5) {
                self.process.send(data: ArraySlice(Array("\r".utf8)))
                self.queue.asyncAfter(deadline: .now() + 1.5) { self.finish(nil) }
            }
            return
        }
        queue.asyncAfter(deadline: .now() + 0.2) { self.tick() }
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        let pid = process.shellPid, wasRunning = process.running
        process.terminate()
        if wasRunning { Terminals.reap(pid) }
        DispatchQueue.main.async {
            AttachTyper.running[ObjectIdentifier(self)] = nil
            self.completion(error)
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        if !sent { finish("La session d'arrière-plan n'a pas pu être rattachée (claude attach).") }
    }
    func dataReceived(slice: ArraySlice<UInt8>) { lastData = Date() }
    func getWindowSize() -> winsize { winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0) }
}

/// Shared settings for terminals the app runs itself (`claude attach`).
enum Terminals {
    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "fr_FR.UTF-8"
        // Apps launched from Finder get a minimal PATH: keep Claude Code's own tools reachable.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")]).joined(separator: ":")
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Collects the exit status of a child just terminated: its LocalProcess (and the exit monitor it owns) may be
    /// released right after, which would leave the process as a zombie until the app quits.
    static func reap(_ pid: pid_t) {
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
    }
}

/// Background sessions are managed through Claude Code's own commands (`claude stop`, `claude rm`).
enum BackgroundJobs {
    /// Stops a background session and removes it from Claude Code's list; calls back on the main queue.
    private static var inFlight = Set<String>()   // main thread: a job stopped twice at once (stop + delete) runs once

    static func stopAndRemove(_ job: String, completion: (() -> Void)? = nil) {
        guard let claude = UsagePoller.claudePath, !job.isEmpty, !inFlight.contains(job) else { completion?(); return }
        inFlight.insert(job)
        DispatchQueue.global(qos: .userInitiated).async {
            for args in [["stop", job], ["rm", job]] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claude)
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { continue }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
                p.waitUntilExit()
                killer.cancel()
            }
            DispatchQueue.main.async { inFlight.remove(job); completion?() }
        }
    }

    /// True when Claude Code still knows this job (its folder in ~/.claude/jobs).
    static func exists(_ job: String) -> Bool {
        !job.isEmpty && FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jobs/\(job)").path)
    }
}
