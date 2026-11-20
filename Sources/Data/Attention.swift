import AppKit
import Observation

/// Something that needs the user: a session finished or waiting, a context about to compact, a quota at risk.
struct AttentionItem: Identifiable, Equatable {
    enum Kind: Int { case waiting, finished, context, quota, digest }
    let id: String
    let kind: Kind
    let sessionID: String?
    let title: String
    let detail: String
    let date: Date
}

/// Watches live sessions, contexts and quotas; feeds the in-app "À traiter" card (no macOS notifications).
@MainActor
@Observable
final class AttentionCenter {
    static let shared = AttentionCenter()

    private(set) var items: [AttentionItem] = []
    @ObservationIgnored private var dismissed = Set<String>()
    @ObservationIgnored private var busySince: [String: Date] = [:]
    @ObservationIgnored private var contextFlagged = Set<String>()
    @ObservationIgnored private var digestTimer: Timer?

    static func enabled(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    // MARK: Sessions

    func observe(old: [String: LiveSession], new: [String: LiveSession]) {
        let now = Date()
        for (id, s) in new where s.kind != "background" && !s.name.hasPrefix("my-claude-code") {
            let before = old[id]?.phase
            if s.phase == 0 {
                if before != 0 { busySince[id] = now }
                remove { $0.sessionID == id && ($0.kind == .finished || $0.kind == .waiting) }
            } else if s.phase == 2 {
                if before == 0, let start = busySince[id], now.timeIntervalSince(start) >= 15 {
                    add(AttentionItem(id: "finished-\(id)-\(Int(now.timeIntervalSince1970))", kind: .finished, sessionID: id,
                                      title: "\(s.name) a terminé", detail: "après \(Fmt.duration(now.timeIntervalSince(start))) de travail", date: now),
                        show: "notify.finished")
                }
                busySince[id] = nil
                remove { $0.sessionID == id && $0.kind == .waiting }
            } else if before != 1 {
                add(AttentionItem(id: "waiting-\(id)-\(Int(now.timeIntervalSince1970))", kind: .waiting, sessionID: id,
                                  title: "\(s.name) attend votre réponse", detail: "elle a besoin de vous pour continuer", date: now),
                    show: "notify.waiting")
            }
        }
        // Sessions that closed: nothing left to do for them.
        remove { item in item.sessionID.map { new[$0] == nil } ?? false && item.kind != .finished }
    }

    // MARK: Context

    func observeContexts(_ store: UsageStore) {
        for s in store.snapshot.sessions where store.live[s.info.id] != nil {
            let ctx = store.context(of: s).fraction
            if ctx >= 0.85, !contextFlagged.contains(s.info.id) {
                contextFlagged.insert(s.info.id)
                add(AttentionItem(id: "context-\(s.info.id)", kind: .context, sessionID: s.info.id,
                                  title: "Contexte à \(Int((ctx * 100).rounded())) % sur \(store.live[s.info.id]?.name ?? s.name)",
                                  detail: "compaction automatique bientôt : faites-lui consigner son travail", date: Date()),
                    show: "notify.context")
            } else if ctx < 0.5, contextFlagged.contains(s.info.id) {
                contextFlagged.remove(s.info.id)
                remove { $0.id == "context-\(s.info.id)" }
            }
        }
    }

    // MARK: Quotas

    /// One item per quota window: over the alert threshold, or on pace to run out before its reset.
    func observeLimits(_ plan: PlanUsage, threshold: Double) {
        let fr = Locale(identifier: "fr_FR")
        var current = Set<String>()
        for w in plan.all {
            let over = w.usedPercent >= threshold
            let runsOut = w.kind != .session && w.usedPercent >= 25 && w.exhaustion != nil
            guard over || runsOut else { continue }
            let key = "limit-\(w.shortName)-\(Int(w.resetsAt.timeIntervalSince1970))"
            current.insert(key)
            let name = w.kind == .session ? "Session" : w.kind == .week ? "Semaine" : "Quota \(w.shortName)"
            let reset = "réinit. \(w.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(fr)))"
            let detail = runsOut ? "épuisé \(w.exhaustion!.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(fr))) à ce rythme (réinit. \(w.resetsAt.formatted(.dateTime.weekday(.abbreviated).locale(fr))))"
                                 : "\(reset) · modèle plus léger, contexte plus court"
            let isNew = !items.contains { $0.id == key } && !dismissed.contains(key)
            add(AttentionItem(id: key, kind: .quota, sessionID: nil, title: "\(name) à \(Int(w.usedPercent.rounded())) %", detail: detail, date: Date()),
                show: "notify.quota")
            if isNew, over, UserDefaults.standard.bool(forKey: "alertOpensPanel"), !PanelController.shared.isOpen {
                PanelController.shared.openPanel()
            }
        }
        remove { $0.id.hasPrefix("limit-") && !current.contains($0.id) }
    }

    // MARK: Evening digest

    func startDigest() {
        digestTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AttentionCenter.shared.checkDigest() }
        }
    }

    private func checkDigest() {
        remove { $0.kind == .digest && !Calendar.current.isDateInToday($0.date) }
        guard Self.enabled("notify.digest") else { return }
        let d = UserDefaults.standard
        let hour = d.object(forKey: "digest.hour") as? Int ?? 18, minute = d.object(forKey: "digest.minute") as? Int ?? 30
        let cal = Calendar.current, now = Date()
        guard let target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now), now >= target,
              d.string(forKey: "digest.last") != now.formatted(.iso8601.year().month().day()) else { return }
        d.set(now.formatted(.iso8601.year().month().day()), forKey: "digest.last")
        let store = UsageStore.shared, snap = store.snapshot
        let projects = Set(snap.sessions.filter { cal.isDateInToday(Date(timeIntervalSince1970: $0.info.last)) }.map(\.name))
        var lines = ["\(snap.today.sessions.count) sessions · \(snap.today.messages) réponses · \(Fmt.tokens(snap.today.tokens)) tokens"]
        if !projects.isEmpty { lines.append("Projets : " + projects.sorted().prefix(4).joined(separator: ", ")) }
        if let w = store.plan?.week { lines.append("Semaine à \(Int(w.usedPercent)) %" + (w.exhaustion.map { $0 < w.resetsAt ? ", épuisée \($0.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "fr_FR")))) à ce rythme" : "" } ?? "")) }
        let open = store.live.values.filter { $0.kind != "background" && !$0.name.hasPrefix("my-claude-code") }.count
        if open > 0 { lines.append("\(open) session\(open > 1 ? "s" : "") encore ouverte\(open > 1 ? "s" : "")") }
        add(AttentionItem(id: "digest-\(now.formatted(.iso8601.year().month().day()))", kind: .digest, sessionID: nil,
                          title: "Bilan de la journée", detail: lines.joined(separator: "\n"), date: now), show: "notify.digest")
    }

    // MARK: Items

    /// Sample items for render checks (no notification).
    func injectDemo(_ store: UsageStore) {
        let ids = store.snapshot.sessions.prefix(3).map(\.info.id)
        guard ids.count == 3 else { return }
        let now = Date()
        items = [
            AttentionItem(id: "d1", kind: .waiting, sessionID: ids[0], title: "api-refacto attend votre réponse", detail: "elle a besoin de vous pour continuer", date: now.addingTimeInterval(-40)),
            AttentionItem(id: "d2", kind: .finished, sessionID: ids[1], title: "vigie a terminé", detail: "après 12 min de travail", date: now.addingTimeInterval(-300)),
            AttentionItem(id: "d3", kind: .context, sessionID: ids[2], title: "Contexte à 87 % sur docs", detail: "compaction automatique bientôt", date: now.addingTimeInterval(-600)),
        ]
    }

    func clearAll() {
        dismissed.formUnion(items.map(\.id))
        items.removeAll()
        PanelController.shared.refreshButton()
    }

    /// Opening a session counts as reading its "finished" / "waiting" items.
    func markSeen(session id: String) {
        let seen = items.filter { $0.sessionID == id && ($0.kind == .finished || $0.kind == .waiting) }
        guard !seen.isEmpty else { return }
        dismissed.formUnion(seen.map(\.id))
        remove { item in seen.contains { $0.id == item.id } }
    }

    func dismiss(_ item: AttentionItem) {
        dismissed.insert(item.id)
        items.removeAll { $0.id == item.id }
        PanelController.shared.refreshButton()
    }

    private func add(_ item: AttentionItem, show key: String) {
        guard Self.enabled(key), !dismissed.contains(item.id) else { return }
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            // Same alert, fresher wording (e.g. a percentage that moved): update in place.
            if items[i].title != item.title || items[i].detail != item.detail { items[i] = AttentionItem(id: item.id, kind: item.kind, sessionID: item.sessionID, title: item.title, detail: item.detail, date: items[i].date) }
            return
        }
        // One live item per session and kind.
        items.removeAll { $0.sessionID != nil && $0.sessionID == item.sessionID && $0.kind == item.kind }
        items.insert(item, at: 0)
        items.sort { $0.kind.rawValue < $1.kind.rawValue || ($0.kind == $1.kind && $0.date > $1.date) }
        PanelController.shared.refreshButton()
    }

    private func remove(where match: (AttentionItem) -> Bool) {
        let before = items.count
        items.removeAll(where: match)
        if items.count != before { PanelController.shared.refreshButton() }
    }

}

