import Foundation

/// One deduplicated assistant response with its token usage.
struct UsageRecord: Codable {
    var t: Double        // unix time
    var s: Int           // session index
    var m: Int           // model index
    var i: Int           // input tokens
    var o: Int           // output tokens
    var w5: Int          // cache write, 5-minute TTL
    var w1: Int          // cache write, 1-hour TTL
    var r: Int           // cache read
    var f: Bool          // fast mode
    var sc: Bool? = nil  // sub-agent (sidechain) response
    var tokens: Int { i + o + w5 + w1 + r }
    /// Tokens sent to the model on this turn, i.e. the context size at that point.
    var context: Int { i + w5 + w1 + r }
}

struct SessionInfo: Codable {
    var id: String
    var project: String
    var branch: String?
    var first: Double
    var last: Double
}

struct FileMark: Codable {
    var offset: UInt64
    var size: UInt64
}

/// On-disk cache so that only new lines are parsed after the first launch.
struct UsageCache: Codable {
    var version = 3
    var files: [String: FileMark] = [:]
    var sessions: [SessionInfo] = []
    var models: [String] = []
    var records: [UsageRecord] = []
    var seen: [String] = []
}

/// Reads Claude Code's local JSONL transcripts. Only usage counters and metadata are read,
/// never the conversation text.
enum UsageLog {
    struct Parsed {
        let key: String
        let t: Double
        let session: String
        let cwd: String
        let branch: String?
        let model: String
        let i, o, w5, w1, r: Int
        let fast: Bool
        let sidechain: Bool
    }

    static var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list = [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            list.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects"), at: 0)
        }
        return list.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Main transcript of each session (`<session id>.jsonl`), refreshed by every `listFiles()` call (background scans),
    /// so that looking a transcript up never walks the projects folders on the main thread.
    private static var index: [String: String] = [:]
    private static let indexLock = NSLock()

    static func transcriptPath(for sessionID: String) -> String? {
        indexLock.lock(); defer { indexLock.unlock() }
        if index.isEmpty { indexLock.unlock(); _ = listFiles(); indexLock.lock() }   // first use only
        return index[sessionID]
    }

    static func listFiles() -> [(path: String, size: UInt64)] {
        var out: [(String, UInt64)] = []
        defer {
            var fresh: [String: String] = [:]
            for (path, _) in out {
                let name = (path as NSString).lastPathComponent
                if name.count == 42 { fresh[String(name.dropLast(6))] = path }   // UUID (36) + ".jsonl"
            }
            indexLock.lock(); index = fresh; indexLock.unlock()
        }
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
                out.append((url.path, size))
            }
        }
        return out
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)

    /// Parses complete lines from `offset`; returns records and the offset after the last full line.
    static func parse(path: String, from offset: UInt64) -> (records: [Parsed], end: UInt64) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return ([], offset) }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: offset) } catch { return ([], offset) }
        let data = fh.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let complete = data[data.startIndex...lastNewline]
        let end = offset + UInt64(complete.count)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var out: [Parsed] = []
        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.range(of: usageMarker) != nil, line.range(of: assistantMarker) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model.hasPrefix("claude"),
                  let stamp = obj["timestamp"] as? String,
                  let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp) else { continue }
            func n(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? 0 }
            let id = message["id"] as? String ?? UUID().uuidString
            let key = id + "|" + (obj["requestId"] as? String ?? "")
            var w5 = 0, w1 = 0
            if let creation = usage["cache_creation"] as? [String: Any] {
                w5 = n(creation["ephemeral_5m_input_tokens"])
                w1 = n(creation["ephemeral_1h_input_tokens"])
            }
            if w5 + w1 == 0 { w5 = n(usage["cache_creation_input_tokens"]) }
            out.append(Parsed(key: key, t: date.timeIntervalSince1970,
                              session: obj["sessionId"] as? String ?? (path as NSString).lastPathComponent,
                              cwd: obj["cwd"] as? String ?? "", branch: obj["gitBranch"] as? String,
                              model: model, i: n(usage["input_tokens"]), o: n(usage["output_tokens"]),
                              w5: w5, w1: w1, r: n(usage["cache_read_input_tokens"]),
                              fast: (usage["speed"] as? String) == "fast", sidechain: obj["isSidechain"] as? Bool ?? false))
        }
        return (out, end)
    }
}
