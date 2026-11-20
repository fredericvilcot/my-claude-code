import SwiftUI

/// "What weighs on your usage" from /usage, shared by the overview and the stats tab.
struct ContributorsBlock: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let list = store.plan?.contributors ?? []
        Block(title: "Ce qui pèse sur votre usage", note: "24 dernières heures") {
            if list.isEmpty {
                Text("Disponible dès la prochaine actualisation de /usage.").font(Theme.sans(12.5)).foregroundStyle(Theme.inkSoft)
            } else {
                VStack(spacing: 14) {
                    ForEach(Array(list.prefix(5).enumerated()), id: \.offset) { i, c in
                        let parts = OverviewView.translate(c.1).components(separatedBy: " · ")
                        MeterRow(label: parts.first ?? c.1, fraction: Double(c.0) / 100, value: "\(c.0) %",
                                 color: i == 0 ? Theme.seriesClay : Theme.muted)
                        if parts.count > 1 {
                            Text(parts.dropFirst().joined(separator: " · ")).font(Theme.sans(11)).foregroundStyle(Theme.inkFaint)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, -9)
                        }
                    }
                }
                Text("Parts approximatives, sessions de ce Mac ; elles se recoupent.").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
            }
        }
    }
}

/// Cost per model over the last seven days: one segmented whole plus a legend with values.
struct ModelsBlock: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let models = store.snapshot.weekModels
        let main = Array(models.prefix(4))
        let rest = models.dropFirst(4).reduce(0) { $0 + $1.cost }
        var parts = main.map { (label: Fmt.model($0.name) + ($0.estimated ? " *" : ""), value: $0.cost,
                                color: Theme.modelColor($0.name), text: Viz.compactUSD($0.cost)) }
        if rest > 0 { parts.append((label: "Autres", value: rest, color: Theme.muted, text: Viz.compactUSD(rest))) }
        return Block(title: "Modèles", note: "7 derniers jours") {
            if parts.isEmpty {
                Text("Aucune activité cette semaine.").font(Theme.sans(12.5)).foregroundStyle(Theme.inkSoft)
            } else {
                SegmentedBar(parts: parts, height: 12)
            }
        }
    }
}

/// Context window of the live session, with model, effort and thinking (no money).
struct ContextBlock: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let st = store.claude
        Block(title: "Session en cours", note: st.statusDate.map { OverviewView.ago($0) }) {
            if let pct = st.contextPercent {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Circle().stroke(Theme.rule, lineWidth: 11)
                        Circle().trim(from: 0, to: max(0.01, min(1, pct / 100)))
                            .stroke(pct >= 80 ? Color.orange : Theme.slate, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(Int(pct.rounded()))").font(.system(size: 30, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                            + Text(" %").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.inkSoft)
                            Text("contexte").font(Theme.sans(10.5)).foregroundStyle(Theme.inkSoft)
                        }
                    }
                    .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 9) {
                        if let name = st.sessionName ?? st.cwd.map({ ($0 as NSString).lastPathComponent }) {
                            Text(name).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                        }
                        info("Modèle", st.model)
                        info("Effort", st.effort.map(Self.effort))
                        info("Réflexion", st.thinking.map { $0 ? "activée" : "désactivée" })
                        if let used = st.contextUsed, let size = st.contextSize {
                            info("Tokens", "\(Fmt.tokens(used)) / \(Fmt.tokens(size))")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                if pct >= 80 {
                    Label("Contexte bientôt plein : pensez à /compact ou à une nouvelle session.", systemImage: "exclamationmark.circle")
                        .font(Theme.sans(12)).foregroundStyle(.orange)
                }
            } else {
                Text("Apparaîtra à la prochaine réponse de Claude Code (ligne d'état connectée).")
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.inkSoft)
            }
        }
    }

    static func effort(_ level: String) -> String {
        ["low": "faible", "medium": "moyen", "high": "élevé", "xhigh": "très élevé", "max": "maximal"][level] ?? level
    }

    private func info(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).frame(width: 66, alignment: .leading)
            Text(value ?? "—").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
        }
    }
}

