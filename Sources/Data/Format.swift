import SwiftUI

enum Fmt {
    private static let stampFull: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "dd/MM/yyyy HH:mm:ss"; return f
    }()
    private static let stampTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "HH:mm:ss"; return f
    }()
    /// Exact timestamp: "23/11/2026 10:42:15".
    static func stamp(_ d: Date) -> String { stampFull.string(from: d) }
    /// Exact time to the second: "10:42:15".
    static func stampTime(_ d: Date) -> String { stampTime.string(from: d) }

    private static let money: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        return f
    }()

    static func usd(_ v: Double) -> String {
        money.minimumFractionDigits = v >= 1000 ? 0 : 2
        money.maximumFractionDigits = v >= 1000 ? 0 : 2
        return (money.string(from: NSNumber(value: v)) ?? "0") + "\u{202F}$"
    }

    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        func f(_ x: Double, _ unit: String) -> String {
            (x >= 100 ? String(format: "%.0f", x) : String(format: "%.1f", x)).replacingOccurrences(of: ".", with: ",") + "\u{202F}" + unit
        }
        if v >= 1e9 { return f(v / 1e9, "Md") }
        if v >= 1e6 { return f(v / 1e6, "M") }
        if v >= 1e3 { return f(v / 1e3, "k") }
        return "\(n)"
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))\u{202F}%" }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) j \(h) h" }
        if h > 0 { return "\(h) h \(String(format: "%02d", m))" }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .full
        return f
    }()

    static func relative(_ date: Date) -> String { relativeFormatter.localizedString(for: date, relativeTo: Date()) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Aujourd'hui" }
        if cal.isDateInYesterday(date) { return "Hier" }
        return dayFormatter.string(from: date).capitalized(with: Locale(identifier: "fr_FR"))
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "Opus 5.5" from "claude-opus-5-5".
    static func model(_ id: String) -> String {
        var name = id.replacingOccurrences(of: "claude-", with: "")
        if let r = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(r) }
        let parts = name.split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    static func modelColor(_ id: String) -> Color {
        if id.contains("opus") { return .claude }
        if id.contains("sonnet") { return .indigo }
        if id.contains("haiku") { return .teal }
        if id.contains("fable") || id.contains("mythos") { return .purple }
        return .gray
    }
}

extension Color {
    /// Warm terracotta accent of the app.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}
