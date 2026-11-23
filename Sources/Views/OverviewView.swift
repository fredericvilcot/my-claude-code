import Charts
import SwiftUI

enum OverviewWidget: String, BoardWidget {
    case attention, limits, context, day, contributors, today, current, week, models, recent, calendar, hours, cache
    var title: String {
        switch self {
        case .attention: "À traiter"
        case .limits: "Limites du forfait"
        case .contributors: "Ce qui pèse sur votre usage"
        case .context: "Sessions actives"
        case .day: "Votre journée"
        case .today: "Aujourd'hui"
        case .current: "Session en cours"
        case .week: "Sept derniers jours"
        case .models: "Modèles"
        case .recent: "Sessions récentes"
        case .calendar: "Calendrier"
        case .hours: "Heures de travail"
        case .cache: "Économies du cache"
        }
    }
    var pinned: Bool { self == .attention }

    var symbol: String {
        switch self {
        case .attention: "bell.badge"
        case .limits: "gauge.with.dots.needle.67percent"
        case .contributors: "list.bullet.indent"
        case .context: "text.alignleft"
        case .day: "sun.and.horizon"
        case .today: "sun.max"
        case .current: "bolt"
        case .week: "chart.bar"
        case .models: "cpu"
        case .recent: "clock.arrow.circlepath"
        case .calendar: "square.grid.3x3"
        case .hours: "clock"
        case .cache: "leaf"
        }
    }
    static let defaultHidden: Set<OverviewWidget> = [.contributors, .today, .current, .week, .models, .recent, .calendar, .hours, .cache]

    static func order(_ raw: String) -> [OverviewWidget] {
        var list = raw.split(separator: ",").compactMap { OverviewWidget(rawValue: String($0)) }
        for w in allCases where !list.contains(w) {
            if w == .attention { list.insert(w, at: 0) } else if w == .limits { list.insert(w, at: min(1, list.count)) } else { list.append(w) }
        }
        return list
    }
    static func hidden(_ raw: String?) -> Set<OverviewWidget> {
        guard let raw else { return defaultHidden }
        return Set(raw.split(separator: ",").compactMap { OverviewWidget(rawValue: String($0)) })
    }
    static func encode<S: Sequence>(_ s: S) -> String where S.Element == OverviewWidget { s.map(\.rawValue).joined(separator: ",") }
}

struct OverviewView: View {
    @Environment(UsageStore.self) private var store
    let openSession: (Int) -> Void
    private var snap: Snapshot { store.snapshot }

    var body: some View {
        WidgetBoard(orderKey: "widgetOrder4", hiddenKey: "hiddenWidgets4", defaultHidden: OverviewWidget.defaultHidden,
                    isAvailable: { ($0 != .current || snap.current != nil) && $0 != .attention }) { w in widget(w) }
    }

    @ViewBuilder
    private func widget(_ w: OverviewWidget) -> some View {
        switch w {
        case .attention: EmptyView()   // notifications live in the notification center now
        case .limits: limits
        case .context: ActiveSessionsBlock()
        case .day: DayBlock()
        case .contributors: contributors
        case .today: today
        case .current: if let s = snap.current { current(s) }
        case .week: week
        case .models: models
        case .recent: recent
        case .calendar: calendar
        case .hours: hours
        case .cache: cache
        }
    }

    // MARK: Extra widgets

