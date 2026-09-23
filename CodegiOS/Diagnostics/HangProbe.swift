import Foundation

/// TEMPORARY hang triage for the "Message Settings" freeze.
///
/// A hang report can't say *why* a view re-renders, and the counters narrowed it to
/// "the chat channels list re-evaluates ~60×/s with nothing invalidating it from
/// outside". SwiftUI can answer that itself: `Self._printChanges()` returns the
/// description of what changed for the current body evaluation. Recording those
/// strings — rather than counting guesses — names the invalidation source directly.
///
/// Counters and reasons are persisted to `UserDefaults` so they survive the
/// watchdog killing the app, and the chat channels screen shows them after a
/// relaunch. Remove this file, its call sites and the debug card once fixed.
enum HangProbe {
    private static let key = "codeg.hangProbe.v1"
    private static let queue = DispatchQueue(label: "app.codeg.hangProbe")
    private static var counts: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    /// Why a body re-ran: `"<view>: <what changed>"` → how many times.
    private static var reasons: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: key + ".why") as? [String: Int]) ?? [:]
    private static var lastFlush = Date.distantPast

    /// Count one occurrence of `name`. Cheap, and flushed at most twice a second.
    static func bump(_ name: String) {
        queue.sync {
            counts[name, default: 0] += 1
            flushIfDue()
        }
    }

    /// Record SwiftUI's own explanation for a body re-run (`Self._printChanges()`).
    static func note(_ view: String, _ change: String) {
        let trimmed = change.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let text = String(trimmed.prefix(70))
        queue.sync {
            reasons["\(view): \(text)", default: 0] += 1
            flushIfDue()
        }
    }

    private static func flushIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastFlush) > 0.5 else { return }
        lastFlush = now
        counts["probe.flush", default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
        UserDefaults.standard.set(reasons, forKey: key + ".why")
    }

    static func snapshot() -> [(name: String, count: Int)] {
        queue.sync {
            (counts.map { ($0.key, $0.value) } + reasons.map { ($0.key, $0.value) })
                .sorted { $0.1 > $1.1 }
        }
    }

    static func reset() {
        queue.sync {
            counts = [:]
            reasons = [:]
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key + ".why")
        }
    }
}
