import AppKit
import Observation

/// One prompt sent from the app to a Claude Code session.
struct SendJob: Identifiable, Codable {
    enum State: Codable { case sending, delivered, resumed, failed(String) }
    var id = UUID()
    let fromSession: String        // session whose card was used to send
    let recipient: String          // messaging name, or session name when resumed
    let resume: Bool
    let prompt: String
    var started = Date()
    var finished: Date?
    var state: State = .sending
    /// Quick command: final report of the ephemeral agent (or of the broadcast).
    var result: String?
    var quick: Bool? = nil
    /// Session chat: the session asked to write (`via`) and the one it writes to (`target`).
    var via: String? = nil
    var target: String? = nil
    var targetSession: String? = nil
    /// Where the conversation stands (see `relay`): 0 asking `via`, 1 `via` writes, 2 passing it to `target`,
    /// 3 `target` answers, 4 passing the answer back, 5 done.
    var stage: Int? = nil
    var composed: String? = nil
    var reply: String? = nil
    /// Tag linking the transcripts' entries to this request.
    var tag: String { String(id.uuidString.lowercased().prefix(8)) }

    var isRelay: Bool { via != nil }

    var isRunning: Bool { if case .sending = state { return true }; return false }
    var duration: TimeInterval { (finished ?? Date()).timeIntervalSince(started) }
    var succeeded: Bool { if case .delivered = state { return true }; if case .resumed = state { return true }; return false }

    /// Human-readable step while sending (the process gives no progress, so steps follow typical timings).
    var stepLabel: String {
        let t = duration
        if resume { return t < 4 ? "Préparation de la relance…" : "Relance de la session en arrière-plan…" }
        if t < 3 { return "Envoi à \(recipient)…" }
        return "Remise du message à \(recipient)…"
    }

    var summary: String {
        switch state {
        case .sending: return stepLabel
        case .delivered: return quick == true && recipient == "agent éphémère" ? "Tâche terminée" : "Transmis à \(recipient)"
        case .resumed: return "Session \(recipient) relancée avec votre prompt"
        case .failed(let why): return "Échec vers \(recipient) : \(why)"
        }
    }
}

/// Owns sends and drafts at app level, so closing the panel never cancels or loses anything.
@MainActor
@Observable
final class SendCenter {
    static let shared = SendCenter()

    /// Persisted history (survives restarts and updates); an unfinished send from a previous run is marked failed.
    var jobs: [SendJob] = SendCenter.loadJobs() {
        didSet { SendCenter.saveJobs(jobs) }
    }

    private static var jobsURL: URL { PlanUsage.directory.appendingPathComponent("sends.json") }

    private static func loadJobs() -> [SendJob] {
        guard let data = try? Data(contentsOf: jobsURL), var list = try? JSONDecoder().decode([SendJob].self, from: data) else { return [] }
        for i in list.indices where list[i].isRunning {
            list[i].state = .failed("interrompu par la fermeture de l'app")
            list[i].finished = list[i].started
        }
        return list
    }