    private var calendar: some View {
        let weeks = stride(from: 0, to: snap.heat.count, by: 7).map { Array(snap.heat[$0..<min($0 + 7, snap.heat.count)]) }
        let peak = max(0.0001, snap.heat.map(\.cost).max() ?? 1)
        return Block(title: "Calendrier", note: "18 semaines") {
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(week) { d in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(d.cost == 0 ? Theme.rule : Theme.clay.opacity(0.25 + 0.75 * sqrt(d.cost / peak)))
                                .frame(width: 15, height: 15)
                                .tip("\(Fmt.day(d.day)) : \(Fmt.usd(d.cost))")
                        }
                    }
                }
            }
        }
    }

    private var hours: some View {
        Block(title: "Heures de travail", note: "coût par heure") {
            Chart(Array(snap.hours.enumerated()), id: \.offset) { h, v in
                BarMark(x: .value("Heure", h), y: .value("Coût", v), width: .ratio(0.7)).foregroundStyle(Theme.clay.opacity(0.85))
            }
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { if let h = v.as(Int.self) { Text("\(h) h").font(Theme.sans(10.5)) } } } }
            .chartYAxis(.hidden)
            .frame(height: 90)
        }
    }

    private var cache: some View {
        Block(title: "Économies du cache", note: "depuis le début") {
            HStack(alignment: .lastTextBaseline) {
                Figure(value: Fmt.usd(snap.cacheSavings), caption: "évités grâce à la relecture du cache", size: 34)
                Spacer()
            }
            Metric(label: "Taux de cache", value: Fmt.percent(Double(snap.all.read) / Double(max(1, snap.all.read + snap.all.input + snap.all.write))),
                   accent: Theme.sage)
        }
    }

    // MARK: Plan limits (same figures as /usage)

    private var limits: some View {
        let plan = store.plan
        let threshold = LimitAlerts.threshold
        let windows = plan?.all ?? []
        // Alerts live in the "À traiter" card only; here the red figures are enough.
        return Block(title: "Limites du forfait", note: plan.map { Self.ago($0.updatedAt) }) {
            switch windows.isEmpty ? store.link : ClaudeCodeLink.State.connected {
            case .connected:
                if let plan, !windows.isEmpty {
                    // Session as the hero ring, weekly quotas as rich rows beside it.
                    HStack(alignment: .center, spacing: 18) {
                        SessionHero(window: plan.session, threshold: threshold)
                        VStack(spacing: 14) {
                            // Fixed slots: the weekly quota and every per-model quota seen before, placeholders until known.
                            let known = UserDefaults.standard.stringArray(forKey: "knownScopedQuotas") ?? ["Fable"]
                            if let w = plan.week { LimitRow(window: w, threshold: threshold) } else { LimitPlaceholder(name: "Semaine", detail: "tous modèles") }
                            ForEach(known, id: \.self) { name in
                                if let w = plan.scoped.first(where: { $0.shortName == name }) {
                                    LimitRow(window: w, threshold: threshold)
                                } else {
                                    LimitPlaceholder(name: name, detail: "semaine")
                                }
                            }
                            ForEach(plan.scoped.filter { !known.contains($0.shortName) }, id: \.label) { w in
                                LimitRow(window: w, threshold: threshold)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    Text("Connecté. Les pourcentages apparaîtront après la prochaine réponse de Claude Code.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
            case .notConnected:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Affichez ici les mêmes chiffres que /usage : session et semaine, avec alertes.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    Text("My Claude Code ajoute une ligne d'état à Claude Code (~/.claude/settings.json, sauvegardé). Réversible dans les Réglages.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                    Button {
                        try? ClaudeCodeLink.connect()
                        store.refreshPlan()
                    } label: {
                        Text("Connecter à Claude Code").font(Theme.sans(12.5, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.clay))
                    }
                    .buttonStyle(.plain)
                }
            case .otherStatusLine:
                Text("Une autre ligne d'état est déjà configurée dans Claude Code : My Claude Code ne la remplace pas sans votre accord (Réglages).")
                    .font(Theme.sans(12)).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var contributors: some View { ContributorsBlock() }

    /// French wording for the usual /usage advice (unknown lines stay as Claude Code wrote them).
    static func translate(_ text: String) -> String {
        let table: [(String, String)] = [
            ("Start fresh when you switch tasks", "Repartir de zéro en changeant de tâche"),
            ("run /clear", "lancez /clear"),
            ("Check which models your subagents use", "Vérifier les modèles de vos sous-agents"),
            ("share covers whole sessions, not only subagents", "la part couvre les sessions entières, pas seulement les sous-agents"),
            ("Review sessions active over many hours", "Revoir les sessions actives pendant de longues heures"),
            ("whole sessions with requests in 8 or more separate hours", "sessions avec des requêtes réparties sur 8 heures ou plus"),
            ("Run fewer sessions at once", "Lancer moins de sessions en parallèle"),
            ("Trim ", "Alléger "),
            (" tokens per request", " tokens par requête"),
            ("up to ", "jusqu'à "),
            (" at once", " en même temps"),
        ]
        return table.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    static func ago(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "à l'instant" }
        if s < 3600 { return "il y a \(Int(s / 60)) min" }
        return "il y a \(Fmt.duration(s))"
    }

    private var today: some View {
        let t = snap.today.cost.total, y = snap.yesterday.cost.total
        return Block(title: "Aujourd'hui", note: Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))) {
            HStack(alignment: .lastTextBaseline) {
                Figure(value: Fmt.usd(t), size: 44)
                Spacer()
                if y > 0 {
                    let d = (t - y) / y
                    Text("\(d >= 0 ? "↑" : "↓") \(Fmt.percent(abs(d))) vs hier").font(Theme.sans(12))
                        .foregroundStyle(d >= 0 ? Theme.clayDeep : Theme.sage)
                }
            }
            HStack(spacing: 0) {
                Metric(label: "Tokens", value: Fmt.tokens(snap.today.tokens))
                Metric(label: "Réponses", value: "\(snap.today.messages)")
                Metric(label: "Sessions", value: "\(snap.today.sessions.count)")
                Metric(label: "Dern. heure", value: Fmt.usd(snap.lastHourCost))
            }
            SplitBar(cost: snap.today.cost)
        }
    }

    private func current(_ s: SessionStat) -> some View {
        Block(title: "Session en cours", note: Fmt.duration(s.duration)) {
            Button { openSession(s.index) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.displayName).font(Theme.serif(18, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text([s.info.branch.map { "⎇ " + $0 }, s.models.max { $0.value < $1.value }.map { Fmt.model($0.key) }]
                                .compactMap { $0 }.joined(separator: "  ·  "))
                                .font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        }
                        Spacer()
                        Text(Fmt.usd(s.totals.cost.total)).font(Theme.serif(24)).foregroundStyle(Theme.clayDeep).monospacedDigit()
                    }
                    HStack(spacing: 0) {
                        Metric(label: "Tokens", value: Fmt.tokens(s.totals.tokens))
                        Metric(label: "Réponses", value: "\(s.totals.messages)")
                        Metric(label: "Rythme", value: s.duration > 300 ? Fmt.usd(s.totals.cost.total / s.duration * 3600) + "/h" : "—")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var week: some View {
        let days = Array(snap.last30.suffix(7))
        return Block(title: "Sept derniers jours", note: Fmt.usd(snap.week.cost.total)) {
            Chart(days) { d in
                BarMark(x: .value("Jour", d.day, unit: .day), y: .value("Coût", d.cost), width: .ratio(0.55))
                    .foregroundStyle(Calendar.current.isDateInToday(d.day) ? Theme.clay : Theme.bar)
                    .annotation(position: .top, spacing: 3) {
                        if d.cost > 0 { Text(Fmt.usd(d.cost)).font(Theme.sans(11)).foregroundStyle(Theme.inkFaint) }
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).locale(Locale(identifier: "fr_FR")), centered: true)
                        .font(Theme.sans(11))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 120)
            HStack(spacing: 0) {
                Metric(label: "Moyenne/jour", value: Fmt.usd(snap.week.cost.total / 7))
                Metric(label: "30 jours", value: Fmt.usd(snap.month.cost.total))
                Metric(label: "Éco. cache", value: Fmt.usd(snap.cacheSavings), accent: Theme.sage)
            }
        }
    }

    private var models: some View { ModelsBlock() }

    private var recent: some View {
        Block(title: "Sessions récentes") {
            let recent = Array(snap.sessions.prefix(5))
            let top = recent.map { $0.totals.cost.total }.max() ?? 0
            VStack(spacing: 0) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Rectangle().fill(Theme.rule).frame(height: 0.5) }
                    Button { openSession(s.index) } label: { SessionLine(session: s, scale: top) }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// Cost split into output, cache writes, cache reads and input.
struct SplitBar: View {
    let cost: Pricing.Breakdown

    private var parts: [(String, Double, Color)] {
        var list: [(String, Double, Color)] = [("sortie", cost.output, Theme.clay), ("écriture cache", cost.write, Theme.sand),
                                               ("lecture cache", cost.read, Theme.sage), ("entrée", cost.input, Theme.slate)]
        if cost.other > 0.005 { list.append(("hors journal", cost.other, Theme.inkFaint)) }
        return list
    }

    var body: some View {
        let parts = self.parts
        let total = max(0.0001, cost.total)
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2).frame(width: max(0, (geo.size.width - 6) * p.1 / total))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            FlowRow(parts.map { p in (p.0, Fmt.usd(p.1), p.2) })
        }
    }
}

/// Legend laid out on two columns so nothing gets truncated.
struct FlowRow: View {
    let items: [(String, String, Color)]
    init(_ items: [(String, String, Color)]) { self.items = items }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 5) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(item.2).frame(width: 8, height: 8)
                    Text(item.0).font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft)
                    Spacer(minLength: 4)
                    Text(item.1).font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.ink)
                }
                .padding(.trailing, 8)
            }
        }
    }
}

