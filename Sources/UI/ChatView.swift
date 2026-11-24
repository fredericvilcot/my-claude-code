import SwiftUI

/// Agent-to-agent messaging of a session: what it exchanged with other Claude Code sessions (SendMessage), and the
/// requests the user made here. Never its terminal nor the prompts typed there (those are in the terminal mirror).
/// Writing here asks this session to message another running session itself; to talk to this session, use its
/// terminal or the quick command.
@MainActor
struct ChatPanel: View {
    @Environment(UsageStore.self) private var store
    let session: SessionStat
    /// Height of the message list (smaller in a floating window).
    var listHeight: CGFloat = 340
    @State private var center = SendCenter.shared
    @State private var items: [ChatItem] = []
    @State private var dictation = Dictation()
    @State private var pickerOpen = false
    /// The field takes the keyboard as soon as the messages are shown: caret blinking, ready to type.
    @State private var fieldFocused = false

    private var live: LiveSession? { store.live[session.info.id] }
    /// Latest entries laid out in the list (all rows are measured, see the list below).
    static let shownLimit = 60

    /// One row of the conversation: a transcript entry, or one of your requests from this chat.
    enum Row: Identifiable {
        case item(ChatItem)
        case request(SendJob)
        var id: String { switch self { case .item(let i): i.id; case .request(let j): j.id.uuidString } }
        var date: Date { switch self { case .item(let i): i.date; case .request(let j): j.started } }
    }

