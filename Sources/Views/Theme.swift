import AppKit
import SwiftUI

/// Editorial, warm visual language: paper background, clay accent, serif figures, monospaced labels.
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    static let paper = dynamic(0xFAF9F5, 0x1F1E1D)
    static let raised = dynamic(0xFFFFFF, 0x2B2A28)
    static let ink = dynamic(0x141413, 0xF5F4EF)
    static let inkSoft = dynamic(0x3D3D3A, 0xD9D6CF)
    static let inkFaint = dynamic(0x6B6963, 0xACA9A1)
    static let rule = dynamic(0xE6E3D9, 0x3C3B38)
    static let clay = Color(nsColor: NSColor(hex: 0xD97757))
    static let clayDeep = dynamic(0xC15F3C, 0xEA9371)
    /// Neutral bars for charts (today stays clay).
    static let bar = dynamic(0xCFCBC1, 0x67645E)
    static let sage = dynamic(0x7C8B6B, 0x9AAA88)
    static let sand = dynamic(0xC9B993, 0xB8A57E)
    static let slate = dynamic(0x6F7A8C, 0x97A2B4)

    /// Display figures and titles: SF Pro, semibold, aligned digits (formerly a serif).
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight == .regular ? .semibold : (weight == .medium ? .semibold : weight)).monospacedDigit()
    }
    /// Amounts: SF Pro with aligned digits (formerly monospaced).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight == .regular ? .medium : weight).monospacedDigit()
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    /// Categorical series palette, validated (lightness, chroma, colour-blind separation) on both surfaces.
    static let seriesClay = dynamic(0xD97757, 0xC96A4C)
    static let seriesBlue = Color(nsColor: NSColor(hex: 0x4F86D9))
    static let seriesGreen = Color(nsColor: NSColor(hex: 0x4E9B5A))
    static let seriesPurple = Color(nsColor: NSColor(hex: 0x9670D6))
    static let seriesAmber = Color(nsColor: NSColor(hex: 0xC08A1E))
    /// Recessive neutral for "the rest" and for non-highlighted bars.
    static let muted = dynamic(0xD9D3C7, 0x55524C)

    static func modelColor(_ id: String) -> Color {
        if id.contains("opus") { return seriesClay }
        if id.contains("sonnet") { return seriesBlue }
        if id.contains("haiku") { return seriesGreen }
        if id.contains("fable") || id.contains("mythos") { return seriesPurple }
        return seriesAmber
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// A section: clay title, optional right note, content on a soft raised panel.
struct Block<Content: View>: View {
    @Environment(\.widgetRemove) private var remove
    @Environment(\.blockFold) private var foldScope
    /// Space-separated fold keys: folded ones, and default-folded ones the user opened.
    @AppStorage("foldedBlocks") private var foldedRaw = ""
    @AppStorage("openedBlocks") private var openedRaw = ""
    let title: String
    var note: String?
    var alert = false
    /// Optional text action at the right of the title (e.g. "Tout effacer").
    var action: (title: String, run: () -> Void)?
    /// Détacher / Rattacher control in the header (state, toggle).
    var detach: (detached: Bool, toggle: () -> Void)?
    @ViewBuilder let content: Content

    /// Cards folded until the user opens them (heavy content in the session sheet).
    static var defaultFolded: Set<String> { ["Messages entre agents", "Coût", "Tokens", "Détails"] }

    private var foldKey: String? { foldScope.map { "\($0).\(title)".replacingOccurrences(of: " ", with: "_") } }
    private var folded: Bool {
        guard let key = foldKey else { return false }
        if Self.defaultFolded.contains(title) { return !openedRaw.split(separator: " ").contains(Substring(key)) }
        return foldedRaw.split(separator: " ").contains(Substring(key))
    }
    private func toggleFold() {
        guard let key = foldKey else { return }
        let isDefault = Self.defaultFolded.contains(title)
        var set = Set((isDefault ? openedRaw : foldedRaw).split(separator: " ").map(String.init))
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(.snappy(duration: 0.22)) {
            if isDefault { openedRaw = set.sorted().joined(separator: " ") } else { foldedRaw = set.sorted().joined(separator: " ") }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: folded ? 0 : 14) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 7) {
                    Circle().fill(alert ? Color.red : Theme.clay).frame(width: 7, height: 7)
                    Text(title).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink).tracking(-0.1)
                    if foldKey != nil {
                        Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.inkFaint)
                            .rotationEffect(.degrees(folded ? 0 : 90))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleFold() }
                Spacer()
                if let note {
                    Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                }
                if let detach {
                    DetachButton(detached: detach.detached, action: detach.toggle)
                        .tip(detach.detached ? "Détaché · cliquer pour fermer la fenêtre flottante" : "Détacher en fenêtre flottante")
                }
                if let action {
                    Button(action: action.run) {
                        Text(action.title).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.clayDeep)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.clay.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.inkFaint)
                            .frame(width: 20, height: 20)
                            .background(Theme.rule.opacity(0.7), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .tip("Retirer ce widget")
                }
            }
            if !folded { content }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised)
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 0.5)
                if alert { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.red.opacity(0.06)) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(alert ? Color.red.opacity(0.35) : Theme.rule, lineWidth: alert ? 1 : 0.5))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

/// Big serif figure with an optional small caption.
struct Figure: View {
    let value: String
    var caption: String?
    var size: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.serif(size, .medium)).foregroundStyle(Theme.ink).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let caption {
                Text(caption).font(Theme.sans(12)).foregroundStyle(Theme.inkSoft)
            }
        }
    }
}

/// Small metric: readable label above a serif value.
struct Metric: View {
    let label: String
    let value: String
    var accent: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.sans(11)).foregroundStyle(Theme.inkSoft).lineLimit(1)
            Text(value).font(Theme.serif(19, .medium)).foregroundStyle(accent ?? Theme.ink).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Horizontal meter: the track is a light step of the fill's own hue, the fill a soft gradient.
struct Bar: View {
    let fraction: Double
    var color: Color = Theme.clay
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.78), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: fraction)
    }
}

/// Chart axis label style shared by every chart.
extension View {
    func editorialChart() -> some View {
        self.chartYAxis(.hidden)
    }
}

/// Simple left-to-right wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
