import SwiftUI

/// A session's terminal, in a dark window frame (traffic-light dots, tab name, live dot):
/// - background session: a real terminal running `claude attach` (its own interface, keyboard included);
/// - interactive session: the exact screen of its iTerm tab, character for character, in the tab's font and colours,
///   with the keyboard forwarded to the tab on click;
/// - closed session: its history, rebuilt from the transcript.
@MainActor
struct TerminalMirrorView: View {
    let session: SessionStat
    let live: LiveSession?
    var fill = false
    @State private var mirror: TerminalMirror?
    @State private var transcript: [TerminalMirror.Row] = []
    /// The terminal has the keyboard: every key goes to the session.
    @State private var keyboard = false
    /// The embedded `claude attach` client has exited (session stopped, or detached with ←/⌃C).
    @State private var attachEnded = false
    @State private var attachGeneration = 0

    private var attachedJob: String? {
        guard let live, live.kind == "background", !live.shortId.isEmpty, !Demo.isOn else { return nil }   // demo: journal
        return live.shortId
    }

    var body: some View {
        VStack(spacing: 0) {
            windowBar
            content
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: ITermProfile.current.background)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(keyboard ? Theme.clay.opacity(0.8) : Color.white.opacity(0.07), lineWidth: keyboard ? 1.5 : 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .noWindowDrag()
        .task(id: "\(live?.pid ?? 0)-\(live?.kind ?? "")-\(session.info.id)") { await poll() }
    }

    private var isLive: Bool {
        if attachedJob != nil { return !attachEnded }
        return mirror != nil && mirror?.failure == nil
    }

    private var windowBar: some View {
        HStack(spacing: 6) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                Circle().fill(c.opacity(0.85)).frame(width: 8, height: 8)
            }
            Text(title).font(Term.mono(10.5)).foregroundStyle(Term.dim).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)
            if !isLive {
                Text("journal").font(Term.mono(9.5, .semibold)).foregroundStyle(Term.dim)
            } else {
                if keyboard {
                    Label("clavier", systemImage: "keyboard").font(Term.mono(9.5, .semibold)).foregroundStyle(Theme.clay)
                }
                TimelineView(.whileShown(1)) { ctx in
                    HStack(spacing: 4) {
                        Circle().fill(Term.green).frame(width: 6, height: 6)
                            .opacity(Int(ctx.date.timeIntervalSince1970) % 2 == 0 ? 1 : 0.4)
                        Text("direct").font(Term.mono(9.5, .semibold)).foregroundStyle(Term.green)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5) }
    }

    private var title: String {
        if let m = mirror, !m.tabName.isEmpty { return m.tabName }
        if let live, !live.name.isEmpty { return attachedJob != nil ? "claude attach \(live.shortId) · \(live.name)" : live.name }
        return session.displayName
    }

    private var frameHeight: (min: CGFloat, max: CGFloat) { fill ? (160, .infinity) : (340, 340) }

    @ViewBuilder
    private var content: some View {
        if let job = attachedJob {
            ZStack {
                AttachedTerminal(job: job, directory: session.info.project, focused: $keyboard, ended: $attachEnded)
                    .id(attachGeneration)
                    .padding(.leading, 8).padding(.vertical, 4)
                if attachEnded {
                    VStack(spacing: 10) {
                        Text("Terminal détaché de la session.").font(Term.mono(11)).foregroundStyle(Term.dim)
                        Button { attachEnded = false; attachGeneration += 1 } label: {
                            Label("Rattacher", systemImage: "arrow.uturn.left").font(Term.mono(11, .semibold))
                                .foregroundStyle(Term.green)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().strokeBorder(Term.green.opacity(0.5), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: ITermProfile.current.background).opacity(0.92))
                }
            }
            .frame(minHeight: frameHeight.min, maxHeight: frameHeight.max)
        } else if let mirror, mirror.failure == nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // iTerm only exposes the visible screen: the session's history above it comes from its transcript.
                    if !transcript.isEmpty {
                        TermRowsView(rows: transcript).opacity(0.78)
                        HStack(spacing: 8) {
                            Rectangle().fill(Term.green.opacity(0.35)).frame(height: 1)
                            Text("en direct").font(Term.mono(9.5, .semibold)).foregroundStyle(Term.green).fixedSize()
                            Rectangle().fill(Term.green.opacity(0.35)).frame(height: 1)
                        }
                        .padding(.vertical, 4)
                    }
                    ITermScreen(lines: mirror.lines, styled: mirror.styled, columns: mirror.columns)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            // Click the screen to give it the keyboard: arrows, Return, Esc, Tab, ⌫, ⌃C and text go to iTerm.
            .overlay {
                KeyCapture(active: $keyboard) { mirror.send($0) }
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .frame(minHeight: frameHeight.min, maxHeight: frameHeight.max)
        } else {
            // No terminal (closed session, iTerm unreachable): rebuilt from the transcript.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let failure = mirror?.failure {
                        Text(failure).font(Term.mono(10)).foregroundStyle(Term.amber)
                    }
                    if transcript.isEmpty {
                        Text("Aucun échange dans le journal de cette session.").font(Term.mono(11)).foregroundStyle(Term.dim)
                    } else {
                        TermRowsView(rows: transcript)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .frame(minHeight: frameHeight.min, maxHeight: frameHeight.max)
        }
    }

    private func poll() async {
        attachEnded = false
        // Background session: the embedded terminal is the session itself, nothing to poll.
        if attachedJob != nil { mirror = nil; return }
        var tty: String?
        if let pid = SessionLineage.terminalPID(for: session.info.id, live: live) {
            tty = await Task.detached(priority: .userInitiated) { Terminals.tty(of: pid) }.value
        }
        guard !Task.isCancelled else { return }
        guard let tty else {
            mirror = nil
            keyboard = false
            let id = session.info.id
            transcript = await Task.detached { TranscriptTerminal.rows(for: id) }.value
            return
        }
        let m = mirror?.tty == tty ? mirror! : TerminalMirror(tty: tty)
        mirror = m
        var lastHistory = Date.distantPast
        while !Task.isCancelled {
            // Panel hidden and no floating window: no AppleScript traffic (iTerm stays idle too).
            guard AppActivity.shared.visible else { try? await Task.sleep(for: .seconds(1)); continue }
            await m.refresh()
            // History (transcript) above the live screen: refreshed every few seconds, cached by file size.
            if Date().timeIntervalSince(lastHistory) > 3 {
                lastHistory = Date()
                let id = session.info.id
                let history = await Task.detached { TranscriptTerminal.rows(for: id) }.value
                if history != transcript { transcript = history }
            }
            // Typing: refresh every 150 ms (each send also refreshes at once); otherwise every second. Tab not found:
            // each attempt walks every iTerm window, so retry every 5 s only.
            try? await Task.sleep(for: m.failure != nil ? .seconds(5) : keyboard ? .milliseconds(150) : .seconds(1))
        }
    }
}

/// An iTerm screen drawn exactly: same characters, same line breaks, the tab's font and colours, no wrapping.
/// The font shrinks so that the tab's full width fits, down to a readable minimum; beyond, the screen scrolls sideways.
struct ITermScreen: View {
    let lines: [String]
    var styled: [AttributedString]? = nil
    let columns: Int

