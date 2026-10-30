import SwiftUI

/// Subscribes to the server's legacy global `app://agent-install` event channel
/// for one install task and forwards its log lines to the settings model.
///
/// The normal session `EventStream` ignores legacy channel frames; this monitor
/// asks for them explicitly (`captureAppEvents: true`), so unrelated folder /
/// conversation broadcasts stay out of every conversation socket.
@MainActor
final class AgentInstallMonitor {
    enum Status { case idle, running, success, failed }

    private let taskId: String
    private let onUpdate: ([String]) -> Void
    private var stream: EventStream?
    private var consumer: Task<Void, Never>?
    private var isReady = false
    private(set) var logs: [String] = []
    private(set) var status: Status = .idle

    init(taskId: String, onUpdate: @escaping ([String]) -> Void) {
        self.taskId = taskId
        self.onUpdate = onUpdate
    }

    /// Opens the socket and waits briefly for the server's ready frame so the
    /// first install lines aren't dropped. Proceeds on timeout: a missing log
    /// stream must never block the install itself.
    func start(baseURL: URL, token: String) async {
        let stream = EventStream(baseURL: baseURL, token: token, captureAppEvents: true)
        self.stream = stream
        stream.start()
        consumer = Task { [weak self] in
            for await frame in stream.frames {
                if Task.isCancelled { return }
                guard let self else { return }
                switch frame {
                case .ready:
                    self.isReady = true
                case .appEvent(let channel, let payload):
                    guard channel == "app://agent-install" else { continue }
                    self.ingest(payload)
                case .closed:
                    return
                default:
                    break
                }
            }
        }
        for _ in 0..<20 where !isReady {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
        stream?.close()
        stream = nil
    }

    private func ingest(_ payload: AnyJSON) {
        guard payload["task_id"]?.string == taskId else { return }
        let kind = payload["kind"]?.string ?? ""
        let text = payload["payload"]?.string ?? ""
        switch kind {
        case "started":
            status = .running
        case "log":
            append(text)
        case "completed":
            append(text)
            status = .success
        case "failed":
            append("ERROR: \(text)")
            status = .failed
        default:
            break
        }
    }

    private func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logs.append(trimmed)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        onUpdate(logs)
    }
}