    var body: some View {
        let selfName = live?.name ?? session.displayName
        let others = store.live.values.filter { $0.sessionId != session.info.id && $0.isMessagingTarget }.sorted { $0.name < $1.name }
        let target = chosenTarget(among: others)
        let canSend = live.map { !$0.name.isEmpty } == true && target != nil
        let text = Binding(get: { center.drafts[session.info.id] ?? "" },
                           set: { center.drafts[session.info.id] = $0.isEmpty ? nil : $0 })
        let requests = center.jobs(for: session.info.id).filter(\.isRelay)
        let rows = (items.map(Row.item) + requests.map(Row.request)).sorted { $0.date < $1.date }
        let shown = Array(rows.suffix(Self.shownLimit))
        let loop = Self.loopWarning(items, selfName: selfName)
        Block(title: "Messages entre agents", note: items.isEmpty ? nil : "\(items.count) message\(items.count > 1 ? "s" : "")") {
            Text("Ce que cette session échange avec les autres sessions Claude Code (SendMessage). Écrire ici demande à \(selfName) de rédiger un message pour la session choisie : My Claude Code le lui transmet, puis rapporte sa réponse à \(selfName). Pour lui parler directement : son terminal ou le message rapide.")
                .font(Theme.sans(11)).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
            RecipientPicker(selfName: selfName, others: others, includeSelf: false,
                            recipientID: Binding(get: { target?.sessionId }, set: { center.recipients[session.info.id] = $0 }),
                            open: $pickerOpen)

            ScrollViewReader { proxy in
                ScrollView {
                    // A plain VStack, never a lazy one: this scroll view sits inside the session sheet's own scroll view,
                    // whose layout measures the list's full height on every pass. A LazyVStack answers with estimates
                    // that change with the rows it has just realized, and realizing rows invalidates that measure again:
                    // in the menu bar menu the two never settled and the main thread spun forever (LazyLayoutViewCache
                    // item phases ↔ LazySubviewPlacements). The list is short (the latest entries only), so laying
                    // out every row is cheap and its height is exact.
                    VStack(alignment: .leading, spacing: 10) {
                        if rows.isEmpty {
                            Text("Aucun message entre sessions pour l'instant. Choisissez une session ci-dessus et demandez à \(selfName) de lui écrire.")
                                .font(Theme.sans(12)).foregroundStyle(Theme.inkFaint).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        if rows.count > Self.shownLimit {
                            Text("\(rows.count - Self.shownLimit) messages plus anciens dans le journal de la session")
                                .font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint).frame(maxWidth: .infinity)
                        }
                        ForEach(shown) { row in
                            switch row {
                            case .item(let item): ChatRow(item: item, selfName: selfName, retry: resend(item, among: others)).id(item.id)
                            case .request(let job):
                                RequestBubble(job: job, steps: Self.steps(of: job, selfName: selfName),
                                              hide: { center.delete(job.id) }, retry: retry(job, among: others))
                                    .id(job.id.uuidString)
                            }
                        }
                        if let loop {
                            Label(loop, systemImage: "arrow.triangle.2.circlepath")
                                .font(Theme.sans(11)).foregroundStyle(.orange).frame(maxWidth: .infinity)
                        }
                        if typing(shown.last) { TypingBubble(name: selfName).id("typing") }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: listHeight)
                // Opens on the latest messages, and stays there as the list grows.
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.never)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: rows.count) { old, _ in
                    // First load: straight to the latest message; then new messages slide in.
                    if old == 0 { proxy.scrollTo("bottom", anchor: .bottom) } else { withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
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
                ClayTextField(text: text, placeholder: dictation.isRecording ? "Je vous écoute…"
                                : target.map { "Ce que \(selfName) doit écrire à \($0.name)…" } ?? "Choisissez d'abord à qui écrire",
                              minLines: 1, maxLines: 6, focused: $fieldFocused, onSubmit: { send(text.wrappedValue, to: target) })
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(dictation.isRecording ? Color.red.opacity(0.6) : Theme.rule, lineWidth: dictation.isRecording ? 1.5 : 0.5))
                let empty = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { send(text.wrappedValue, to: target) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(empty || !canSend ? Theme.inkFaint : Theme.clay))
                }
                .buttonStyle(.plain)
                .disabled(empty || !canSend)
            }
            if live == nil {
                Text("Cette session est fermée : elle ne peut pas écrire à une autre session.").font(Theme.sans(11)).foregroundStyle(Theme.inkFaint)
            } else if others.isEmpty {
                Text("Aucune autre session ouverte à qui écrire.").font(Theme.sans(11)).foregroundStyle(Theme.inkFaint)
            } else if target == nil {
                Text(center.recipients[session.info.id] != nil ? "La session choisie est fermée : choisissez un autre destinataire."
                                                                : "Choisissez la session à qui \(selfName) doit écrire.")
                    .font(Theme.sans(11)).foregroundStyle(.orange)
            }
            if let error = dictation.error { Text(error).font(Theme.sans(11.5)).foregroundStyle(.orange) }
        }
        .onChange(of: dictation.transcript) { _, t in if dictation.isRecording { center.drafts[session.info.id] = t } }
        .onAppear { fieldFocused = true }
        .task(id: session.info.id) {
            // Live refresh: re-read the transcript (only when it changed) every second while the chat is shown.
            while !Task.isCancelled {
                guard AppActivity.shared.visible else { try? await Task.sleep(for: .seconds(1)); continue }
                let id = session.info.id
                let fresh = await Task.detached(priority: .utility) { ChatLog.items(for: id) }.value
                if fresh != items { items = fresh }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The recipient chosen for this session, kept across openings; never silently another one. With no choice yet,
    /// the last session this one exchanged with, if it is still open.
    private func chosenTarget(among others: [LiveSession]) -> LiveSession? {
        if let chosen = center.recipients[session.info.id] { return others.first { $0.sessionId == chosen } }
        for item in items.reversed() {
            let name = item.role == .agent ? item.to : item.role == .peer ? item.from : ""
            if let o = others.first(where: { $0.name == name }) { return o }
        }
        return nil
    }

    /// Dots while this session works on a request: the latest entry asks something of it and it is busy.
    private func typing(_ last: Row?) -> Bool {
        guard live?.phase == 0, let last else { return false }
        switch last {
        case .request(let job): return job.succeeded
        case .item(let item): return item.role == .relay || item.role == .quick || item.role == .me || item.role == .peer
        }
    }

    /// Progress of one of your requests, leg by leg (see SendCenter.relay).
    static func steps(of job: SendJob, selfName: String) -> [RequestBubble.Step] {
        let a = job.via ?? selfName, b = job.target ?? ""
        let legs = [("transmettre votre consigne à \(a)", "consigne transmise à \(a)"),
                    ("\(a) rédige son message pour \(b)", "\(a) a rédigé son message"),
                    ("transmettre le message à \(b)", "message transmis à \(b)"),
                    ("\(b) rédige sa réponse", "\(b) a répondu"),
                    ("transmettre la réponse à \(a)", "réponse transmise à \(a)")]
        guard let stage = job.stage else {
            // Request from an earlier version of the app.
            return [.init(text: job.summary, state: job.isRunning ? .running : job.succeeded ? .done : .failed)]
        }
        var steps: [RequestBubble.Step] = []
        for (i, leg) in legs.enumerated() where i <= stage {
            if i < stage { steps.append(.init(text: leg.1, state: .done)); continue }
            switch job.state {
            case .failed(let why): steps.append(.init(text: why, state: .failed))
            case .sending: steps.append(.init(text: leg.0 + "…", state: i == 1 || i == 3 ? .waiting : .running))
            default: break
            }
        }
        if stage == 5, job.reply == "(rien à répondre)" { steps.append(.init(text: "\(b) n'avait rien à répondre", state: .done)) }
        return steps
    }

    /// Sessions answering each other back and forth with no new request: likely a loop.
    static func loopWarning(_ items: [ChatItem], selfName: String) -> String? {
        var turns = 0
        var other = ""
        for item in items.reversed() {
            let name = item.role == .agent ? item.to : item.role == .peer ? item.from : nil
            guard let name else { break }
            if other.isEmpty { other = name } else if name != other { break }
            turns += 1
        }
        return turns >= 6 ? "\(selfName) et \(other) se répondent en boucle (\(turns) messages sans nouvelle demande)" : nil
    }

    /// Sends a failed request again, as a new one (the failed one is removed): only while both sessions are open.
    private func retry(_ job: SendJob, among others: [LiveSession]) -> (() -> Void)? {
        guard let live, !live.name.isEmpty, let target = others.first(where: { $0.name == job.target }) else { return nil }
        return {
            center.delete(job.id)
            center.relay(job.prompt, from: session, via: live, to: target)
        }
    }

    /// A message this session could not send (refused, failed): asks it again, through a new request, to send it to
    /// the same session. Only while both sessions are open.
    private func resend(_ item: ChatItem, among others: [LiveSession]) -> (() -> Void)? {
        guard item.role == .agent, case .failed = item.delivery, let live, !live.name.isEmpty,
              let target = others.first(where: { $0.name == item.to }) else { return nil }
        return {
            center.recipients[session.info.id] = target.sessionId
            center.relay("Écris à « \(target.name) » ce message :\n\n\(item.text)", from: session, via: live, to: target)
        }
    }

    /// Asks this session to write to `target` itself, with SendMessage (relayed to it by an ephemeral agent).
    private func send(_ prompt: String, to target: LiveSession?) {
        dictation.stop()
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, let live, !live.name.isEmpty, let target else { return }
        center.recipients[session.info.id] = target.sessionId
        center.relay(p, from: session, via: live, to: target)
    }
}

/// One transcript entry, labelled with who writes to whom.
struct ChatRow: View {
    let item: ChatItem
    let selfName: String
    /// Failed send: sends it again (nil when one of the two sessions is closed).
    var retry: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        switch item.role {
        case .relay:
            Fold(icon: "arrow.turn.down.right", label: "Consigne transmise à \(selfName) par l'agent intermédiaire", text: item.text,
                 date: item.date, expanded: $expanded)
        case .quick:
            Fold(icon: "bolt.fill", label: "Message rapide transmis à \(selfName)", text: item.text, date: item.date, expanded: $expanded)
        case .me:
            Fold(icon: "bolt.fill", label: "Message de My Claude Code à \(selfName)", text: item.text, date: item.date, expanded: $expanded)
        case .note:
            message(header: item.to.isEmpty ? "\(selfName) → vous (dans son terminal)" : "\(selfName) n'a pas écrit à \(item.to) · fin de son tour",
                    tint: item.to.isEmpty ? Theme.inkSoft : .orange, fill: Theme.raised, stroke: item.to.isEmpty ? Theme.rule : Color.orange.opacity(0.5))
        case .agent:
            switch item.delivery {
            case .failed(let why):
                message(header: "\(selfName) → \(item.to)", tint: .red, fill: Color.red.opacity(0.06), stroke: Color.red.opacity(0.5),
                        status: "non envoyé : \(why)")
            case .pending:
                message(header: "\(selfName) → \(item.to)", tint: Theme.inkSoft, fill: Theme.raised, stroke: Theme.rule, status: "envoi en cours…")
            case .sent:
                message(header: "\(selfName) → \(item.to)", tint: Theme.inkSoft, fill: Theme.raised, stroke: Theme.rule)
            }
        case .peer:
            message(header: "\(item.from) → \(selfName)", tint: Theme.slate, fill: Theme.slate.opacity(0.12), stroke: Theme.slate.opacity(0.35))
        }
    }

    private func message(header: String, tint: Color, fill: Color, stroke: Color, status: String? = nil) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(header).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
                    .lineLimit(1).truncationMode(.middle).padding(.horizontal, 4)
                Text(LocalizedStringKey(item.text))
                    .font(Theme.sans(13)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(fill))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(stroke, lineWidth: 0.5))
                Text([Fmt.time(item.date), status].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.sans(10)).foregroundStyle(status == nil ? Theme.inkFaint : tint).padding(.horizontal, 4)
                if case .failed = item.delivery {
                    Group {
                        if let retry {
                            Button(action: retry) { Label("Réessayer", systemImage: "arrow.clockwise") }
                                .buttonStyle(.plain).foregroundStyle(Theme.clay)
                        } else {
                            Text("session fermée : impossible de réessayer").foregroundStyle(Theme.inkFaint)
                        }
                    }
                    .font(Theme.sans(10.5, .semibold)).padding(.horizontal, 4)
                }
            }
            Spacer(minLength: 40)
        }
    }
}

