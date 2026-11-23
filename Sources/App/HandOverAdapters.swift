import AppKit

// Adapters of the hand-over ports (Core/Ports/HandOverPorts.swift) on this Mac: Claude Code's files and CLI,
// iTerm, the Trash, the app's windows.

@MainActor struct TerminalTyping: SessionTyping {
    func type(_ text: String, into live: LiveSession, completion: @escaping (String?) -> Void) {
        SessionInput.type(text, into: live, completion: completion)
    }
}

@MainActor struct ClaudeSessionState: SessionStateReading {
    func phase(of sessionID: String, job: String?) -> Int? {
        if let phase = UsageStore.shared.live[sessionID]?.phase { return phase }
        if let job, BackgroundJobs.exists(job) { return 2 }   // a background job between two turns: idle, reachable
        return nil
    }

    func stat(of sessionID: String) -> SessionStat? {
        UsageStore.shared.snapshot.sessions.first { $0.info.id == sessionID }
    }

    func newSession(in directory: String, startedAfter date: Date, excluding excluded: String) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        // Claude Code records its real working directory: compare resolved paths (symlinked folders).
        let target = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = s["sessionId"] as? String, sid != excluded,
                  let cwd = s["cwd"] as? String, URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == target,
                  let startedAt = (s["startedAt"] as? NSNumber)?.doubleValue, startedAt / 1000 >= date.timeIntervalSince1970 - 2
            else { continue }
            return sid
        }
        return nil
    }

    func refresh() { UsageStore.shared.refreshAll() }
}

@MainActor struct ITermLaunching: SessionLaunching {
    func start(in directory: String, prompt: String, model: String?, completion: @escaping (String?) -> Void) {
        SessionLauncher.startProject(in: directory, prompt: prompt, model: model, completion: completion)
    }
}

@MainActor struct SessionRetirement: SessionRetiring {
    /// Background job: `claude stop` + `claude rm`. Interactive: SIGTERM, then its iTerm tab is closed.
    /// Either way the transcript goes to the Trash and the session is hidden.
    func retire(_ session: SessionStat, live: LiveSession) {
        if live.kind == "background" {
            BackgroundJobs.stopAndRemove(live.shortId) { UsageStore.shared.refreshAll() }
        } else if let pid = live.pid, pid > 1 {
            let tty = Terminals.tty(of: pid)
            kill(pid, SIGTERM)
            if let tty { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SessionInput.closeITermTab(tty: tty) } }
        }
        SessionFiles.delete(session)
        UsageStore.shared.refreshAll()
    }
}

@MainActor struct SessionNotes: NoteStore {
    private var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/session-notes") }
    var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    func newNotePath(folder: String, suffix: String) -> String {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(folder)-\(suffix).md").path
    }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func folderExists(_ path: String) -> Bool { !path.isEmpty && FileManager.default.fileExists(atPath: path) }
}

@MainActor struct AppPresenter: SessionPresenting {
    /// The panel's session sheet, and the floating window if the old session had one.
    func present(_ session: SessionStat, replacing oldID: String) {
        let newID = session.info.id
        if MiniWindows.shared.isOpen(.session(oldID)) {
            MiniWindows.shared.close(.session(oldID))
            MiniWindows.shared.open(.session(newID))
        }
        NotificationCenter.default.post(name: .openSession, object: session.index)
    }
}
