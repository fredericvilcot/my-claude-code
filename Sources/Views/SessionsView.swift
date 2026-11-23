import AppKit
import Charts
import SwiftUI

/// Period shared by every widget of the Sessions tab.
enum SessionPeriod: Int, CaseIterable {
    case today, week, month, all
    var label: String { ["Aujourd'hui", "7 jours", "30 jours", "Tout"][rawValue] }
    var title: String { ["Aujourd'hui", "7 derniers jours", "30 derniers jours", "Depuis le début"][rawValue] }

    func contains(_ t: Double) -> Bool {
        let d = Date(timeIntervalSince1970: t)
        switch self {
        case .today: return Calendar.current.isDateInToday(d)
        case .week: return d >= Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
        case .month: return d >= Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
        case .all: return true
        }
    }

    func totals(_ snap: Snapshot) -> Totals { [snap.today, snap.week, snap.month, snap.all][rawValue] }
}

struct SessionsView: View {
    @Environment(UsageStore.self) private var store
    @Binding var selected: Int?
    @AppStorage("sessionsPeriod") private var periodRaw = SessionPeriod.week.rawValue

    private var period: SessionPeriod { SessionPeriod(rawValue: periodRaw) ?? .week }

    var body: some View {
        Group {
            if let index = selected, let s = store.snapshot.sessions.first(where: { $0.index == index }) {
                SessionDetailView(session: s, back: { withAnimation(.snappy) { selected = nil } })
            } else {
                list
            }
        }
        // Back from a session (deleted there, or elsewhere): the list re-reads which sessions are deleted.
        .onChange(of: selected) { _, _ in hiddenSessions = SessionFiles.hidden }
    }

    @State private var hiddenSessions = SessionFiles.hidden
    @State private var confirmDeleteAll = false

