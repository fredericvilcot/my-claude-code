import Charts
import SwiftUI

/// Small visualisation kit shared by every widget: stat tiles with deltas, segmented bars, horizontal meters,
/// hairline axes and hover tooltips. Marks carry colour; text always uses ink tokens.
enum Viz {
    /// Bar fills: highlighted (today / now / best), hovered, and the recessive rest.
    static let highlight = LinearGradient(colors: [Theme.seriesClay.opacity(0.8), Theme.seriesClay], startPoint: .top, endPoint: .bottom)
    static let hover = LinearGradient(colors: [Theme.seriesClay.opacity(0.45), Theme.seriesClay.opacity(0.65)], startPoint: .top, endPoint: .bottom)
    static let rest = LinearGradient(colors: [Theme.muted.opacity(0.75), Theme.muted], startPoint: .top, endPoint: .bottom)

    static func compactUSD(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.1f k$", v / 1000).replacingOccurrences(of: ".", with: ",") }
        return "\(Int(v.rounded())) $"
    }
}

/// Stat tile: optional icon, label, strong value, signed delta as a neutral pill.
struct StatTile: View {
    let label: String
    let value: String
    var delta: Double? = nil
    var deltaLabel = "vs hier"
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.seriesClay)
                }
                Text(label).font(Theme.sans(11, .medium)).foregroundStyle(Theme.inkSoft).lineLimit(1)
            }
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let delta, delta.isFinite {
                HStack(spacing: 3) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 8, weight: .heavy))
                    Text("\(Fmt.percent(abs(delta)))").monospacedDigit()
                    Text(deltaLabel).foregroundStyle(Theme.inkFaint)
                }
                .font(Theme.sans(10, .semibold)).foregroundStyle(Theme.inkSoft)
                .padding(.horizontal, 6).padding(.vertical, 2.5)
                .background(Capsule().fill(Theme.ink.opacity(0.06)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.rule.opacity(0.6), lineWidth: 0.5))
    }
}

/// One whole split into parts, 2 pt surface gaps between segments, plus a legend with values.
struct SegmentedBar: View {
    let parts: [(label: String, value: Double, color: Color, text: String)]
    var height: CGFloat = 14

