import SwiftUI

/// A widget kind that can be placed on a board (an enum with a String raw value).
protocol BoardWidget: Hashable, Identifiable, CaseIterable, RawRepresentable where RawValue == String, AllCases == [Self] {
    var title: String { get }
    var symbol: String { get }
    /// Pinned widgets stay first, can't be dragged or removed.
    var pinned: Bool { get }
}

extension BoardWidget {
    var id: String { rawValue }
    var pinned: Bool { false }
}

/// Vertical board of widgets: drag a card by its handle, remove it with ✕, add it back with "+ Ajouter".
/// Order and visibility are persisted per board.
struct WidgetBoard<W: BoardWidget, Content: View>: View {
    @AppStorage private var orderRaw: String
    @AppStorage private var hiddenRaw: String
    private let isAvailable: (W) -> Bool
    private let content: (W) -> Content

    @State private var liveOrder: [W]?
    @State private var dragged: W?
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartMinY: CGFloat = 0
    @State private var dragBase: CGFloat = 0
    @State private var frames: [String: CGRect] = [:]
    @State private var showPicker = false

    init(orderKey: String, hiddenKey: String, defaultHidden: Set<W> = [],
         isAvailable: @escaping (W) -> Bool = { _ in true }, @ViewBuilder content: @escaping (W) -> Content) {
        _orderRaw = AppStorage(wrappedValue: "", orderKey)
        _hiddenRaw = AppStorage(wrappedValue: W.allCases.filter(defaultHidden.contains).map(\.rawValue).joined(separator: ","), hiddenKey)
        self.isAvailable = isAvailable
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(visible) { w in
                    content(w)
                        .overlay(alignment: .top) {
                            if !w.pinned { BoardHandle(active: dragged == w).padding(.top, 12).gesture(drag(w)) }
                        }
                        .environment(\.widgetRemove, w.pinned ? nil : { hide(w) })
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BoardFramesKey.self, value: [w.rawValue: g.frame(in: .named("board"))])
                        })
                        .modifier(BoardLift(active: dragged == w))
                        .offset(y: dragged == w ? dragOffset : 0)
                        .zIndex(dragged == w ? 1 : 0)
                }
                addSection
            }
            .padding(.bottom, 12)
            .coordinateSpace(name: "board")
            .onPreferenceChange(BoardFramesKey.self) { frames = $0 }
        }
        .scrollIndicators(.never)
    }

    // MARK: State

    private var fullOrder: [W] {
        if let liveOrder { return liveOrder }
        var list = orderRaw.split(separator: ",").compactMap { W(rawValue: String($0)) }
        for w in W.allCases where !list.contains(w) { list.append(w) }
        return list
    }
    private var hidden: Set<W> { Set(hiddenRaw.split(separator: ",").compactMap { W(rawValue: String($0)) }) }
    private var visible: [W] {
        let shown = fullOrder.filter { ($0.pinned || !hidden.contains($0)) && isAvailable($0) }
        return shown.filter(\.pinned) + shown.filter { !$0.pinned }
    }
    private var removed: [W] { fullOrder.filter { hidden.contains($0) && !$0.pinned } }

    private func setHidden(_ h: Set<W>) { hiddenRaw = W.allCases.filter(h.contains).map(\.rawValue).joined(separator: ",") }
    private func hide(_ w: W) { var h = hidden; h.insert(w); withAnimation(.snappy) { setHidden(h) } }
    private func show(_ w: W) {
        var h = hidden; h.remove(w)
        withAnimation(.snappy) { setHidden(h); if h.isEmpty { showPicker = false } }
    }

    // MARK: Drag and drop

    private func height(_ w: W) -> CGFloat? { frames[w.rawValue]?.height }
    private func offsetBefore(_ i: Int, in order: [W]) -> CGFloat { order.prefix(i).reduce(0) { $0 + (height($1) ?? 0) } }

    private func drag(_ w: W) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("board"))
            .onChanged { value in
                if dragged == nil {
                    guard let f = frames[w.rawValue], let i = visible.firstIndex(of: w) else { return }
                    liveOrder = fullOrder
                    dragStartMinY = f.minY
                    dragBase = f.minY - offsetBefore(i, in: visible)
                    dragged = w
                }
                guard let h = height(w) else { return }
                let minY = dragStartMinY + value.translation.height
                let center = minY + h / 2
                var order = visible
                var moved = true
                while moved, let i = order.firstIndex(of: w) {
                    moved = false
                    if i + 1 < order.count, let nh = height(order[i + 1]), center > dragBase + offsetBefore(i + 1, in: order) + nh / 2 {
                        swap(w, order[i + 1]); order.swapAt(i, i + 1); moved = true
                    } else if i > 0, let ph = height(order[i - 1]), center < dragBase + offsetBefore(i - 1, in: order) + ph / 2 {
                        swap(w, order[i - 1]); order.swapAt(i, i - 1); moved = true
                    }
                }
                if let i = order.firstIndex(of: w) { dragOffset = minY - (dragBase + offsetBefore(i, in: order)) }
            }
            .onEnded { _ in
                orderRaw = fullOrder.map(\.rawValue).joined(separator: ",")
                withAnimation(.snappy(duration: 0.3)) { dragged = nil; dragOffset = 0 }
                liveOrder = nil
            }
    }

    private func swap(_ a: W, _ b: W) {
        guard var o = liveOrder, let i = o.firstIndex(of: a), let j = o.firstIndex(of: b) else { return }
        o.swapAt(i, j)
        withAnimation(.snappy(duration: 0.25)) { liveOrder = o }
    }

    // MARK: Add back

    private var addSection: some View {
        VStack(spacing: 8) {
            if showPicker && !removed.isEmpty {
                VStack(spacing: 0) {
                    ForEach(removed) { w in
                        Button { show(w) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: w.symbol).font(.system(size: 12)).foregroundStyle(Theme.clay).frame(width: 18)
                                Text(w.title).font(Theme.sans(13)).foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.clay)
                            }
                            .padding(.vertical, 9).padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
            }
            Button { withAnimation(.snappy) { showPicker.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showPicker && !removed.isEmpty ? "chevron.up" : "plus").font(.system(size: 11, weight: .bold))
                    Text(removed.isEmpty ? "Tous les widgets sont affichés" : showPicker ? "Fermer" : "Ajouter un widget (\(removed.count))")
                        .font(Theme.sans(12.5, .medium))
                }
                .foregroundStyle(removed.isEmpty ? Theme.inkFaint : Theme.clayDeep)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(Theme.rule))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(removed.isEmpty)
            Text("Glissez la poignée d'un widget pour le déplacer · ✕ pour le retirer")
                .font(Theme.sans(10.5)).foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, 12).padding(.top, 12)
    }
}

struct BoardFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct BoardHandle: View {
    let active: Bool
    @State private var hovering = false
    var body: some View {
        Capsule()
            .fill(active || hovering ? Theme.clay : Theme.inkFaint.opacity(0.45))
            .frame(width: active || hovering ? 40 : 30, height: 4)
            .frame(width: 90, height: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .animation(.snappy(duration: 0.2), value: hovering)
            .tip("Glisser pour déplacer ce widget")
    }
}

struct BoardLift: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.scaleEffect(1.02).shadow(color: .black.opacity(0.3), radius: 12, y: 6) } else { content }
    }
}
