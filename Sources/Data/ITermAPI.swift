import AppKit
import SwiftUI

/// iTerm2's official API (WebSocket + protobuf over a Unix socket), used for one thing: reading a session's screen
/// with its colours and styles, so the mirror looks exactly like the tab. Requires iTerm's "Enable Python API"
/// setting (General › Magic); without it `isEnabled` is false and the mirror stays plain text.
/// Authentication: a one-time cookie from AppleScript (`request cookie and key`), i.e. the app's existing Automation
/// permission for iTerm. One connection for the app, opened on demand, reopened after any error.
/// Thread: call from `ITermScript.queue` only (it also runs the cookie AppleScript).
final class ITermAPI {
    static let shared = ITermAPI()

    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iTerm2/private/socket").path
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: socketPath) }

    private var fd: Int32 = -1
    private var nextID: Int64 = 1
    private var pending = Data()
    private var retryAfter = Date.distantPast

    // MARK: Screen

    /// Colours of the user's profile, resolved on the main thread and handed to the reader.
    struct Palette {
        var foreground: SwiftUI.Color
        var background: SwiftUI.Color
        var ansi: [NSColor]   // 0…15

        init(_ p: ITermProfile) {
            foreground = SwiftUI.Color(nsColor: p.foreground)
            background = SwiftUI.Color(nsColor: p.background)
            ansi = p.ansi
        }

        func color(_ index: Int) -> SwiftUI.Color {
            if index < 16 { return SwiftUI.Color(nsColor: ansi[max(0, index)]) }
            if index < 232 {
                let i = index - 16, levels: [Double] = [0, 95, 135, 175, 215, 255]
                return SwiftUI.Color(.sRGB, red: levels[i / 36] / 255, green: levels[(i / 6) % 6] / 255, blue: levels[i % 6] / 255)
            }
            let g = Double(8 + 10 * (min(index, 255) - 232)) / 255
            return SwiftUI.Color(.sRGB, red: g, green: g, blue: g)
        }
    }

    /// The visible screen of the session with this iTerm unique id, one attributed string per line (trailing blank
    /// lines dropped), or nil when the API is unavailable.
    func screen(session: String, palette: Palette) -> [AttributedString]? {
        guard Self.isEnabled, Date() >= retryAfter else { return nil }
        var request = Proto()
        request.string(1, session)
        var range = Proto(); range.bool(1, true)            // screen_contents_only
        request.message(2, range)
        request.bool(3, true)                               // include_styles
        guard let response = call(field: 100, request), let buffer = response.messages(100).first else { return nil }
        guard buffer.varint(1) ?? 0 == 0 else { return nil }   // status OK
        var lines = buffer.messages(3).map { Self.line($0, palette: palette) }
        while let last = lines.last, last.characters.allSatisfy({ $0 == " " }) { lines.removeLast() }
        return lines
    }

    /// The iTerm session (unique id) whose terminal is `tty` (e.g. "/dev/ttys004"), with its width in columns.
    /// Works for every window, the hidden hotkey window included (AppleScript only reaches it while it is current).
    func session(tty: String) -> (id: String, columns: Int, title: String)? {
        if let hit = ttyCache[tty], Date().timeIntervalSince(hit.date) < 30 { return (hit.id, hit.columns, hit.title) }
        guard let list = call(field: 106, Proto())?.messages(106).first else { return nil }
        var sessions: [(id: String, columns: Int, title: String)] = []
        func summary(_ s: Proto.Message) {
            guard let id = s.string(1) else { return }
            sessions.append((id, Int(s.messages(3).first?.varint(1) ?? 80), s.string(4) ?? ""))
        }
        func walk(_ node: Proto.Message) {
            for link in node.messages(2) {
                if let s = link.messages(1).first { summary(s) }
                if let child = link.messages(2).first { walk(child) }
            }
        }
        for window in list.messages(1) {
            for tab in window.messages(1) {
                if let root = tab.messages(3).first { walk(root) }
                tab.messages(6).forEach(summary)
            }
        }
        list.messages(2).forEach(summary)
        for s in sessions {
            var request = Proto()
            request.string(1, s.id)
            request.string(3, "tty")
            guard let value = call(field: 115, request)?.messages(115).first, let json = value.string(2) else { continue }
            guard let found = (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)) as? String else { continue }
            ttyCache[found] = (s.id, s.columns, s.title, Date())
        }
        guard let hit = ttyCache[tty] else { return nil }
        return (hit.id, hit.columns, hit.title)
    }
    private var ttyCache: [String: (id: String, columns: Int, title: String, date: Date)] = [:]

    /// Forgets a session lookup (closed tab, moved session): the next call lists the sessions again.
    func forget(tty: String) { ttyCache[tty] = nil }

    /// Types `text` into the session, exactly as keystrokes (escape sequences included). True when delivered.
    func send(_ text: String, session: String) -> Bool {
        var request = Proto()
        request.string(1, session)
        request.string(2, text)
        guard let response = call(field: 107, request)?.messages(107).first else { return false }
        return (response.varint(1) ?? 0) == 0
    }

    private struct Style: Equatable {
        var fg: Int? , fgRGB: [UInt64]?, fgAlt: UInt64?
        var bg: Int?, bgRGB: [UInt64]?, bgAlt: UInt64?
        var bold = false, faint = false, italic = false, underline = false, strike = false, invisible = false, inverse = false
    }

    private static func line(_ m: Proto.Message, palette: Palette) -> AttributedString {
        // Cells the program skipped over (cursor moves) come as NUL: they are blanks on screen.
        let scalars = (m.string(1) ?? "").unicodeScalars.map { $0.value == 0 ? " " as Unicode.Scalar : $0 }
        // Cells → code points (0 code points: empty cell).
        var cells: [String] = []
        var cursor = 0
        for entry in m.messages(2) {
            let n = Int(entry.varint(1) ?? 1), repeats = Int(entry.varint(2) ?? 1)
            for _ in 0..<repeats {
                if n == 0 { cells.append(" "); continue }
                var s = String.UnicodeScalarView()
                for _ in 0..<n where cursor < scalars.count { s.append(scalars[cursor]); cursor += 1 }
                cells.append(String(s))
            }
        }
        if cells.isEmpty { cells = scalars.map { String($0) } }
        // Cells → styles.
        var styles: [Style] = []
        for s in m.messages(4) {
            var st = Style()
            if let v = s.varint(1) { st.fg = Int(v) }
            if let v = s.varint(2) { st.fgAlt = v }
            if let c = s.messages(3).first { st.fgRGB = [c.varint(1) ?? 0, c.varint(2) ?? 0, c.varint(3) ?? 0] }
            if let v = s.varint(5) { st.bg = Int(v) }
            if let v = s.varint(6) { st.bgAlt = v }
            if let c = s.messages(7).first { st.bgRGB = [c.varint(1) ?? 0, c.varint(2) ?? 0, c.varint(3) ?? 0] }
            st.bold = s.varint(9) == 1; st.faint = s.varint(10) == 1; st.italic = s.varint(11) == 1
            st.underline = s.varint(13) == 1; st.strike = s.varint(14) == 1; st.invisible = s.varint(15) == 1
            st.inverse = s.varint(16) == 1
            styles.append(contentsOf: repeatElement(st, count: max(1, Int(s.varint(22) ?? 1))))
        }
        // Runs of identical style → attributed string.
        var out = AttributedString()
        var i = 0
        while i < cells.count {
            let st = i < styles.count ? styles[i] : Style()
            var text = cells[i]
            var j = i + 1
            while j < cells.count, (j < styles.count ? styles[j] : Style()) == st { text += cells[j]; j += 1 }
            var run = AttributedString(text)
            func rgb(_ c: [UInt64]) -> SwiftUI.Color { SwiftUI.Color(.sRGB, red: Double(c[0]) / 255, green: Double(c[1]) / 255, blue: Double(c[2]) / 255) }
            var fg: SwiftUI.Color? = st.fgRGB.map(rgb) ?? st.fg.map(palette.color) ?? (st.fgAlt == 3 ? palette.background : nil)
            var bg: SwiftUI.Color? = st.bgRGB.map(rgb) ?? st.bg.map(palette.color) ?? (st.bgAlt == 3 ? palette.foreground : nil)
            if st.inverse { swap(&fg, &bg); fg = fg ?? palette.background; bg = bg ?? palette.foreground }
            if st.invisible { fg = bg ?? palette.background }
            if let fg { run.foregroundColor = st.faint ? fg.opacity(0.55) : fg } else if st.faint { run.foregroundColor = palette.foreground.opacity(0.55) }
            if let bg { run.backgroundColor = bg }
            if st.underline { run.underlineStyle = .single }
            if st.strike { run.strikethroughStyle = .single }
            if st.bold || st.italic {
                var intents: InlinePresentationIntent = []
                if st.bold { intents.insert(.stronglyEmphasized) }
                if st.italic { intents.insert(.emphasized) }
                run.inlinePresentationIntent = intents
            }
            out += run
            i = j
        }
        return out
    }

    // MARK: Request / response

    /// Sends a ClientOriginatedMessage carrying `request` in `field`; returns the matching ServerOriginatedMessage.
    private func call(field: Int, _ request: Proto) -> Proto.Message? {
        for attempt in 0..<2 {
            if fd < 0, !connect() { return nil }
            let id = nextID; nextID += 1
            var envelope = Proto()
            envelope.varint(1, UInt64(id))
            envelope.message(field, request)
            if send(frame: envelope.data, opcode: 0x2), let reply = receive(id: id) { return reply }
            close()
            if attempt == 1 { retryAfter = Date().addingTimeInterval(10) }
        }
        return nil
    }

    private func receive(id: Int64) -> Proto.Message? {
        for _ in 0..<50 {
            guard let payload = readMessage() else { return nil }
            let m = Proto.Message(payload)
            if Int64(m.varint(1) ?? 0) == id { return m.string(2) == nil ? m : nil }   // field 2: error
        }
        return nil
    }

    // MARK: Connection (WebSocket over a Unix socket)

    private func connect() -> Bool {
        guard Date() >= retryAfter else { return false }
        guard let auth = Self.cookie() else { retryAfter = Date().addingTimeInterval(30); return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in path.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(s); retryAfter = Date().addingTimeInterval(10); return false }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        pending = Data()
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let handshake = [
            "GET / HTTP/1.1", "Host: localhost", "Upgrade: websocket", "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)", "Sec-WebSocket-Version: 13", "Sec-WebSocket-Protocol: api.iterm2.com",
            "Origin: ws://localhost/", "x-iterm2-library-version: python 2.13", "x-iterm2-disable-auth-ui: true",
            "x-iterm2-cookie: \(auth.cookie)", "x-iterm2-key: \(auth.key)", "x-iterm2-advisory-name: My Claude Code", "", "",
        ].joined(separator: "\r\n")
        guard write(Data(handshake.utf8)) else { close(); return false }
        // Response headers, up to the blank line.
        while pending.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard fill() else { close(); return false }
        }
        let end = pending.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: pending[..<end.lowerBound], as: UTF8.self)
        pending.removeSubrange(..<end.upperBound)
        guard head.hasPrefix("HTTP/1.1 101") else { close(); retryAfter = Date().addingTimeInterval(30); return false }
        return true
    }

    private func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        pending = Data()
    }

    /// One-time cookie and key, from AppleScript (must run on ITermScript.queue).
    private static func cookie() -> (cookie: String, key: String)? {
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"iTerm2\" to request cookie and key for app named \"My Claude Code\"")
        guard let out = script?.executeAndReturnError(&error).stringValue, error == nil else { return nil }
        let parts = out.split(separator: " ")
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
    }

    private func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return false }
        pending.append(contentsOf: chunk[0..<n])
        return true
    }

    private func take(_ count: Int) -> Data? {
        while pending.count < count { guard fill() else { return nil } }
        let out = pending.prefix(count)
        pending.removeFirst(count)
        return Data(out)
    }

    /// Client frames are masked (RFC 6455).
    private func send(frame payload: Data, opcode: UInt8) -> Bool {
        var frame = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 { frame.append(UInt8(n) | 0x80) }
        else if n < 65536 { frame.append(126 | 0x80); frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 0xFF)) }
        else { frame.append(127 | 0x80); for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF)) } }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return write(frame)
    }

    /// Next complete data message (fragments joined; pings answered).
    private func readMessage() -> Data? {
        var message = Data()
        while true {
            guard let head = take(2) else { return nil }
            let fin = head[head.startIndex] & 0x80 != 0, opcode = head[head.startIndex] & 0x0F
            let masked = head[head.startIndex + 1] & 0x80 != 0
            var length = UInt64(head[head.startIndex + 1] & 0x7F)
            if length == 126 { guard let l = take(2) else { return nil }; length = l.reduce(0) { $0 << 8 | UInt64($1) } }
            else if length == 127 { guard let l = take(8) else { return nil }; length = l.reduce(0) { $0 << 8 | UInt64($1) } }
            guard length < 64 << 20 else { return nil }
            let mask = masked ? take(4) : nil
            guard var payload = take(Int(length)) else { return nil }
            if let mask { payload = Data(payload.enumerated().map { $0.element ^ mask[mask.startIndex + $0.offset % 4] }) }
            switch opcode {
            case 0x8: return nil                                         // close
            case 0x9: _ = send(frame: payload, opcode: 0xA); continue    // ping → pong
            case 0xA: continue
            default:
                message.append(payload)
                if fin { return message }
            }
        }
    }
}

