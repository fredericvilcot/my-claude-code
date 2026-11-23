import Foundation

/// The name Claude Code gives a session (its "ai-title" transcript entry), read from the head and tail of the
/// transcript and cached by file size.
enum SessionTitles {
    private static var cache: [String: (size: UInt64, title: String?)] = [:]
    private static let lock = NSLock()

    /// Last known title, instantly; refreshed in the background when the transcript grows.
    static func title(for sessionID: String) -> String? {
        guard let path = ChatLog.transcript(for: sessionID) else { return nil }
        let size = TranscriptWork.size(of: path)
        lock.lock(); let hit = cache[path]; lock.unlock()
        if let hit, hit.size == size { return hit.title }
        TranscriptWork.schedule("title:" + path, evenHidden: hit == nil) { _ = compute(path) }
        return hit?.title
    }

    @discardableResult
    private static func compute(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // The latest title wins: look at the tail first, then the head.
        var title: String?
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        title = last(in: handle.readDataToEndOfFile())
        if title == nil, size > window {
            try? handle.seek(toOffset: 0)
            title = last(in: handle.readData(ofLength: Int(window)))
        }
        lock.lock(); cache[path] = (size, title); lock.unlock()
        return title
    }

    private static func last(in data: Data) -> String? {
        for line in data.split(separator: 0x0A).reversed() where line.count < 4000 {
            guard line.range(of: Data("ai-title".utf8)) != nil || line.range(of: Data("custom-title".utf8)) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if let t = (obj["customTitle"] ?? obj["aiTitle"]) as? String, !t.isEmpty { return t }
        }
        return nil
    }
}

extension SessionStat {
    /// The session's real name (the title Claude Code gave it), else its folder. Instant (cached, see SessionTitles).
    var displayName: String { SessionTitles.title(for: info.id) ?? name }
}
