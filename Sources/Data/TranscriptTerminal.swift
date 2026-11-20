import Foundation

/// A session without an iTerm tab (closed, or a background agent) shown as Claude Code would print it, rebuilt from
/// its transcript: "❯ prompt", "⏺ answer", "⏺ Tool(…)" then "  ⎿  precision". Same rows as the live mirror.
enum TranscriptTerminal {
    private static var cache: [String: (size: UInt64, rows: [TerminalMirror.Row])] = [:]
    private static let lock = NSLock()

    static func rows(for sessionID: String, limit: Int = 600) -> [TerminalMirror.Row] {
        guard let path = ChatLog.transcript(for: sessionID), let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        lock.lock()
        if let hit = cache[path], hit.size == size { lock.unlock(); return hit.rows }
        lock.unlock()
        let window: UInt64 = 6 * 1024 * 1024   // long sessions: enough of the transcript for a real scrollback
        try? handle.seek(toOffset: size > window ? size - window : 0)
        var rows = build(handle.readDataToEndOfFile())
        if rows.count > limit { rows = Array(rows.suffix(limit)) }
        lock.lock(); cache[path] = (size, rows); lock.unlock()
        return rows
    }

    private static func build(_ data: Data) -> [TerminalMirror.Row] {
        var out: [TerminalMirror.Row] = []
        func block(_ lines: [String]) {
            if !out.isEmpty { out.append(.text("")) }
            out.append(contentsOf: lines.map { .text($0) })
        }
        func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true else { continue }
            let content = (obj["message"] as? [String: Any])?["content"]
            if type == "user" {
                if let origin = obj["origin"] as? [String: Any], origin["kind"] as? String == "peer" {
                    if origin["senderTaskId"] == nil, let body = origin["body"] as? String {
                        block(["✉ message de \(origin["name"] as? String ?? "une session") : " + clip(PromptSender.stripFooter(body), 300)])
                    }
                    continue
                }
                var text = content as? String
                if text == nil, let blocks = content as? [[String: Any]] {
                    if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                    text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                }
                guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { continue }
                block(["❯ " + clip(t.replacingOccurrences(of: "\n", with: " "), 400)])
                continue
            }
            for b in content as? [[String: Any]] ?? [] {
                switch b["type"] as? String {
                case "text":
                    let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    let paragraphs = clip(t, 900).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    block(paragraphs.enumerated().map { $0.offset == 0 ? "⏺ " + $0.element : "  " + $0.element })
                case "tool_use":
                    let name = b["name"] as? String ?? "Outil"
                    let input = b["input"] as? [String: Any] ?? [:]
                    let arg = (input["description"] as? String) ?? (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
                        ?? (input["pattern"] as? String) ?? (input["command"] as? String).map { clip($0, 60) } ?? ""
                    var lines = ["⏺ \(name)(\(clip(arg.replacingOccurrences(of: "\n", with: " "), 80)))"]
                    if let p = ActivityReader.precision(b), !p.isEmpty { lines.append("  ⎿  " + p) }
                    block(lines)
                default: continue
                }
            }
        }
        return out
    }
}