    private var list: some View {
        let live = store.live
        let hidden = hiddenSessions
        let items = store.snapshot.sessions.filter {
            !hidden.contains($0.info.id) && !SessionLineage.isParked($0.info.id) && (live[$0.info.id] != nil || period.contains($0.info.last))
        }
        // Open sessions by phase (working, waiting, idle), most recent first within each.
        let open = items.filter { live[$0.info.id] != nil }.sorted { $0.info.last > $1.info.last }
        // A session left waiting for over an hour is simply idle (e.g. a background agent that ended its turn days ago).
        let phaseOf: (SessionStat) -> Int? = { s in
            guard let p = live[s.info.id]?.phase else { return nil }
            return p == 1 && Date().timeIntervalSince1970 - s.info.last > 3600 ? 2 : p
        }
        let phases: [(String, Int, [SessionStat])] = [("Actives", 0), ("Attendent votre réponse", 1), ("Au repos", 2)].map { title, phase in
            (title, phase, open.filter { phaseOf($0) == phase })
        }.filter { !$0.2.isEmpty }
        let others = items.filter { live[$0.info.id] == nil }
        let groups = Dictionary(grouping: others.prefix(200)) { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0.info.last)) }
            .sorted { $0.key > $1.key }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SessionPeriod.allCases, id: \.rawValue) { p in
                    Button { withAnimation(.snappy(duration: 0.2)) { periodRaw = p.rawValue } } label: {
                        Text(p.label).font(Theme.sans(12, period == p ? .semibold : .regular))
                            .foregroundStyle(period == p ? Color.white : Theme.inkSoft)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Capsule().fill(period == p ? Theme.clay : Theme.raised))
                            .overlay(Capsule().strokeBorder(period == p ? Color.clear : Theme.rule, lineWidth: 0.5))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(items.count)").font(Theme.sans(12, .medium)).foregroundStyle(Theme.inkSoft)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            // A List (not a stack) for swipe actions: swipe a card left to stop or delete it.
            List {
                ForEach(Array(phases.enumerated()), id: \.element.0) { i, group in
                    PhaseBadge(title: group.0, count: group.2.count, color: PhaseBadge.color(group.1))
                        .padding(.top, i == 0 ? 0 : 8)
                        .listRow()
                    ForEach(group.2) { s in card(s) }
                }
                if !groups.isEmpty {
                    let inactive = Array(others.prefix(200))
                    HStack(spacing: 8) {
                        PhaseBadge(title: "Inactives", count: inactive.count, color: PhaseBadge.color(nil))
                        Spacer()
                        if confirmDeleteAll {
                            Button("annuler") { withAnimation(.snappy) { confirmDeleteAll = false } }
                                .buttonStyle(.plain).font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft)
                            Button {
                                withAnimation(.snappy) {
                                    inactive.forEach(SessionFiles.delete)
                                    hiddenSessions = SessionFiles.hidden
                                    confirmDeleteAll = false
                                }
                            } label: {
                                Text("Supprimer les \(inactive.count)").font(Theme.sans(11.5, .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Color.red))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { withAnimation(.snappy) { confirmDeleteAll = true } } label: {
                                Label("Tout supprimer", systemImage: "trash").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.inkSoft)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Capsule().strokeBorder(Theme.rule, lineWidth: 0.5))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .tip("Place à la Corbeille les journaux des \(inactive.count) sessions inactives de cette période (récupérables).")
                        }
                    }
                    .padding(.top, phases.isEmpty ? 0 : 8)
                    .listRow()
                }
                ForEach(Array(groups.enumerated()), id: \.element.key) { i, entry in
                    let (day, sessions) = entry
                    sectionTitle(Fmt.day(day), count: sessions.count).padding(.top, i == 0 ? 0 : 6).listRow()
                    ForEach(sessions) { s in card(s) }
                }
                if items.isEmpty {
                    Text("Aucune session sur cette période.").font(Theme.sans(13)).foregroundStyle(Theme.inkSoft)
                        .frame(maxWidth: .infinity).padding(.top, 40).listRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
            Text("\(count)").font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 4)
    }

    private func card(_ s: SessionStat) -> some View {
        let live = store.live[s.info.id]
        return Button { withAnimation(.snappy) { selected = s.index } } label: { SessionCard(session: s, live: live) }
            .buttonStyle(.plain)
            .listRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    withAnimation(.snappy) {
                        if let live { SessionFiles.stop(live) }
                        SessionFiles.delete(s)
                        hiddenSessions = SessionFiles.hidden
                    }
                    store.refreshAll()
                } label: { Label("Supprimer", systemImage: "trash") }
                .tint(.red)
                if let live {
                    Button {
                        SessionFiles.stop(live)
                        store.refreshAll()
                    } label: { Label("Arrêter", systemImage: "stop.circle") }
                    .tint(.orange)
                }
            }
            .contextMenu {
                if let live {
                    Button { SessionFiles.stop(live); store.refreshAll() } label: { Label("Arrêter la session", systemImage: "stop.circle") }
                }
                Button(role: .destructive) {
                    withAnimation(.snappy) {
                        if let live { SessionFiles.stop(live) }
                        SessionFiles.delete(s)
                        hiddenSessions = SessionFiles.hidden
                    }
                } label: { Label("Supprimer (Corbeille)", systemImage: "trash") }
            }
    }
}

/// One session card: project, branch, live status and messaging name, time and model, context gauge.
struct SessionCard: View {
    @Environment(UsageStore.self) private var store
    let session: SessionStat
    let live: LiveSession?

    var body: some View {
        let ctx = store.context(of: session)
        let start = Date(timeIntervalSince1970: session.info.first), end = Date(timeIntervalSince1970: session.info.last)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.title(of: session)).font(Theme.sans(14.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                if let b = session.info.branch, !b.isEmpty, b != "HEAD" {
                    Text(b).font(Theme.sans(11, .medium)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.rule.opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Spacer(minLength: 6)
                StatusDot(live: live, last: session.info.last)
            }
            if let live, !live.name.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "at").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.clay)
                    Text(live.name).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.inkSoft)
                        .lineLimit(1).truncationMode(.tail)   // background jobs carry long names: never wrap
                }
            }
            if let live {
                // What the agent is doing right now, on its own full-width row.
                ActivityLine(sessionID: session.info.id, live: live)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.paper))
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Fmt.time(start)) → \(Fmt.time(end)) · \(Fmt.duration(session.duration))")
                    Text("\(Fmt.model(session.lastModel)) · \(session.totals.messages) réponses · \(Fmt.usd(session.totals.cost.total))")
                }
                .font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int((ctx.fraction * 100).rounded())) %").font(Theme.sans(15, .semibold).monospacedDigit())
                        .foregroundStyle(ctx.fraction >= 0.8 ? contextColor(ctx.fraction) : Theme.ink)
                    Bar(fraction: ctx.fraction, color: contextColor(ctx.fraction), height: 5).frame(width: 76)
                    Text("contexte").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(live != nil ? Theme.clay.opacity(0.45) : Theme.rule, lineWidth: live != nil ? 1 : 0.5))
        .contentShape(Rectangle())
    }
}