/// Minimal protobuf: varints and length-delimited fields, enough for the iTerm2 API messages used here.
struct Proto {
    private(set) var data = Data()

    mutating func key(_ field: Int, _ wire: UInt64) { appendVarint(UInt64(field) << 3 | wire) }
    mutating func appendVarint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    mutating func varint(_ field: Int, _ v: UInt64) { key(field, 0); appendVarint(v) }
    mutating func bool(_ field: Int, _ v: Bool) { varint(field, v ? 1 : 0) }
    mutating func bytes(_ field: Int, _ d: Data) { key(field, 2); appendVarint(UInt64(d.count)); data.append(d) }
    mutating func string(_ field: Int, _ s: String) { bytes(field, Data(s.utf8)) }
    mutating func message(_ field: Int, _ m: Proto) { bytes(field, m.data) }

    /// A decoded message: every field with its values (varints and length-delimited bytes).
    struct Message {
        private var varints: [Int: [UInt64]] = [:]
        private var blobs: [Int: [Data]] = [:]

        init(_ data: Data) {
            let bytes = [UInt8](data)
            var i = 0
            func readVarint() -> UInt64? {
                var result: UInt64 = 0, shift: UInt64 = 0
                while i < bytes.count {
                    let b = bytes[i]; i += 1
                    result |= UInt64(b & 0x7F) << shift
                    if b & 0x80 == 0 { return result }
                    shift += 7
                    if shift > 63 { return nil }
                }
                return nil
            }
            while i < bytes.count, let k = readVarint() {
                let field = Int(k >> 3)
                switch k & 7 {
                case 0: guard let v = readVarint() else { return }; varints[field, default: []].append(v)
                case 2:
                    guard let n = readVarint(), i + Int(n) <= bytes.count else { return }
                    blobs[field, default: []].append(Data(bytes[i..<i + Int(n)])); i += Int(n)
                case 1: i += 8
                case 5: i += 4
                default: return
                }
            }
        }

        func varint(_ field: Int) -> UInt64? { varints[field]?.last }
        func string(_ field: Int) -> String? { blobs[field]?.last.map { String(decoding: $0, as: UTF8.self) } }
        func messages(_ field: Int) -> [Message] { (blobs[field] ?? []).map(Message.init) }
    }
}
