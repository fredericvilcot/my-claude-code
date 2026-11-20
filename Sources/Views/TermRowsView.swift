import SwiftUI

/// Terminal rows rendered like Claude Code in a real terminal: airy lines, the prompt on a soft band, coloured
/// bullets (answers white, tool calls green with the tool name in bold), dimmed tool results, amber status lines,
/// red errors, green/red diff lines, a quiet status bar.
struct TermRowsView: View {
    let rows: [TerminalMirror.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .rule:
                    Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1).padding(.vertical, 6)
                case .text(let line):
                    if line.isEmpty { Color.clear.frame(height: 7) } else { styled(line) }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let red = Color(red: 0.95, green: 0.45, blue: 0.42)
    private static let diffGreen = Color(red: 0.55, green: 0.80, blue: 0.55)

    @ViewBuilder
    private func styled(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let font = Term.mono(11)
        if trimmed.range(of: #"^❯\s*\d+\."#, options: .regularExpression) != nil {
            // Selected option of a choice menu.
            Text(String(trimmed.drop(while: { $0 == "❯" || $0 == " " })))
                .font(Term.mono(11, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.clay.opacity(0.85)))
        } else if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil, line.hasPrefix(" ") {
            // Other options of a choice menu.
            Text(trimmed).font(font).foregroundStyle(Term.text.opacity(0.75))
                .padding(.horizontal, 8).padding(.vertical, 3)
        } else if trimmed.hasPrefix("❯") || trimmed.hasPrefix("> ") {
            // The prompt: what was typed, on a soft band.
            (Text("❯ ").foregroundStyle(Term.green).fontWeight(.bold)
             + Text(String(trimmed.drop(while: { $0 == "❯" || $0 == ">" || $0 == " " }))).foregroundStyle(Term.text).fontWeight(.medium))
                .font(font).lineSpacing(2.5)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                .padding(.vertical, 2)
        } else if trimmed.hasPrefix("⏺") || trimmed.hasPrefix("●") {
            let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let paren = rest.firstIndex(of: "("), rest[..<paren].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == ":" }), !rest[..<paren].isEmpty {
                // Tool call: green bullet, tool name in bold.
                (Text("⏺ ").foregroundStyle(Term.green)
                 + Text(String(rest[..<paren])).foregroundStyle(Term.text).fontWeight(.bold)
                 + Text(String(rest[paren...])).foregroundStyle(Term.text.opacity(0.75)))
                    .font(font).lineSpacing(2.5)
            } else {
                (Text("⏺ ").foregroundStyle(Term.text) + Text(rest).foregroundStyle(Term.text))
                    .font(font).lineSpacing(2.5)
            }
        } else if trimmed.hasPrefix("⎿") {
            Text(line).font(Term.mono(10.5)).foregroundStyle(Term.dim).lineSpacing(2)
        } else if let f = trimmed.first, "✻✳✶✢✽✺*·".contains(f) {
            Text(line).font(font).foregroundStyle(Term.amber.opacity(0.9)).italic()
        } else if let f = trimmed.first, "✗✘⚠".contains(f) || trimmed.lowercased().hasPrefix("error") {
            Text(line).font(font).foregroundStyle(Self.red)
        } else if trimmed.hasPrefix("✉") {
            Text(line).font(font).foregroundStyle(Color(red: 0.71, green: 0.60, blue: 0.88)).lineSpacing(2.5)
        } else if trimmed.range(of: #"^\d+\s*\+"#, options: .regularExpression) != nil {
            Text(line).font(Term.mono(10.5)).foregroundStyle(Self.diffGreen)
        } else if trimmed.range(of: #"^\d+\s*-"#, options: .regularExpression) != nil {
            Text(line).font(Term.mono(10.5)).foregroundStyle(Self.red)
        } else if trimmed.hasPrefix("⏵") || trimmed.contains("shift+tab") || trimmed.contains("auto mode") || trimmed.contains("? for shortcuts") {
            Text(line).font(Term.mono(10)).foregroundStyle(Term.dim.opacity(0.8))
        } else {
            Text(line).font(font).foregroundStyle(Term.text.opacity(0.92)).lineSpacing(2.5)
        }
    }
}