struct StatusDot: View {
    let live: LiveSession?
    var last: Double = Date().timeIntervalSince1970

    /// Waiting for over an hour reads as idle, like the list sections.
    private var stale: Bool { live?.phase == 1 && Date().timeIntervalSince1970 - last > 3600 }

    var body: some View {
        let color = PhaseBadge.color(stale ? 2 : live?.phase)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(live.map { (stale ? "au repos" : $0.label) + ($0.kind == "background" ? " · fond" : "") } ?? "inactive")
                .font(Theme.sans(11, .semibold)).foregroundStyle(color).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct PeriodSummaryBlock: View {
    @Environment(UsageStore.self) private var store
    let period: SessionPeriod

    var body: some View {
        let snap = store.snapshot
        let t = period.totals(snap)
        let y = snap.yesterday
        let delta: (Double, Double) -> Double? = { a, b in period == .today && b > 0 ? (a - b) / b : nil }
        Block(title: period.title, note: "équivalent tarif API") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.usd(t.cost.total)).font(.system(size: 30, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                if let d = delta(t.cost.total, y.cost.total) {
                    Label("\(Fmt.percent(abs(d))) vs hier", systemImage: d >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.inkSoft)
                }
            }
            Grid(horizontalSpacing: 8) {
                GridRow {
                    StatTile(label: "Tokens", value: Fmt.tokens(t.tokens), delta: delta(Double(t.tokens), Double(y.tokens)))
                    StatTile(label: "Réponses", value: "\(t.messages)", delta: delta(Double(t.messages), Double(y.messages)))
                    StatTile(label: "Sessions", value: "\(t.sessions.count)", delta: delta(Double(t.sessions.count), Double(y.sessions.count)))
                }
            }
            SegmentedBar(parts: [
                (label: "Lecture du cache", value: t.cost.read, color: Theme.seriesGreen, text: Viz.compactUSD(t.cost.read)),
                (label: "Écriture du cache", value: t.cost.write, color: Theme.seriesAmber, text: Viz.compactUSD(t.cost.write)),
                (label: "Sortie", value: t.cost.output, color: Theme.seriesClay, text: Viz.compactUSD(t.cost.output)),
                (label: "Entrée", value: t.cost.input, color: Theme.seriesBlue, text: Viz.compactUSD(t.cost.input)),
            ] + (t.cost.other > 0.005 ? [(label: "Hors journal", value: t.cost.other, color: Theme.muted, text: Viz.compactUSD(t.cost.other))] : []))
        }
    }
}

struct PeriodChartBlock: View {
    @Environment(UsageStore.self) private var store
    let period: SessionPeriod

    var body: some View {
        let snap = store.snapshot
        Block(title: period == .today ? "Activité heure par heure" : "Activité jour par jour", note: "survolez une barre") {
            if period == .today {
                HourBars(values: snap.todayHours.map(Double.init), unit: "tokens")
            } else {
                DailyBars(points: period == .week ? Array(snap.last30.suffix(7)) : snap.last30, height: 130, weekdayLabels: period == .week)
            }
        }
    }
}

struct SessionDetailView: View {
    @Environment(UsageStore.self) private var store
    let session: SessionStat
    let back: () -> Void
    @State private var points: [(Date, Double)] = []
    @State private var confirmTrash = false
    @State private var feedback: String?