/// Today's spend summary (used at the top of the Sessions tab).
struct TodaySummaryBlock: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let snap = store.snapshot
        Block(title: "Aujourd'hui", note: "\(snap.today.sessions.count) sessions") {
            HStack(alignment: .lastTextBaseline) {
                Figure(value: Fmt.usd(snap.today.cost.total), size: 34)
                Spacer()
                if snap.yesterday.cost.total > 0 {
                    let d = (snap.today.cost.total - snap.yesterday.cost.total) / snap.yesterday.cost.total
                    Text("\(d >= 0 ? "↑" : "↓") \(Fmt.percent(abs(d))) vs hier").font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
                }
            }
            HStack(spacing: 0) {
                Metric(label: "Tokens", value: Fmt.tokens(snap.today.tokens))
                Metric(label: "Réponses", value: "\(snap.today.messages)")
                Metric(label: "7 jours", value: Fmt.usd(snap.week.cost.total))
                Metric(label: "30 jours", value: Fmt.usd(snap.month.cost.total))
            }
            SplitBar(cost: snap.today.cost)
        }
    }
}

/// Projects ranked by cost (Stats tab).
struct ProjectsBlock: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let all = store.snapshot.projects
        let items = Array(all.prefix(8))
        let total = max(0.0001, all.reduce(0) { $0 + $1.totals.cost.total })
        let top = max(0.0001, items.first?.totals.cost.total ?? 1)
        Block(title: "Projets", note: "\(all.count) au total") {
            VStack(spacing: 13) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                    MeterRow(label: p.name, sublabel: "\(p.sessionCount) sessions · \(Fmt.percent(p.totals.cost.total / total))",
                             fraction: p.totals.cost.total / top, value: Viz.compactUSD(p.totals.cost.total),
                             color: i == 0 ? Theme.seriesClay : Theme.muted)
                        .tip(p.path)
                }
            }
        }
    }
}

/// Colour of a context level: calm, then orange from 80 %, red from 90 %.
func contextColor(_ fraction: Double) -> Color {
    fraction >= 0.9 ? .red : fraction >= 0.8 ? .orange : Theme.slate
}

/// Right-hand gauge of a session row: context level first, cost as a small footnote.
struct ContextGauge: View {
    @Environment(UsageStore.self) private var store
    let session: SessionStat

    var body: some View {
        let ctx = store.context(of: session)
        VStack(alignment: .trailing, spacing: 5) {
            Text("\(Int((ctx.fraction * 100).rounded())) %").font(Theme.sans(15, .semibold).monospacedDigit())
                .foregroundStyle(ctx.fraction >= 0.8 ? contextColor(ctx.fraction) : Theme.ink)
            Bar(fraction: ctx.fraction, color: contextColor(ctx.fraction), height: 5).frame(width: 80)
            Text("contexte · \(Fmt.usd(session.totals.cost.total))").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
        }
        .frame(width: 96, alignment: .trailing)
        .tip(ctx.exact ? "Contexte exact transmis par Claude Code" : "Contexte calculé depuis le journal (dernière réponse)")
    }
}

