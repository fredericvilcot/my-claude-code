import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview, sessions, stats, status, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Direct"
        case .sessions: "Sessions"
        case .stats: "Stats"
        case .status: "Statut"
        case .settings: "Réglages"
        }
    }
}

struct DashboardView: View {
    @Environment(UsageStore.self) private var store
    @State private var tab: Tab = .overview
    @State private var quickOpen = false
    @State private var notificationsOpen = false
    @State private var quickDictate = false   // set by the global hot key: the quick view starts dictation
    @State private var selectedSession: Int?
    @State private var resetToken = UUID()
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            header
            // Single place for send feedback: the running send, then its result.
            // Only failures get a banner: progress and acknowledgements live in the chat.
            if let job = SendCenter.shared.banner, !job.isRunning, !job.succeeded {
                SendBanner(job: job) { SendCenter.shared.banner = nil }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.snappy, value: job.isRunning)
            }
            tabBar
            Group {
                if store.loading && store.snapshot.all.messages == 0 {
                    VStack(spacing: 12) {
                        SparkGlyph(size: 28)
                        Text(store.status).font(Theme.serif(16, .medium)).foregroundStyle(Theme.ink)
                        Text("Première lecture de vos journaux — quelques secondes.").font(Theme.sans(11.5)).foregroundStyle(Theme.inkFaint)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch tab {
                    case .overview: LiveView()
                    case .sessions: SessionsView(selected: $selectedSession)
                    case .stats: StatsView()
                    case .status: StatusView()
                    case .settings: SettingsView()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .background(Theme.paper)
        .overlay {
            if notificationsOpen {
                NotificationCenterView(close: { withAnimation(.snappy(duration: 0.25)) { notificationsOpen = false } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.paper)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if quickOpen {
                QuickView(dictate: $quickDictate, close: { withAnimation(.snappy(duration: 0.25)) { quickOpen = false } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.paper)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .tint(Theme.clay)
        .onReceive(NotificationCenter.default.publisher(for: .openQuick)) { note in
            withAnimation(.snappy(duration: 0.2)) { quickOpen = true }
            if note.object as? Bool == true { quickDictate = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNotifications)) { _ in
            quickOpen = false
            withAnimation(.snappy(duration: 0.25)) { notificationsOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeOverlays)) { _ in
            notificationsOpen = false; quickOpen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSession)) { note in
            if let index = note.object as? Int { open(index) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectTab)) { note in
            if let raw = note.object as? String, let t = Tab(rawValue: raw) { tab = t }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelReset)) { _ in
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { tab = .overview; selectedSession = nil }   // no rebuild: keeps opening instant
        }
    }

    private func open(_ index: Int) {
        selectedSession = index
        withAnimation(.snappy) { tab = .sessions }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                SparkGlyph(size: 24)
                Text("My Claude Code").font(Theme.serif(19, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    .fixedSize().layoutPriority(2)
                Spacer(minLength: 6)
                bellButton
                Button { withAnimation(.snappy(duration: 0.25)) { notificationsOpen = false; quickOpen = true } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold))
                        Text("Rapide").font(Theme.sans(12, .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .fixedSize()
                    .background(Capsule().fill(Theme.clay))
                }
                .buttonStyle(.plain)
                .tip("Message rapide à une ou plusieurs sessions, ou tâche ponctuelle")
            }
            // One summary line: plan, model and effort, open sessions.
            HStack(spacing: 0) {
                summaryItem("person.crop.circle.fill", planShort)
                divider
                summaryItem("cpu", modelShort)
                divider
                summaryItem("rectangle.stack.fill", "\(activeCount) session\(activeCount > 1 ? "s" : "")")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.raised))
            .overlay(Capsule().strokeBorder(Theme.rule, lineWidth: 0.5))
            .tip([planLine, setupLine, sessionsLine].joined(separator: "\n"))
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
        // Floating window: the header is its drag area, with a small grip on top as a hint.
        .background { if detached { WindowDragHandle() } }
        .overlay(alignment: .top) {
            if detached {
                Capsule().fill(Theme.inkFaint.opacity(0.5)).frame(width: 36, height: 4).padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
    }

    @AppStorage("panelDetached") private var detached = false

    /// The bell: opens the notification center; a badge counts what is waiting.
    private var bellButton: some View {
        let count = MainActor.assumeIsolated { AttentionCenter.shared.items.count }
        return Button { withAnimation(.snappy(duration: 0.25)) { quickOpen = false; notificationsOpen = true } } label: {
            Image(systemName: count > 0 ? "bell.fill" : "bell").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(count > 0 ? Theme.clay : Theme.inkSoft)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.raised))
                .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(min(count, 99))").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4.5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 4, y: -3)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip(count > 0 ? "\(count) notification\(count > 1 ? "s" : "")" : "Notifications")
    }

    private var planShort: String {
        let plan = (store.account.plan ?? "Claude").replacingOccurrences(of: "Claude ", with: "")
        return [plan, store.account.limits].compactMap { $0 }.joined(separator: " · ")
    }

    private var modelShort: String {
        let c = store.claude
        return [c.model, c.effort.map(ContextBlock.effort)].compactMap { $0 }.joined(separator: " · ")
    }

    private var divider: some View {
        Rectangle().fill(Theme.rule).frame(width: 1, height: 14)
    }

    private func summaryItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.seriesClay)
            Text(text).font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.inkSoft).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var busyCount: Int {
        store.live.values.filter { $0.phase == 0 && !$0.name.hasPrefix("my-claude-code") }.count
    }

    /// Green while a session is open, grey otherwise.
    private var statusPill: some View {
        let on = activeCount > 0
        let label = busyCount > 0 ? "\(busyCount) en cours" : on ? "en session" : "au repos"
        return HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Theme.inkFaint).frame(width: 7, height: 7)
            Text(label).font(Theme.sans(11.5, .semibold)).foregroundStyle(on ? Color.green : Theme.inkSoft)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill((on ? Color.green : Theme.inkFaint).opacity(0.12)))
        .fixedSize()
    }

    private var activeCount: Int {
        store.live.values.filter { !$0.name.hasPrefix("my-claude-code") }.count
    }

    private var planLine: String {
        var parts: [String] = []
        parts.append(store.account.plan ?? "Offre inconnue")
        if let limits = store.account.limits { parts.append(limits) }
        if store.account.extraUsage { parts.append("usage supplémentaire") }
        return parts.joined(separator: " · ")
    }

    private var setupLine: String {
        let c = store.claude
        var parts: [String] = ["Claude Code " + (c.version ?? "—")]
        if let m = c.model { parts.append(m) }
        if let e = c.effort { parts.append("effort " + ContextBlock.effort(e)) }
        return parts.joined(separator: " · ")
    }

    private var sessionsLine: String {
        let bg = store.live.values.filter { $0.kind == "background" }.count
        var parts = ["\(activeCount) session\(activeCount > 1 ? "s" : "") ouverte\(activeCount > 1 ? "s" : "")"]
        if bg > 0 { parts.append("\(bg) en arrière-plan") }
        parts.append("\(store.snapshot.sessions.count) au total")
        return parts.joined(separator: " · ")
    }

    private func infoLine(_ symbol: String, _ text: String, tint: Color = Theme.inkFaint, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: small ? 6.5 : 10.5, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 14)
            Text(text).font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.tail)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 18) {
            ForEach(Tab.allCases) { t in
                Button { withAnimation(.snappy(duration: 0.25)) { tab = t; if t != .sessions { selectedSession = nil } } } label: {
                    VStack(spacing: 6) {
                        Text(t.title).font(Theme.sans(13, tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? Theme.ink : Theme.inkSoft)
                        ZStack {
                            Rectangle().fill(Color.clear).frame(height: 2)
                            if tab == t {
                                Rectangle().fill(Theme.clay).frame(height: 2).matchedGeometryEffect(id: "underline", in: ns)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 0.5) }
    }

    private var footer: some View {
        HStack {
            RefreshStamp()
            Spacer()
            Button { PanelController.shared.closePanel(); NSApp.terminate(nil) } label: {
                Text("quitter").font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 0.5) }
    }
}

/// Banner shown when a send finishes: result, recipient, duration.
struct SendBanner: View {
    let job: SendJob
    let dismiss: () -> Void

    var body: some View {
        TimelineView(.whileShown(0.5)) { _ in
            let tint: Color = job.isRunning ? Theme.clay : job.succeeded ? .green : .red
            HStack(spacing: 10) {
                Group {
                    if job.isRunning { ProgressView().controlSize(.small) }
                    else { Image(systemName: job.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").font(.system(size: 16)).foregroundStyle(tint) }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.isRunning ? job.stepLabel : job.summary).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("\(job.isRunning ? "à \(job.recipient) · " : "")« \(job.prompt.prefix(60))\(job.prompt.count > 60 ? "…" : "") »")
                        .font(Theme.sans(11)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                Spacer()
                Text("\(Int(job.duration)) s").font(Theme.sans(11.5).monospacedDigit()).foregroundStyle(Theme.inkSoft)
                if !job.isRunning {
                    Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.inkFaint) }
                        .buttonStyle(.plain)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        }
    }
}

/// Lets the user move the floating window by dragging the area it covers.
struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        // Floating windows are rarely key: take the very first click, or it would be swallowed.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Exact time of the last refresh, to the second: quotas (/usage or status line) and sessions (transcripts).
/// A green dot flashes on each update.
struct RefreshStamp: View {
    @Environment(UsageStore.self) private var store
    @State private var flash = false

    var body: some View {
        let quotas = store.plan?.updatedAt
        let sessions = store.lastUpdate
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6).opacity(flash ? 1 : 0.35)
            Group {
                if let quotas {
                    Text("Quotas ") + Text(Fmt.stamp(quotas)).fontWeight(.semibold)
                        + Text("  ·  Sessions ") + Text(Fmt.stampTime(sessions)).fontWeight(.semibold)
                } else {
                    Text("Sessions ") + Text(Fmt.stamp(sessions)).fontWeight(.semibold)
                }
            }
            .font(Theme.sans(10.5).monospacedDigit())
            .foregroundStyle(Theme.inkSoft)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .tip([quotas.map { "Quotas (/usage ou ligne d'état) : \(Fmt.stamp($0))" },
              "Sessions (journaux de Claude Code) : \(Fmt.stamp(sessions))"].compactMap { $0 }.joined(separator: "\n"))
        .onChange(of: quotas) { _, _ in pulse() }
        .onChange(of: sessions) { _, _ in pulse() }
    }

    private func pulse() {
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        withAnimation(.easeIn(duration: 0.8).delay(0.4)) { flash = false }
    }
}
