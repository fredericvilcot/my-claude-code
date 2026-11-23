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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
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
