import AppKit
import SwiftUI

/// Small floating windows ("picture in picture"), independent from the menu bar panel: the quotas, or one session
/// followed live. Above everything on every Space (full-screen apps included), moved by their title bar,
/// reopened at launch where the user left them.
@MainActor
@Observable
final class MiniWindows {
    static let shared = MiniWindows()

    enum Kind: Hashable {
        case quotas
        case notifications
        case quick
        case session(String)

        var key: String {
            switch self {
            case .quotas: "quotas"
            case .notifications: "notifications"
            case .quick: "quick"
            case .session(let id): "session:" + id
            }
        }
        init?(key: String) {
            if key == "quotas" { self = .quotas }
            else if key == "quick" { self = .quick }
            else if key == "notifications" { self = .notifications }
            else if key.hasPrefix("session:") { self = .session(String(key.dropFirst(8))) }
            else { return nil }
        }
        var size: NSSize {
            switch self {
            case .quotas: NSSize(width: 400, height: 330)
            case .notifications: NSSize(width: 380, height: 520)
            case .quick: NSSize(width: 400, height: 560)
            case .session: NSSize(width: 460, height: 620)
            }
        }
    }

    private(set) var openKeys: [String] = []
    @ObservationIgnored private var windows: [String: NSPanel] = [:]

    func isOpen(_ kind: Kind) -> Bool { openKeys.contains(kind.key) }

    func toggle(_ kind: Kind) { isOpen(kind) ? close(kind) : open(kind) }

    func open(_ kind: Kind) {
        let key = kind.key
        if let w = windows[key] { w.orderFrontRegardless(); return }
        // A real titled window with an invisible title bar: macOS then provides edge/corner resizing with the
        // native resize cursors and rounded corners (a borderless window gets neither).
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: kind.size),
                                  styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.isFloatingPanel = true
        // One level above the menu bar panel (after isFloatingPanel, which resets the level): when the panel is
        // open over the same corner, floating windows stay on top, clickable and movable.
        panel.level = NSWindow.Level(rawValue: PanelController.panelLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // The quotas card needs its full width (ring + weekly rows); the others can shrink a little.
        panel.minSize = NSSize(width: kind == .quotas ? kind.size.width : 320, height: { if case .session = kind { return 480 } else { return 200 } }())
        let effect = PanelBackground(frame: NSRect(origin: .zero, size: kind.size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let hosting = NSHostingView(rootView: MiniWindowView(kind: kind).environment(UsageStore.shared))
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect
        var frame = savedFrame(key) ?? defaultFrame(kind)
        if frame.width < panel.minSize.width { frame.size.width = panel.minSize.width }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !CommandLine.arguments.contains("--snapshot") { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "mini.frame." + key) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !CommandLine.arguments.contains("--snapshot") { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "mini.frame." + key) }
            }
        }
        windows[key] = panel
        if !openKeys.contains(key) { openKeys.append(key) }
        persist()
    }

    func close(_ kind: Kind) {
        let key = kind.key
        windows[key]?.orderOut(nil)
        windows[key] = nil
        openKeys.removeAll { $0 == key }
        persist()
    }

    /// "↩": back into the app (panel opened on that element), and the mini window goes away.
    func reattach(_ kind: Kind) {
        close(kind)
        PanelController.shared.openPanel()
        switch kind {
        case .quotas, .quick, .notifications:
            NotificationCenter.default.post(name: .selectTab, object: Tab.overview.rawValue)
        case .session(let id):
            if let s = UsageStore.shared.snapshot.sessions.first(where: { $0.info.id == id }) {
                NotificationCenter.default.post(name: .openSession, object: s.index)
            }
        }
    }

    /// Reopens the mini windows that were open when the app quit.
    func restore() {
        for key in UserDefaults.standard.stringArray(forKey: "mini.open") ?? [] {
            if let kind = Kind(key: key) { open(kind) }
        }
    }

    /// Debug: renders every open mini window to `<prefix>-<key>.png`.
    func capture(prefix: String) {
        for (key, w) in windows {
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = key.replacingOccurrences(of: ":", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
    }

    /// Test captures (--snapshot) never touch the user's saved windows.
    private var isSnapshot: Bool { CommandLine.arguments.contains("--snapshot") }

    private func persist() { if !isSnapshot { UserDefaults.standard.set(openKeys, forKey: "mini.open") } }

    private func savedFrame(_ key: String) -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: "mini.frame." + key) else { return nil }
        let r = NSRectFromString(raw)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(r) } && r.width >= 200 ? r : nil
    }

    /// Top-right corner of the main screen, cascading below the windows already open.
    private func defaultFrame(_ kind: Kind) -> NSRect {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let below = windows.values.map(\.frame.minY).min() ?? screen.maxY
        var y = min(below, screen.maxY) - kind.size.height - 14
        if y < screen.minY + 10 { y = screen.maxY - kind.size.height - 14 }
        return NSRect(x: screen.maxX - kind.size.width - 16, y: y, width: kind.size.width, height: kind.size.height)
    }
}