    var body: some View {
        VStack(spacing: 0) {
            stickyHeader
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // The session's terminal, mirrored live from its iTerm tab (accordion with the messages below).
                Block(title: "Terminal", note: store.live[session.info.id] != nil ? "clic pour taper" : "journal") {
                    TerminalMirrorView(session: session, live: store.live[session.info.id])
                }
                .padding(.top, 10)
                ChatPanel(session: session)
                Block(title: "Contexte", note: store.context(of: session).exact ? "exact" : "d'après le journal") {
                    let ctx = store.context(of: session)
                    HStack(alignment: .lastTextBaseline) {
                        Figure(value: "\(Int((ctx.fraction * 100).rounded())) %", caption: "\(Fmt.tokens(session.lastContext)) sur \(Fmt.tokens(session.contextWindow)) tokens", size: 40)
                        Spacer()
                        Text("reste \(Int(((1 - ctx.fraction) * 100).rounded())) %\navant compaction").font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
                            .multilineTextAlignment(.trailing)
                    }
                    Bar(fraction: ctx.fraction, color: contextColor(ctx.fraction), height: 9)
                    if let live = store.live[session.info.id] {
                        SessionActions(session: session, live: live, compact: false)
                    }
                }
                Block(title: "Coût", note: Fmt.duration(session.duration)) {
                    Figure(value: Fmt.usd(session.totals.cost.total), size: 40)
                    Text(session.official != nil
                         ? "Coût officiel calculé par Claude Code, dont \(Fmt.usd(session.totals.cost.other)) hors journal (classificateur du mode automatique, tâches de fond)."
                         : "Estimation tirée du journal : Claude Code n'a pas transmis son coût officiel pour cette session.")
                        .font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                    Chart(points, id: \.0) { p in
                        AreaMark(x: .value("t", p.0), y: .value("$", p.1))
                            .foregroundStyle(LinearGradient(colors: [Theme.clay.opacity(0.25), Theme.clay.opacity(0)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("t", p.0), y: .value("$", p.1)).foregroundStyle(Theme.clay)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .frame(height: 70)
                    Text("Coût cumulé au fil de la session").font(Theme.sans(11)).foregroundStyle(Theme.inkFaint)
                    SplitBar(cost: session.totals.cost)
                }
                Block(title: "Tokens", note: Fmt.tokens(session.totals.tokens)) {
                    HStack(spacing: 0) {
                        Metric(label: "Entrée", value: Fmt.tokens(session.totals.input))
                        Metric(label: "Sortie", value: Fmt.tokens(session.totals.output))
                        Metric(label: "Écr. cache", value: Fmt.tokens(session.totals.write))
                        Metric(label: "Lect. cache", value: Fmt.tokens(session.totals.read))
                    }
                }
                Block(title: "Actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        if store.live[session.info.id] == nil {
                            ActionTile(title: "Reprendre dans iTerm", detail: "nouvel onglet dans la fenêtre à raccourci", symbol: "plus.rectangle.on.rectangle") {
                                feedback = "Ouverture dans iTerm…"
                                SessionLauncher.openInITerm(session) { error in feedback = error }
                            }
                        }
                        ActionTile(title: "Copier la commande de reprise", detail: "claude --resume dans le bon dossier", symbol: "doc.on.doc", tint: Theme.inkSoft) {
                            SessionFiles.copyResumeCommand(for: session)
                            feedback = "Commande copiée : collez-la dans votre terminal."
                        }
                        ActionTile(title: "Afficher le journal dans le Finder", detail: "fichier .jsonl de la session", symbol: "folder", tint: Theme.inkSoft) {
                            SessionFiles.reveal(SessionFiles.files(for: session.info.id))
                        }
                        if confirmTrash {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Supprimer cette session ?").font(Theme.serif(15, .medium)).foregroundStyle(Theme.ink)
                                Text("Elle ne pourra plus être reprise avec claude --resume, sauf à la restaurer depuis la Corbeille. Son coût reste dans vos statistiques.")
                                    .font(Theme.sans(12)).foregroundStyle(Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 16) {
                                    Button("annuler") { confirmTrash = false }.buttonStyle(.plain).font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
                                    Button("supprimer") {
                                        // Same as the list: a session still running is stopped before its transcript goes.
                                        if let live = store.live[session.info.id] { SessionFiles.stop(live) }
                                        SessionFiles.delete(session)
                                        store.refreshAll()
                                        confirmTrash = false
                                        back()
                                    }
                                    .buttonStyle(.plain).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.clayDeep)
                                }
                            }
                            .padding(12)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                        } else if Date().timeIntervalSince1970 - session.info.last > 3600 {
                            ActionTile(title: "Supprimer la session", detail: "journal placé à la Corbeille, récupérable", symbol: "trash", destructive: true) {
                                confirmTrash = true
                            }
                        }
                        if let feedback {
                            Text(feedback).font(Theme.sans(11.5)).foregroundStyle(Theme.sage)
                        }
                    }
                }
                Block(title: "Détails") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                        row("début", Date(timeIntervalSince1970: session.info.first).formatted(date: .abbreviated, time: .shortened))
                        row("fin", Date(timeIntervalSince1970: session.info.last).formatted(date: .abbreviated, time: .shortened))
                        if let b = session.info.branch, !b.isEmpty { row("branche", b) }
                        row("réponses", "\(session.totals.messages)")
                        row("modèles", session.models.sorted { $0.value > $1.value }.map { "\(Fmt.model($0.key)) \(Fmt.usd($0.value))" }.joined(separator: "\n"))
                        row("session", session.info.id)
                    }
                }
            }
        }
        .environment(\.blockFold, "session")
        .scrollIndicators(.never)
        }
        .task(id: session.index) {
            AttentionCenter.shared.markSeen(session: session.info.id)
            points = await store.costCurve(ofSession: session.index)
        }
    }


    /// Always visible, even in a small floating window: where you are (session, status, messaging name),
    /// back to the list, and follow in a floating window.
    private var stickyHeader: some View {
        let live = store.live[session.info.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.inkSoft)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.raised))
                        .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .tip("Retour aux sessions")
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.title(of: session)).font(Theme.sans(16, .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let origin = SessionLineage.origin(of: session.info.id) {
                        Text("Reprise en arrière-plan de \(origin.name.isEmpty ? "la session d'origine" : origin.name) (onglet iTerm)")
                            .font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint).lineLimit(1)
                    } else {
                        Text(session.info.project).font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 6)
                if live != nil { FollowButton(sessionID: session.info.id) }
            }
            HStack(spacing: 8) {
                StatusDot(live: live, last: session.info.last)
                if let b = session.info.branch, !b.isEmpty, b != "HEAD" {
                    Label(b, systemImage: "arrow.triangle.branch").font(Theme.sans(11)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let name = live?.name, !name.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(name, forType: .string)
                    } label: {
                        HStack(spacing: 3) {
                            Text("@" + name).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                            Image(systemName: "doc.on.doc").font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                        }
                    }
                    .buttonStyle(.plain)
                    .tip("Nom de messagerie de la session : cliquer pour le copier")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 0.5) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.inkFaint)
            Text(value).font(Theme.sans(11.5)).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Type or dictate a prompt and send it to this session, invisibly (see PromptSender).
@MainActor
struct PromptComposer: View {
    @Environment(UsageStore.self) private var store
    let session: SessionStat
    @State private var center = SendCenter.shared
    @State private var dictation = Dictation()
    @State private var pickerOpen = false

    var body: some View {
        let live = store.live[session.info.id]
        let others = store.live.values.filter {
            // Interactive sessions only: no background agents, no My Claude Code relays.
            $0.sessionId != session.info.id && !$0.name.isEmpty && !$0.name.hasPrefix("my-claude-code")
        }.sorted { $0.name < $1.name }
        let recipientID = center.recipients[session.info.id]
        let recipient = recipientID.flatMap { store.live[$0] }
        let text = Binding(get: { center.drafts[session.info.id] ?? "" }, set: { center.drafts[session.info.id] = $0.isEmpty ? nil : $0 })
        Block(title: "Envoyer un prompt", note: recipient != nil || live != nil ? "message direct" : "relance en arrière-plan") {
            RecipientPicker(selfName: live?.name ?? session.displayName, others: others,
                            recipientID: Binding(get: { center.recipients[session.info.id] }, set: { center.recipients[session.info.id] = $0 }),
                            open: $pickerOpen)
            ClayTextField(text: text, placeholder: dictation.isRecording ? "Je vous écoute…" : "Votre instruction pour cette session…",
                          minLines: 3, maxLines: 8, onSubmit: { send(text.wrappedValue, live: recipient ?? live) })
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(dictation.isRecording ? Color.red.opacity(0.6) : Theme.rule, lineWidth: dictation.isRecording ? 1.5 : 0.5))
            HStack(spacing: 10) {
                Button { dictation.toggle() } label: {
                    Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(dictation.isRecording ? Color.red : Theme.clay)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill((dictation.isRecording ? Color.red : Theme.clay).opacity(0.13)))
                }
                .buttonStyle(.plain)
                .tip(dictation.isRecording ? "Arrêter la dictée" : "Dicter le prompt")
                Spacer()
                Button { send(text.wrappedValue, live: recipient ?? live) } label: {
                    HStack(spacing: 6) {
                        Text("Envoyer").font(Theme.sans(13, .semibold))
                        Image(systemName: "paperplane.fill").font(.system(size: 11))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.inkFaint : Theme.clay))
                }
                .buttonStyle(.plain)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = dictation.error {
                Text(error).font(Theme.sans(11.5)).foregroundStyle(.orange)
            }
            let jobs = center.jobs(for: session.info.id)
            let done = jobs.filter { !$0.isRunning }.prefix(10)
            if !done.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Historique des envois").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.inkSoft).padding(.top, 4)
                    ForEach(Array(done)) { job in SentRow(job: job) }
                }
            }
        }
        .onChange(of: dictation.transcript) { _, t in if dictation.isRecording { center.drafts[session.info.id] = t } }
    }

    private func send(_ prompt: String, live: LiveSession?) {
        dictation.stop()
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        center.send(p, from: session, to: live)
    }
}

