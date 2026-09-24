import Foundation

/// TEMPORARY diagnostic for the two transcript-scroll defects that do not reproduce
/// in the simulator:
///
///  * the picture jumping while a command runs, and
///  * the blank screen after a reasoning block auto-collapses.
///
/// Both are timing-dependent on the device, and the geometry at the moment they go
/// wrong is what tells the candidate mechanisms apart — "the viewport is parked past
/// the end of the content" (an offset problem) versus "the scroll view believes it is
/// at the bottom while the content is laid out shorter than it reports" (a layout
/// problem). So record what the scroll view actually reports, and every snap we
/// issue, around that moment.
///
/// Writes `Documents/scroll-trace.txt`; `UIFileSharingEnabled` puts it in the Files
/// app so it can come off the device. A relaunch keeps the previous run as
/// `scroll-trace-prev.txt` instead of overwriting it. Remove this file, its call
/// sites and the two Info.plist keys once the culprit is named.
enum ScrollTrace {
    private static let queue = DispatchQueue(label: "app.codeg.scrollTrace")
    private static let started = Date()
    /// Ring: only the tail is kept, so a long session can't grow the file forever.
    private static var lines: [String] = []
    private static let maxLines = 8_000
    private static var lastFlush = Date.distantPast
    private static var didStart = false

    /// Throttle state. Main thread only — the transcript's metrics callback runs
    /// hundreds of times a second while scrolling, so the decision (and therefore
    /// building the line) has to happen before the hop to the logging queue;
    /// formatting a string per report would be its own source of jank.
    private static var lastReportAt = Date.distantPast

    /// Whether a periodic report should be recorded. `force` marks the interesting
    /// ones — the geometry changed — which are never thinned out.
    static func shouldReport(force: Bool) -> Bool {
        let now = Date()
        guard force || now.timeIntervalSince(lastReportAt) >= 0.05 else { return false }
        lastReportAt = now
        return true
    }

    /// Record a one-off event (a pin flip, a snap, a collapse) or a report the
    /// caller already decided to keep.
    static func note(_ text: String) {
        let t = Date().timeIntervalSince(started)
        queue.async {
            if !didStart {
                didStart = true
                archivePreviousRun()
                lines.append("=== session start ===")
            }
            lines.append(String(format: "%.3f %@", t, text))
            flushIfDue()
        }
    }

    /// Keep the previous session's trace: the app is often relaunched (or killed)
    /// before the file is pulled off the device.
    private static func archivePreviousRun() {
        guard let url = fileURL else { return }
        let previous = url.deletingLastPathComponent().appendingPathComponent("scroll-trace-prev.txt")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    private static func flushIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastFlush) > 1.0 else { return }
        lastFlush = now
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        guard let url = fileURL else { return }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("scroll-trace.txt")
    }
}
