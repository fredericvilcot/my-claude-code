import AppKit
import QuartzCore
import CoreGraphics
import SwiftUI

/// Status item + floating panel anchored below it: full screen height, above every window,
/// closed by the icon, Escape or any click outside.
final class PanelController: NSObject, NSMenuDelegate {
    /// Same level as system menus (Wi-Fi…): above iTerm's floating hotkey window (level 22).
    static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    static let shared = PanelController()

    private var item: NSStatusItem?
    private var panel: FloatingPanel?
    private var outsideClickMonitor: Any?

    /// The panel is never ordered out: it stays rendered and up to date, just transparent and click-through,
    /// so opening it is instantaneous.
    var isOpen: Bool { (panel?.alphaValue ?? 0) > 0 }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        UsageStore.shared.onUpdate = { [weak self] in self?.refreshButton() }
        refreshButton()
        DispatchQueue.main.async {
            _ = self.fullScreenMenu
            // Pre-render the panel once, invisible, so the first opening is instant too.
            let panel = self.makePanel()
            self.panel = panel
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            self.position(panel)
            panel.orderFrontRegardless()
        }
        observeSystem()
    }

    /// Opens the panel on "⚡ Rapide", taking the keyboard so ↩ and typing work at once.
    func openQuick(dictate: Bool) {
        if !isOpen { openPanel() }
        panel?.makeKey()
        NotificationCenter.default.post(name: .openQuick, object: dictate)
    }

    /// Detached ("picture in picture"): the panel becomes a movable floating window, above everything on every
    /// Space (full-screen apps included), never closed by outside clicks, Escape or screen lock; the same button
    /// re-attaches it under the menu bar. Stored in defaults so the SwiftUI header follows it.
    var detached: Bool {
        get { UserDefaults.standard.bool(forKey: "panelDetached") }
        set { UserDefaults.standard.set(newValue, forKey: "panelDetached") }
    }

    func setDetached(_ on: Bool) {
        if on {
            if !isOpen {   // from the full-screen menu: swap the menu for the floating panel
                fullScreenMenu.cancelTracking()
                openPanel()
            }
            detached = true
            guard let panel else { return }
            panel.isMovable = true   // dragged by its header only (WindowDragHandle), never by widgets
            let target = savedDetachedFrame(for: panel) ?? defaultDetachedFrame(for: panel)
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.25
                c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            reattach(animated: true)
        }
    }

    private func reattach(animated: Bool) {
        guard let panel else { detached = false; return }
        if detached { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "detachedFrame") }
        detached = false
        panel.isMovable = false
        if animated, let target = attachedFrame() {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.25
                c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            position(panel)
        }
    }

    /// Last place the user left the floating window, if it is still on a screen.
    private func savedDetachedFrame(for panel: NSPanel) -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: "detachedFrame") else { return nil }
        let r = NSRectFromString(raw)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(r) } && r.width > 100 ? r : nil
    }

    /// First detach: a bit lower and to the left of the menu bar spot, shorter, so it visibly floats.
    private func defaultDetachedFrame(for panel: NSPanel) -> NSRect {
        var f = panel.frame
        let height = min(f.height, 620)
        f.origin.y += f.height - height - 40
        f.size.height = height
        f.origin.x -= 60
        return f
    }

    /// The ✕ of the floating window: re-attach (silently) and close.
    func closeFromButton() {
        reattach(animated: false)
        closePanel()
    }

    @objc func toggle() {
        if isOpen, detached { panel?.orderFrontRegardless(); return }   // floating: its own buttons close/re-attach it
        if isOpen { closePanel(); return }
        if menuBarAutoHides { openAsMenu(byClick: true) } else { openPanel(byClick: true) }
    }

    /// True when the active Space is a full-screen one (macOS Space type 4) or the menu bar hides automatically:
    /// only a real menu keeps the menu bar visible there.
    private var menuBarAutoHides: Bool {
        if let screen = item?.button?.window?.screen ?? NSScreen.main, screen.visibleFrame.maxY >= screen.frame.maxY - 1 { return true }
        return Self.activeSpaceIsFullScreen
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    /// Reads the type of the current Space on the display that shows the menu bar (read-only SkyLight query).
    static var activeSpaceIsFullScreen: Bool {
        guard let mainPtr = dlsym(skyLight, "SLSMainConnectionID"), let copyPtr = dlsym(skyLight, "SLSCopyManagedDisplaySpaces") else { return false }
        let connection = unsafeBitCast(mainPtr, to: MainConnection.self)()
        guard let displays = unsafeBitCast(copyPtr, to: CopyManagedSpaces.self)(connection)?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mainID = NSScreen.screens.first.flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
            .flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            .flatMap { CFUUIDCreateString(nil, $0) as String? }
        let display = displays.first { ($0["Display Identifier"] as? String) == mainID || ($0["Display Identifier"] as? String) == "Main" } ?? displays.first
        return ((display?["Current Space"] as? [String: Any])?["type"] as? Int) == 4
    }

    static func debug(_ line: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("My Claude Code")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug.log")
        let text = "\(Date()) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Shows the dashboard inside a native menu, like Wi-Fi or Bluetooth.
    /// Native menu used in full screen (keeps the menu bar visible). It first shows an exact picture of the
    /// always-rendered panel, so it appears instantly, then swaps in the live dashboard right after.
    private let menuContainer = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
    private var liveMenuDashboard: NSView?

    private lazy var fullScreenMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        let entry = NSMenuItem()
        entry.view = menuContainer
        menu.addItem(entry)
        return menu
    }()

    private var menuTiming: (click: TimeInterval?, start: TimeInterval, reset: TimeInterval, picture: TimeInterval)?

    func openAsMenu(byClick: Bool = false) {
        let start = ProcessInfo.processInfo.systemUptime
        let click = byClick ? NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? start - $0.timestamp : nil } : nil
        resetIfStale()
        let afterReset = ProcessInfo.processInfo.systemUptime
        guard let item else { return }
        let size = NSSize(width: 400, height: min((NSScreen.main?.frame.height ?? 900) - 60, 900))
        menuContainer.frame = NSRect(origin: .zero, size: size)
        // One live dashboard, kept inside the menu between openings: it shows at once with its last state and
        // updates in place (no snapshot of the panel, no rebuild).
        let live = liveMenuDashboard ?? {
            let hosting = NSHostingView(rootView: AnyView(DashboardView().environment(UsageStore.shared)))
            hosting.sizingOptions = []
            return hosting
        }()
        liveMenuDashboard = live
        if live.superview !== menuContainer {
            menuContainer.subviews.forEach { $0.removeFromSuperview() }
            menuContainer.addSubview(live)
        }
        live.frame = menuContainer.bounds
        menuTiming = (click, start, afterReset - start, ProcessInfo.processInfo.systemUptime - afterReset)
        item.menu = fullScreenMenu
        item.button?.performClick(nil)
    }

    /// Test helper: opens the full-screen menu, measures how long the main thread stays blocked, then closes it.
    func benchMenu() {
        let start = Date()
        var first: TimeInterval?
        let probe = Timer(timeInterval: 0.005, repeats: true) { t in
            if first == nil { first = Date().timeIntervalSince(start) }
        }
        RunLoop.main.add(probe, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            FileHandle.standardError.write(String(format: "menu : thread principal libre après %.0f ms\n", (first ?? 3) * 1000).data(using: .utf8)!)
            probe.invalidate()
            self.fullScreenMenu.cancelTracking()
        }
        let timer = Timer(timeInterval: 3.2, repeats: false) { _ in self.fullScreenMenu.cancelTracking() }
        RunLoop.main.add(timer, forMode: .common)
        openAsMenu()
        // Same measure for the floating panel.
        let p0 = Date()
        var pFirst: TimeInterval?
        let pProbe = Timer(timeInterval: 0.005, repeats: true) { _ in if pFirst == nil { pFirst = Date().timeIntervalSince(p0) } }
        RunLoop.main.add(pProbe, forMode: .common)
        openPanel()
        closePanel()
        let p1 = Date(); var reopen: TimeInterval?
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let probe2 = Timer(timeInterval: 0.002, repeats: true) { _ in if reopen == nil { reopen = Date().timeIntervalSince(p1) } }
            RunLoop.main.add(probe2, forMode: .common)
            _ = p1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let t0 = Date()
            self.openPanel()
            let t1 = Date()
            DispatchQueue.main.async {
                FileHandle.standardError.write(String(format: "réouverture panneau : %.0f ms\n", Date().timeIntervalSince(t0) * 1000).data(using: .utf8)!)
                _ = t1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            FileHandle.standardError.write(String(format: "panneau : thread principal libre après %.0f ms\n", (pFirst ?? 2) * 1000).data(using: .utf8)!)
            exit(0)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        AppActivity.shared.set(menu: true)
        guard let t = menuTiming else { return }
        let now = ProcessInfo.processInfo.systemUptime
        Self.debug(String(format: "menu : clic→code %@ · remise à zéro %.0f ms · préparation %.0f ms · ouverture %.0f ms",
                          t.click.map { String(format: "%.0f ms", $0 * 1000) } ?? "—", t.reset * 1000, t.picture * 1000,
                          (now - t.start - t.reset - t.picture) * 1000))
    }

    func menuDidClose(_ menu: NSMenu) {
        AppActivity.shared.set(menu: false)
        // Back to the floating panel for the next click outside full screen.
        DispatchQueue.main.async { self.item?.menu = nil }
        lastClosed = Date()
        scheduleReset()
    }

    /// Reopened within 2 minutes (e.g. after an accidental click outside): keep the tab, session and draft.
    /// Later: back to the overview.
    private var lastClosed = Date.distantPast
    /// Back to the overview after two minutes closed. Done while the panel is hidden (timer at close time), so it
    /// never opens on its previous screen and then jumps; the check at opening only covers a missed timer (sleep).
    private var resetWork: DispatchWorkItem?
    private func resetIfStale() {
        resetWork?.cancel(); resetWork = nil
        if Date().timeIntervalSince(lastClosed) > 120 {
            NotificationCenter.default.post(name: .panelReset, object: nil)
            panel?.contentView?.layoutSubtreeIfNeeded()
        }
    }
    private func scheduleReset() {
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isOpen else { return }
            NotificationCenter.default.post(name: .panelReset, object: nil)
            self.lastClosed = .distantFuture   // already reset: nothing to do at the next opening
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    func openPanel(byClick: Bool = false) {
        // Timing of each step, written to debug.log: click received → here, reset, on screen, first frame drawn.
        // Only a real click on the icon has a meaningful event time (automatic openings keep an older event).
        let now = ProcessInfo.processInfo.systemUptime
        let clickEvent = byClick ? NSApp.currentEvent.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0 : nil } : nil
        let clickDelay = clickEvent.map { now - $0.timestamp }
        resetIfStale()
        let afterReset = ProcessInfo.processInfo.systemUptime
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if detached {
            // A floating window keeps the place the user gave it (or gets a sensible one on first creation).
            panel.isMovable = true
            if let saved = savedDetachedFrame(for: panel) { panel.setFrame(saved, display: true) }
            else { position(panel); panel.setFrame(defaultDetachedFrame(for: panel), display: true) }
        } else {
            position(panel)
        }
        panel.level = Self.panelLevel
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        // Short fade-in like native menus: hides the translucent background being recomputed.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        panel.invalidateShadow()
        let shown = ProcessInfo.processInfo.systemUptime
        CATransaction.setCompletionBlock {
            let drawn = ProcessInfo.processInfo.systemUptime
            Self.debug(String(format: "panneau (%@) : clic→code %@ · remise à zéro %.0f ms · affichage %.0f ms · premier rendu %.0f ms",
                              byClick ? "clic" : "auto", clickDelay.map { String(format: "%.0f ms", $0 * 1000) } ?? "—",
                              (afterReset - now) * 1000, (shown - afterReset) * 1000, (drawn - shown) * 1000))
        }
        item?.button?.highlight(true)
        UsageStore.shared.pollUsage()   // always show fresh /usage figures when opening
        AppActivity.shared.set(panel: true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, !self.detached else { return }
            self.closePanel()
        }
    }

    func lowerForSystemDialog() { panel?.level = .normal }
    func restoreAfterSystemDialog() { if isOpen { panel?.level = Self.panelLevel; panel?.orderFrontRegardless() } }

    func closePanel() {
        if detached { reattach(animated: false) }
        MainActor.assumeIsolated { Tooltip.shared.hide() }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        panel?.alphaValue = 0
        panel?.ignoresMouseEvents = true
        // An invisible panel must never keep the keyboard: give the focus back to the previous app.
        if let panel, panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        item?.button?.highlight(false)
        AppActivity.shared.set(panel: false)
        lastClosed = Date()
        scheduleReset()
        // On a full-screen Space an invisible window left under the menu bar keeps the app's title bar revealed
        // (white strip over Webex): really take it off screen there.
        if menuBarAutoHides { panel?.orderOut(nil) }
    }

    private func makePanel() -> FloatingPanel {
        let hosting = NSHostingView(rootView: DashboardView().environment(UsageStore.shared))
        let size = NSSize(width: 400, height: 700)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                                  backing: .buffered, defer: false)
        panel.onEscape = { [weak self] in if self?.detached == false { self?.closePanel() } }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // Like system menus: never steal keyboard focus on open (keeps iTerm's hotkey window visible).
        panel.becomesKeyOnlyIfNeeded = true
        // Must come after isFloatingPanel, which silently resets the level to .floating (3).
        panel.level = Self.panelLevel
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let effect = PanelBackground(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.refreshBorder()
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect
        return panel
    }

    private func position(_ panel: NSPanel) {
        if let frame = attachedFrame() { panel.setFrame(frame, display: true) }
    }

    /// Where the panel sits when attached: under the menu bar icon, full height.
    private func attachedFrame() -> NSRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? window.screen ?? NSScreen.main
        guard let frame = screen?.frame, let visible = screen?.visibleFrame else { return nil }
        let width: CGFloat = 400
        let top = min(anchor.minY, visible.maxY) - 6
        let height = max(300, top - visible.minY - 8)
        let x = min(max(anchor.midX - width / 2, frame.minX + 8), frame.maxX - width - 8)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    /// Close on lock, sleep or session switch; follow screen changes while open.
    private func observeSystem() {
        let close: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { if self?.detached == false { self?.closePanel() } }   // the floating window stays
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: close)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main, using: close)
        }
        // Entering a full-screen Space with the panel closed: take the invisible panel off screen (see closePanel).
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.isOpen else { return }
            if self.menuBarAutoHides { self.panel?.orderOut(nil) }
        }
        // When another app (e.g. iTerm's hotkey window) comes forward, bring the open panel back on top.
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let panel = self.panel, self.isOpen else { return }
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if self.isOpen { panel.orderFrontRegardless() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let panel = self.panel, self.isOpen, !self.detached else { return }
            self.position(panel)
        }
    }

    /// Debug helper: renders the panel content to a PNG.
    func capture(to path: String) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Appends the number of notifications, in a small clay badge (white figures), to the menu bar image.
    /// A template image keeps following the menu bar's light/dark appearance (tinted with the label colour).
    static func withCount(_ image: NSImage, _ count: Int) -> NSImage {
        let text = count > 99 ? "99+" : "\(count)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let textSize = label.size()
        let badge = NSSize(width: max(15, ceil(textSize.width) + 9), height: 15)
        let gap: CGFloat = 4
        let size = NSSize(width: image.size.width + gap + badge.width, height: max(image.size.height, badge.height))
        let out = NSImage(size: size, flipped: false) { _ in
            let imageRect = NSRect(x: 0, y: (size.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            if image.isTemplate {
                NSGraphicsContext.saveGraphicsState()
                image.draw(in: imageRect)
                NSColor.labelColor.set()
                imageRect.fill(using: .sourceAtop)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                image.draw(in: imageRect)
            }
            let rect = NSRect(x: image.size.width + gap, y: (size.height - badge.height) / 2, width: badge.width, height: badge.height)
            NSColor(red: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
            // Centre the figures on their drawn shape (glyph bounds), not on the font's line box, which sits them low.
            if let ctx = NSGraphicsContext.current?.cgContext {
                let line = CTLineCreateWithAttributedString(label)
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                ctx.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
                CTLineDraw(line, ctx)
            }
            return true
        }
        out.isTemplate = false
        return out
    }

    func refreshButton() {
        guard let button = item?.button else { return }
        let snap = UsageStore.shared.snapshot
        let plan = UsageStore.shared.plan
        let threshold = LimitAlerts.threshold
        // Two choices: plan limits (default) or today's cost; older values fall back to limits.
        let style = UserDefaults.standard.string(forKey: "menuBarStyle") == "today" ? "today" : "both"
        let session = plan?.session?.usedPercent ?? (plan != nil ? 0 : nil)   // no open window yet = 0 %
        let week = plan?.week?.usedPercent

        switch style {
        case "both", "session":
            button.image = MenuBarLabel.render(session: session, week: style == "both" ? (week ?? -1) : nil,
                                               threshold: threshold, active: snap.current != nil)
            button.attributedTitle = NSAttributedString(string: "")
        default:
            button.image = SparkIcon.starburst(active: snap.current != nil)
            var text = ""
            if style == "today" { text = " " + Fmt.usd(snap.today.cost.total) }
            let over = (plan?.all ?? []).contains { $0.usedPercent >= threshold }
            var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), .baselineOffset: 0.5]
            if over { attrs[.foregroundColor] = NSColor.systemRed }
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        }
        let pending = MainActor.assumeIsolated { AttentionCenter.shared.items.count }
        if pending > 0, let image = button.image { button.image = Self.withCount(image, pending) }
        button.toolTip = (pending > 0 ? "\(pending) élément\(pending > 1 ? "s" : "") à traiter · " : "") + "My Claude Code — session \(session.map { "\(Int($0)) %" } ?? "—") · semaine \(week.map { "\(Int($0)) %" } ?? "—") · aujourd'hui \(Fmt.usd(snap.today.cost.total))"
    }
}