/// A message from an intermediary agent: one line, unfolded on demand.
struct Fold: View {
    let icon: String
    let label: String
    let text: String
    let date: Date
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 9, weight: .bold))
                    Text("\(label) · \(Fmt.time(date))").lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(LocalizedStringKey(text)).font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).textSelection(.enabled)
                    .padding(.leading, 14).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Your request from this chat, with its progress.
struct RequestBubble: View {
    struct Step { enum State { case running, waiting, done, failed }; let text: String; let state: State }
    let job: SendJob
    let steps: [Step]
    let hide: () -> Void
    /// Nil when one of the two sessions is closed.
    var retry: (() -> Void)?
    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 3) {
                Text("Vous → \(job.via ?? "") · écrire à \(job.target ?? "")")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.clay)
                    .lineLimit(1).truncationMode(.middle).padding(.horizontal, 4)
                Text(job.prompt).font(Theme.sans(13)).foregroundStyle(.white).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.clay.opacity(job.isRunning ? 0.6 : 1)))
                TimelineView(.whileShown(1)) { _ in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.time(job.started)).foregroundStyle(Theme.inkFaint)
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            HStack(spacing: 4) {
                                switch step.state {
                                case .running: ProgressView().controlSize(.mini)
                                case .waiting: Image(systemName: "clock").foregroundStyle(Theme.inkFaint)
                                case .done: Image(systemName: "checkmark").foregroundStyle(Theme.sage)
                                case .failed: Image(systemName: "xmark").foregroundStyle(.red)
                                }
                                Text(step.text).foregroundStyle(step.state == .failed ? Color.red : Theme.inkSoft)
                                    .lineLimit(3).multilineTextAlignment(.trailing)
                            }
                        }
                        if !job.isRunning, steps.contains(where: { $0.state == .failed }) {
                            HStack(spacing: 10) {
                                if let retry {
                                    Button(action: retry) { Label("Réessayer", systemImage: "arrow.clockwise") }
                                        .buttonStyle(.plain).foregroundStyle(Theme.clay)
                                } else {
                                    Text("session fermée : impossible de réessayer").foregroundStyle(Theme.inkFaint)
                                }
                                Button("Masquer", action: hide).buttonStyle(.plain).foregroundStyle(Theme.inkFaint).underline()
                            }
                            .font(Theme.sans(10.5, .semibold))
                        }
                    }
                    .font(Theme.sans(10)).padding(.horizontal, 4)
                }
            }
        }
    }
}

struct TypingBubble: View {
    var name = ""
    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.whileShown(0.35)) { ctx in
                let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle().fill(Theme.inkSoft).frame(width: 6, height: 6).opacity(i == phase ? 1 : 0.35)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.raised))
            }
            if !name.isEmpty { Text("\(name) travaille…").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint) }
            Spacer()
        }
    }
}
