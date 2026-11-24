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

/// Multi-line text field built on AppKit's NSTextView: a crisp clay caret where the text starts, the placeholder on
/// the very same origin, Return sends, ⇧Return or ⌥Return adds a line, Escape still closes the panel, and the field
/// grows from `minLines` to `maxLines` then scrolls. (SwiftUI's vertical TextField draws a misplaced caret in the
/// app's non-activating panels.)
struct ClayTextField: View {
    @Binding var text: String
    var placeholder: String
    var minLines = 1
    var maxLines = 6
    var focused: Binding<Bool>? = nil
    var onSubmit: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(.system(size: 13.5)).foregroundStyle(Theme.inkFaint).lineLimit(1).allowsHitTesting(false)
            }
            ClayTextEditor(text: $text, minLines: minLines, maxLines: maxLines, focused: focused, onSubmit: onSubmit)
        }
    }
}

struct ClayTextEditor: NSViewRepresentable {
    @Binding var text: String
    var minLines: Int
    var maxLines: Int
    var focused: Binding<Bool>?
    var onSubmit: () -> Void

    static let font = NSFont.systemFont(ofSize: 13.5)

    final class SubmitTextView: NSTextView {
        var submit: () -> Void = {}
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn, !hasMarkedText(), event.modifierFlags.intersection([.shift, .option]).isEmpty { submit(); return }
            if isReturn { insertNewlineIgnoringFieldEditor(nil); return }
            super.keyDown(with: event)
        }
        // Escape is the panel's (close), not the text view's (completion).
        override func cancelOperation(_ sender: Any?) { window?.cancelOperation(sender) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ClayTextEditor
        /// The keyboard was already asked for since `focused` last became true: asked once, never again on later
        /// updates (otherwise every refresh of the view would take the keyboard back from wherever the user went).
        var focusRequested = false
        init(_ parent: ClayTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused?.wrappedValue = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused?.wrappedValue = false }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let tv = SubmitTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.textColor = NSColor(Theme.ink)
        tv.insertionPointColor = NSColor(Theme.clay)
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.string = text
        tv.submit = onSubmit
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? SubmitTextView else { return }
        tv.submit = onSubmit
        if tv.string != text {   // changed from outside (sent, dictation…): caret at the end
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        // Takes the keyboard once when `focused` turns true (or when shown with it true), on the next turn, once the
        // field is in its window.
        if focused?.wrappedValue == true {
            if !context.coordinator.focusRequested, tv.window != nil {
                context.coordinator.focusRequested = true
                DispatchQueue.main.async { [weak tv] in
                    guard let tv, let window = tv.window, window.firstResponder !== tv else { return }
                    window.makeKey()
                    window.makeFirstResponder(tv)
                }
            }
        } else {
            context.coordinator.focusRequested = false
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 240)
        guard let tv = scroll.documentView as? NSTextView else { return nil }
        // Measured on a copy of the text, never on the text view itself: SwiftUI asks with several trial widths, and
        // setting them on the live container left its layout for the wrong width, redone while drawing, which AppKit
        // rejects with an exception (crash in the menu bar menu with a long draft, or when the field was cleared).
        let storage = NSTextStorage(string: tv.string, attributes: [.font: Self.font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: Self.font)
        let used = max(layout.usedRect(for: container).height, line)
        return CGSize(width: width, height: ceil(min(max(used, line * CGFloat(minLines)), line * CGFloat(maxLines))))
    }
}
