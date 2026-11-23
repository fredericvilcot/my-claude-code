import Foundation

// What is kept from Claude Code transcripts: one record per reply, the sessions, and the scan cache.

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
