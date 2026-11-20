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
    @State private var inputError: String?

    var body: some View {
        VStack(spacing: 0) {
            windowBar
            content
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Term.background))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
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
                TermRowsView(rows: mirror.rows).padding(.horizontal, 14).padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.never)
            .frame(minHeight: fill ? 120 : 340, maxHeight: fill ? .infinity : 340)
            promptLine(mirror)
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
        while !Task.isCancelled {
            await m.refresh()
            if m.failure != nil, transcript.isEmpty {
                let id = session.info.id
                transcript = await Task.detached { TranscriptTerminal.rows(for: id) }.value
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
