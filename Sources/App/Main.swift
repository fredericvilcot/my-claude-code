import AppKit
import AVFoundation
import Speech
import CoreGraphics
import SwiftUI

/// Pure AppKit entry point: no SwiftUI scene, hence no stray window.
@main
enum MyClaudeCodeMain {
    static func main() {
        UserDefaults.standard.register(defaults: ["refreshInterval": 15.0, "menuBarStyle": "both",
                                                  "alertThreshold": 70.0, "usagePollInterval": 60.0, "notify.finished": true, "notify.waiting": true,
                                                  "notify.context": true, "notify.quota": true, "notify.digest": true])
        if CommandLine.arguments.contains("--dump") {
            let c = UsageCache()
            _ = c
            Diagnostics.dump()
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { UsageStore.shared.flushCache() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Composition.install() }
        LimitAlerts.shared.setUp()
        ClaudeCodeLink.refreshScriptIfNeeded()
        PanelController.shared.install()
        UsageStore.shared.start()
        Task { @MainActor in AttentionCenter.shared.startDigest() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MiniWindows.shared.restore() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { PanelController.shared.openPanel() }
            if let t = CommandLine.arguments.firstIndex(of: "--tab"), t + 1 < CommandLine.arguments.count {
                let tab = CommandLine.arguments[t + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NotificationCenter.default.post(name: .selectTab, object: tab) }
            }
            if CommandLine.arguments.contains("--minis") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MiniWindows.shared.open(.quotas)
                    if let s = UsageStore.shared.snapshot.current { MiniWindows.shared.open(.session(s.info.id)) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { MiniWindows.shared.capture(prefix: path.replacingOccurrences(of: ".png", with: "")) }
            }
            if CommandLine.arguments.contains("--session-detail") {
                // `--session <id prefix>` picks the session; default: the most recent one.
                let wanted = CommandLine.arguments.firstIndex(of: "--session").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    let store = UsageStore.shared
                    let s = wanted.flatMap { w in store.snapshot.sessions.first { $0.info.id.hasPrefix(w) } } ?? store.snapshot.current
                    if let s { NotificationCenter.default.post(name: .openSession, object: s.index) }
                }
            }
            if CommandLine.arguments.contains("--notifications") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NotificationCenter.default.post(name: .openNotifications, object: nil) }
            }
            if CommandLine.arguments.contains("--quick") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NotificationCenter.default.post(name: .openQuick, object: false) }
                if CommandLine.arguments.contains("--picker") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NotificationCenter.default.post(name: .openPicker, object: nil) }
                }
            }
            if CommandLine.arguments.contains("--demo-attention") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AttentionCenter.shared.injectDemo(UsageStore.shared) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                PanelController.shared.capture(to: path)
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--diag-voice") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let d = Dictation()
                d.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    PanelController.debug("dictée : fin du test, texte=« \(d.transcript) » erreur=\(d.error ?? "aucune")")
                    d.stop()
                }
            }
        }
        if CommandLine.arguments.contains("--tip-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { PanelController.shared.openPanel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                print(Tooltip.shared.debugShow("Prévision d'après votre profil d'activité heure par heure (4 dernières semaines) et l'intensité de cette semaine."))
                let path = NSTemporaryDirectory() + "mcc-tip-test.png"
                PanelController.shared.capture(to: path)
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--forecast") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let store = UsageStore.shared
                for w in store.plan?.all ?? [] {
                    let f = w.forecast
                    print(w.shortName, "officiel", w.usedPercent, "· en direct", f.map { String(format: "%.1f", $0.livePercent) } ?? "—",
                          "· à la réinit.", f.map { String(format: "%.1f", $0.atReset) } ?? "—",
                          "· épuisement", f?.exhaustion.map { $0.formatted() } ?? "aucun")
                }
                if let week = store.plan?.week {
                    for h in [0.0, 0.5, 1, 2, 4] {
                        let f = Forecaster.forecast(week, observedAt: store.plan?.updatedAt ?? Date(), snapshot: store.snapshot,
                                                    history: UsageHistory.samples, now: Date().addingTimeInterval(h * 3600))
                        print("si inactif pendant", h, "h → épuisement", f?.exhaustion.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "aucun",
                              String(format: "· %.1f %% à la réinit.", f?.atReset ?? 0))
                    }
                    let now = Date().timeIntervalSince1970
                    let lastHour = store.snapshot.costSeries.filter { $0.t > now - 3600 }.reduce(0) { $0 + $1.cost }
                    print(String(format: "consommation de la dernière heure : %.2f $", lastHour))
                    print(Forecaster.backtest(series: store.snapshot.costSeries, weekEnd: week.resetsAt.timeIntervalSince1970))
                }
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--diag") {
            // Self-test of dictation permissions and of prompt sending, results on stderr.
            func say(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
            say("micro : \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0 non demandé, 1 restreint, 2 refusé, 3 autorisé)")
            say("reconnaissance vocale : \(SFSpeechRecognizer.authorizationStatus().rawValue) (0 non demandé, 1 refusé, 2 restreint, 3 autorisé)")
            say("recognizer fr-FR disponible : \(SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))?.isAvailable ?? false)")
            Task {
                let live = LiveSessions.fetch()
                say("sessions vues : \(live.values.map(\.name))")
                // Target: the session named by --diag-target, else the first interactive one.
                let wanted = CommandLine.arguments.firstIndex(of: "--diag-target").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
                guard let target = live.values.first(where: { wanted.map($0.name.hasPrefix) ?? ($0.kind == "interactive" && $0.isUserSession) })
                else { say("cible absente"); exit(1) }
                let stat = SessionStat(index: 0, info: SessionInfo(id: target.sessionId, project: "", branch: nil, first: 0, last: 0))
                let t0 = Date()
                let outcome = await PromptSender.send("[diagnostic My Claude Code] test d'envoi, aucune action requise.", to: stat, live: target)
                say("envoi : \(outcome) en \(Int(Date().timeIntervalSince(t0))) s")
                exit(0)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-menubar"), i + 1 < CommandLine.arguments.count {
            // Render check of the menu bar label with 0, 1, 12 and 120 notifications, on light and dark bars.
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let base = MenuBarLabel.render(session: 14, week: 91, threshold: 70, active: true)
                let rows = [0, 1, 12, 120].map { $0 == 0 ? base : PanelController.withCount(base, $0) }
                let width = (rows.map(\.size.width).max() ?? 100) + 24, rowH: CGFloat = 26
                let out = NSImage(size: NSSize(width: width * 2, height: rowH * CGFloat(rows.count)), flipped: true) { _ in
                    for (col, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                            (col == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
                            NSRect(x: CGFloat(col) * width, y: 0, width: width, height: rowH * CGFloat(rows.count)).fill()
                            for (r, img) in rows.enumerated() {
                                img.draw(in: NSRect(x: CGFloat(col) * width + 12, y: CGFloat(r) * rowH + (rowH - img.size.height) / 2,
                                                    width: img.size.width, height: img.size.height),
                                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                            }
                        }
                    }
                    return true
                }
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(out.size.width * 2), pixelsHigh: Int(out.size.height * 2),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = out.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                out.draw(in: NSRect(origin: .zero, size: out.size))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--test-scroll") {
            // With --snapshot --session-detail on a background session: scrolls its embedded terminal up with real
            // wheel events (through NSApp, like a trackpad) just before the capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                func find(_ v: NSView) -> AttachTerminalView? { (v as? AttachTerminalView) ?? v.subviews.lazy.compactMap(find).first }
                guard let window = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }), let content = window.contentView,
                      let term = find(content) else { print("terminal introuvable"); return }
                func screen() -> [String] {
                    let t = term.getTerminal()
                    return (0..<t.rows).compactMap { t.getLine(row: $0)?.translateToString(trimRight: true) }
                }
                let before = screen()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let after = screen()
                    let changed = zip(before, after).filter { $0 != $1 }.count
                    print("lignes modifiées : \(changed)/\(before.count)")
                    let first: String = before.first(where: { $0.count > 20 }) ?? ""
                    let last: String = after.first(where: { $0.count > 20 }) ?? ""
                    print("avant : \(first.prefix(70))")
                    print("après : \(last.prefix(70))")
                }
                let center = term.convert(NSPoint(x: term.bounds.midX, y: term.bounds.midY), to: nil)
                let screen = window.convertPoint(toScreen: center)
                let flipped = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
                let wheelLines: Int32 = Int32(ProcessInfo.processInfo.environment["MCC_WHEEL"] ?? "") ?? 3
                for _ in 0..<8 {
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: wheelLines, wheel2: 0, wheel3: 0) else { continue }
                    cg.location = flipped
                    cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                    cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                    if let ev = NSEvent(cgEvent: cg) { NSApp.sendEvent(ev) }
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--dump-chat"), i + 1 < CommandLine.arguments.count {
            // Prints what "Messages entre agents" shows for the session whose id starts with the argument.
            let prefix = CommandLine.arguments[i + 1]
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                let files = UsageLog.listFiles().map(\.path).filter { ($0 as NSString).lastPathComponent.hasPrefix(prefix) }
                guard let path = files.first else { print("journal introuvable"); exit(1) }
                let id = String((path as NSString).lastPathComponent.dropLast(6))
                for item in ChatLog.items(for: id) {
                    let who = "\(item.role) \(item.from) → \(item.to) [\(item.delivery)]"
                    print("\(who) : \(item.text.replacingOccurrences(of: "\n", with: " ").prefix(110))")
                }
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--bench-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { PanelController.shared.benchMenu() }
        }
        if CommandLine.arguments.contains("--bench") {
            // Times a full layout + render of the dashboard, as when the menu or panel opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                for run in 1...4 {
                    let start = Date()
                    let view = NSHostingView(rootView: DashboardView().environment(UsageStore.shared))
                    view.sizingOptions = []
                    view.frame = NSRect(x: 0, y: 0, width: 400, height: 900)
                    view.layoutSubtreeIfNeeded()
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: rep)
                    print(String(format: "rendu %d : %.0f ms", run, Date().timeIntervalSince(start) * 1000))
                }
                // Each tab alone, twice (first render, then a re-render as on a data refresh).
                let tabs: [(String, AnyView)] = [("Direct", AnyView(LiveView())), ("Sessions", AnyView(SessionsView(selected: .constant(nil)))),
                                                 ("Stats", AnyView(StatsView())), ("Statut", AnyView(StatusView())), ("Réglages", AnyView(SettingsView()))]
                for (name, root) in tabs {
                    for pass in 1...2 {
                        let start = Date()
                        let view = NSHostingView(rootView: root.environment(UsageStore.shared))
                        view.sizingOptions = []
                        view.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
                        view.layoutSubtreeIfNeeded()
                        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: rep)
                        print(String(format: "onglet %@ (%d) : %.0f ms", name, pass, Date().timeIntervalSince(start) * 1000))
                    }
                }
                let fm = Date()
                for _ in 0..<20 { _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) }
                print(String(format: "détection plein écran : %.1f ms", Date().timeIntervalSince(fm) * 1000 / 20))
                exit(0)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-day"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let r = ImageRenderer(content: DayBlock().environment(UsageStore.shared).frame(width: 400).background(Theme.paper))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { PanelController.shared.openPanel() }
        }
    }
}

