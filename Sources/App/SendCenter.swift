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

    func send(_ prompt: String, from session: SessionStat, to live: LiveSession?) {
        var job = SendJob(fromSession: session.info.id, recipient: live?.name ?? session.name, resume: live == nil, prompt: prompt)
        jobs.insert(job, at: 0)
        if jobs.count > 200 { jobs.removeLast(jobs.count - 200) }
        drafts[session.info.id] = nil
        let id = job.id
        Task.detached(priority: .userInitiated) {
            let outcome = await PromptSender.send(prompt, to: session, live: live)
            await MainActor.run {
                guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                switch outcome {
                case .delivered: self.jobs[i].state = .delivered
                case .resumed: self.jobs[i].state = .resumed
                case .failed(let why): self.jobs[i].state = .failed(why)
                }
                self.jobs[i].finished = Date()
                job = self.jobs[i]
                self.banner = job
                UsageStore.shared.refreshStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if self.banner?.id == id { self.banner = nil } }
            }
        }
    }

}