extension PlanUsage.Window {
    /// Length of the quota window.
    var span: TimeInterval { kind == .session ? 5 * 3600 : 7 * 86400 }

    /// When the quota runs out before its reset, per the forecast (see Forecaster).
    var exhaustion: Date? { forecast?.exhaustion }
}

enum SessionLauncher {
    /// Resumes a stopped session in a new tab of iTerm's hotkey window.
    static func openInITerm(_ session: SessionStat, completion: @escaping (String?) -> Void) {
        let dir = session.info.project.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : session.info.project
        runInHotkeyTab("cd \(shellQuote(dir)) && claude --resume \(session.info.id)", completion: completion)
    }

    /// Starts a new interactive Claude Code session in `dir`, with `prompt` as its first message,
    /// in a new tab of iTerm's hotkey window. The prompt goes through a temp file: any quote or newline is safe.
    static func startProject(in dir: String, prompt: String, completion: @escaping (String?) -> Void) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mcc-prompt-\(UUID().uuidString).txt")
        do { try prompt.write(to: file, atomically: true, encoding: .utf8) } catch {
            completion("Impossible de préparer la consigne (\(error.localizedDescription))."); return
        }
        let f = shellQuote(file.path)
        runInHotkeyTab("cd \(shellQuote(dir)) && claude \"$(cat \(f))\"; rm -f \(f)", completion: completion)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// iTerm doesn't list its hotkey window among `windows`; it is only reachable as `current window`,
    /// which stays the hotkey window even while it is hidden. Calls back on the main queue with an error message, or nil.
    static func runInHotkeyTab(_ command: String, completion: @escaping (String?) -> Void) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "iTerm"
            set isHotkey to false
            try
                set isHotkey to is hotkey window of current window
            end try
            if not isHotkey then return "nohotkey"
            reveal hotkey window current window
            set hotkeyProfile to ""
            try
                set hotkeyProfile to hotkey window profile of current window
            end try
            tell current window
                if hotkeyProfile is "" then
                    create tab with default profile
                else
                    try
                        create tab with profile hotkeyProfile
                    on error
                        create tab with default profile
                    end try
                end if
            end tell
            tell current session of current window to write text "\(escaped)"
            return "ok"
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            let message: String?
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                message = code == -1743
                    ? "macOS bloque le contrôle d'iTerm : autorisez My Claude Code dans Réglages Système › Confidentialité et sécurité › Automatisation."
                    : "iTerm n'a pas pu ouvrir l'onglet (\(error[NSAppleScript.errorMessage] as? String ?? "erreur \(code)"))."
            } else if result == "nohotkey" {
                message = "Fenêtre à raccourci d'iTerm introuvable : ouvrez-la une fois avec votre raccourci, puis réessayez."
            } else {
                message = nil
            }
            DispatchQueue.main.async {
                if message == nil, !PanelController.shared.detached { PanelController.shared.closePanel() }   // a floating window stays
                completion(message)
            }
        }
    }
}
