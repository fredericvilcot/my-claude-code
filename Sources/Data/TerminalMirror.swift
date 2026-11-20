import AppKit
import Observation

/// Live mirror of a session's iTerm tab: the exact screen contents, read through iTerm's AppleScript `contents`
/// (no keystrokes, read only), refreshed every second while shown.
@MainActor
@Observable
final class TerminalMirror {
    /// A mirrored screen line: text, or a horizontal rule (Claude Code's separators, drawn natively).
    enum Row: Equatable { case text(String), rule }
    private(set) var rows: [Row] = []
    private(set) var tabName = ""
    private(set) var failure: String?
    let tty: String

    /// One serial queue for all AppleScript calls (NSAppleScript is not thread-safe).
    nonisolated private static let queue = DispatchQueue(label: "mcc.iterm.mirror")

    init(tty: String) { self.tty = tty }

    func refresh() async {
        let tty = self.tty
        let result: (String?, String?, String?) = await withCheckedContinuation { cont in
            Self.queue.async {
                let source = """
                tell application "iTerm"
                    try
                        repeat with t in tabs of current window
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then return (name of s) & (ASCII character 30) & (contents of s)
                            end repeat
                        end repeat
                    end try
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then return (name of s) & (ASCII character 30) & (contents of s)
                            end repeat
                        end repeat
                    end repeat
                    return ""
                end tell
                """
                var error: NSDictionary?
                let out = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
                if let error {
                    cont.resume(returning: (nil, nil, error[NSAppleScript.errorMessage] as? String ?? "iTerm indisponible"))
                } else if let out, let sep = out.firstIndex(of: "\u{1E}") {
                    cont.resume(returning: (String(out[..<sep]), String(out[out.index(after: sep)...]), nil))
                } else {
                    cont.resume(returning: (nil, nil, "Onglet iTerm introuvable."))
                }
            }
        }
        if let error = result.2 { failure = error; return }
        failure = nil
        tabName = result.0 ?? ""
        let cleaned = Self.clean(result.1 ?? "")
        if cleaned != rows { rows = cleaned }
    }

    /// Lines made of box-drawing characters become rules; box borders around a line are dropped; runs of rules
    /// or blank lines collapse into one. Text lines stay as they are (and wrap in the view).
    nonisolated static func clean(_ screen: String) -> [Row] {
        let box: Set<Character> = ["─", "━", "═", "│", "┃", "║", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "▔", "▁"]
        var out: [Row] = []
        for raw in screen.components(separatedBy: "\n") {
            var line = raw
            while line.last == " " { line.removeLast() }
            let visible = line.filter { $0 != " " }
            if !visible.isEmpty, Double(visible.filter { box.contains($0) }.count) / Double(visible.count) > 0.6 {
                if out.last != .rule { out.append(.rule) }
                continue
            }
            // Strip a frame around the line ("│ text │").
            if let f = line.first, box.contains(f) { line.removeFirst() }
            while line.last == " " { line.removeLast() }
            if let l = line.last, box.contains(l) { line.removeLast() }
            while line.last == " " { line.removeLast() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if case .text(let prev)? = out.last, prev.isEmpty { continue }
                if out.isEmpty || out.last == .rule { continue }
                out.append(.text(""))
            } else {
                out.append(.text(line))
            }
        }
        while out.last == .rule || out.last == .text("") { out.removeLast() }
        return out
    }
}
