import Foundation
import Observation

/// "Compacter": types into the session's own iTerm tab a request for a synthesis note, waits for it,
/// then types `/compact` asking to keep that note. Sessions can't run /compact themselves, so the app types it.
@MainActor
@Observable
final class Compactor {
    /// Set by the composition root (App/Composition.swift).
    static var shared: Compactor!
    private let ports: HandOverPorts
    init(ports: HandOverPorts) { self.ports = ports }

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
        guard Restarter.shared?.isBusy(id) != true else { return }   // never two hand-overs typing into the same session
        let project = (session.info.project as NSString).lastPathComponent
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "-" +
            Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: "")
        let note = ports.notes.newNotePath(folder: project.isEmpty ? "session" : project, suffix: stamp)
        let prompt = "Avant une compaction de contexte : rédige une note de synthèse de cette session dans \(note) "
            + "(objectif, ce qui est fait, ce qui reste à faire, décisions prises, fichiers clés, prochaines étapes), "
            + "puis réponds seulement « note prête »."
        steps[id] = .writingNote(note)
        let job = live.kind == "background" ? live.shortId : nil
        ports.typing.type(prompt, into: live) { [weak self] error in
            guard let self else { return }
            if let error { self.steps[id] = .failed(error); return }
            self.waitForTurn(id, job: job) {
                self.steps[id] = .compacting(note)
                self.ports.typing.type("/compact Conserve l'essentiel de la note de synthèse \(note) et l'état du travail en cours.", into: live) { error in
                    if let error { self.steps[id] = .failed(error); return }
                    self.waitForTurn(id, job: job) {
                        self.steps[id] = .done(note)
                        self.ports.state.refresh()
                    }
                }
            }
        }
    }

    /// Calls back once the session has worked (busy) and is idle again; gives up after 20 minutes.
    func isBusy(_ id: String) -> Bool {
        switch steps[id] { case .writingNote, .compacting: true; default: false }
    }


    private func waitForTurn(_ id: String, job: String?, then: @escaping () -> Void) {
        watchers[id]?.invalidate()
        var sawBusy = false
        let start = Date()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let phase = self.ports.state.phase(of: id, job: job)
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

}
