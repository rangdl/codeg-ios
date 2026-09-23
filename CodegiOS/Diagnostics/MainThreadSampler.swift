import Foundation
import Darwin

/// TEMPORARY: a statistical sampler for the main thread.
///
/// **Why this exists.** The `bug_type 509` watchdog reports cannot localise this
/// hang, and that is a property of the report, not of our reading of it:
///
/// - the stackshot is a *single* sample, taken after the 10 s allowance is
///   already gone (the main thread was even back in `TH_WAIT` when it was taken,
///   having spent the allowance spinning);
/// - every frame but one lands in the dyld shared cache, which the report
///   carries as **one opaque image** (type `S`), so `atos` can name the app's
///   frames and nothing else — and in the build-62 report the app's only frame
///   was `main`, i.e. no information at all.
///
/// So sample the main thread ourselves. A background thread suspends it, reads
/// its program counter, resumes it, and resolves that PC with `dladdr` — which
/// names the **image** (SwiftUI, UIKitCore, AttributeGraph, CoreFoundation, …)
/// even when the symbol itself is private. That is the layer the reports throw
/// away, and it is the layer that says whether this is SwiftUI's own update
/// machinery or app code.
///
/// 20 Hz, tallied per second; the last ten seconds are always on disk, so
/// whatever is running when the app wedges is what the file holds. Read it at
/// `Documents/mainsample.txt` — the app declares `UIFileSharingEnabled`, so it
/// appears in the Files app.
///
/// Remove this file, its call site in `CodegiOSApp`, and the two file-sharing
/// Info.plist keys once the culprit is known.
enum MainThreadSampler {
    private static let sampleInterval = 0.05   // 20 Hz
    private static let windowCount = 10        // seconds of history kept

    /// The main thread's Mach port, captured from the main thread at launch —
    /// `mach_thread_self()` on a background thread returns *that* thread.
    private static var mainThread: thread_t = 0
    private static let queue = DispatchQueue(label: "app.codeg.mainSampler")
    private static var timer: DispatchSourceTimer?

    private static var window: [String: Int] = [:]
    private static var history: [[(String, Int)]] = []
    private static var lastWindowAt = Date.distantPast

    /// Call once, from the main thread, as early as possible.
    static func start() {
        guard mainThread == 0 else { return }
        mainThread = mach_thread_self()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: sampleInterval)
        source.setEventHandler { tick() }
        source.resume()
        timer = source
    }

    private static func tick() {
        guard mainThread != 0 else { return }
        if let pc = sampleProgramCounter() {
            window[describe(pc), default: 0] += 1
        }
        let now = Date()
        guard now.timeIntervalSince(lastWindowAt) >= 1 else { return }
        lastWindowAt = now
        history.append(window.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) })
        if history.count > windowCount { history.removeFirst(history.count - windowCount) }
        window = [:]
        flush()
    }

    /// The main thread's PC. It is suspended for exactly these two calls and
    /// resumed immediately: `dladdr` takes dyld's lock, and calling it while the
    /// main thread is stopped could deadlock against a main thread holding it.
    private static func sampleProgramCounter() -> UInt? {
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return nil }
        defer { thread_resume(mainThread) }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt(state.__pc)
        #else
        return nil
        #endif
    }

    /// `Image  symbol` for a PC. The image is the point: it survives stripping
    /// and it survives the symbol being private, which is the usual case inside
    /// SwiftUI and AttributeGraph.
    private static func describe(_ pc: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0 else {
            return String(format: "0x%llx  (unresolved)", UInt64(pc))
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image)  \(symbol)"
    }

    private static func flush() {
        let text = history.enumerated().map { offset, entries in
            let age = history.count - offset
            let body = entries.map { "\($0.1)× \($0.0)" }.joined(separator: "\n            ")
            return "[\(age)s ago]  \(body)"
        }.joined(separator: "\n")
        guard let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("mainsample.txt")
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