/// Custom recipient selector: a chip showing who receives the prompt, unfolding into a list of running sessions.
struct RecipientPicker: View {
    @Environment(UsageStore.self) private var store
    let selfName: String
    let others: [LiveSession]
    /// Recent closed sessions: writing to one relaunches it in the background with its history.
    var closed: [SessionStat] = []
    @Binding var recipientID: String?
    @Binding var open: Bool

    var body: some View {
        let current = recipientID.flatMap { id in others.first { $0.sessionId == id } }
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Text("À").font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
                    Circle().fill(current.map(Self.color) ?? Theme.clay).frame(width: 7, height: 7)
                    Text(current?.name ?? "\(selfName) (cette session)")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    if !others.isEmpty || !closed.isEmpty {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.inkSoft)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(open ? Theme.clay.opacity(0.6) : Theme.rule, lineWidth: open ? 1 : 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(others.isEmpty && closed.isEmpty)

            if open {
                VStack(spacing: 0) {
                    option(id: nil, name: "\(selfName)", subtitle: "cette session", color: Theme.clay)
                    ForEach(others, id: \.sessionId) { o in
                        Rectangle().fill(Theme.rule).frame(height: 0.5).padding(.leading, 34)
                        option(id: o.sessionId, name: o.name, subtitle: subtitle(o), color: Self.color(o))
                    }
                    if !closed.isEmpty {
                        Text("SESSIONS FERMÉES · RELANCÉES EN ARRIÈRE-PLAN").font(Theme.sans(9.5, .bold)).tracking(0.5)
                            .foregroundStyle(Theme.inkFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                        ForEach(closed) { s in
                            option(id: s.info.id, name: s.displayName,
                                   subtitle: [s.info.branch, OverviewView.ago(Date(timeIntervalSince1970: s.info.last))].compactMap { $0 }.joined(separator: " · "),
                                   color: Color.gray)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func subtitle(_ o: LiveSession) -> String {
        var parts = [o.label]
        if let stat = store.snapshot.sessions.first(where: { $0.info.id == o.sessionId }) {
            parts.insert(stat.name, at: 0)
            parts.append("contexte \(Int((store.context(of: stat).fraction * 100).rounded())) %")
        }
        return parts.joined(separator: " · ")
    }

    private func option(id: String?, name: String, subtitle: String, color: Color) -> some View {
        let selected = recipientID == id
        return Button {
            recipientID = id
            withAnimation(.snappy(duration: 0.2)) { open = false }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(subtitle).font(Theme.sans(11)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.clay) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(selected ? Theme.clay.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRow())
    }

    static func color(_ o: LiveSession) -> Color { o.phase == 0 ? .green : o.phase == 2 ? Theme.sage : .orange }
}

/// Subtle hover highlight for list rows.
struct HoverRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Theme.ink.opacity(configuration.isPressed ? 0.08 : hovering ? 0.04 : 0))
                .onHover { hovering = $0 }
        }
    }
}

/// In-flight send: step, elapsed time, prompt excerpt. Refreshes every half second.
struct SendingCard: View {
    let job: SendJob
    var body: some View {
        TimelineView(.whileShown(0.5)) { _ in
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.stepLabel).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(Int(job.duration)) s").font(Theme.sans(12).monospacedDigit()).foregroundStyle(Theme.inkSoft)
                    }
                    Text("à \(job.recipient) · « \(job.prompt.prefix(70))\(job.prompt.count > 70 ? "…" : "") »")
                        .font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(2)
                    Text("Vous pouvez fermer le panneau : l'envoi continue.").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.clay.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.clay.opacity(0.3), lineWidth: 0.5))
        }
    }
}