/// Content of a mini window: a title bar (drag to move, ↩ back to the app, ✕ close) over the element.
@MainActor
struct MiniWindowView: View {
    @Environment(UsageStore.self) private var store
    let kind: MiniWindows.Kind

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Group {
                switch kind {
                case .quotas:
                    ScrollView { LimitsContent().padding(16) }.scrollIndicators(.never)
                case .notifications:
                    NotificationCenterView(close: { MiniWindows.shared.close(.notifications) }, floating: true)
                case .quick:
                    QuickView(dictate: .constant(false), close: { MiniWindows.shared.close(.quick) }, floating: true)
                case .session(let id):
                    SessionFollowView(sessionID: id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .background(Theme.paper.opacity(0.92))
    }

    /// Drag anywhere on the bar to move the window (titles let clicks through); Fermer on the right.
    private var titleBar: some View {
        ZStack {
            WindowDragHandle()
            HStack(spacing: 7) {
                titleContent.allowsHitTesting(false)
                Spacer(minLength: 4).allowsHitTesting(false)
                chromeButton("xmark", tip: "Fermer la fenêtre flottante") { MiniWindows.shared.close(kind) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 0.5) }
    }

    @ViewBuilder
    private var titleContent: some View {
        HStack(spacing: 7) {
            switch kind {
            case .quotas:
                Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.clay)
                Text("Quotas").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
            case .notifications:
                Image(systemName: "bell.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.clay)
                Text("Notifications").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
            case .quick:
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.clay)
                Text("Commande rapide").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
            case .session(let id):
                let live = store.live[id]
                Circle().fill(live.map { PhaseBadge.color($0.phase) } ?? Color.gray).frame(width: 8, height: 8)
                Text(store.snapshot.sessions.first { $0.info.id == id }?.name ?? "Session")
                    .font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(live?.label ?? "fermée").font(Theme.sans(11)).foregroundStyle(Theme.inkFaint).lineLimit(1)
            }
        }
    }

    private func chromeButton(_ symbol: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.inkSoft)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.rule.opacity(0.7)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip(tip)
    }
}

/// A detached session: a one-line summary, its context (with Compacter), the live mirror of its iTerm tab,
/// and a field to write to it.
@MainActor
struct SessionFollowView: View {
    @Environment(UsageStore.self) private var store
    let sessionID: String

    var body: some View {
        let session = store.snapshot.sessions.first { $0.info.id == sessionID }
        let live = store.live[sessionID]
        VStack(alignment: .leading, spacing: 12) {
            if let session {
                let ctx = store.context(of: session)
                Text([Fmt.model(session.lastModel), "\(session.totals.messages) réponses", Fmt.usd(session.totals.cost.total),
                      Fmt.duration(session.duration)].joined(separator: "  ·  "))
                    .font(Theme.sans(11)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                HStack(spacing: 10) {
                    Text("Contexte").font(Theme.sans(11, .medium)).foregroundStyle(Theme.inkSoft)
                    Bar(fraction: ctx.fraction, color: contextColor(ctx.fraction), height: 5)
                    Text("\(Int((ctx.fraction * 100).rounded())) %").font(Theme.sans(12, .semibold).monospacedDigit())
                        .foregroundStyle(ctx.fraction >= 0.8 ? contextColor(ctx.fraction) : Theme.ink)
                        .fixedSize()
                    if let live { CompactButton(session: session, live: live, compact: true).fixedSize() }
                }
                // Terminal and agent-to-agent messages: two foldable cards, opening one folds the other.
                VStack(spacing: 0) {
                    Block(title: "Terminal", note: live?.pid != nil ? "clic pour taper" : "journal") {
                        TerminalMirrorView(session: session, live: live, fill: true)
                            .frame(minHeight: 110, maxHeight: .infinity)
                    }
                    ChatPanel(session: session, listHeight: 260)
                }
                .environment(\.blockFold, "mini")
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Text("Session introuvable.").font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(14)
    }

}