/// One session: project and branch, time range, duration and model; cost with a comparative bar.
struct SessionLine: View {
    let session: SessionStat
    var scale: Double = 0

    var body: some View {
        let start = Date(timeIntervalSince1970: session.info.first)
        let end = Date(timeIntervalSince1970: session.info.last)
        let model = session.models.max { $0.value < $1.value }.map { Fmt.model($0.key) }
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.displayName).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let branch = session.info.branch, !branch.isEmpty, branch != "HEAD" {
                        Text(branch).font(Theme.sans(10.5, .medium)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.rule.opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                Text([ "\(Fmt.time(start)) → \(Fmt.time(end))", Fmt.duration(session.duration), model ].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(1)
            }
            Spacer(minLength: 8)
            ContextGauge(session: session)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Large ring for one plan limit, with a tick at the alert threshold.
struct LimitRing: View {
    let title: String
    let subtitle: String
    let window: PlanUsage.Window
    let threshold: Double
    var size: CGFloat = 104
    @State private var shown = 0.0

    var body: some View {
        let pct = window.usedPercent
        let alert = pct >= threshold
        let color: Color = alert ? .red : (pct >= threshold * 0.8 ? .orange : Theme.seriesClay)
        VStack(spacing: 12) {
            GaugeRing(fraction: shown / 100, color: color, threshold: threshold / 100, size: size) {
                VStack(spacing: 0) {
                    (Text("\(Int(pct.rounded()))").font(.system(size: size > 95 ? 32 : 26, weight: .semibold).monospacedDigit())
                        .foregroundStyle(alert ? Color.red : Theme.ink)
                     + Text("%").font(.system(size: size > 95 ? 14 : 12, weight: .semibold)).foregroundStyle(Theme.inkSoft))
                    Text("utilisé").font(Theme.sans(10)).foregroundStyle(Theme.inkFaint)
                }
            }
            VStack(spacing: 2) {
                Text(title).font(Theme.sans(13.5, .semibold)).foregroundStyle(Theme.ink)
                Text(window.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR"))))
                    .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.inkSoft)
                Text(Fmt.relative(window.resetsAt)).font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
            }
            .tip(subtitle)
        }
        .frame(maxWidth: .infinity)
        .onAppear { withAnimation(.smooth(duration: 0.9)) { shown = pct } }
        .onChange(of: pct) { _, v in withAnimation(.smooth(duration: 0.6)) { shown = v } }
    }
}

/// Circular gauge: same-hue track, fine graduations, gradient arc with a soft glow, threshold notch.
struct GaugeRing<Center: View>: View {
    let fraction: Double
    let color: Color
    var threshold: Double? = nil
    var size: CGFloat = 104
    var ticks = false
    var lineWidth: CGFloat? = nil
    @ViewBuilder let center: Center

    var body: some View {
        let line: CGFloat = lineWidth ?? (size > 95 ? 11 : 9)
        ZStack {
            Circle().stroke(color.opacity(0.13), lineWidth: line)
            // Optional graduations every 5 %.
            if ticks { ForEach(0..<20, id: \.self) { i in
                Capsule().fill(Theme.inkFaint.opacity(i % 5 == 0 ? 0.55 : 0.25))
                    .frame(width: 1, height: i % 5 == 0 ? 5 : 3)
                    .offset(y: -(size / 2 - line - 6))
                    .rotationEffect(.degrees(Double(i) * 18))
            } }
            Circle()
                .trim(from: 0, to: min(1, fraction))   // nothing drawn at 0 %
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.05, fraction))),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.35), radius: 5)
            if let threshold {
                Capsule().fill(Theme.ink.opacity(0.75))
                    .frame(width: 2.5, height: line + 6)
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(360 * threshold))
            }
            center
        }
        .frame(width: size, height: size)
        .padding(.top, 4)
    }
}

