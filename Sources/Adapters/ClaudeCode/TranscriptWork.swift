import Foundation

/// Work derived from a transcript (title, current activity…) never runs on the main thread: callers get the last
/// computed value at once, and a recomputation is queued in the background when the file has grown. When it lands,
/// `UsageStore.transcriptTick` changes so that views showing it refresh.
enum TranscriptWork {
    private static let queue = DispatchQueue(label: "mcc.transcripts", qos: .utility)
    private static let lock = NSLock()
    private static var inFlight = Set<String>()

    /// Size of a file (one stat, no read).
    static func size(of path: String) -> UInt64 {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(st.st_size) : 0
    }

    /// Runs `work` in the background unless the same key is already being computed. While nothing is on screen only
    /// first computations run (`evenHidden`), so the panel never opens on missing data; updates wait until it is shown.
    static func schedule(_ key: String, evenHidden: Bool = false, _ work: @escaping () -> Void) {
        guard evenHidden || AppActivity.isVisible else { return }
        lock.lock()
        guard !inFlight.contains(key) else { lock.unlock(); return }
        inFlight.insert(key)
        lock.unlock()
        queue.async {
            work()
            lock.lock(); inFlight.remove(key); lock.unlock()
            DispatchQueue.main.async { UsageStore.shared.transcriptTick &+= 1 }
        }
    }
}