    private static func saveJobs(_ jobs: [SendJob]) {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: jobsURL, options: .atomic) }
    }
    /// Latest finished job, shown as a banner at the top of the panel.
    var banner: SendJob?

    var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "promptDrafts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(drafts, forKey: "promptDrafts") }
    }
    var recipients: [String: String] = UserDefaults.standard.dictionary(forKey: "promptRecipients") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(recipients, forKey: "promptRecipients") }
    }

    func jobs(for sessionID: String) -> [SendJob] { jobs.filter { $0.fromSession == sessionID } }
    var quickJobs: [SendJob] { jobs.filter { $0.quick == true } }

    /// New project opened in an iTerm tab: logged in the quick history like any other quick command.
    func logProject(_ prompt: String, in dir: String) -> UUID {
        var job = SendJob(fromSession: "quick", recipient: "chantier · \((dir as NSString).lastPathComponent)", resume: false, prompt: prompt)
        job.quick = true
        jobs.insert(job, at: 0)
        return job.id
    }

    func finishProject(_ id: UUID, in dir: String, error: String?) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].finished = Date()
        if let error {
            jobs[i].state = .failed(error)
            jobs[i].result = error
        } else {
            jobs[i].state = .delivered
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let shown = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
            jobs[i].result = "Session ouverte dans un nouvel onglet de votre fenêtre iTerm, dans `\(shown)`."
        }
    }

    func delete(_ id: UUID) {
        jobs.removeAll { $0.id == id && !$0.isRunning }
    }

    /// Quick command: to the given running sessions, or — with no target — a one-off task run by an ephemeral agent.
    func quick(_ prompt: String, to targets: [LiveSession]) {
        var job = SendJob(fromSession: "quick", recipient: targets.isEmpty ? "agent éphémère" : targets.map(\.name).joined(separator: ", "),
                          resume: false, prompt: prompt)
        job.quick = true
        jobs.insert(job, at: 0)
        let id = job.id
        let names = targets.map(\.name)
        Task.detached(priority: .userInitiated) {
            let r = names.isEmpty ? await PromptSender.runEphemeral(prompt, model: nil) : await PromptSender.broadcast(prompt, to: names)
            await MainActor.run {
                guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                self.jobs[i].state = r.ok ? .delivered : .failed(String(r.text.prefix(160)))
                self.jobs[i].result = r.text
                self.jobs[i].finished = Date()
                let done = self.jobs[i]
                if !r.ok { self.banner = done }
                UsageStore.shared.refreshStatus()
            }
        }
    }

    /// Session chat: the user asks `sender` to write to `target`. The app orchestrates the round trip, every leg sent
    /// by an intermediary agent (see PromptSender's conversation): `sender` writes its message in its reply, the app
    /// passes it to `target`, whose answer the app passes back to `sender`.
    func relay(_ prompt: String, from session: SessionStat, via sender: LiveSession, to target: LiveSession) {
        var job = SendJob(fromSession: session.info.id, recipient: sender.name, resume: false, prompt: prompt)
        job.via = sender.name
        job.target = target.name
        job.targetSession = target.sessionId
        job.stage = 0
        jobs.insert(job, at: 0)
        if jobs.count > 200 { jobs.removeLast(jobs.count - 200) }
        drafts[session.info.id] = nil
        let id = job.id, tag = job.tag
        let a = sender.name, aSession = sender.sessionId, b = target.name, bSession = target.sessionId
        Task.detached(priority: .userInitiated) {
            let outcome = await Self.converse(prompt, tag: tag, a: a, aSession: aSession, b: b, bSession: bSession) { stage, composed, reply in
                guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                self.jobs[i].stage = stage
                if let composed { self.jobs[i].composed = composed }
                if let reply { self.jobs[i].reply = reply }
            }
            await MainActor.run { self.finish(id, outcome) }
        }
    }

    /// The round trip of a chat request; `advance` reports each leg reached (stage, A's message, B's answer).
    nonisolated private static func converse(_ prompt: String, tag: String, a: String, aSession: String, b: String, bSession: String,
                                             advance: @escaping @MainActor (Int, String?, String?) -> Void) async -> PromptSender.Outcome {
        let wait: TimeInterval = 3600   // a busy session answers once its current task is done
        guard await PromptSender.askToWrite(prompt, tag: tag, writer: a, target: b) else { return .failed("consigne non transmise à \(a)") }
        await advance(1, nil, nil)
        let composed: String
        switch await PromptSender.awaitAnswer(in: aSession, tag: tag, timeout: wait) {
        case .text(let t): composed = t
        case .declined: return .failed("\(a) n'a pas rédigé de message (sa réponse est dans le chat)")
        case .timedOut: return .failed("\(a) n'a pas rédigé de message dans l'heure")
        }
        await advance(2, composed, nil)
        guard await PromptSender.pass(composed, leg: .deliver, tag: tag, from: a, to: b) else { return .failed("message non transmis à \(b)") }
        await advance(3, nil, nil)
        let reply: String
        switch await PromptSender.awaitAnswer(in: bSession, tag: tag, timeout: wait) {
        case .text(let t), .declined(let t): reply = t
        case .timedOut: return .failed("\(b) n'a pas répondu dans l'heure")
        }
        if reply == "(rien à répondre)" {
            await advance(5, nil, reply)
            return .delivered
        }
        await advance(4, nil, reply)
        guard await PromptSender.pass(reply, leg: .answer, tag: tag, from: b, to: a) else { return .failed("réponse non transmise à \(a)") }
        await advance(5, nil, nil)
        return .delivered
    }

    private func finish(_ id: UUID, _ outcome: PromptSender.Outcome) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .delivered: jobs[i].state = .delivered
        case .resumed: jobs[i].state = .resumed
        case .failed(let why): jobs[i].state = .failed(why)
        }
        jobs[i].finished = Date()
        // A chat request shows its progress in the chat itself; only a failure is worth the banner.
        if !jobs[i].isRelay || !jobs[i].succeeded { banner = jobs[i] }
        UsageStore.shared.refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if self.banner?.id == id { self.banner = nil } }
    }

    func send(_ prompt: String, from session: SessionStat, to live: LiveSession?) {
        let job = SendJob(fromSession: session.info.id, recipient: live?.name ?? session.name, resume: live == nil, prompt: prompt)
        jobs.insert(job, at: 0)
        if jobs.count > 200 { jobs.removeLast(jobs.count - 200) }
        drafts[session.info.id] = nil
        let id = job.id
        Task.detached(priority: .userInitiated) {
            let outcome = await PromptSender.send(prompt, to: session, live: live)
            await MainActor.run { self.finish(id, outcome) }
        }
    }

}
