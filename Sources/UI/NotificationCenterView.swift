import SwiftUI

/// The app's notification center (session finished, waiting for you, context nearly full, quota at risk, evening
/// summary). A surface of its own, opened from the bell in the header, or detached as a floating window.
/// Grouped by day; click a notification (or its action) to act on it, which clears it; swipe left or ✕ to clear one.
@MainActor
struct NotificationCenterView: View {
    let close: () -> Void
    var floating = false
    private var center: AttentionCenter { AttentionCenter.shared }

    private var groups: [(title: String, items: [AttentionItem])] {
        let cal = Calendar.current
        let today = center.items.filter { cal.isDateInToday($0.date) }
        let yesterday = center.items.filter { cal.isDateInYesterday($0.date) }
        let older = center.items.filter { !cal.isDateInToday($0.date) && !cal.isDateInYesterday($0.date) }
        return [("Aujourd'hui", today), ("Hier", yesterday), ("Plus tôt", older)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if center.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bell.slash").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.inkFaint)
                    Text("Aucune notification").font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink)
                    Text("Fins de session, réponses attendues, contexte bientôt plein, quotas menacés et bilan du soir arrivent ici.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.inkFaint).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 260)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Text(group.title.uppercased()).font(Theme.sans(10.5, .bold)).tracking(0.6).foregroundStyle(Theme.inkFaint)
                            .padding(.top, 6)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        ForEach(group.items) { item in
                            NotificationRow(item: item)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { withAnimation(.snappy) { center.dismiss(item) } } label: {
                                        Label("Effacer", systemImage: "xmark")
                                    }
                                }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !floating {
                Text("Notifications").font(Theme.sans(15, .bold)).foregroundStyle(Theme.ink).fixedSize()
            }
            if !center.items.isEmpty {
                Text("\(center.items.count)").font(Theme.sans(10.5, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1.5).background(Capsule().fill(Theme.clay)).fixedSize()
            }
            Spacer(minLength: 6)
            if !center.items.isEmpty {
                iconButton("checkmark.circle", tip: "Tout effacer") { withAnimation(.snappy) { center.clearAll() } }
            }
            if !floating {
                let detached = MiniWindows.shared.isOpen(.notifications)
                DetachButton(detached: detached) {
                    if detached { MiniWindows.shared.close(.notifications) } else { MiniWindows.shared.open(.notifications); close() }
                }
                .tip(detached ? "Détaché · cliquer pour fermer la fenêtre flottante" : "Détacher en fenêtre flottante")
                iconButton("xmark", tip: "Fermer", action: close)
            }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, floating ? 8 : 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 0.5) }
    }

    private func iconButton(_ symbol: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.inkSoft)
                .frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip(tip)
    }
}

/// One notification, macOS style: icon tile, title, text, time; its action; ✕ on hover.
@MainActor
struct NotificationRow: View {
    @Environment(UsageStore.self) private var store
    let item: AttentionItem
    @State private var hovering = false
    private var center: AttentionCenter { AttentionCenter.shared }

    private var session: SessionStat? { item.sessionID.flatMap { id in store.snapshot.sessions.first { $0.info.id == id } } }

    var body: some View {
        let (symbol, color) = style
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(time).font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint).lineLimit(1).fixedSize()
                }
                Text(item.detail).font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft)
                    .lineLimit(item.kind == .digest ? 5 : 2).fixedSize(horizontal: false, vertical: true)
                if let action = actionTitle {
                    Button(action: act) {
                        HStack(spacing: 3) {
                            Text(action)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(Theme.sans(11, .semibold)).foregroundStyle(Theme.clayDeep).fixedSize()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.raised : Theme.raised.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            if hovering {
                Button { withAnimation(.snappy) { center.dismiss(item) } } label: {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(Theme.inkSoft)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.raised).shadow(color: .black.opacity(0.15), radius: 2, y: 1))
                        .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .tip("Effacer")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if session != nil { open() } }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu { Button("Effacer") { center.dismiss(item) } }
    }

    private var time: String {
        Calendar.current.isDateInToday(item.date) ? Fmt.time(item.date) : OverviewView.ago(item.date)
    }

    private var style: (String, Color) {
        switch item.kind {
        case .waiting: ("hand.raised.fill", .orange)
        case .finished: ("checkmark", .green)
        case .context: ("rectangle.compress.vertical", .orange)
        case .quota: ("chart.line.downtrend.xyaxis", .red)
        case .digest: ("moon.stars.fill", .indigo)
        }
    }

    private var actionTitle: String? {
        guard session != nil else { return nil }
        return item.kind == .context ? "Compacter" : "Ouvrir la session"
    }

    private func act() { item.kind == .context ? compact() : open() }

    /// Opens the session's sheet (showing the panel if needed) and clears the notification.
    private func open() {
        guard let session else { return }
        withAnimation(.snappy) { center.dismiss(item) }
        if !PanelController.shared.isOpen { PanelController.shared.openPanel() }
        NotificationCenter.default.post(name: .closeOverlays, object: nil)
        NotificationCenter.default.post(name: .openSession, object: session.index)
    }

    private func compact() {
        guard let session, let live = store.live[session.info.id] else { return }
        Compactor.shared.compact(session, live: live)
        withAnimation(.snappy) { center.dismiss(item) }
    }
}
