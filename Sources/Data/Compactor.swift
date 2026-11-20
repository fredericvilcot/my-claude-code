import AppKit
import Observation

/// "Compacter": types into the session's own iTerm tab a request for a synthesis note, waits for it,
/// then types `/compact` asking to keep that note. Sessions can't run /compact themselves, so the app types it.
@MainActor
@Observable
final class Compactor {
    static let shared = Compactor()

    enum Step: Equatable {
        case writingNote(String)   // note path
        case compacting(String)
        case done(String)
        case failed(String)
    }
    private(set) var steps: [String: Step] = [:]
    @ObservationIgnored private var watchers: [String: Timer] = [:]

    func step(_ sessionID: String) -> Step? { steps[sessionID] }

    func compact(_ session: SessionStat, live: LiveSession) {
        let id = session.info.id
        if case .writingNote = steps[id] { return }
        if case .compacting = steps[id] { return }
        guard let pid = live.pid, let tty = Self.tty(of: pid) else {
            steps[id] = .failed("Session sans terminal (arrière-plan) : compactez-la depuis son onglet.")
            return
        }
        let project = (session.info.project as NSString).lastPathComponent
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "-" +
            Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: "")
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/session-notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let note = dir.appendingPathComponent("\(project.isEmpty ? "session" : project)-\(stamp).md").path
        let prompt = "Avant une compaction de contexte : rédige une note de synthèse de cette session dans \(note) "
            + "(objectif, ce qui est fait, ce qui reste à faire, décisions prises, fichiers clés, prochaines étapes), "
            + "puis réponds seulement « note prête »."
        steps[id] = .writingNote(note)
        Self.type(prompt, tty: tty) { [weak self] error in
            guard let self else { return }
            if let error { self.steps[id] = .failed(error); return }
            self.waitForTurn(id) {
                self.steps[id] = .compacting(note)
                Self.type("/compact Conserve l'essentiel de la note de synthèse \(note) et l'état du travail en cours.", tty: tty) { error in
                    if let error { self.steps[id] = .failed(error); return }
                    self.waitForTurn(id) {
                        self.steps[id] = .done(note)
                        UsageStore.shared.refreshAll()
                    }
                }
            }
        }
    }

    /// Calls back once the session has worked (busy) and is idle again; gives up after 20 minutes.
    private func waitForTurn(_ id: String, then: @escaping () -> Void) {
        watchers[id]?.invalidate()
        var sawBusy = false
        let start = Date()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let phase = UsageStore.shared.live[id]?.phase
                if phase == 0 { sawBusy = true }
                if phase == nil { t.invalidate(); self.steps[id] = .failed("La session s'est fermée."); return }
                // Idle again after working (or never seen busy after 25 s: a very fast turn).
                if phase != 0, sawBusy || Date().timeIntervalSince(start) > 25 {
                    t.invalidate(); then()
                } else if Date().timeIntervalSince(start) > 1200 {
                    t.invalidate(); self.steps[id] = .failed("Pas de fin de tour après 20 min.")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchers[id] = timer
    }

    static func tty(of pid: Int32) -> String? {
        let out = Shell.run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty || out.hasPrefix("?") ? nil : "/dev/" + out
    }

    /// Types `text` + Return into the iTerm session attached to `tty` (hotkey window first: it isn't in `windows`).
    static func type(_ text: String, tty: String, completion: @escaping (String?) -> Void) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "iTerm"
            try
                repeat with t in tabs of current window
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            tell s to write text "\(escaped)"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end try
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            tell s to write text "\(escaped)"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            let message: String? = error != nil
                ? "iTerm n'a pas accepté la saisie (\(error?[NSAppleScript.errorMessage] as? String ?? "erreur"))."
                : result == "notfound" ? "Onglet iTerm de la session introuvable." : nil
            DispatchQueue.main.async { completion(message) }
        }
    }
}
