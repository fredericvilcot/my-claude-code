import AppKit
import Observation

/// Live mirror of a session's iTerm tab: the exact screen contents, character for character, read through iTerm's
/// AppleScript `contents` with the tab's column count, refreshed every second while shown. Keys typed in the app are
/// written to the tab.
@MainActor
@Observable
final class TerminalMirror {
    /// A mirrored screen line: text, or a horizontal rule (Claude Code's separators, drawn natively).
    typealias Row = TerminalRow
    /// The screen, line by line, exactly as iTerm shows it (only trailing blanks dropped).
    private(set) var lines: [String] = []
    /// The same screen with iTerm's colours and styles (iTerm API enabled), else nil.
    private(set) var styled: [AttributedString]?
    /// Width of the tab in characters (to draw the screen at the same proportions).
    private(set) var columns = 80
    private(set) var tabName = ""
    private(set) var failure: String?
    let tty: String

    /// The app-wide AppleScript queue (NSAppleScript is not thread-safe).
    nonisolated private static var queue: DispatchQueue { ITermScript.queue }

    init(tty: String) { self.tty = tty }

    // MARK: iTerm access (low latency)
    //
    // Finding a session by looping over tabs costs ~120 ms per call (one Apple event per property); addressing
    // "session j of tab i" directly costs ~18 ms. The tab is located once, then addressed directly; a miss
    // (tab moved or closed) triggers a new lookup. All calls run on one serial queue, with compiled scripts.

    /// Where the session lives: in the current (hotkey) window, or in a regular window by id.
    private struct Location { var inCurrent: Bool; var window: Int; var tab: Int; var session: Int }
    nonisolated(unsafe) private var location: Location?
    nonisolated(unsafe) private static var scripts: [String: NSAppleScript] = [:]

