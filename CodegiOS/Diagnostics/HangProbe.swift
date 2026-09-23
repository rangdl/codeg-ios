import Foundation

/// TEMPORARY hang triage for the "Message Settings" freeze.
///
/// The counters narrowed the freeze to "the chat channels list re-evaluates ~60×/s
/// with nothing invalidating it from outside". SwiftUI can answer *why* itself via
/// `Self._printChanges()`, but in this SDK that returns `Void` and only prints to
/// stdout — unreachable from the app. So stdout is redirected to a file at launch
/// and the debug card reads the file back.
///
/// Counters are persisted to `UserDefaults` so they survive the watchdog killing
/// the app. Remove this file, its call sites and the debug card once fixed.
enum HangProbe {
    private static let key = "codeg.hangProbe.v1"
    private static let queue = DispatchQueue(label: "app.codeg.hangProbe")
    private static var counts: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    private static var lastFlush = Date.distantPast
    /// Rolling one-second window used to notice an update loop.
    private static var windowStart = Date.distantPast
    private static var windowCount = 0
    private static var stack: String =
        UserDefaults.standard.string(forKey: key + ".stack") ?? ""

    /// Count one occurrence of `name`. Cheap, and flushed at most twice a second.
    static func bump(_ name: String) {
        queue.sync {
            counts[name, default: 0] += 1
            flushIfDue()
        }
    }

    /// Count a body evaluation, and — if bodies are being evaluated faster than
    /// any real screen could need — capture the main thread's call stack once.
    /// That stack is what re-entered SwiftUI, which is the thing a hang report
    /// can't tell us.
    static func bodyTick(_ view: String) {
        queue.sync {
            counts["\(view).body", default: 0] += 1
            let now = Date()
            if now.timeIntervalSince(windowStart) > 1 {
                windowStart = now
                windowCount = 0
            }
            windowCount += 1
            if windowCount == 60, stack.isEmpty {
                // `#dsohandle` is this image's Mach-O header = its load address, so
                // each app frame's file offset is `address - base` and the captured
                // stack can be symbolized later against the build's dSYM.
                let base = UInt(bitPattern: #dsohandle)
                stack = "base=0x\(String(base, radix: 16))\n"
                    + Thread.callStackSymbols.prefix(30).joined(separator: "\n")
                UserDefaults.standard.set(stack, forKey: key + ".stack")
                print("[probe] loop stack:\n\(stack)")
                flushIfDue()
            }
        }
    }

    /// The main-thread stack captured the first time an update loop was seen.
    static var capturedStack: String { stack }

    // MARK: - stdout capture

    private static var logURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hangprobe.log")
    }

    /// Call once, as early as possible (from the app's `init`).
    static func startCapturingStdout() {
        freopen(logURL.path, "a", stdout)
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered: lines land as they print
    }

    private static var linesCache: [(name: String, count: Int)] = []
    private static var linesCacheAt = Date.distantPast

    /// The most frequent captured lines (deduped), newest file contents only.
    /// Cached for a second: the debug card re-renders with its screen, and reading
    /// a multi-megabyte log on every body evaluation would cost more than it shows.
    static func capturedLines(limit: Int = 8) -> [(name: String, count: Int)] {
        if Date().timeIntervalSince(linesCacheAt) < 1 { return linesCache }
        linesCacheAt = Date()
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            linesCache = []
            return []
        }
        var tally: [String: Int] = [:]
        for line in text.split(separator: "\n").suffix(20_000) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            tally[String(trimmed.prefix(90)), default: 0] += 1
        }
        linesCache = tally.map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
        return linesCache
    }

    private static func flushIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastFlush) > 0.5 else { return }
        lastFlush = now
        counts["probe.flush", default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }

    static func snapshot() -> [(name: String, count: Int)] {
        queue.sync { counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 } }
    }

    static func reset() {
        queue.sync {
            counts = [:]
            stack = ""
            windowStart = .distantPast
            windowCount = 0
            linesCache = []
            linesCacheAt = .distantPast
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key + ".stack")
            try? FileManager.default.removeItem(at: logURL)
        }
    }
}
