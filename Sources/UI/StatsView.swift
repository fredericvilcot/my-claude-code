import Charts
import SwiftUI

enum StatsWidget: String, BoardWidget {
    case summary, activity, contributors, models, alltime, calendar, days30, hours, weekdays, projects
    var title: String {
        switch self {
        case .summary: "Résumé du jour"
        case .activity: "Trente derniers jours"
        case .contributors: "Ce qui pèse sur votre usage"
        case .models: "Modèles"
        case .alltime: "Depuis le début"
        case .calendar: "Calendrier"
        case .days30: "Cumul du mois"
        case .hours: "Heures de travail"
        case .weekdays: "Jours de la semaine"
        case .projects: "Projets"
        }
    }
    var symbol: String {
        switch self {
        case .summary: "sum"
        case .activity: "chart.bar"
        case .contributors: "list.bullet.indent"
        case .models: "cpu"
        case .alltime: "infinity"
        case .calendar: "square.grid.3x3"
        case .days30: "chart.line.uptrend.xyaxis"
        case .hours: "clock"
        case .weekdays: "calendar"
        case .projects: "folder"
        }
    }
}

struct StatsView: View {
    @Environment(UsageStore.self) private var store
    private var snap: Snapshot { store.snapshot }

    var body: some View {
        WidgetBoard(orderKey: "stats.order", hiddenKey: "stats.hidden") { (w: StatsWidget) in
            switch w {
            case .summary: PeriodSummaryBlock(period: .today)
            case .activity: activity
            case .contributors: ContributorsBlock()
            case .models: ModelsBlock()
            case .alltime: alltime
            case .calendar: calendar
            case .days30: cumulative
            case .hours: hours
            case .weekdays: weekdays
            case .projects: ProjectsBlock()
            }
        }
    }

    // MARK: Thirty days

