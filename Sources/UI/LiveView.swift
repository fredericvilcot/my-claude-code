import SwiftUI

/// "Direct": the home tab, centred on monitoring. Quotas at a glance (detachable), what needs you,
/// and every open session with what its agent is doing right now.
@MainActor
struct LiveView: View {
    @Environment(UsageStore.self) private var store

    private var openSessions: [SessionStat] {
        let hidden = SessionFiles.hidden
        return store.snapshot.sessions
            .filter { s in
                guard let l = store.live[s.info.id] else { return false }
                return !hidden.contains(s.info.id) && l.isUserSession
            }
            .sorted { a, b in
                let pa = store.live[a.info.id]?.phase ?? 3, pb = store.live[b.info.id]?.phase ?? 3
                return pa != pb ? pa < pb : a.info.last > b.info.last
            }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                quotasCard
                sessionsSection
                todayLine
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    // MARK: Quotas

    private var quotasCard: some View {
        let detached = MiniWindows.shared.isOpen(.quotas)
        return Block(title: "Quotas", note: store.plan.map { "màj " + Fmt.stampTime($0.updatedAt) },
                     detach: (detached, { MiniWindows.shared.toggle(.quotas) })) {
            LimitsContent()
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        let sessions = openSessions
        Block(title: "Sessions ouvertes", note: sessions.isEmpty ? nil : "\(sessions.count)") {
            if sessions.isEmpty {
                Text("Aucune session Claude Code ouverte. Lancez-en une avec ⚡ Rapide › Nouveau chantier.")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(sessions) { s in
                        if let live = store.live[s.info.id] { LiveSessionCard(session: s, live: live) }
                    }
                }
            }
        }
    }

    private var todayLine: some View {
        let t = store.snapshot.today
        return HStack(spacing: 6) {
            Image(systemName: "sun.max").foregroundStyle(Theme.inkFaint)
            Text("Aujourd'hui · \(Fmt.usd(t.cost.total)) · \(Fmt.tokens(t.tokens)) tokens · \(t.sessions.count) sessions")
        }
        .font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

/// One row per quota: name, value, bar with the alert notch, reset time and forecast. Used in "Direct" and in the
/// floating quotas window.
struct QuotaSummary: View {
    @Environment(UsageStore.self) private var store
    var dense = false

    var body: some View {
        if let plan = store.plan {
            VStack(spacing: dense ? 9 : 12) {
                row(name: "Session", window: plan.session, fallback: "démarre au prochain message")
                row(name: "Semaine", window: plan.week, fallback: "en attente de /usage")
                ForEach(plan.scoped, id: \.label) { w in row(name: w.shortName, window: w, fallback: "") }
            }
        } else {
            Text("Limites en attente de la première lecture de /usage.").font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
        }
    }

    private func row(name: String, window: PlanUsage.Window?, fallback: String) -> some View {
        let pct = window?.usedPercent ?? 0
        let threshold = LimitAlerts.threshold
        let color: Color = pct >= threshold ? .red : (pct >= threshold * 0.8 ? .orange : Theme.seriesClay)
        let f = window?.forecast
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(Theme.sans(dense ? 12 : 12.5, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                (Text("\(Int(pct.rounded()))").font(.system(size: dense ? 15 : 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pct >= threshold ? Color.red : Theme.ink)
                 + Text(" %").font(Theme.sans(11, .medium)).foregroundStyle(Theme.inkSoft))
            }
            ZStack(alignment: .leading) {
                Bar(fraction: pct / 100, color: color, height: dense ? 5 : 6)
                GeometryReader { g in
                    Rectangle().fill(Theme.ink.opacity(0.55)).frame(width: 1.5, height: dense ? 9 : 10)
                        .offset(x: g.size.width * threshold / 100, y: -2)
                }
            }
            .frame(height: dense ? 5 : 6)
            HStack(spacing: 6) {
                if let window {
                    Text("réinit. \(window.kind == .session ? Fmt.time(window.resetsAt) : window.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR"))))")
                        .foregroundStyle(Theme.inkFaint)
                } else {
                    Text(fallback).foregroundStyle(Theme.inkFaint)
                }
                Spacer(minLength: 4)
                if let f {
                    if let e = f.exhaustion {
                        Label("épuisé \(window?.kind == .session ? Fmt.time(e) : e.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR"))))",
                              systemImage: "chart.line.downtrend.xyaxis").foregroundStyle(.orange)
                    } else {
                        Text("≈ \(Int(f.atReset.rounded())) % à la réinit.").foregroundStyle(Theme.sage)
                    }
                }
            }
            .font(Theme.sans(dense ? 10.5 : 11, .medium)).lineLimit(1).minimumScaleFactor(0.85)
        }
    }
}

