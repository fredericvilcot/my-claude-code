import Foundation
import Observation

/// "Relancer à neuf": hands a session over to a fresh one, without ever losing anything.
/// 1. the session writes a complete synthesis note in ~/.claude/session-notes;
/// 2. a new Claude Code session starts in a new tab of iTerm's hotkey window, same folder, with a resume prompt;
/// 3. only once that new session is seen running: the old one is stopped, its tab closed, its transcript trashed;
/// 4. the app switches to the new session (panel sheet and floating window).
/// Any failure stops the hand-over before step 3: the old session stays untouched.
@MainActor
@Observable
final class Restarter {
    /// Set by the composition root (App/Composition.swift).
    static var shared: Restarter!
    private let ports: HandOverPorts
    init(ports: HandOverPorts) { self.ports = ports }

    enum Step: Equatable {
        case writingNote, opening, switching
        case done(String)        // new session id
        case failed(String)
    }
    private(set) var steps: [String: Step] = [:]
    @ObservationIgnored private var timers: [String: Timer] = [:]

    func step(_ id: String) -> Step? { steps[id] }

    func isBusy(_ id: String) -> Bool {
        switch steps[id] { case .writingNote, .opening, .switching: true; default: false }
    }

    func restart(_ session: SessionStat, live: LiveSession) {
        let id = session.info.id
        guard !isBusy(id), Compactor.shared?.isBusy(id) != true else { return }
        let dir = ports.notes.folderExists(session.info.project) ? session.info.project : ports.notes.home
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmm"
        let folder = (dir as NSString).lastPathComponent
        let note = ports.notes.newNotePath(folder: folder.isEmpty ? "session" : folder, suffix: f.string(from: Date()) + "-reprise")
        let ask = "Cette session va être fermée et reprise dans une nouvelle session. Rédige maintenant une note de synthèse complète "
            + "dans \(note) : objectif, ce qui est fait, ce qui reste à faire, décisions prises, fichiers clés, commandes utiles, "
            + "points d'attention et prochaine étape précise. Puis réponds seulement « note prête »."
        steps[id] = .writingNote
        ports.typing.type(ask, into: live) { [weak self] error in
            guard let self else { return }
            if let error { self.steps[id] = .failed(error); return }
            self.waitForNote(id, job: live.kind == "background" ? live.shortId : nil, note: note) {
                self.open(session, live: live, dir: dir, note: note)
            }
        }
    }

    private func open(_ session: SessionStat, live: LiveSession, dir: String, note: String) {
        let id = session.info.id
        steps[id] = .opening
        let started = Date()
        let resume = "Tu reprends un travail commencé dans une session précédente, qui vient d'être fermée. "
            + "Lis d'abord en entier la note de synthèse \(note), puis continue exactement là où le travail s'était arrêté, "
            + "sans refaire ce qui est déjà fait. Commence par résumer en trois lignes où nous en sommes."
        // Same model as the session it replaces.
        ports.launcher.start(in: dir, prompt: resume, model: session.lastModel.isEmpty ? nil : session.lastModel) { [weak self] error in
            guard let self else { return }
            if let error { self.steps[id] = .failed(error); return }
            self.waitForNewSession(after: started, in: dir, excluding: id) { newID in
                guard let newID else {
                    self.steps[id] = .failed("La nouvelle session n'a pas démarré : l'ancienne est conservée.")
                    return
                }
                self.steps[id] = .switching
                self.ports.retirement.retire(session, live: live)
                self.switchTo(newID, from: id)
            }
        }
    }


    /// Opens the new session's sheet (and swaps the floating window) as soon as its statistics exist.
    private func switchTo(_ newID: String, from oldID: String) {
        let start = Date()
        poll(oldID, every: 1) { [weak self] in
            guard let self else { return true }
            if let stat = self.ports.state.stat(of: newID) {
                self.ports.presenter.present(stat, replacing: oldID)
                self.steps[oldID] = .done(newID)
                return true
            }
            if Date().timeIntervalSince(start) > 90 { self.steps[oldID] = .done(newID); return true }
            return false
        }
    }

    // MARK: Waiting

    /// Calls back once the session has finished its turn and the note exists (20 minutes at most).
    private func waitForNote(_ id: String, job: String?, note: String, then: @escaping () -> Void) {
        var sawBusy = false
        var idleSince: Date?
        let start = Date()
        poll(id, every: 2) { [weak self] in
            guard let self else { return true }
            let phase = self.ports.state.phase(of: id, job: job)
            if phase == nil { self.steps[id] = .failed("La session s'est fermée avant d'écrire la note."); return true }
            if phase == 0 { sawBusy = true; idleSince = nil; return false }
            if sawBusy || Date().timeIntervalSince(start) > 30 {
                if self.ports.notes.exists(note) { then(); return true }
                idleSince = idleSince ?? Date()
                if Date().timeIntervalSince(idleSince!) > 30 {
                    self.steps[id] = .failed("La note de synthèse n'a pas été écrite : rien n'a été fermé.")
                    return true
                }
            }
            if Date().timeIntervalSince(start) > 1200 { self.steps[id] = .failed("Pas de note après 20 min : rien n'a été fermé."); return true }
            return false
        }
    }

    /// The new interactive session: started in `dir` after `date`, read from Claude Code's session files (2 min at most).
    private func waitForNewSession(after date: Date, in dir: String, excluding old: String, then: @escaping (String?) -> Void) {
        let start = Date()
        poll(old, every: 1) { [weak self] in
            guard let self else { return true }
            if let sid = self.ports.state.newSession(in: dir, startedAfter: date, excluding: old) { then(sid); return true }
            if Date().timeIntervalSince(start) > 120 { then(nil); return true }
            return false
        }
    }

    /// Repeats `check` on the main run loop until it returns true (one timer per session).
    private func poll(_ id: String, every seconds: TimeInterval, _ check: @escaping @MainActor () -> Bool) {
        timers[id]?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                if check() { t.invalidate(); if self?.timers[id] === t { self?.timers[id] = nil } }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }
}
