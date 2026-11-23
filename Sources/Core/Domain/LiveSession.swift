import Foundation

/// A Claude Code session currently running (from `claude agents --json`), with its messaging name.
struct LiveSession {
    let sessionId: String
    let name: String          // messaging name used by SendMessage, e.g. "my-project-42"
    let shortId: String
    let kind: String          // "interactive" or "background"
    let state: String         // busy, idle, blocked…
    var pid: Int32? = nil     // process of an interactive session (to stop it)

    /// Sort/display phase: 0 working, 1 waiting for the user, 2 open but idle.
    var phase: Int {
        switch state {
        case "busy", "running", "working": return 0   // background jobs say "working"
        case "idle", "done": return 2                 // a background job's "done" is the end of its turn
        default: return 1
        }
    }

    var label: String {
        switch state {
        case "busy", "running", "working": return "en cours"
        case "idle", "done": return "au repos"
        case "blocked", "waiting": return "attend votre réponse"
        default: return state
        }
    }
}