/// An open session, live: status, what the agent is doing (with its precision), context with "Compacter",
/// and "follow in a window". Click opens the session sheet.
struct LiveSessionCard: View {
    @Environment(UsageStore.self) private var store
    let session: SessionStat
    let live: LiveSession
    @State private var hovering = false

    var body: some View {
        let ctx = store.context(of: session)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Circle().fill(PhaseBadge.color(live.phase)).frame(width: 8, height: 8)
                Text(store.title(of: session)).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                if let b = session.info.branch, !b.isEmpty, b != "HEAD" {
                    Text(b).font(Theme.sans(10.5, .medium)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.rule.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Spacer(minLength: 4)
                FollowButton(sessionID: session.info.id)
            }
            if !live.name.isEmpty, live.name != store.title(of: session) {
                Text("@" + live.name).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
                    .tip("Nom technique de la session, utilisé par la messagerie entre agents")
            }
            ActivityLine(sessionID: session.info.id, live: live)
            if live.phase == 0, let p = ActivityReader.activity(for: session.info.id)?.precision, !p.isEmpty {
                Text(p).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.inkFaint).lineLimit(1)
                    .padding(.leading, 18)
            }
            HStack(spacing: 8) {
                Text("contexte").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
                Bar(fraction: ctx.fraction, color: contextColor(ctx.fraction), height: 5)
                Text("\(Int((ctx.fraction * 100).rounded())) %").font(Theme.sans(11.5, .semibold).monospacedDigit())
                    .foregroundStyle(ctx.fraction >= 0.8 ? contextColor(ctx.fraction) : Theme.ink)
                SessionActions(session: session, live: live)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.rule.opacity(0.3) : Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { NotificationCenter.default.post(name: .openSession, object: session.index) }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// Détacher a session as a floating window, or close that window ("Fermer").
@MainActor
struct FollowButton: View {
    let sessionID: String
    var label = false

    var body: some View {
        let open = MiniWindows.shared.isOpen(.session(sessionID))
        DetachButton(detached: open, label: label) { MiniWindows.shared.toggle(.session(sessionID)) }
            .tip(open ? "Détachée · cliquer pour fermer la fenêtre flottante"
                      : "Détacher en fenêtre flottante")
    }
}

/// The one detach control, everywhere: a discreet picture-in-picture icon at the top right of the element.
/// Detached, it turns clay; clicking it then closes the floating window.
struct DetachButton: View {
    let detached: Bool
    var label = false   // kept for call sites; the control is always an icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: detached ? "pip.fill" : "pip.exit")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(detached ? Theme.clay : (hovering ? Theme.ink : Theme.inkFaint))
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Theme.rule.opacity(0.6) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// The quotas card: session as the hero ring, weekly quotas as rich rows beside it (with forecasts).
struct LimitsContent: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let threshold = LimitAlerts.threshold
        if let plan = store.plan, !plan.all.isEmpty {
            HStack(alignment: .center, spacing: 16) {
                SessionHero(window: plan.session, threshold: threshold)
                VStack(spacing: 12) {
                    let known = UserDefaults.standard.stringArray(forKey: "knownScopedQuotas") ?? []
                    if let w = plan.week { LimitRow(window: w, threshold: threshold) } else { LimitPlaceholder(name: "Semaine", detail: "tous modèles") }
                    ForEach(known, id: \.self) { name in
                        if let w = plan.scoped.first(where: { $0.shortName == name }) { LimitRow(window: w, threshold: threshold) }
                        else { LimitPlaceholder(name: name, detail: "semaine") }
                    }
                    ForEach(plan.scoped.filter { !known.contains($0.shortName) }, id: \.label) { w in LimitRow(window: w, threshold: threshold) }
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("Limites en attente de la première lecture de /usage.").font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
        }
    }
}