/// Session ring when no 5-hour window is open: 0 %, starts with the next message.
struct IdleSessionRing: View {
    var size: CGFloat = 104
    var body: some View {
        VStack(spacing: 12) {
            GaugeRing(fraction: 0, color: Theme.seriesClay, size: size) {
                VStack(spacing: 0) {
                    (Text("0").font(.system(size: size > 95 ? 32 : 26, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                     + Text("%").font(.system(size: size > 95 ? 14 : 12, weight: .semibold)).foregroundStyle(Theme.inkSoft))
                    Text("utilisé").font(Theme.sans(10)).foregroundStyle(Theme.inkFaint)
                }
            }
            VStack(spacing: 2) {
                Text("Session").font(Theme.sans(13.5, .semibold)).foregroundStyle(Theme.ink)
                Text("au prochain message").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.inkSoft)
                Text(" ").font(Theme.sans(10.5))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Hero ring for the 5-hour session quota.
struct SessionHero: View {
    let window: PlanUsage.Window?
    let threshold: Double
    @State private var shown = 0.0

    var body: some View {
        let pct = window?.usedPercent ?? 0
        let alert = pct >= threshold
        let color: Color = alert ? .red : (pct >= threshold * 0.8 ? .orange : Theme.seriesClay)
        VStack(spacing: 10) {
            GaugeRing(fraction: shown / 100, color: color, threshold: threshold / 100, size: 138, lineWidth: 13) {
                VStack(spacing: 1) {
                    (Text("\(Int(pct.rounded()))").font(.system(size: 42, weight: .semibold).monospacedDigit())
                        .foregroundStyle(alert ? Color.red : Theme.ink)
                     + Text("%").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.inkSoft))
                    Text("session").font(Theme.sans(11, .medium)).foregroundStyle(Theme.inkSoft)
                }
            }
            if let window {
                VStack(spacing: 1) {
                    Text("réinit. \(Fmt.time(window.resetsAt))").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.ink)
                    Text(Fmt.relative(window.resetsAt)).font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
                    if let f = window.forecast, f.atReset >= 5 || f.exhaustion != nil {
                        Text(f.exhaustion.map { "épuisée à \(Fmt.time($0))" } ?? "≈ \(Int(f.atReset.rounded())) % à la réinit.")
                            .font(Theme.sans(10.5, .medium)).monospacedDigit()
                            .foregroundStyle(f.exhaustion != nil ? Color.orange : Theme.sage)
                            .padding(.top, 2)
                            .tip("D'après votre rythme des 45 dernières minutes et celui de la fenêtre en cours.")
                    }
                }
            } else {
                Text("démarre au prochain message").font(Theme.sans(11)).foregroundStyle(Theme.inkFaint)
            }
        }
        .frame(width: 148)
        .onAppear { withAnimation(.smooth(duration: 0.9)) { shown = pct } }
        .onChange(of: pct) { _, v in withAnimation(.smooth(duration: 0.6)) { shown = v } }
    }
}

/// A weekly quota as a compact panel: name, strong value, thick meter with the alert notch, reset.
struct LimitRow: View {
    let window: PlanUsage.Window
    let threshold: Double

    var body: some View {
        let pct = window.usedPercent
        let alert = pct >= threshold
        let color: Color = alert ? .red : (pct >= threshold * 0.8 ? .orange : Theme.seriesClay)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.shortName).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                    Text(window.kind == .week ? "tous modèles" : "semaine").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
                }
                Spacer(minLength: 4)
                (Text("\(Int(pct.rounded()))").font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundStyle(alert ? Color.red : Theme.ink)
                 + Text("%").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.inkSoft))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Bar(fraction: pct / 100, color: color, height: 10)
                    Capsule().fill(Theme.ink.opacity(0.7)).frame(width: 2, height: 16)
                        .offset(x: geo.size.width * threshold / 100 - 1)
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            Text("réinit. \(window.resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR")))) · \(Fmt.relative(window.resetsAt))")
                .font(Theme.sans(10.5)).foregroundStyle(Theme.inkSoft).lineLimit(1).minimumScaleFactor(0.85)
            ProjectionLine(window: window)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.paper.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.rule.opacity(0.7), lineWidth: 0.5))
    }
}