    private var activity: some View {
        let days = snap.last30
        let total = days.reduce(0) { $0 + $1.cost }
        let prev7 = days.dropLast(7).suffix(7).reduce(0) { $0 + $1.cost }
        let last7 = days.suffix(7).reduce(0) { $0 + $1.cost }
        return Block(title: "Trente derniers jours", note: "survolez une barre") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.usd(total)).font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                if prev7 > 0 {
                    let d = (last7 - prev7) / prev7
                    Label("\(Fmt.percent(abs(d))) sur 7 j", systemImage: d >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.inkSoft)
                }
            }
            DailyBars(points: days, height: 140)
        }
    }

    // MARK: Cumulative

    private var cumulative: some View {
        var running = 0.0
        let points = snap.last30.map { d -> DayPoint in running += d.cost; return DayPoint(day: d.day, cost: running) }
        return Block(title: "Cumul du mois", note: "30 jours glissants") {
            Chart(points) { p in
                AreaMark(x: .value("Jour", p.day), y: .value("Cumul", p.cost))
                    .foregroundStyle(LinearGradient(colors: [Theme.seriesClay.opacity(0.16), Theme.seriesClay.opacity(0.01)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Jour", p.day), y: .value("Cumul", p.cost))
                    .foregroundStyle(Theme.seriesClay).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                if p.id == points.last?.id {
                    PointMark(x: .value("Jour", p.day), y: .value("Cumul", p.cost))
                        .symbol {
                            Circle().fill(Theme.seriesClay).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Theme.raised, lineWidth: 2))
                        }
                        .annotation(position: .topLeading, spacing: 4) {
                            Text(Viz.compactUSD(p.cost)).font(Theme.sans(11, .semibold)).foregroundStyle(Theme.ink)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
                        .font(Theme.sans(10)).foregroundStyle(Theme.inkFaint)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.rule)
                    AxisValueLabel { if let n = v.as(Double.self) { Text(Viz.compactUSD(n)).font(Theme.sans(9.5)).foregroundStyle(Theme.inkFaint) } }
                }
            }
            .frame(height: 130)
        }
    }

    // MARK: All time

    private var alltime: some View {
        let cacheRate = Double(snap.all.read) / Double(max(1, snap.all.read + snap.all.input + snap.all.write))
        return Block(title: "Depuis le début",
                     note: snap.firstDate.map { "depuis le " + $0.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR"))) }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.usd(snap.all.cost.total)).font(.system(size: 32, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                Text("\(Fmt.tokens(snap.all.tokens)) tokens · \(snap.all.messages) réponses · \(snap.sessions.count) sessions")
                    .font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    StatTile(label: "Jours actifs", value: "\(snap.activeDays)", symbol: "calendar")
                    StatTile(label: "Série", value: "\(snap.streak) j", symbol: "flame.fill")
                    StatTile(label: "Record", value: snap.biggestDay.map { Viz.compactUSD($0.cost) } ?? "—", symbol: "trophy.fill")
                }
                GridRow {
                    StatTile(label: "Par session", value: Viz.compactUSD(snap.all.cost.total / Double(max(1, snap.sessions.count))), symbol: "divide")
                    StatTile(label: "Cache", value: Fmt.percent(cacheRate), symbol: "arrow.triangle.2.circlepath")
                    StatTile(label: "Économie", value: Viz.compactUSD(snap.cacheSavings), symbol: "leaf.fill")
                }
            }
        }
    }

    // MARK: Calendar

    private var calendar: some View {
        let allWeeks = stride(from: 0, to: snap.heat.count, by: 7).map { Array(snap.heat[$0..<min($0 + 7, snap.heat.count)]) }
        let firstActive = allWeeks.firstIndex { $0.contains { $0.cost > 0 } } ?? 0
        let weeks = Array(allWeeks.dropFirst(max(0, min(firstActive - 1, allWeeks.count - 10))))
        let peak = max(0.0001, snap.heat.map(\.cost).max() ?? 1)
        let level: (Double) -> Int = { c in c <= 0 ? 0 : min(4, Int(ceil(sqrt(c / peak) * 4))) }
        let fills: [Color] = [Theme.rule.opacity(0.65), Theme.seriesClay.opacity(0.25), Theme.seriesClay.opacity(0.48),
                              Theme.seriesClay.opacity(0.72), Theme.seriesClay]
        let gap: CGFloat = 4, labelW: CGFloat = 26
        return Block(title: "Calendrier", note: "\(snap.activeDays) jours actifs") {
            GeometryReader { geo in
                let cell = min(26, (geo.size.width - labelW - CGFloat(weeks.count) * gap) / CGFloat(max(1, weeks.count)))
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .leading) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { i, week in
                            let first = week.first?.day ?? Date()
                            let isNew = i == 0 || Calendar.current.component(.month, from: first)
                                != Calendar.current.component(.month, from: weeks[i - 1].first?.day ?? first)
                            if isNew {
                                Text(first.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                                    .font(Theme.sans(10, .medium)).foregroundStyle(Theme.inkFaint).fixedSize()
                                    .offset(x: labelW + gap + CGFloat(i) * (cell + gap))
                            }
                        }
                    }
                    .frame(height: 12)
                    HStack(alignment: .top, spacing: gap) {
                        VStack(alignment: .trailing, spacing: gap) {
                            ForEach(Array(["lun", "", "mer", "", "ven", "", "dim"].enumerated()), id: \.offset) { _, d in
                                Text(d).font(Theme.sans(9.5)).foregroundStyle(Theme.inkFaint).frame(width: labelW, height: cell, alignment: .trailing)
                            }
                        }
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: gap) {
                                ForEach(week) { d in
                                    RoundedRectangle(cornerRadius: cell * 0.24, style: .continuous)
                                        .fill(fills[level(d.cost)])
                                        .frame(width: cell, height: cell)
                                        .overlay {
                                            if Calendar.current.isDateInToday(d.day) {
                                                RoundedRectangle(cornerRadius: cell * 0.24, style: .continuous).strokeBorder(Theme.ink.opacity(0.8), lineWidth: 1.5)
                                            }
                                        }
                                        .tip("\(Fmt.day(d.day)) : \(Fmt.usd(d.cost))")
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 18 + 7 * 26 + 6 * 4)
            HStack(spacing: 4) {
                Spacer()
                Text("moins").font(Theme.sans(10)).foregroundStyle(Theme.inkFaint)
                ForEach(0..<5, id: \.self) { i in RoundedRectangle(cornerRadius: 2.5).fill(fills[i]).frame(width: 10, height: 10) }
                Text("plus").font(Theme.sans(10)).foregroundStyle(Theme.inkFaint)
            }
        }
    }

    // MARK: Hours

    private var hours: some View {
        let values = snap.hours
        let peak = values.enumerated().max { $0.element < $1.element }
        return Block(title: "Heures de travail", note: peak.map { "pic vers \($0.offset) h" }) {
            HourBars(values: values, unit: "coût", height: 96, highlightPeak: true)
        }
    }

    // MARK: Weekdays

    private var weekdays: some View {
        let names = ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"]
        let top = max(0.0001, snap.weekdays.max() ?? 1)
        let best = snap.weekdays.enumerated().max { $0.element < $1.element }?.offset
        return Block(title: "Jours de la semaine", note: best.map { "le \(names[$0].lowercased()) en tête" }) {
            VStack(spacing: 9) {
                ForEach(0..<7, id: \.self) { i in
                    HStack(spacing: 10) {
                        Text(names[i]).font(Theme.sans(12)).foregroundStyle(Theme.ink).frame(width: 74, alignment: .leading)
                        Bar(fraction: snap.weekdays[i] / top, color: i == best ? Theme.seriesClay : Theme.muted, height: 8)
                        Text(Viz.compactUSD(snap.weekdays[i])).font(Theme.sans(12, .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }
}
