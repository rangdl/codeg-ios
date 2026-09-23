import Foundation
import Darwin

/// TEMPORARY: a statistical sampler for the main thread.
///
/// **Why this exists.** The `bug_type 509` watchdog reports cannot localise this
/// hang, and that is a property of the report, not of our reading of it: the
/// stackshot is a *single* sample taken after the 10 s allowance is gone, and
/// every frame but one lands in the dyld shared cache, which the report carries
/// as **one opaque image** (type `S`). `atos` can therefore name the app's frames
/// and nothing else — and in every report so far the app's only frame was `main`.
///
/// So sample it ourselves: a background timer suspends the main thread, reads its
/// registers, resumes it, and resolves each address with `dladdr`, which names
/// the **image** even when the symbol is private.
///
/// **The first version of this was wrong in two ways, and the first file it
/// produced is what showed it.** It read only the program counter, and that is
/// ambiguous exactly where it matters: an idle run loop and a main thread wedged
/// in a synchronous XPC both bottom out in `mach_msg2_trap`, and only the
/// *caller* tells them apart (`__CFRunLoopServiceMachPort` vs `SecItemCopyMatching`
/// / `xpc_connection_*`). The first file was 19-20 of every 20 samples in
/// `mach_msg2_trap` and told us the main thread is *waiting*, not spinning —
/// which is the opposite of what the "runaway update loop" reading assumed — but
/// not what it is waiting on. So walk the frame pointer chain and record the
/// caller frames too.
///
/// It also overwrote its own evidence: the ring is rewritten every second, so
/// relaunching the app replaced the frozen window with an idle one before anyone
/// could read it. So the ring is only *preserved* when the main thread is
/// actually stuck — a main-queue heartbeat stops when the main thread cannot
/// drain its own queue, which is precisely the failure — and that episode is
/// appended to `mainsample-freeze.txt`, which is never rewritten.
///
/// Both files are in the app's Documents folder; `UIFileSharingEnabled` puts them
/// in the Files app. Remove this file, its call site in `CodegiOSApp`, and the two
/// file-sharing Info.plist keys once the culprit is known.
enum MainThreadSampler {
    private static let sampleInterval = 0.05   // 20 Hz
    private static let windowCount = 10        // seconds of history kept
    private static let heartbeatInterval = 0.25
    /// How long the main queue may go undrained before the ring is preserved.
    private static let stallThreshold: UInt64 = 2_000_000_000

    /// The main thread's Mach port, captured from the main thread at launch —
    /// `mach_thread_self()` on a background thread returns *that* thread.
    private static var mainThread: thread_t = 0
    private static let queue = DispatchQueue(label: "app.codeg.mainSampler")
    private static var samplerTimer: DispatchSourceTimer?
    private static var heartbeatTimer: DispatchSourceTimer?

    private static var window: [String: Int] = [:]
    private static var history: [[(String, Int)]] = []
    private static var lastWindowAt = Date.distantPast

    /// Bumped by a main-queue timer. It stops advancing exactly when the main
    /// thread is wedged, which is the signal the sampler needs — `mach_msg2_trap`
    /// on its own cannot distinguish wedged from idle.
    private static var mainHeartbeat: UInt64 = 0
    private static var stallReported = false

    /// The main thread's stack bounds, so the frame-pointer walk can reject a
    /// wild pointer before dereferencing it.
    private static var stackLow: UInt = 0
    private static var stackHigh: UInt = 0

    /// Call once, from the main thread, as early as possible.
    static func start() {
        guard mainThread == 0 else { return }
        mainThread = mach_thread_self()

        if let thread = pthread_from_mach_thread_np(mainThread) {
            let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
            let size = UInt(pthread_get_stacksize_np(thread))
            stackHigh = top
            stackLow = top > size ? top - size : 0
        }

        let sampler = DispatchSource.makeTimerSource(queue: queue)
        sampler.schedule(deadline: .now() + 1, repeating: sampleInterval)
        sampler.setEventHandler { tick() }
        sampler.resume()
        samplerTimer = sampler

        let heartbeat = DispatchSource.makeTimerSource(queue: .main)
        heartbeat.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        heartbeat.setEventHandler { mainHeartbeat = DispatchTime.now().uptimeNanoseconds }
        heartbeat.resume()
        heartbeatTimer = heartbeat
    }