enum Diagnostics {
    /// `MyClaudeCode --dump`: parses everything synchronously and prints the totals.
    static func dump() {
        let started = Date()
        var cache = UsageCache()
        var seen = Set<String>()
        var sessions: [String: Int] = [:], models: [String: Int] = [:]
        let files = UsageLog.listFiles()
        for f in files {
            for p in UsageLog.parse(path: f.path, from: 0).records where seen.insert(p.key).inserted {
                let s = sessions[p.session] ?? { cache.sessions.append(SessionInfo(id: p.session, project: p.cwd, branch: p.branch, first: p.t, last: p.t)); sessions[p.session] = cache.sessions.count - 1; return cache.sessions.count - 1 }()
                cache.sessions[s].first = min(cache.sessions[s].first, p.t); cache.sessions[s].last = max(cache.sessions[s].last, p.t)
                let m = models[p.model] ?? { cache.models.append(p.model); models[p.model] = cache.models.count - 1; return cache.models.count - 1 }()
                cache.records.append(UsageRecord(t: p.t, s: s, m: m, i: p.i, o: p.o, w5: p.w5, w1: p.w1, r: p.r, f: p.fast, sc: p.sidechain))
            }
        }
        cache.records.sort { $0.t < $1.t }
        let snap = UsageStore.aggregate(cache)
        print("files \(files.count) · records \(cache.records.count) · \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        print("today \(Fmt.usd(snap.today.cost.total)) \(Fmt.tokens(snap.today.tokens)) · 7d \(Fmt.usd(snap.week.cost.total)) · 30d \(Fmt.usd(snap.month.cost.total)) · all \(Fmt.usd(snap.all.cost.total))")
        print("models", snap.models.prefix(6).map { "\(Fmt.model($0.name)) \(Fmt.usd($0.cost))\($0.estimated ? " (estimé)" : "")" })
        print("current", snap.current.map { "\($0.name) \(Fmt.usd($0.totals.cost.total))" } ?? "none",
              "· window", snap.window.map { "\(Fmt.usd($0.cost)) reset \(Fmt.time($0.reset)) peak \($0.typicalPeak.map(Fmt.usd) ?? "-")" } ?? "none")
        print("streak \(snap.streak) · active days \(snap.activeDays) · savings \(Fmt.usd(snap.cacheSavings))")
    }
}