/// One finished send in the session's history.
struct SentRow: View {
    let job: SendJob
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: job.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(job.succeeded ? Color.green : Color.red).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.summary).font(Theme.sans(12, .medium)).foregroundStyle(Theme.ink).lineLimit(2)
                Text("« \(job.prompt.prefix(80))\(job.prompt.count > 80 ? "…" : "") »").font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(2)
                Text("\(Fmt.time(job.started)) · \(Int(job.duration)) s").font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
            }
        }
    }
}

/// Colored section badge for a session phase: green working, orange waiting, sage idle, grey inactive.
struct PhaseBadge: View {
    let title: String
    let count: Int
    let color: Color

    static func color(_ phase: Int?) -> Color {
        switch phase {
        case 0: .green
        case 1: .orange
        case 2: Theme.sage
        default: Color.gray
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(Theme.sans(12.5, .semibold))
            Text("\(count)").font(Theme.sans(11.5, .bold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.18)))
        }
        .foregroundStyle(color)
        .padding(.leading, 9).padding(.trailing, 5).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .padding(.horizontal, 2)
    }
}

/// Live activity of an open session, styled like a terminal log: past actions top to bottom with their time,
/// the current one at the bottom with a running timer and a blinking cursor. Click a line to unfold its full
/// command or path; hover to copy it.
struct ActivityBlock: View {
    let sessionID: String
    let live: LiveSession

