import SwiftUI

// The app's own switches, segmented pickers, radio choices and slider. AppKit's native controls draw grey whenever
// the (non-activating) panel lacks the keyboard focus; these keep the clay accent, look the same everywhere, and
// never depend on the window state.

/// iOS/macOS-like switch in clay; the whole row toggles it.
struct ClaySwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.snappy(duration: 0.18)) { configuration.isOn.toggle() } } label: {
            HStack(spacing: 10) {
                configuration.label.foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.clay : Theme.inkFaint.opacity(0.35))
                    Circle().fill(.white).shadow(color: .black.opacity(0.18), radius: 1.5, y: 1).padding(2)
                }
                .frame(width: 36, height: 21)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Segmented choice: the selected segment filled in clay, white text.
struct ClaySegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let selected = options[i].value == selection
                Button { withAnimation(.snappy(duration: 0.18)) { selection = options[i].value } } label: {
                    Text(options[i].label).font(Theme.sans(12, selected ? .semibold : .regular)).lineLimit(1).fixedSize()
                        .foregroundStyle(selected ? Color.white : Theme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.clay : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.inkFaint.opacity(0.14)))
    }
}

/// Exclusive choice, one option per line, with a clay radio dot.
struct ClayRadio<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(options.indices, id: \.self) { i in
                let selected = options[i].value == selection
                Button { withAnimation(.snappy(duration: 0.18)) { selection = options[i].value } } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().strokeBorder(selected ? Theme.clay : Theme.inkFaint.opacity(0.6), lineWidth: selected ? 5 : 1)
                                .background(Circle().fill(selected ? Color.white : Color.clear))
                        }
                        .frame(width: 15, height: 15)
                        Text(options[i].label).foregroundStyle(Theme.ink)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Slider in clay with a white knob, snapping to `step`.
struct ClaySlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 18
            let span = range.upperBound - range.lowerBound
            let fraction = CGFloat((value - range.lowerBound) / span)
            let x = fraction * (geo.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.inkFaint.opacity(0.3)).frame(height: 4)
                Capsule().fill(Theme.clay).frame(width: x + knob / 2, height: 4)
                Circle().fill(.white).shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                    .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 0.5))
                    .frame(width: knob, height: knob).offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(1, max(0, (g.location.x - knob / 2) / max(1, geo.size.width - knob)))
                let raw = range.lowerBound + Double(f) * span
                value = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
            })
            .noWindowDrag()
        }
        .frame(height: 22)
    }
}