/// Same footprint as LimitRow, greyed while the figure is loading: nothing moves when it arrives.
struct LimitPlaceholder: View {
    let name: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.inkFaint)
                    Text(detail).font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
                }
                Spacer(minLength: 4)
                (Text("—").font(.system(size: 24, weight: .semibold)) + Text("%").font(.system(size: 12, weight: .semibold)))
                    .foregroundStyle(Theme.inkFaint)
            }
            Capsule().fill(Theme.rule.opacity(0.7)).frame(height: 10).frame(height: 16)
            Text("lecture de /usage…").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.paper.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.rule.opacity(0.7), lineWidth: 0.5))
    }
}

/// "Holds until reset" or "runs out Thu 3 pm at this pace", from the average pace since the window started.
struct ProjectionLine: View {
    let window: PlanUsage.Window
    var body: some View {
        if let f = window.forecast {
            let short = f.exhaustion != nil
            HStack(spacing: 4) {
                Image(systemName: short ? "chart.line.downtrend.xyaxis" : "checkmark.circle").font(.system(size: 9.5, weight: .semibold))
                Text(short ? "épuisé \(f.exhaustion!.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(Locale(identifier: "fr_FR"))))"
                           : "≈ \(Int(f.atReset.rounded())) % à la réinit.")
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(Theme.sans(10.5, .medium))
            .foregroundStyle(short ? Color.orange : Theme.sage)
            .tip("Prévision heure par heure jusqu'à la réinitialisation : votre profil d'activité habituel (4 dernières semaines, heure par heure), ajusté à l'intensité de cette semaine, étalonné sur l'évolution réelle du quota. Recalculée toutes les 5 s.")
        }
    }
}
