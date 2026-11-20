import SwiftUI

/// A session's terminal, mirrored: a dark window frame (traffic-light dots, tab name, live dot) around the exact
/// screen of its iTerm tab. Background sessions (no tab) fall back to the activity log.
@MainActor
struct TerminalMirrorView: View {
    let session: SessionStat
    let live: LiveSession?
    var fill = false
    @State private var mirror: TerminalMirror?
    @State private var transcript: [TerminalMirror.Row] = []
    @State private var input = ""
    /// The terminal has the keyboard: every key goes to the session's iTerm tab.
    @State private var keyboard = false
    @State private var inputError: String?

    var body: some View {
        VStack(spacing: 0) {
            windowBar
            content
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Term.background))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(keyboard ? Theme.clay.opacity(0.8) : Color.white.opacity(0.07), lineWidth: keyboard ? 1.5 : 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .task(id: live?.pid) { await poll() }
    }

    private var windowBar: some View {
        HStack(spacing: 6) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                Circle().fill(c.opacity(0.85)).frame(width: 8, height: 8)
            }
            Text(title).font(Term.mono(10.5)).foregroundStyle(Term.dim).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity)
            if mirror == nil || mirror?.failure != nil {
                Text("journal").font(Term.mono(9.5, .semibold)).foregroundStyle(Term.dim)
            } else {
                if keyboard {
                    Label("clavier", systemImage: "keyboard").font(Term.mono(9.5, .semibold)).foregroundStyle(Theme.clay)
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
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
        return live?.name.isEmpty == false ? live!.name : session.name
    }

    @ViewBuilder
    private var content: some View {
        if let mirror, mirror.failure == nil {
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
                    TermRowsView(rows: mirror.rows)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            // Click the screen to give it the keyboard: arrows, Return, Esc, Tab, ⌫, ⌃C and text go to iTerm.
            .overlay {
                KeyCapture(active: $keyboard) { mirror.send($0) }
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .frame(minHeight: fill ? 120 : 340, maxHeight: fill ? .infinity : 340)
        } else {
            // No iTerm tab (closed session, background agent, iTerm unreachable): rebuilt from the transcript.
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
            .frame(minHeight: fill ? 120 : 340, maxHeight: fill ? .infinity : 340)
        }
    }

    /// Typing here is typing in the session's terminal: the text goes to its iTerm tab, followed by Return.
    private func promptLine(_ mirror: TerminalMirror) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text("❯").font(Term.mono(12, .bold)).foregroundStyle(Term.green)
                TextField("", text: $input, prompt: Text("Écrire à l'agent, comme dans le terminal…").foregroundStyle(Term.dim))
                    .textFieldStyle(.plain)
                    .font(Term.mono(11.5)).foregroundStyle(Term.text)
                    .onSubmit { type(into: mirror) }
            }
            if let inputError { Text(inputError).font(Term.mono(10)).foregroundStyle(Term.amber) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5) }
    }

    private func type(into mirror: TerminalMirror) {
        let text = input.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input = ""
        Compactor.type(text, tty: mirror.tty) { error in
            inputError = error
            Task { await mirror.refresh() }   // show it right away
        }
    }

    private func poll() async {
        guard let pid = live?.pid, let tty = Compactor.tty(of: pid) else {
            mirror = nil
            // Rebuilt from the transcript; refreshed while the session is still running (background agent).
            repeat {
                let id = session.info.id
                transcript = await Task.detached { TranscriptTerminal.rows(for: id) }.value
                if live == nil { return }
                try? await Task.sleep(for: .seconds(2))
            } while !Task.isCancelled
            return
        }
        let m = mirror?.tty == tty ? mirror! : TerminalMirror(tty: tty)
        mirror = m
        var lastHistory = Date.distantPast
        while !Task.isCancelled {
            await m.refresh()
            // History (transcript) under the live screen: refreshed every few seconds, cached by file size.
            if Date().timeIntervalSince(lastHistory) > 3 {
                lastHistory = Date()
                let id = session.info.id
                let history = await Task.detached { TranscriptTerminal.rows(for: id) }.value
                if history != transcript { transcript = history }
            }
            if keyboard {   // typing: refresh every 150 ms (each send also refreshes at once)
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            if m.failure != nil, transcript.isEmpty {
                let id = session.info.id
                transcript = await Task.detached { TranscriptTerminal.rows(for: id) }.value
            }
            try? await Task.sleep(for: .seconds(1))
        }
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
        override var acceptsFirstResponder: Bool { true }
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self) }
        override func becomeFirstResponder() -> Bool { onFocus(true); return true }
        override func resignFirstResponder() -> Bool { onFocus(false); return true }
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
            default: break
            }
            if event.modifierFlags.contains(.control), let c = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
               c.value >= 97, c.value <= 122 {
                send(String(UnicodeScalar(c.value - 96)!))   // ⌃A…⌃Z
                return
            }
            if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
            if let chars = event.characters, !chars.isEmpty { send(chars) }
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
