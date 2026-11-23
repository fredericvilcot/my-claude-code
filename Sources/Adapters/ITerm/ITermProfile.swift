import AppKit

/// The look of the user's iTerm profile (font, colours), read from iTerm's own preferences so that the app's
/// terminals look exactly like iTerm's. Generic: hotkey-window profile first, then the default profile; sensible
/// defaults when iTerm is not installed.
struct ITermProfile {
    var font: NSFont
    var foreground: NSColor
    var background: NSColor
    var cursor: NSColor
    /// ANSI colours 0…15.
    var ansi: [NSColor]

    static let fallback = ITermProfile(
        font: .monospacedSystemFont(ofSize: 12, weight: .regular),
        foreground: NSColor(srgbRed: 0.91, green: 0.90, blue: 0.87, alpha: 1),
        background: NSColor(srgbRed: 0.118, green: 0.110, blue: 0.102, alpha: 1),
        cursor: NSColor(srgbRed: 0.91, green: 0.90, blue: 0.87, alpha: 1),
        ansi: [(0, 0, 0), (0.79, 0.11, 0.09), (0.05, 0.74, 0.12), (0.78, 0.77, 0.04), (0.11, 0.25, 0.98), (0.78, 0.25, 0.78),
               (0, 0.77, 0.78), (0.78, 0.78, 0.78), (0.41, 0.41, 0.41), (1, 0.43, 0.40), (0.37, 0.98, 0.41), (1, 0.99, 0.40),
               (0.39, 0.43, 1), (1, 0.44, 0.99), (0.37, 0.99, 1), (1, 1, 1)].map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) })

    private static var cached: (profile: ITermProfile, dark: Bool, date: Date)?

    /// Current profile (re-read at most every 30 s, and when the system appearance changes).
    static var current: ITermProfile {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let c = cached, c.dark == dark, Date().timeIntervalSince(c.date) < 30 { return c.profile }
        let p = load(dark: dark) ?? fallback
        cached = (p, dark, Date())
        return p
    }

    private static func load(dark: Bool) -> ITermProfile? {
        let domain = "com.googlecode.iterm2" as CFString
        guard let profiles = CFPreferencesCopyAppValue("New Bookmarks" as CFString, domain) as? [[String: Any]], !profiles.isEmpty else { return nil }
        let defaultGuid = CFPreferencesCopyAppValue("Default Bookmark Guid" as CFString, domain) as? String
        let profile = profiles.first { ($0["Has Hotkey"] as? Bool) == true }
            ?? profiles.first { ($0["Guid"] as? String) == defaultGuid }
            ?? profiles[0]
        let separate = (profile["Use Separate Colors for Light and Dark Mode"] as? Bool) == true
        func color(_ key: String) -> NSColor? {
            let dict = (separate ? profile["\(key) (\(dark ? "Dark" : "Light"))"] : nil) ?? profile[key]
            guard let d = dict as? [String: Any],
                  let r = (d["Red Component"] as? NSNumber)?.doubleValue,
                  let g = (d["Green Component"] as? NSNumber)?.doubleValue,
                  let b = (d["Blue Component"] as? NSNumber)?.doubleValue else { return nil }
            let a = (d["Alpha Component"] as? NSNumber)?.doubleValue ?? 1
            switch d["Color Space"] as? String {
            case "P3": return NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
            case "Calibrated": return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
            default: return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            }
        }
        var p = fallback
        if let spec = profile["Normal Font"] as? String {
            // "Monaco 12", "MesloLGS-NF-Regular 13": PostScript name, then size.
            let parts = spec.split(separator: " ")
            if let last = parts.last, let size = Double(last), parts.count > 1,
               let f = NSFont(name: parts.dropLast().joined(separator: " "), size: size) { p.font = f }
        }
        p.foreground = color("Foreground Color") ?? p.foreground
        p.background = color("Background Color") ?? p.background
        p.cursor = color("Cursor Color") ?? p.foreground
        p.ansi = (0..<16).map { color("Ansi \($0) Color") ?? p.ansi[$0] }
        return p
    }
}
