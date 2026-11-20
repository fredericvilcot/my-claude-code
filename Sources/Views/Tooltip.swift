import AppKit
import SwiftUI

/// Hover tooltips that work in the non-activating panel. Standard `.help` tooltips only show when the app is
/// active, which the panel never makes it; this one is a tiny borderless window above everything.
@MainActor
final class Tooltip {
    static let shared = Tooltip()
    private var window: NSPanel?
    private var host: NSHostingView<TooltipBubble>?
    private var pending: DispatchWorkItem?
    private var owner: UUID?

    func schedule(_ text: String, owner id: UUID) {
        pending?.cancel()
        owner = id
        let work = DispatchWorkItem { [weak self] in self?.show(text, owner: id) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func hide(owner id: UUID? = nil) {
        if let id, id != owner { return }
        pending?.cancel(); pending = nil
        window?.orderOut(nil)
        owner = nil
    }

    /// Debug: frame and visibility of the tooltip window after a forced show.
    func debugShow(_ text: String) -> String {
        let id = UUID(); owner = id; show(text, owner: id)
        if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "mcc-tip.png"))
        }
        return "visible=\(window?.isVisible ?? false) frame=\(window.map { NSStringFromRect($0.frame) } ?? "—") level=\(window?.level.rawValue ?? 0)"
    }

    private func show(_ text: String, owner id: UUID) {
        guard owner == id, PanelController.shared.isOpen else { return }
        let view = TooltipBubble(text: text)
        if window == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 3)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let hosting = NSHostingView(rootView: view)
            panel.contentView = hosting
            window = panel; host = hosting
        }
        host?.rootView = view
        guard let window, let host else { return }
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x + 10, y: mouse.y - size.height - 16)
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        if origin.y < screen.minY + 6 { origin.y = mouse.y + 18 }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }
}

struct TooltipBubble: View {
    let text: String

    /// Natural width of the text, capped: short tips stay on one line, long ones wrap at 260 pt.
    private var width: CGFloat {
        let natural = text.split(separator: "\n").map {
            (String($0) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5)]).width
        }.max() ?? 0
        return min(260, ceil(natural) + 2)
    }

    var body: some View {
        Text(text)
            .font(Theme.sans(11.5))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.rule, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(8)   // room for the shadow
            .fixedSize()
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !text.isEmpty { Tooltip.shared.schedule(text, owner: id) } else { Tooltip.shared.hide(owner: id) }
            }
            .onDisappear { Tooltip.shared.hide(owner: id) }
    }
}

extension View {
    /// Hover tooltip that shows in the panel (use instead of `.help`).
    func tip(_ text: String) -> some View { modifier(TipModifier(text: text)) }
}
