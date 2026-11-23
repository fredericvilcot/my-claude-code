import Foundation

// Ports of the hand-over use cases (Compactor, Restarter): what they need from the outside world, nothing more.
// Implemented by adapters (Adapters/…) and wired in App/Composition.swift.

/// Types text into a running session as if the user typed it, then presses Return. Calls back with an error message.
@MainActor protocol SessionTyping {
    func type(_ text: String, into live: LiveSession, completion: @escaping (String?) -> Void)
}

/// What is known of sessions right now.
@MainActor protocol SessionStateReading {
    /// 0 working, 1 waiting, 2 idle, nil closed. `job`: a background job stays reachable between its turns.
    func phase(of sessionID: String, job: String?) -> Int?
    /// The session's statistics, once its transcript has been read.
    func stat(of sessionID: String) -> SessionStat?
    /// The interactive session started in `directory` after `date` (other than `excluded`), if any.
    func newSession(in directory: String, startedAfter date: Date, excluding excluded: String) -> String?
    func refresh()
}

/// Starts a new interactive session (a new terminal tab) with a first prompt.
@MainActor protocol SessionLaunching {
    func start(in directory: String, prompt: String, model: String?, completion: @escaping (String?) -> Void)
}

/// Stops a session, closes its terminal and trashes its transcript.
@MainActor protocol SessionRetiring {
    func retire(_ session: SessionStat, live: LiveSession)
}

/// Where synthesis notes are written.
@MainActor protocol NoteStore {
    func newNotePath(folder: String, suffix: String) -> String
    func exists(_ path: String) -> Bool
    func folderExists(_ path: String) -> Bool
    var home: String { get }
}

/// Brings a session to the screen in place of another one.
@MainActor protocol SessionPresenting {
    func present(_ session: SessionStat, replacing oldID: String)
}

struct HandOverPorts {
    var typing: SessionTyping
    var state: SessionStateReading
    var launcher: SessionLaunching
    var retirement: SessionRetiring
    var notes: NoteStore
    var presenter: SessionPresenting
}
