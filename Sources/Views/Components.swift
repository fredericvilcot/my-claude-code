import AppKit
import Charts
import SwiftUI

private struct WidgetRemoveKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct BlockFoldKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// When set (a scope name, e.g. "session"), cards can be folded by clicking their title; the state is remembered.
    var blockFold: String? {
        get { self[BlockFoldKey.self] }
        set { self[BlockFoldKey.self] = newValue }
    }

    /// When set, cards show a built-in remove button in their header.
    var widgetRemove: (() -> Void)? {
        get { self[WidgetRemoveKey.self] }
        set { self[WidgetRemoveKey.self] = newValue }
    }
}

/// Discreet remove button that lives inside a card header.
struct WidgetRemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tip("Retirer ce widget de l'aperçu")
    }
}


struct Card<Content: View>: View {
    @Environment(\.widgetRemove) private var remove
    let title: String
    let symbol: String
    let tint: Color
    var trailing: String?
    var trailingSymbol: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let remove { WidgetRemoveButton(action: remove) }
            }
            content
        }
        .padding(13)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.05), tint.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.13), Color.primary.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
    }
}

/// Rounded, tinted badge used for every small piece of metadata.

struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .gray
    var small = false

    var body: some View {
        HStack(spacing: 3.5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: small ? 8 : 9, weight: .bold))
            }
            Text(text).font(.system(size: small ? 9.5 : 10.5, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .foregroundStyle(tint == .gray ? Color.secondary : tint)
        .padding(.horizontal, small ? 6 : 8)
        .padding(.vertical, small ? 2 : 3.5)
        .background(Capsule().fill(tint.opacity(tint == .gray ? 0.12 : 0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }
}


struct RingGauge: View {
    let value: Double          // 0...1
    let text: String
    let label: String
    let colors: [Color]
    var symbol: String?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().inset(by: 3).stroke(Color.primary.opacity(0.08), lineWidth: 6)
                Circle().inset(by: 3)
                    .trim(from: 0, to: max(0.005, min(1, value)))
                    .stroke(AngularGradient(colors: colors + [colors.first!], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, value))),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(text)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
            }
            .frame(width: 58, height: 58)
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.tertiary) }
                Text(label).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}


struct Sparkline: View {
    let samples: [Sample]
    let tint: Color
    var domain: ClosedRange<Double>?

    var body: some View {
        let scale = domain ?? 0...max(1, (samples.map(\.value).max() ?? 1) * 1.15)
        Chart(samples) { s in
            AreaMark(x: .value("t", s.date), yStart: .value("v", scale.lowerBound), yEnd: .value("v", max(scale.lowerBound, s.value)))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.38), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", s.date), y: .value("v", s.value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: scale)
        .chartLegend(.hidden)
        .clipped()
    }
}


struct MeterBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient)
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.smooth, value: fraction)
    }
}


struct BigValue: View {
    let value: String
    var unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            if let unit { Text(unit).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary) }
        }
        .contentTransition(.numericText())
    }
}


struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 2)
            Text(text).font(.system(size: 10.5, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.13)))
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}


struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
        }
    }
}



/// Modern tinted action tile: icon above label, soft tinted background, hover and press feedback.
struct ActionTileStyle: ButtonStyle {
    var tint: Color = .accentColor
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct Tile: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .labelStyle(TileLabelStyle(tint: prominent ? .white : tint))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 6)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(hovering ? 0.2 : 0.12)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(tint.opacity(prominent ? 0 : hovering ? 0.45 : 0.22), lineWidth: 1)
                }
                .shadow(color: prominent ? tint.opacity(0.35) : .clear, radius: 6, y: 2)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.18), value: hovering)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
        }
    }

    private struct TileLabelStyle: LabelStyle {
        let tint: Color
        func makeBody(configuration: Configuration) -> some View {
            VStack(spacing: 5) {
                configuration.icon
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(height: 18)
                configuration.title
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}

/// SwiftUI text fields edit through an NSTextView (field editor) that paints an opaque white background
/// when focused, which showed as an offset white box inside our rounded fields. Keep it transparent.
extension NSTextView {
    open override var frame: CGRect {
        didSet { if drawsBackground, isFieldEditor { drawsBackground = false } }
    }
}
