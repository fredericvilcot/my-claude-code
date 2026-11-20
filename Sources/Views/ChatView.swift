import SwiftUI

/// Agent-to-agent messaging of a session: what it exchanged with other Claude Code sessions and with My Claude Code
/// (SendMessage). Never its terminal nor the prompts typed there (those are in the terminal mirror).
@MainActor
struct ChatPanel: View {
    @Environment(UsageStore.self) private var store
    let session: SessionStat
    @State private var center = SendCenter.shared
    @State private var items: [ChatItem] = []
    @State private var dictation = Dictation()
    @State private var pickerOpen = false

    private var live: LiveSession? { store.live[session.info.id] }

    var body: some View {
        let others = store.live.values.filter {
            $0.sessionId != session.info.id && !$0.name.isEmpty && $0.kind != "background" && !$0.name.hasPrefix("my-claude-code")
        }.sorted { $0.name < $1.name }
        let text = Binding(get: { center.drafts[session.info.id] ?? "" },
                           set: { center.drafts[session.info.id] = $0.isEmpty ? nil : $0 })
        let sessionJobs = center.jobs(for: session.info.id)
        // A message already visible in the session's transcript is shown once, with its live status under it.
        let pending = sessionJobs.filter { job in
            !items.contains { $0.role == .me && $0.text == job.prompt } && (job.isRunning || !job.succeeded)
        }
        Block(title: "Messages entre agents", note: items.isEmpty ? nil : "\(items.count) message\(items.count > 1 ? "s" : "")") {
            Text("Ce que cette session a échangé avec les autres sessions Claude Code et avec My Claude Code. Ni son terminal, ni les prompts tapés dedans : ils sont dans le miroir ci-dessus.")
                .font(Theme.sans(11)).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
            RecipientPicker(selfName: live?.name ?? session.name, others: others,
                            recipientID: Binding(get: { nil }, set: { id in
                                // Choosing another session opens its own conversation.
                                if let id, let target = store.snapshot.sessions.first(where: { $0.info.id == id }) {
                                    NotificationCenter.default.post(name: .openSession, object: target.index)
                                }
                            }),
                            open: $pickerOpen)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if items.isEmpty && pending.isEmpty {
                            Text("Aucun message entre sessions pour l'instant. Écrivez à l'agent de cette session ci-dessous.")
                                .font(Theme.sans(12)).foregroundStyle(Theme.inkFaint)
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        ForEach(items) { item in
                            Bubble(item: item, status: item.role == .me ? sessionJobs.first { $0.isRunning && $0.prompt == item.text } : nil)
                                .id(item.id)
                        }
                        ForEach(pending) { job in PendingBubble(job: job).id(job.id.uuidString) }
                        if typing { TypingBubble().id("typing") }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 340)
                .scrollIndicators(.never)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: items.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: pending.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))

            HStack(alignment: .bottom, spacing: 8) {
                Button { dictation.toggle() } label: {
                    Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(dictation.isRecording ? Color.red : Theme.clay)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill((dictation.isRecording ? Color.red : Theme.clay).opacity(0.13)))
                }
                .buttonStyle(.plain)
                TextField("", text: text, prompt: Text(dictation.isRecording ? "Je vous écoute…" : "Écrire à l'agent…")
                            .foregroundStyle(Theme.inkFaint), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.sans(13.5)).foregroundStyle(Theme.ink)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(dictation.isRecording ? Color.red.opacity(0.6) : Theme.rule, lineWidth: dictation.isRecording ? 1.5 : 0.5))
                    .onSubmit { send(text.wrappedValue) }
                Button { send(text.wrappedValue) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.inkFaint : Theme.clay))
                }
                .buttonStyle(.plain)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = dictation.error { Text(error).font(Theme.sans(11.5)).foregroundStyle(.orange) }
        }
        .onChange(of: dictation.transcript) { _, t in if dictation.isRecording { center.drafts[session.info.id] = t } }
        .task(id: session.info.id) {
            // Live refresh: re-read the transcript (only when it changed) every second while the chat is shown.
            while !Task.isCancelled {
                let prompts = Set(center.jobs.map(\.prompt))
                let id = session.info.id
                let fresh = await Task.detached(priority: .utility) { ChatLog.items(for: id, appPrompts: prompts) }.value
                if fresh != items { items = fresh }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The agent is working on your last message.
    private var typing: Bool {
        guard let last = items.last, last.role != .agent else { return false }
        return live?.phase == 0 || Date().timeIntervalSince(last.date) < 20
    }

    private func send(_ prompt: String) {
        dictation.stop()
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        center.send(p, from: session, to: live)
    }
}

struct Bubble: View {
    let item: ChatItem
    var status: SendJob?
    var body: some View {
        let mine = item.role == .me
        let label: String = {
            switch item.role {
            case .me: return "Vous"
            case .agent: return "→ \(item.to)"
            case .peer: return "\(item.from) →"
            }
        }()
        HStack(alignment: .bottom) {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                Text(label).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.role == .peer ? Theme.slate : Theme.inkSoft).padding(.horizontal, 4)
                Text(LocalizedStringKey(item.text))
                    .font(Theme.sans(13)).foregroundStyle(mine ? Color.white : Theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(mine ? Theme.clay : item.role == .peer ? Theme.slate.opacity(0.14) : Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(mine ? Color.clear : item.role == .peer ? Theme.slate.opacity(0.35) : Theme.rule, lineWidth: 0.5))
                if let status {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("\(Fmt.time(item.date)) · en attente de la réponse · \(Int(status.duration)) s")
                        }
                        .font(Theme.sans(10)).foregroundStyle(Theme.inkFaint).padding(.horizontal, 4)
                    }
                } else {
                    Text(Fmt.time(item.date)).font(Theme.sans(10)).foregroundStyle(Theme.inkFaint).padding(.horizontal, 4)
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// Your message while it is being delivered (or if delivery failed).
struct PendingBubble: View {
    let job: SendJob
    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 3) {
                Text(job.prompt).font(Theme.sans(13)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.clay.opacity(job.isRunning ? 0.55 : 0.35)))
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(job.isRunning ? "\(job.stepLabel) \(Int(job.duration)) s" : job.summary)
                        .font(Theme.sans(10)).foregroundStyle(job.isRunning ? Theme.inkFaint : Color.red).lineLimit(2)
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

struct TypingBubble: View {
    var body: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 0.35)) { ctx in
                let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle().fill(Theme.inkSoft).frame(width: 6, height: 6).opacity(i == phase ? 1 : 0.35)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.raised))
            }
            Spacer()
        }
    }
}