    var body: some View {
        Block(title: "Activité", note: "en direct") { TerminalLog(sessionID: sessionID, live: live) }
    }
}

/// The terminal-styled log itself (used in the session sheet and in the floating "follow" window).
struct TerminalLog: View {
    let sessionID: String
    let live: LiveSession
    var limit = 8
    @State private var expanded: Set<String> = []

    var body: some View {
            TimelineView(.whileShown(0.5)) { context in
                let current = ActivityReader.activity(for: sessionID)
                let working = live.phase == 0 && (current?.working ?? true)
                var past = ActivityReader.recent(for: sessionID, limit: limit)
                let _ = {
                    if working, let c = current, let first = past.first, first.since == c.since, first.text == c.text { past.removeFirst() }
                }()
                let blink = Int(context.date.timeIntervalSince1970 * 2) % 2 == 0
                VStack(alignment: .leading, spacing: 0) {
                    if past.isEmpty && current == nil {
                        Text("Aucune action pour l'instant.").font(Term.mono(11.5)).foregroundStyle(Term.dim)
                    }
                    ForEach(Array(past.reversed().enumerated()), id: \.offset) { _, a in
                        TermLine(activity: a, expanded: expanded.contains(key(a))) { toggle(a) }
                    }
                    Rectangle().fill(Term.rule).frame(height: 0.5).padding(.vertical, 6)
                    if working, let c = current {
                        TermCurrent(activity: c, blink: blink)
                    } else {
                        HStack(spacing: 6) {
                            Text("❯").foregroundStyle(Term.green)
                            Text(idleText(current)).foregroundStyle(Term.dim)
                            Text("▋").foregroundStyle(Term.text).opacity(blink ? 1 : 0)
                        }
                        .font(Term.mono(11.5))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Term.background))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            }
    }

    private func key(_ a: SessionActivity) -> String { "\(a.since.timeIntervalSince1970)-\(a.text)" }
    private func toggle(_ a: SessionActivity) {
        withAnimation(.snappy(duration: 0.2)) {
            if expanded.contains(key(a)) { expanded.remove(key(a)) } else { expanded.insert(key(a)) }
        }
    }
    private func idleText(_ a: SessionActivity?) -> String {
        guard let a else { return "au repos" }
        let since = Fmt.duration(max(0, Date().timeIntervalSince(a.since)))
        return live.phase == 1 ? "attend votre réponse · \(since)" : "au repos · \(since)"
    }
}

