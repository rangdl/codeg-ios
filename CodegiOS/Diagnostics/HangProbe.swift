import Foundation

/// TEMPORARY hang triage for the "Message Settings" freeze.
///
/// The hang report shows the main thread blocked >10 s inside a deep SwiftUI stack,
/// with our own frame un-symbolisable (the shipped binary is stripped). So instead
/// of guessing which view or model loops, count the suspicious activity and persist
/// it: the watchdog kills the app, but these counters survive in `UserDefaults`, and
/// the channels list shows them after a relaunch.
///
/// Remove this file, its call sites and the debug card once the freeze is fixed.
enum HangProbe {
    private static let key = "codeg.hangProbe.v1"
    private static let queue = DispatchQueue(label: "app.codeg.hangProbe")
    private static var counts: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    private static var lastFlush = Date.distantPast

    /// Count one occurrence of `name`. Cheap, and flushed at most twice a second.
    static func bump(_ name: String) {
        queue.sync {
            counts[name, default: 0] += 1
            let now = Date()
            if now.timeIntervalSince(lastFlush) > 0.5 {
                lastFlush = now
                UserDefaults.standard.set(counts, forKey: key)
            }
        }
    }

    static func snapshot() -> [(name: String, count: Int)] {
        queue.sync { counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 } }
    }

    static func reset() {
        queue.sync {
            counts = [:]
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