/// Menu bar label drawn as one image: spark + session %, thin separator, calendar + week %.
enum MenuBarLabel {
    static func render(session: Double?, week: Double?, threshold: Double, active: Bool) -> NSImage {
        let sessionOver = (session ?? 0) >= threshold
        let weekOver = (week ?? 0) >= threshold
        let colored = active || sessionOver || weekOver
        let ink: NSColor = colored ? .labelColor : .black
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        func text(_ v: Double?, over: Bool) -> NSAttributedString {
            NSAttributedString(string: v.map { $0 < 0 ? "— %" : "\(Int($0.rounded())) %" } ?? "— %",
                               attributes: [.font: font, .foregroundColor: over ? NSColor.systemRed : ink])
        }
        let sessionText = text(session, over: sessionOver)
        let weekText = week.map { text($0, over: weekOver) }
        let calendar: NSImage? = week == nil ? nil : {
            var config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            config = config.applying(.init(paletteColors: [weekOver ? .systemRed : ink]))
            return NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }()

        let spark: CGFloat = 16, gap: CGFloat = 4, groupGap: CGFloat = 7, height: CGFloat = 18
        var width = spark + gap + ceil(sessionText.size().width)
        if let weekText, let calendar { width += groupGap * 2 + 1 + calendar.size.width + 3 + ceil(weekText.size().width) }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let sparkRect = CGRect(x: 0, y: (rect.height - spark) / 2, width: spark, height: spark)
            ctx.addPath(SparkGeometry.path(in: sparkRect))
            let sparkColor: NSColor = sessionOver ? .systemRed : (active ? NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1) : ink)
            ctx.setFillColor(sparkColor.cgColor)
            ctx.fillPath()
            var x = spark + gap
            sessionText.draw(at: NSPoint(x: x, y: (rect.height - sessionText.size().height) / 2))
            x += ceil(sessionText.size().width)
            if let weekText, let calendar {
                x += groupGap
                ink.withAlphaComponent(0.35).setFill()
                NSRect(x: x, y: 4, width: 1, height: rect.height - 8).fill()
                x += 1 + groupGap
                calendar.draw(in: NSRect(x: x, y: (rect.height - calendar.size.height) / 2, width: calendar.size.width, height: calendar.size.height))
                x += calendar.size.width + 3
                weekText.draw(at: NSPoint(x: x, y: (rect.height - weekText.size().height) / 2))
            }
            return true
        }
        image.isTemplate = !colored
        return image
    }
}