    private static func tick() {
        guard mainThread != 0 else { return }
        if let state = sampleRegisters() {
            window[describe(frames(of: state)), default: 0] += 1
        }

        let now = Date()
        if now.timeIntervalSince(lastWindowAt) >= 1 {
            lastWindowAt = now
            history.append(window.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) })
            if history.count > windowCount { history.removeFirst(history.count - windowCount) }
            window = [:]
            flushRolling()
        }

        checkForStall()
    }

    // MARK: - Stalled?

    /// The main queue not being drained for a couple of seconds is the failure we
    /// are hunting, and it is the one thing a rolling file cannot show: the app
    /// gets killed, the next launch overwrites the ring within a second, and the
    /// frozen window is gone. Preserve it instead, once per episode.
    private static func checkForStall() {
        let beat = mainHeartbeat
        guard beat != 0 else { return }
        let age = DispatchTime.now().uptimeNanoseconds &- beat
        if age > stallThreshold {
            if !stallReported {
                stallReported = true
                appendFrozenEpisode(stalledFor: age)
            }
        } else {
            stallReported = false
        }
    }

    private static func appendFrozenEpisode(stalledFor age: UInt64) {
        let header = "\n===== main queue stalled for \(age / 1_000_000) ms"
            + "  (\(Date())) =====\n"
        guard let directory = documentsDirectory() else { return }
        let url = directory.appendingPathComponent("mainsample-freeze.txt")
        guard let data = (header + renderedHistory()).data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Sampling

    /// The main thread's registers. It is suspended for exactly these two calls
    /// and resumed immediately: the frame-pointer walk calls `dladdr`, which
    /// takes dyld's lock, and taking it while the main thread is stopped could
    /// deadlock against a main thread holding it.
    private static func sampleRegisters() -> arm_thread_state64_t? {
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return nil }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        thread_resume(mainThread)
        guard result == KERN_SUCCESS else { return nil }
        return state
        #else
        return nil
        #endif
    }

    /// Program counter, then the caller frames walked off the frame-pointer
    /// chain. The caller is the whole point: `mach_msg2_trap` is the leaf for
    /// both an idle run loop and a wedged synchronous XPC, and only the frame
    /// above says which.
    private static func frames(of state: arm_thread_state64_t) -> [UInt] {
        #if arch(arm64)
        var addresses = [UInt(state.__pc)]
        if state.__lr != 0 { addresses.append(UInt(state.__lr)) }

        var frame = UInt(state.__fp)
        for _ in 0..<4 {
            guard let next = pointer(at: frame),
                  let returned = pointer(at: frame &+ 8),
                  next > frame else { break }
            if returned != 0 { addresses.append(returned) }
            frame = next
        }

        // Leaf frames repeat the PC in LR; collapse those so the chain reads as
        // a call chain rather than as noise.
        var deduped: [UInt] = []
        for address in addresses where address != deduped.last {
            deduped.append(address)
        }
        return deduped
        #else
        return []
        #endif
    }

    /// A read that cannot crash on a wild frame pointer. The main thread's stack
    /// bounds are known, so a frame pointer outside them is rejected before it is
    /// dereferenced, and a release build that omits frame pointers degrades to a
    /// shorter chain instead of faulting.
    ///
    /// (Not `mach_vm_read_overwrite`: `mach/mach_vm.h` is not part of the Darwin
    /// module, so that symbol is not in scope for Swift here. The stack-bounds
    /// check needs no Mach VM API at all.)
    private static func pointer(at address: UInt) -> UInt? {
        guard address % 8 == 0,
              address >= stackLow,
              address &+ 16 <= stackHigh else { return nil }
        return UnsafeRawPointer(bitPattern: address)?.load(as: UInt.self)
    }

    /// `Image  symbol` per frame, innermost first. The image is the point: it
    /// survives stripping and it survives the symbol being private, which is the
    /// usual case inside SwiftUI and AttributeGraph.
    private static func describe(_ addresses: [UInt]) -> String {
        addresses.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
                return String(format: "0x%llx", UInt64(address))
            }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
            return "\(image) \(symbol)"
        }
        .joined(separator: "  ←  ")
    }

    // MARK: - Output

    private static func documentsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func renderedHistory() -> String {
        history.enumerated().map { offset, entries in
            let age = history.count - offset
            let body = entries.map { "\($0.1)× \($0.0)" }.joined(separator: "\n            ")
            return "[\(age)s ago]  \(body)"
        }.joined(separator: "\n") + "\n"
    }

    private static func flushRolling() {
        guard let directory = documentsDirectory() else { return }
        try? renderedHistory().write(
            to: directory.appendingPathComponent("mainsample.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