/// Terminal palette: the same dark surface in light and dark mode.
enum Term {
    static let background = Color(red: 0.118, green: 0.110, blue: 0.102)
    static let text = Color(red: 0.91, green: 0.90, blue: 0.87)
    static let dim = Color(red: 0.56, green: 0.54, blue: 0.50)
    static let rule = Color.white.opacity(0.09)
    static let green = Color(red: 0.55, green: 0.78, blue: 0.52)
    static let amber = Color(red: 0.88, green: 0.70, blue: 0.40)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    static func glyph(_ tool: String) -> (String, Color) {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": ("pencil", amber)
        case "Bash": ("terminal", green)
        case "Read": ("eye", Color(red: 0.50, green: 0.66, blue: 0.88))
        case "Grep", "Glob", "WebSearch": ("magnifyingglass", Color(red: 0.71, green: 0.60, blue: 0.88))
        case "Agent", "Task", "Workflow": ("person.2", Color(red: 0.85, green: 0.47, blue: 0.34))
        case "WebFetch": ("globe", Color(red: 0.50, green: 0.66, blue: 0.88))
        case "SendMessage": ("paperplane", Color(red: 0.85, green: 0.47, blue: 0.34))
        case "TodoWrite": ("checklist", dim)
        default: ("gearshape", dim)
        }
    }

    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) }
}

private struct TermLine: View {
    let activity: SessionActivity
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let (symbol, color) = Term.glyph(activity.tool)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(Term.time(activity.since)).font(Term.mono(10.5)).foregroundStyle(Term.dim)
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Term.green.opacity(0.8))
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color).frame(width: 12)
                Text(activity.text).font(Term.mono(11.5)).foregroundStyle(Term.text.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 4)
                if hovering, let d = activity.detail, !d.isEmpty { CopyGlyph(text: d) }
            }
            if let p = activity.precision, !p.isEmpty {
                Text(p).font(Term.mono(10.5)).foregroundStyle(Term.dim).lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 74)
            }
            if expanded, let d = activity.detail, !d.isEmpty {
                Text((activity.tool == "Bash" ? "$ " : "") + d)
                    .font(Term.mono(10.5)).foregroundStyle(Term.dim)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 74)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.white.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
    }
}

private struct TermCurrent: View {
    let activity: SessionActivity
    let blink: Bool
    @State private var showFull = false

    var body: some View {
        let (symbol, color) = Term.glyph(activity.tool)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(Term.amber).frame(width: 7, height: 7).opacity(blink ? 1 : 0.35)
                Text("EN COURS").font(Term.mono(10, .bold)).foregroundStyle(Term.amber)
                Spacer()
                Text(Fmt.duration(max(0, Date().timeIntervalSince(activity.since)))).font(Term.mono(11, .semibold)).foregroundStyle(Term.amber)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: activity.tool.isEmpty ? "ellipsis" : symbol).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(activity.tool.isEmpty ? Term.dim : color).frame(width: 12)
                Text(activity.text).font(Term.mono(12.5, .semibold)).foregroundStyle(Term.text).fixedSize(horizontal: false, vertical: true)
            }
            if let p = activity.precision, !p.isEmpty {
                Text(p).font(Term.mono(11)).foregroundStyle(Term.text.opacity(0.7)).lineLimit(2)
                    .padding(.leading, 19)
            }
            if let d = activity.detail, !d.isEmpty {
                Button { withAnimation(.snappy(duration: 0.2)) { showFull.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(showFull ? 90 : 0))
                        Text(showFull ? "masquer le détail" : (activity.tool == "Bash" ? "voir la commande" : "voir le détail"))
                    }
                    .font(Term.mono(10)).foregroundStyle(Term.dim).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.leading, 19)
            }
            if showFull, let d = activity.detail, !d.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    (Text(activity.tool == "Bash" ? "$ " : "").foregroundStyle(Term.green)
                     + Text(d).foregroundStyle(Term.text.opacity(0.75))
                     + Text(" ▋").foregroundStyle(blink ? Term.text : .clear))
                        .font(Term.mono(11)).lineLimit(8).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    CopyGlyph(text: d)
                }
                .padding(.leading, 19)
            }
        }
    }
}

private struct CopyGlyph: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(copied ? Term.green : Term.dim)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip("Copier")
    }
}

extension View {
    /// Plain list row: no separator, no inset, transparent background (cards draw their own).
    func listRow() -> some View {
        self.listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