    var body: some View {
        let profile = ITermProfile.current
        GeometryReader { geo in
            let base = profile.font
            let advance = max(1, ("M" as NSString).size(withAttributes: [.font: base]).width)
            let fit = base.pointSize * geo.size.width / (advance * CGFloat(max(columns, 20)))
            let size = min(base.pointSize, max(10, fit))
            let font = Font(NSFont(descriptor: base.fontDescriptor, size: size) ?? base)
            let screen = VStack(alignment: .leading, spacing: 0) {
                if let styled {
                    ForEach(Array(styled.enumerated()), id: \.offset) { _, line in
                        Text(line.characters.isEmpty ? AttributedString(" ") : line).font(font)
                            .foregroundStyle(Color(nsColor: profile.foreground))
                            .lineLimit(1).fixedSize()
                    }
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).font(font).foregroundStyle(Color(nsColor: profile.foreground))
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            .textSelection(.enabled)
            .background(GeometryReader { inner in Color.clear.preference(key: ScreenHeight.self, value: inner.size.height) })
            if fit < 10 {
                ScrollView(.horizontal) { screen }.scrollIndicators(.automatic)
            } else {
                screen.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: height)
        .onPreferenceChange(ScreenHeight.self) { height = $0 }
    }

    @State private var height: CGFloat = 200
    private struct ScreenHeight: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

/// Transparent layer over the mirrored screen: a click gives it the keyboard; keys are translated to terminal
/// input (escape sequences for arrows…) and sent to the session. Scrolling and clicks still reach the view below
/// through the wheel; text selection is off while the keyboard is captured.
struct KeyCapture: NSViewRepresentable {
    @Binding var active: Bool
    let send: (String) -> Void

    final class KeyView: NSView {
        var send: (String) -> Void = { _ in }
        var onFocus: (Bool) -> Void = { _ in }
        /// Takes the keyboard only after a click in it: never automatically when the panel becomes key (Escape and
        /// typing would otherwise go to the session instead of the panel).
        private var clicked = false
        override var acceptsFirstResponder: Bool { clicked }
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { clicked = true; window?.makeKey(); window?.makeFirstResponder(self) }
        override func becomeFirstResponder() -> Bool { onFocus(true); return true }
        override func resignFirstResponder() -> Bool { clicked = false; onFocus(false); return true }
        // Let trackpad/wheel scrolling through to the scroll view underneath: this layer only takes clicks and keys.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if let type = NSApp.currentEvent?.type, type == .scrollWheel || type == .magnify || type == .swipe { return nil }
            return super.hitTest(point)
        }

        override func keyDown(with event: NSEvent) {
            let esc = "\u{1B}"
            switch event.keyCode {
            case 126: send(esc + "[A"); return          // ↑
            case 125: send(esc + "[B"); return          // ↓
            case 124: send(esc + "[C"); return          // →
            case 123: send(esc + "[D"); return          // ←
            case 36, 76: send("\r"); return             // Return / Enter
            case 53: send(esc); return                   // Esc
            case 48: send(event.modifierFlags.contains(.shift) ? esc + "[Z" : "\t"); return   // Tab / ⇧Tab
            case 51: send("\u{7F}"); return             // ⌫
            case 117: send(esc + "[3~"); return         // ⌦
            case 115: send(esc + "[H"); return          // ↖ Home
            case 119: send(esc + "[F"); return          // ↘ End
            case 116: send(esc + "[5~"); return         // ⇞ Page up
            case 121: send(esc + "[6~"); return         // ⇟ Page down
            default: break
            }
            if event.modifierFlags.contains(.control), let c = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
               c.value >= 97, c.value <= 122 {
                send(String(UnicodeScalar(c.value - 96)!))   // ⌃A…⌃Z
                return
            }
            if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
            // Function keys arrive as private-use characters (U+F700…): never type them as text.
            if let chars = event.characters, !chars.isEmpty, !chars.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) {
                send(chars)
            }
        }
    }

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.send = send
        v.onFocus = { focused in DispatchQueue.main.async { active = focused } }
        return v
    }
    func updateNSView(_ v: KeyView, context: Context) { v.send = send }
}
