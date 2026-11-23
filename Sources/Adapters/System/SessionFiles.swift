import AppKit
import Foundation

/// File-level actions on Claude Code transcripts. Deletion always goes to the Trash (recoverable).
enum SessionFiles {
    /// Transcript files of a session (main log plus any sub-agent logs named after it).
    static func files(for sessionID: String) -> [URL] {
        UsageLog.listFiles().filter { $0.path.contains(sessionID) }.map { URL(fileURLWithPath: $0.path) }
    }

    static func size(of urls: [URL]) -> UInt64 {
        urls.reduce(0) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Total size of all transcripts.
    static func totalSize() -> UInt64 {
        UsageLog.listFiles().reduce(0) { $0 + $1.size }
    }

    struct Candidates {
        var sessions: [SessionStat] = []
        var files: [URL] = []
        var bytes: UInt64 = 0
    }

    /// Sessions whose last activity is older than `days` (never the last hour).
    static func older(than days: Int, in sessions: [SessionStat]) -> Candidates {
        let limit = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        let old = sessions.filter { $0.info.last < limit }
        let ids = Set(old.map(\.info.id))
        let all = UsageLog.listFiles()
        let urls = all.filter { f in ids.contains { f.path.contains($0) } }.map { URL(fileURLWithPath: $0.path) }
        return Candidates(sessions: old, files: urls, bytes: size(of: urls))
    }

    @discardableResult
    static func trash(_ urls: [URL]) -> Int {
        var moved = 0
        for url in urls {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { moved += 1 }
        }
        return moved
    }

    /// Sessions deleted from the app: hidden from lists (their cost stays in the statistics).
    static var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hiddenSessions") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenSessions") }
    }

    /// Moves a session's transcripts to the Trash and hides it.
    static func delete(_ session: SessionStat) {
        // A background job (live or finished) is Claude Code's own record: remove it the official way.
        let job = String(session.info.id.prefix(8))
        if BackgroundJobs.exists(job) { BackgroundJobs.stopAndRemove(job) }
        trash(files(for: session.info.id))
        hidden.insert(session.info.id)
    }

    /// Stops a running session: background ones through `claude stop`, interactive ones with SIGTERM (their
    /// terminal tab stays open on the shell).
    @discardableResult
    static func stop(_ live: LiveSession) -> Bool {
        if live.kind == "background" {
            BackgroundJobs.stopAndRemove(live.shortId) { UsageStore.shared.refreshAll() }
            return true
        }
        guard let pid = live.pid, pid > 1 else { return false }
        return kill(pid, SIGTERM) == 0
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        PanelController.shared.closePanel()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyResumeCommand(for session: SessionStat) {
        let resume = "claude --resume " + SessionLauncher.shellQuote(session.info.id)
        let command = session.info.project.isEmpty ? resume : "cd \(SessionLauncher.shellQuote(session.info.project)) && " + resume
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

extension Fmt {
    static func bytes(_ v: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(clamping: v))
    }
}