    var body: some View {
        let total = max(0.0001, parts.reduce(0) { $0 + $1.value })
        let visible = parts.filter { $0.value / total >= 0.004 }
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let gaps = CGFloat(max(0, visible.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, p in
                        Rectangle()
                            .fill(LinearGradient(colors: [p.color.opacity(0.85), p.color], startPoint: .top, endPoint: .bottom))
                            .frame(width: max(2, (geo.size.width - gaps) * p.value / total))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            }
            .frame(height: height)
            VStack(spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 8) {
                        Circle().fill(p.color).frame(width: 9, height: 9)
                        Text(p.label).font(Theme.sans(12)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(p.text).font(Theme.sans(12, .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
                        Text(Fmt.percent(p.value / total)).font(Theme.sans(11).monospacedDigit()).foregroundStyle(Theme.inkFaint)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Labelled horizontal meter row (ranked lists).
struct MeterRow: View {
    let label: String
    var sublabel: String? = nil
    let fraction: Double
    let value: String
    var color: Color = Theme.seriesClay

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                if let sublabel { Text(sublabel).font(Theme.sans(11)).foregroundStyle(Theme.inkFaint).lineLimit(1) }
                Spacer(minLength: 8)
                Text(value).font(Theme.sans(12.5, .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            }
            Bar(fraction: fraction, color: color, height: 8)
        }
    }
}

/// Floating tooltip used on chart hover.
struct VizTooltip: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.sans(10.5)).foregroundStyle(Theme.inkSoft)
            Text(value).font(Theme.sans(12.5, .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
    }
}

/// Bars per day (native drawing): rounded data-ends, today highlighted, average rule, hover tooltip.
struct DailyBars: View {
    let points: [DayPoint]
    var height: CGFloat = 130
    var weekdayLabels = false

    var body: some View {
        let fr = Locale(identifier: "fr_FR")
        BarStrip(values: points.map(\.cost),
                 highlight: points.firstIndex { Calendar.current.isDateInToday($0.day) },
                 height: height, showAverage: true,
                 label: { i in
                     let d = points[i].day
                     if weekdayLabels { return d.formatted(.dateTime.weekday(.abbreviated).locale(fr)) }
                     return i % 7 == 0 ? d.formatted(.dateTime.day().month(.abbreviated).locale(fr)) : nil
                 },
                 tooltip: { i in (Fmt.day(points[i].day), Fmt.usd(points[i].cost)) },
                 format: Viz.compactUSD)
    }
}

/// 24 hourly bars (native drawing), current hour or peak highlighted, hover tooltip.
struct HourBars: View {
    let values: [Double]
    var unit = "tokens"
    var height: CGFloat = 100
    var highlightPeak = false

    var body: some View {
        let now = Calendar.current.component(.hour, from: Date())
        let peak = values.enumerated().max { $0.element < $1.element }?.offset
        BarStrip(values: values, highlight: highlightPeak ? peak : now, height: height, showAverage: false,
                 label: { i in i % 6 == 0 ? "\(i) h" : nil },
                 tooltip: { i in ("\(i) h – \(i + 1) h", unit == "tokens" ? "\(Fmt.tokens(Int(values[i]))) tokens" : Fmt.usd(values[i])) },
                 format: { unit == "tokens" ? Fmt.tokens(Int($0)) : Viz.compactUSD($0) })
    }
}

/// Native bar strip shared by the daily and hourly charts.
struct BarStrip: View {
    let values: [Double]
    let highlight: Int?
    var height: CGFloat = 110
    var showAverage = false
    let label: (Int) -> String?
    let tooltip: (Int) -> (String, String)
    let format: (Double) -> String
    @State private var hovered: Int?

    var body: some View {
        let top = max(0.0001, values.max() ?? 1)
        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        VStack(spacing: 6) {
            GeometryReader { geo in
                let n = CGFloat(max(1, values.count))
                let slot = geo.size.width / n
                let barW = min(22, max(3, slot * 0.64))
                ZStack(alignment: .bottomLeading) {
                    // Hairline baseline.
                    Rectangle().fill(Theme.rule).frame(height: 0.5)
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(values.indices, id: \.self) { i in
                            let h = values[i] > 0 ? max(3, geo.size.height * values[i] / top) : 2
                            UnevenRoundedRectangle(topLeadingRadius: min(4, barW / 2), topTrailingRadius: min(4, barW / 2), style: .continuous)
                                .fill(i == highlight ? Viz.highlight : i == hovered ? Viz.hover : Viz.rest)
                                .opacity(values[i] > 0 ? 1 : 0.5)
                                .frame(width: barW, height: h)
                                .frame(width: slot, height: geo.size.height, alignment: .bottom)
                                .contentShape(Rectangle())
                                .onHover { inside in if inside { hovered = i } else if hovered == i { hovered = nil } }
                        }
                    }
                    if showAverage && avg > 0 {
                        let y = geo.size.height * (1 - avg / top)
                        Rectangle().fill(Theme.inkFaint.opacity(0.6)).frame(height: 1).offset(y: -(geo.size.height - y))
                        Text("moy. \(format(avg))").font(Theme.sans(9.5)).foregroundStyle(Theme.inkFaint)
                            .offset(y: -(geo.size.height - y) - 12)
                    }
                    if let i = hovered, i < values.count {
                        let t = tooltip(i)
                        VizTooltip(title: t.0, value: t.1)
                            .fixedSize()
                            .position(x: min(max(60, slot * (CGFloat(i) + 0.5)), geo.size.width - 60),
                                      y: max(18, geo.size.height * (1 - values[i] / top) - 26))
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: height)
            GeometryReader { geo in
                let slot = geo.size.width / CGFloat(max(1, values.count))
                ZStack(alignment: .topLeading) {
                    ForEach(values.indices, id: \.self) { i in
                        if let l = label(i) {
                            Text(l).font(Theme.sans(10)).foregroundStyle(Theme.inkFaint).fixedSize()
                                .position(x: slot * (CGFloat(i) + 0.5), y: 6)
                        }
                    }
                }
            }
            .frame(height: 12)
        }
    }
}