/// Every session active in the last 30 minutes, with its context level before compaction.
struct ActiveSessionsBlock: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let now = Date().timeIntervalSince1970
        let active = store.snapshot.sessions.filter { now - $0.info.last < 30 * 60 }
        Block(title: "Sessions actives", note: active.isEmpty ? nil : "\(active.count)") {
            if active.isEmpty {
                Text("Aucune session Claude Code active ces 30 dernières minutes.").font(Theme.sans(12.5)).foregroundStyle(Theme.inkSoft)
            } else {
                VStack(spacing: 18) {
                    ForEach(active) { s in
                        let ctx = store.context(of: s)
                        Button { NotificationCenter.default.post(name: .openSession, object: s.index) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(s.name).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                                if let b = s.info.branch, !b.isEmpty, b != "HEAD" {
                                    Text(b).font(Theme.sans(11)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                                }
                                Spacer()
                                Text("\(Int((ctx.fraction * 100).rounded()))").font(.system(size: 24, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(ctx.fraction >= 0.8 ? contextColor(ctx.fraction) : Theme.ink)
                                + Text(" %").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.inkSoft)
                            }
                            Bar(fraction: ctx.fraction, color: contextColor(ctx.fraction), height: 9)
                            if let live = store.live[s.info.id] {
                                ActivityLine(sessionID: s.info.id, live: live)
                                if ctx.fraction >= 0.5 || Compactor.shared.step(s.info.id) != nil {
                                    CompactButton(session: s, live: live, compact: true)
                                }
                            }
                            Text([store.live[s.info.id].map { "@" + $0.name }, Fmt.model(s.lastModel),
                                  "\(Fmt.tokens(s.lastContext)) / \(Fmt.tokens(s.contextWindow))",
                                  "reste \(Int(((1 - ctx.fraction) * 100).rounded())) %"].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(2)
                        }
                        .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tip("Ouvrir cette session")
                    }
                }
            }
        }
    }
}

/// Today at a glance, without money: hourly activity, responses, sessions, streak, busiest project.
struct DayBlock: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let snap = store.snapshot
        Block(title: "Votre journée", note: Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))) {
            HourBars(values: snap.todayHours.map(Double.init), height: 92)
            Grid(horizontalSpacing: 8) {
                GridRow {
                    StatTile(label: "Réponses", value: "\(snap.today.messages)", symbol: "text.bubble.fill")
                    StatTile(label: "Tokens", value: Fmt.tokens(snap.today.tokens), symbol: "number")
                    StatTile(label: "Série", value: "\(snap.streak) j", symbol: "flame.fill")
                }
            }
            if let top = snap.todayTopProject {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Theme.seriesClay)
                    Text("Projet le plus actif").font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
                    Spacer()
                    Text(top).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                }
            }
        }
    }
}

/// Light view shown inside the native menu (full screen): plan limits and active sessions only.
struct MenuCompactView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let threshold = LimitAlerts.threshold
        let windows = store.plan?.all ?? []
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                SparkGlyph(size: 20)
                Text("My Claude Code").font(Theme.sans(15, .bold)).foregroundStyle(Theme.ink)
                Spacer()
                if let p = store.plan { Text(OverviewView.ago(p.updatedAt)).font(Theme.sans(11)).foregroundStyle(Theme.inkSoft) }
            }
            if windows.isEmpty {
                Text("Limites en cours de lecture…").font(Theme.sans(12.5)).foregroundStyle(Theme.inkSoft)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
                        LimitRing(title: w.shortName, subtitle: "", window: w, threshold: threshold, size: 84)
                    }
                }
            }
            let now = Date().timeIntervalSince1970
            let active = store.snapshot.sessions.filter { now - $0.info.last < 30 * 60 }.prefix(4)
            if !active.isEmpty {
                Rectangle().fill(Theme.rule).frame(height: 0.5)
                ForEach(Array(active)) { s in
                    let ctx = store.context(of: s)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(s.name).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            Text("\(Int((ctx.fraction * 100).rounded())) %").font(Theme.sans(14, .semibold).monospacedDigit())
                                .foregroundStyle(ctx.fraction >= 0.8 ? contextColor(ctx.fraction) : Theme.ink)
                        }
                        Bar(fraction: ctx.fraction, color: contextColor(ctx.fraction), height: 6)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Theme.paper)
    }
}