final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    // MARK: Move from anywhere
    //
    // A movable panel (floating window) is dragged from any spot that isn't interactive: a click still clicks, but a
    // drag that starts on background, text or a card moves the window. Excluded: text fields, terminals, and areas
    // marked `.noWindowDrag()` (widget reorder handles, terminal mirror…).
    private var pendingDown: NSEvent?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pendingDown = isMovable && canMoveWindow(at: event) ? event : nil
        case .leftMouseDragged:
            if let down = pendingDown {
                let a = down.locationInWindow, b = event.locationInWindow
                if hypot(b.x - a.x, b.y - a.y) > 3 {
                    pendingDown = nil
                    performDrag(with: down)
                    // The drag loop ate the mouse-up: release whatever the press started, away from any control.
                    if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: [],
                                                   timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 0) {
                        super.sendEvent(up)
                    }
                    return
                }
            }
        case .leftMouseUp:
            pendingDown = nil
        default: break
        }
        super.sendEvent(event)
    }

    private func canMoveWindow(at event: NSEvent) -> Bool {
        guard let content = contentView else { return false }
        let point = event.locationInWindow
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let v = view {
            if v is NSTextView || (v as? NSTextField)?.isEditable == true || v is NSScroller || v is TerminalLike { return false }
            view = v.superview
        }
        return !Self.exclusions(in: content).contains { $0.convert($0.bounds, to: nil).contains(point) }
    }

    private static func exclusions(in view: NSView) -> [NSView] {
        (view is NoWindowDragView ? [view] : []) + view.subviews.flatMap(exclusions(in:))
    }
}

