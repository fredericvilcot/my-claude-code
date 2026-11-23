import AppKit
import SwiftTerm
import SwiftUI

/// A real terminal inside the app, running `claude attach <job>`: the background session's own interface, keys,
/// colours and scrolling, exactly as in iTerm (font and colours come from the user's iTerm profile). Several clients
/// can be attached at once (an iTerm tab and the app); the session keeps running when this view goes away.
struct AttachedTerminal: NSViewRepresentable {
    let job: String
    let directory: String
    @Binding var focused: Bool
    @Binding var ended: Bool

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var parent: AttachedTerminal
        init(_ parent: AttachedTerminal) { self.parent = parent }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.parent.ended = true; self.parent.focused = false }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AttachTerminalView {
        let view = AttachTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 340))
        view.apply(ITermProfile.current)
        view.processDelegate = context.coordinator
        view.onFocus = { f in DispatchQueue.main.async { context.coordinator.parent.focused = f } }
        if let claude = UsagePoller.claudePath {
            view.startProcess(executable: claude, args: ["attach", job], environment: Terminals.environment(),
                              currentDirectory: FileManager.default.fileExists(atPath: directory) ? directory
                                  : FileManager.default.homeDirectoryForCurrentUser.path)
        } else {
            view.feed(text: "Claude Code introuvable.\r\n")
        }
        return view
    }

    func updateNSView(_ view: AttachTerminalView, context: Context) { context.coordinator.parent = self }

    static func dismantleNSView(_ view: AttachTerminalView, coordinator: Coordinator) { view.detach() }
}

final class AttachTerminalView: LocalProcessTerminalView {
    var onFocus: (Bool) -> Void = { _ in }
    private var clicked = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    // The app's panels are non-activating: ask for key status so keystrokes reach the terminal.
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ p: ITermProfile) {
        font = p.font
        nativeForegroundColor = p.foreground
        nativeBackgroundColor = p.background
        caretColor = p.cursor
        installColors(p.ansi.map { c in
            let s = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(s.redComponent * 65535), green: UInt16(s.greenComponent * 65535), blue: UInt16(s.blueComponent * 65535))
        })
        optionAsMetaKey = false   // ⌥ types accented characters, as on a French keyboard in iTerm
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let window else { return }
        // ⌃Z would suspend `claude attach` (there is no shell to return to here): swallow it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .scrollWheel {
                guard let point = self.localPoint(event) else { return event }
                return self.bounds.contains(point) && self.forwardWheel(event, at: point) ? nil : event
            }
            guard event.window === self.window else { return event }
            if event.type == .leftMouseDown {
                // The terminal gets the keyboard only from a click inside it.
                self.clicked = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                DispatchQueue.main.async { self.onFocus(self.clicked && self.window?.firstResponder === self) }
                return event
            }
            guard self.window?.firstResponder === self else { return event }
            if !self.clicked {
                // Focused by AppKit when the panel became key, not by the user: give the key back to the panel
                // (Escape closes it, as everywhere else) instead of sending it to the session.
                self.window?.makeFirstResponder(nil)
                return event
            }
            if event.modifierFlags.contains(.control), event.keyCode == 6 { return nil }
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.window?.isKeyWindow != true { self.clicked = false }
                self.onFocus(self.clicked && self.window?.isKeyWindow == true && self.window?.firstResponder === self)
            })
        }
    }

    // MARK: Scrolling
    //
    // Claude Code draws on the alternate screen and asks for mouse reports to scroll its conversation itself.
    // SwiftTerm 1.8 only scrolls its own (empty) scrollback there, so the wheel never reached Claude Code: it is
    // forwarded here as wheel buttons, the trackpad's fine deltas grouped into steady line steps (like iTerm).

    private var wheelAccumulator: CGFloat = 0

    /// True when the event was sent to the program (it wants the mouse); false to let SwiftTerm scroll its scrollback.
    /// Where the event is, in this view (events without a window carry screen coordinates).
    private func localPoint(_ event: NSEvent) -> NSPoint? {
        guard let window else { return nil }
        if event.window === window { return convert(event.locationInWindow, from: nil) }
        guard event.window == nil else { return nil }
        return convert(window.convertPoint(fromScreen: event.locationInWindow), from: nil)
    }

    private func forwardWheel(_ event: NSEvent, at point: NSPoint) -> Bool {
        let terminal = getTerminal()
        guard terminal.mouseMode != .off else { return false }
        if event.phase == .began || event.phase == .mayBegin { wheelAccumulator = 0 }
        let lineHeight = max(8, bounds.height / CGFloat(max(terminal.rows, 1)))
        wheelAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * lineHeight
        var steps = Int(wheelAccumulator / lineHeight)
        guard steps != 0 else { return true }
        wheelAccumulator -= CGFloat(steps) * lineHeight
        steps = max(-6, min(6, steps))   // a flick never floods the session
        let col = max(0, min(terminal.cols - 1, Int(point.x / (bounds.width / CGFloat(max(terminal.cols, 1))))))
        let row = max(0, min(terminal.rows - 1, Int((bounds.height - point.y) / lineHeight)))
        let flags = terminal.encodeButton(button: steps > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false)
        for _ in 0..<abs(steps) { terminal.sendEvent(buttonFlags: flags, x: col, y: row) }
        return true
    }

    /// Leaves the session running: only this client goes away.
    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if process?.running == true {
            let pid = process.shellPid
            terminate()
            Terminals.reap(pid)
        }
    }
}