/// One live line for an open session: what the agent is doing and for how long; "au repos depuis…" between turns.
/// Always present for open sessions so cards never change height.
struct ActivityLine: View {
    let sessionID: String
    let live: LiveSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let a = ActivityReader.activity(for: sessionID)
            let working = live.phase == 0 && (a?.working ?? true)
            HStack(spacing: 6) {
                if working {
                    ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
                } else {
                    Image(systemName: live.phase == 1 ? "pause.circle.fill" : "moon.zzz.fill")
                        .font(.system(size: 10)).foregroundStyle(PhaseBadge.color(live.phase == 1 ? 1 : 2))
                        .frame(width: 12)
                }
                Text(text(a, working: working))
                    .font(Theme.sans(11.5, working ? .medium : .regular))
                    .foregroundStyle(working ? Theme.ink : Theme.inkSoft)
                    .lineLimit(1).truncationMode(.tail)
                    .contentTransition(.opacity)
            }
            .animation(.easeOut(duration: 0.2), value: a?.text)
        }
    }

    private func text(_ a: SessionActivity?, working: Bool) -> String {
        guard let a else { return working ? "travaille…" : "au repos" }
        let since = Fmt.duration(max(0, Date().timeIntervalSince(a.since)))
        if working { return "\(a.text) · depuis \(since)" }
        return live.phase == 1 ? "attend votre réponse · depuis \(since)" : "au repos depuis \(since)"
    }
}

/// "Compacter": synthesis note then /compact, typed into the session's iTerm tab (see Compactor).
@MainActor
struct CompactButton: View {
    let session: SessionStat
    let live: LiveSession?
    var compact = false
    private var compactor: Compactor { Compactor.shared }

    var body: some View {
        let step = compactor.step(session.info.id)
        HStack(spacing: 8) {
            if let live, live.pid != nil {
                Button { compactor.compact(session, live: live) } label: {
                    HStack(spacing: 5) {
                        if busy(step) { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                        else { Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10, weight: .bold)) }
                        Text(label(step)).font(Theme.sans(compact ? 11 : 12, .semibold))
                    }
                    .foregroundStyle(busy(step) ? Theme.clayDeep : .white)
                    .padding(.horizontal, compact ? 9 : 11).padding(.vertical, compact ? 4 : 6)
                    .background(Capsule().fill(busy(step) ? Theme.clay.opacity(0.14) : Theme.clay))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy(step))
                .tip("Fait rédiger à la session une note de synthèse (objectif, état, décisions, fichiers, prochaines étapes) dans ~/.claude/session-notes, puis lance /compact en la conservant.")
            }
            if let text = status(step) {
                Text(text).font(Theme.sans(11)).foregroundStyle(isError(step) ? Color.orange : Theme.inkSoft).lineLimit(2)
            }
        }
    }

    private func busy(_ s: Compactor.Step?) -> Bool {
        switch s { case .writingNote, .compacting: true; default: false }
    }
    private func isError(_ s: Compactor.Step?) -> Bool { if case .failed = s { return true }; return false }
    private func label(_ s: Compactor.Step?) -> String {
        switch s {
        case .writingNote: "Note en cours…"
        case .compacting: "Compaction…"
        default: "Compacter"
        }
    }
    private func status(_ s: Compactor.Step?) -> String? {
        switch s {
        case .done(let note): "Compacté · note \((note as NSString).lastPathComponent)"
        case .failed(let why): why
        default: nil
        }
    }
}

/// A real button tile for the session sheet's actions: icon, title, hint, framed, with hover feedback.
struct ActionTile: View {
    let title: String
    let detail: String
    let symbol: String
    var tint: Color = Theme.clay
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = destructive ? Color.red : tint
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.sans(13, .semibold)).foregroundStyle(destructive ? Color.red : Theme.ink)
                    Text(detail).font(Theme.sans(11)).foregroundStyle(Theme.inkFaint).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? color.opacity(0.07) : Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? color.opacity(0.45) : Theme.rule, lineWidth: hovering ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(hovering ? 1.005 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}