/// Views that take their own drags (terminals): never move the window from them.
protocol TerminalLike {}
extension AttachTerminalView: TerminalLike {}
extension KeyCapture.KeyView: TerminalLike {}

/// Marker view behind SwiftUI content that must keep its drags (see `View.noWindowDrag()`).
final class NoWindowDragView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct NoWindowDragMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NoWindowDragView { NoWindowDragView() }
    func updateNSView(_ nsView: NoWindowDragView, context: Context) {}
}

extension View {
    /// Drags starting here are the view's own (reorder, selection…), never a window move.
    func noWindowDrag() -> some View { background(NoWindowDragMarker()) }
}

/// Follows the system light/dark appearance live, border included.
final class PanelBackground: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorder()
    }
    func refreshBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor }
    }
}

extension Notification.Name {
    static let panelReset = Notification.Name("MyClaudeCodePanelReset")
    static let selectTab = Notification.Name("MyClaudeCodeSelectTab")
    static let openSession = Notification.Name("MyClaudeCodeOpenSession")
    static let openQuick = Notification.Name("MyClaudeCodeOpenQuick")
    static let closeOverlays = Notification.Name("MyClaudeCodeCloseOverlays")
    static let openNotifications = Notification.Name("MyClaudeCodeOpenNotifications")
    static let openPicker = Notification.Name("MyClaudeCodeOpenPicker")   // debug: render the destination picker
}

/// Original spark glyph (eight rounded rays of alternating length).
enum SparkIcon {
    static func draw(in rect: NSRect, color: NSColor, lineWidth: CGFloat) {
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let long = rect.width / 2 - lineWidth / 2, short = long * 0.62
        color.setStroke()
        for k in 0..<8 {
            let angle = CGFloat(k) * .pi / 4 + .pi / 8
            let r = k % 2 == 0 ? long : short
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + cos(angle) * r * 0.18, y: c.y + sin(angle) * r * 0.18))
            p.line(to: NSPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r))
            p.lineWidth = lineWidth
            p.lineCapStyle = .round
            p.stroke()
        }
    }

    static func menuBar(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { rect in
            draw(in: rect.insetBy(dx: 0.5, dy: 0.5), color: active ? NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1) : .black,
                 lineWidth: 2.1)
            return true
        }
        image.isTemplate = !active
        return image
    }
}
