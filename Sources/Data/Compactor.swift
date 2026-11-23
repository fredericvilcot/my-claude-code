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
        guard !Restarter.shared.isBusy(id) else { return }   // never two hand-overs typing into the same session
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
        let job = live.kind == "background" ? live.shortId : nil
        SessionInput.type(prompt, into: live) { [weak self] error in
            guard let self else { return }
            if let error { self.steps[id] = .failed(error); return }
            self.waitForTurn(id, job: job) {
                self.steps[id] = .compacting(note)
                SessionInput.type("/compact Conserve l'essentiel de la note de synthèse \(note) et l'état du travail en cours.", into: live) { error in
                    if let error { self.steps[id] = .failed(error); return }
                    self.waitForTurn(id, job: job) {
                        self.steps[id] = .done(note)
                        UsageStore.shared.refreshAll()
                    }
                }
            }
        }
    }

    /// Calls back once the session has worked (busy) and is idle again; gives up after 20 minutes.
    func isBusy(_ id: String) -> Bool {
        switch steps[id] { case .writingNote, .compacting: true; default: false }
    }

    /// Phase of a session during a hand-over: a background job that ended its turn ("done") leaves the live list
    /// while staying idle and reachable, so it counts as idle rather than closed.
    static func turnPhase(_ id: String, job: String?) -> Int? {
        if let phase = UsageStore.shared.live[id]?.phase { return phase }
        if let job, BackgroundJobs.exists(job) { return 2 }
        return nil
    }

    private func waitForTurn(_ id: String, job: String?, then: @escaping () -> Void) {
        watchers[id]?.invalidate()
        var sawBusy = false
        let start = Date()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let phase = Compactor.turnPhase(id, job: job)
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

    nonisolated static func tty(of pid: Int32) -> String? {
        let out = Shell.run("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty || out.hasPrefix("?") ? nil : "/dev/" + out
    }
}