    nonisolated private static func run(_ name: String, _ source: String, _ args: [String]) -> String? {
        var error: NSDictionary?
        let script: NSAppleScript
        if let cached = scripts[name] { script = cached } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            s.compileAndReturnError(&error)
            scripts[name] = s
            script = s
        }
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        let result = script.executeAppleEvent(event, error: &error)
        return error == nil ? (result.stringValue ?? "") : nil
    }

    nonisolated private static let locateSource = """
    on run argv
        set ttyName to item 1 of argv
        tell application "iTerm"
            try
                set tc to count of tabs of current window
                repeat with i from 1 to tc
                    set sc to count of sessions of tab i of current window
                    repeat with j from 1 to sc
                        if tty of session j of tab i of current window is ttyName then return "c,0," & i & "," & j
                    end repeat
                end repeat
            end try
            repeat with w in windows
                set wid to id of w
                set tc to count of tabs of w
                repeat with i from 1 to tc
                    set sc to count of sessions of tab i of w
                    repeat with j from 1 to sc
                        if tty of session j of tab i of w is ttyName then return "w," & wid & "," & i & "," & j
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
    end run
    """

    /// item 1 tty, 2 "c"/"w", 3 window id, 4 tab, 5 session, 6 mode ("read" or "send"), 7 text to send.
    nonisolated private static let actSource = """
    on run argv
        set ttyName to item 1 of argv
        set i to (item 4 of argv) as integer
        set j to (item 5 of argv) as integer
        tell application "iTerm"
            if item 2 of argv is "c" then
                -- Never store the hotkey window in a variable: it resolves to "window id N", which iTerm can't reach.
                if tty of session j of tab i of current window is not ttyName then return "MISS"
                if item 6 of argv is "send" then
                    tell session j of tab i of current window to write text (item 7 of argv) newline NO
                    return "OK"
                end if
                return (name of session j of tab i of current window) & (ASCII character 30) & (columns of session j of tab i of current window) & (ASCII character 30) & (contents of session j of tab i of current window)
            else
                set w to window id ((item 3 of argv) as integer)
                if tty of session j of tab i of w is not ttyName then return "MISS"
                if item 6 of argv is "send" then
                    tell session j of tab i of w to write text (item 7 of argv) newline NO
                    return "OK"
                end if
                return (name of session j of tab i of w) & (ASCII character 30) & (columns of session j of tab i of w) & (ASCII character 30) & (contents of session j of tab i of w)
            end if
        end tell
    end run
    """

    /// Runs `mode` on the session, locating it first if needed and once more after a miss.
    nonisolated private func act(_ mode: String, _ text: String = "") -> String? {
        for attempt in 0..<2 {
            if location == nil || attempt == 1 {
                guard let found = Self.run("locate", Self.locateSource, [tty]), !found.isEmpty else { location = nil; return nil }
                let f = found.split(separator: ",").map(String.init)
                guard f.count == 4, let w = Int(f[1]), let t = Int(f[2]), let s = Int(f[3]) else { return nil }
                location = Location(inCurrent: f[0] == "c", window: w, tab: t, session: s)
            }
            guard let l = location else { return nil }
            let out = Self.run("act", Self.actSource, [tty, l.inCurrent ? "c" : "w", String(l.window), String(l.tab), String(l.session), mode, text])
            if let out, out != "MISS" { return out }
        }
        return nil
    }

    // MARK: Keyboard

    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var sending = false

    /// Sends raw input (keys, escape sequences) to the session's iTerm tab. Keys typed while a send is in flight
    /// are batched into the next one; the screen is refreshed right after each send.
    func send(_ input: String) {
        guard !input.isEmpty else { return }
        pending += input
        flush()
    }

    private func flush() {
        guard !sending, !pending.isEmpty else { return }
        sending = true
        let text = pending
        pending = ""
        let tty = self.tty
        Self.queue.async {
            // Through iTerm's API when enabled (reaches the hidden hotkey window too), else AppleScript.
            if !(ITermAPI.isEnabled && ITermAPI.shared.session(tty: tty).map({ ITermAPI.shared.send(text, session: $0.id) }) == true) {
                _ = self.act("send", text)
            }
            DispatchQueue.main.async {
                self.sending = false
                if !self.pending.isEmpty { self.flush() }
                Task { await self.refresh() }
            }
        }
    }

    // MARK: Screen

    func refresh() async {
        // Colours: iTerm's API gives every cell with its style.
        if ITermAPI.isEnabled {
            let palette = ITermAPI.Palette(ITermProfile.current), tty = self.tty
            let screen: (lines: [AttributedString], columns: Int, title: String)? = await withCheckedContinuation { cont in
                Self.queue.async {
                    guard let s = ITermAPI.shared.session(tty: tty) else { cont.resume(returning: nil); return }
                    guard let lines = ITermAPI.shared.screen(session: s.id, palette: palette) else {
                        ITermAPI.shared.forget(tty: tty)
                        cont.resume(returning: nil); return
                    }
                    cont.resume(returning: (lines, s.columns, s.title))
                }
            }
            if let screen {
                failure = nil
                if !screen.title.isEmpty, tabName != screen.title { tabName = screen.title }
                if screen.columns > 0, screen.columns != columns { columns = screen.columns }
                if screen.lines != styled { styled = screen.lines }
                return
            }
        }
        if styled != nil { styled = nil }
        let out: String? = await withCheckedContinuation { cont in
            Self.queue.async { cont.resume(returning: self.act("read")) }
        }
        let parts = out?.split(separator: "\u{1E}", maxSplits: 2, omittingEmptySubsequences: false) ?? []
        guard parts.count == 3 else {
            failure = "Onglet iTerm introuvable."
            return
        }
        failure = nil
        if tabName != String(parts[0]) { tabName = String(parts[0]) }
        if let c = Int(parts[1]), c > 0, c != columns { columns = c }
        var screen = parts[2].components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.last == " " { l.removeLast() }
            return l
        }
        while screen.last?.isEmpty == true { screen.removeLast() }
        if screen != lines { lines = screen }
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
