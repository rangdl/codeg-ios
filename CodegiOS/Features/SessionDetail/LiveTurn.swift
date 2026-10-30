import SwiftUI
import Foundation

/// The streaming state of a single in-flight tool call, keyed by its ACP tool
/// id. Mutated in place as `tool_call_update` events arrive so the UI updates
/// granularly without rebuilding the whole turn.
@MainActor
final class LiveToolCall: Identifiable, ObservableObject {
    nonisolated let id: String
    @Published var title: String
    @Published var kind: String
    @Published var status: String
    /// Echoed argument JSON (preview), shown under the tool name.
    @Published var rawInput: String?
    /// Accumulated output text. `tool_call_update` with `append:true` appends,
    /// otherwise the value replaces.
    @Published var rawOutput: String
    /// ACP "rendered content" — for an edit this is the unified diff. Kept so the
    /// card can render a red/green diff live (previously this field was dropped).
    @Published var content: String?
    /// ACP `meta` — for `delegate_to_agent` carries `codeg.delegation`, whose
    /// terminal status the delegate card prefers over the running ack. Patched in
    /// place when a `tool_call_update` carries a newer meta.
    @Published var meta: AnyJSON?

    init(id: String, title: String, kind: String, status: String, rawInput: String?, rawOutput: String, content: String? = nil, meta: AnyJSON? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.content = content
        self.meta = meta
    }

    /// True once the agent reports the call finished (success or failure).
    var isFinished: Bool {
        switch status {
        case "completed", "failed", "error", "cancelled", "canceled": return true
        default: return false
        }
    }

    var isError: Bool {
        status == "failed" || status == "error"
    }

    /// SF Symbol chosen from the ACP `kind` hint, falling back to a generic
    /// wrench. Mirrors the kinds emitted by the codeg agents.
    var symbol: String {
        switch kind.lowercased() {
        case "read", "fetch": return "doc.text"
        case "edit", "write": return "square.and.pencil"
        case "search", "grep", "find": return "magnifyingglass"
        case "execute", "command", "bash", "shell", "terminal": return "terminal"
        case "think": return "brain"
        case "delete": return "trash"
        case "move": return "arrow.right.doc.on.clipboard"
        case "web", "browser": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// One ordered piece of an in-flight assistant turn. The live turn is a sequence
/// of these so text, reasoning, and tool calls render in arrival order, exactly
/// as a finalized transcript would. The associated reference types expose a
/// `nonisolated let id`, so the enum's `id` needs no actor hop.
enum LiveSegment: Identifiable {
    case text(LiveTextRun)
    case thinking(LiveTextRun)
    case tool(LiveToolCall)
    /// A native-steering message injected mid-turn. It closes the preceding
    /// assistant reply and opens a fresh assistant segment after it.
    case steering(MessageTurn)

    var id: String {
        switch self {
        case .text(let run): return "t-\(run.id)"
        case .thinking(let run): return "k-\(run.id)"
        case .tool(let call): return "x-\(call.id)"
        case .steering(let turn): return "s-\(turn.id)"
        }
    }
}

/// A growing run of text (either assistant prose or reasoning). A reference type
/// so appending a delta mutates in place and SwiftUI re-renders just this run.
///
/// Deltas land token-by-token, but the *published* `text` is coalesced to a
/// ~50ms cadence so the view re-parses (block Markdown) at most ~20×/sec instead
/// of once per token — the streaming path now renders formatted Markdown live
/// (`MarkdownContent`), and re-parsing the whole accumulated reply per token
/// would be O(n²) main-thread work. The raw `buffer` is always current (so
/// snapshots never lose the tail); `text` trails it by up to one coalesce window.
@MainActor
final class LiveTextRun: Identifiable, ObservableObject {
    /// Stable within a turn: the run's ordinal among runs of its kind. A snapshot
    /// rebuild walks the same blocks in the same order, so a rebuilt run lands on
    /// the id its predecessor had — which is what preserves SwiftUI's node identity
    /// (and therefore the transcript's layout) across a rebuild. A fresh UUID here
    /// re-created every live text/reasoning node on every snapshot, so the whole
    /// in-flight reply was torn down and re-laid-out — the "jump" seen while a long
    /// command streams.
    nonisolated let id: String

    /// What views render. Published at most ~every 50ms while streaming.
    @Published private(set) var text: String

    /// The full accumulated text, updated synchronously on every delta. NOT
    /// observed, so appends don't invalidate views between flushes; read via
    /// `fullText` for snapshotting.
    private var buffer: String
    /// Pending coalesce task; non-nil means a flush is already scheduled.
    private var flushTask: Task<Void, Never>?

    /// Coalesce window for streamed text, scaled with the accumulated length. Each
    /// flush re-parses the whole buffer (block Markdown), which is ~O(n), so a fixed
    /// 50ms cadence makes the stream O(n²). Short replies — the common case — stay
    /// snappy at 50ms; a long reply relaxes toward ~140ms, dropping the re-parse
    /// rate as the per-parse cost rises. `flushNow()` still publishes the complete
    /// text on finalize, so this only trades a little tail latency, never content.
    private var coalesceWindow: Duration {
        switch buffer.utf8.count {
        case ..<4_000:  return .milliseconds(50)
        case ..<16_000: return .milliseconds(90)
        default:        return .milliseconds(140)
        }
    }

    init(id: String, _ text: String) {
        self.id = id
        self.text = text
        self.buffer = text
    }

    /// Authoritative full content, regardless of any pending flush. Snapshots and
    /// finalization read this so the last partial chunk is never dropped.
    var fullText: String { buffer }

    /// Append a streamed delta. The buffer updates immediately; the observed
    /// `text` is published on the next coalesce tick.
    func append(_ delta: String) {
        buffer += delta
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }   // leading-guard: one task per window
        let window = coalesceWindow              // sampled at schedule time
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard let self else { return }
            self.flushTask = nil
            if self.text != self.buffer { self.text = self.buffer }   // trailing publish
        }
    }

    /// Publish the buffer immediately and cancel any pending coalesce. Call when
    /// the turn finalizes / fails / is cancelled so the finalized render sees the
    /// complete text with no trailing reflow.
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        if text != buffer { text = buffer }
    }
}

/// The mutable, observable model for the assistant reply that is currently
/// streaming. Built optimistically when the user sends, mutated as ACP events
/// arrive, then converted to an immutable `MessageTurn` on completion.
@MainActor
final class LiveTurn: Identifiable, ObservableObject {
    nonisolated let id: String
    @Published private(set) var segments: [LiveSegment] = []
    /// Tool-call lookup so `tool_call_update` finds its target in O(1).
    @Published private var toolIndex: [String: LiveToolCall] = [:]
    /// How many text / reasoning runs this turn has started, so each gets a
    /// rebuild-stable id (see `LiveTextRun.id`).
    private var textRunCount = 0
    private var thinkingRunCount = 0
    /// The agent's live plan/TODO list (`plan_update`). Replaced wholesale per
    /// event (each carries the full list); rendered as a checklist above the turn.
    @Published var livePlan: [PlanEntry] = []
    /// Fatal error surfaced inline at the end of the turn.
    @Published var errorMessage: String?
    /// Whether the turn is still receiving events (drives the pulse).
    @Published var isStreaming = true
    /// Most recent stop reason once the turn completes.
    @Published var stopReason: String?
    /// When this turn started. Carried from a reattach snapshot when available,
    /// so the live elapsed timer doesn't restart when the screen reopens.
    nonisolated let startedAt: Date
    /// Rough output-token rate over the last few seconds (web parity). Updated at
    /// most twice a second; nil until enough new output has arrived to measure.
    @Published private(set) var outputTokensPerSecond: Double?

    /// Cumulative estimated output tokens (text + reasoning). Reset to zero after
    /// a snapshot hydration so the rate measures only what streams from here.
    private var outputTokens: Double = 0
    private var speedSamples: [(at: Date, tokens: Double)] = []
    private var lastSpeedSampleAt: Date = .distantPast
    /// Cached edit totals; invalidated whenever a tool call is added/patched so
    /// the stats row never re-parses every diff on each one-second tick.
    private var cachedEditStats: (files: Int, additions: Int, deletions: Int)?

    init(id: String = "live-\(UUID().uuidString)", startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
    }

    /// True before any content has streamed — used to show a "waiting" shimmer.
    var isEmpty: Bool { segments.isEmpty && errorMessage == nil && livePlan.isEmpty }

    /// Replace the live plan from a `plan_update` event (or snapshot `plan` block).
    func updatePlan(_ entries: [PlanEntry]) {
        livePlan = entries
    }

    // MARK: - Mutation (event handlers call these on the main actor)

    func appendText(_ delta: String) {
        guard !delta.isEmpty else { return }
        noteOutput(delta)
        if case .text(let run)? = segments.last {
            run.append(delta)
        } else {
            segments.append(.text(LiveTextRun(id: "t\(textRunCount)", delta)))
            textRunCount += 1
        }
    }

    func appendThinking(_ delta: String) {
        guard !delta.isEmpty else { return }
        noteOutput(delta)
        if case .thinking(let run)? = segments.last {
            run.append(delta)
        } else {
            segments.append(.thinking(LiveTextRun(id: "k\(thinkingRunCount)", delta)))
            thinkingRunCount += 1
        }
    }

    /// A snapshot rebuild appends the whole already-streamed reply at once. Drop
    /// that from the rate measurement so the first post-reattach sample doesn't
    /// report the entire turn as one burst.
    func resetOutputSpeed() {
        outputTokens = 0
        speedSamples.removeAll()
        outputTokensPerSecond = nil
        lastSpeedSampleAt = .distantPast
    }

    /// Running edit totals across this turn's tool calls, for the live stats row.
    /// Built from the same diff derivation the cards use, so the figures agree.
    var liveEditStats: (files: Int, additions: Int, deletions: Int) {
        if let cachedEditStats { return cachedEditStats }
        var paths = Set<String>()
        var additions = 0
        var deletions = 0
        for segment in segments {
            guard case .tool(let call) = segment else { continue }
            let state: ToolCallState = call.isFinished ? (call.isError ? .error : .done) : .running
            let vm = ToolCallVM(
                id: call.id,
                rawName: call.title,
                kind: call.kind,
                state: state,
                input: call.rawInput,
                output: call.rawOutput,
                content: call.content,
                isError: call.isError,
                meta: call.meta
            )
            guard let files = vm.diffFiles else { continue }
            for file in files {
                paths.insert(file.path)
                additions += file.additions
                deletions += file.deletions
            }
        }
        let stats = (paths.count, additions, deletions)
        cachedEditStats = stats
        return stats
    }

    /// Add one text/thinking delta to the token-rate estimator. Deltas arrive per
    /// token; the published rate is sampled at most twice a second over a sliding
    /// three-second window, so the readout is steady rather than jittery.
    private func noteOutput(_ delta: String) {
        outputTokens += TokenEstimate.tokens(in: delta)
        let now = Date()
        guard now.timeIntervalSince(lastSpeedSampleAt) >= 0.5 else { return }
        lastSpeedSampleAt = now
        speedSamples.append((now, outputTokens))
        let cutoff = now.addingTimeInterval(-3)
        while speedSamples.count > 2, speedSamples[0].at < cutoff {
            speedSamples.removeFirst()
        }
        guard let first = speedSamples.first, let last = speedSamples.last else { return }
        let seconds = last.at.timeIntervalSince(first.at)
        guard seconds >= 0.5 else { return }
        outputTokensPerSecond = max(0, (last.tokens - first.tokens) / seconds)
    }

    /// Insert a delivered native-steering note once. The server broadcasts the
    /// same item to the submitting client as well as every other attached
    /// client, so the id check makes the HTTP response and stream event idempotent.
    @discardableResult
    func insertSteering(_ item: FeedbackItem) -> Bool {
        guard item.status == .delivered else { return false }
        let turnID = "steer-\(item.id)"
        guard !segments.contains(where: {
            if case .steering(let turn) = $0 { return turn.id == turnID }
            return false
        }) else { return false }

        var blocks: [ContentBlock] = []
        for block in item.blocks ?? [] {
            switch block {
            case .text(let text):
                if !text.isEmpty { blocks.append(.text(text)) }
            case .image(let image):
                blocks.append(.image(image))
            case .unknown:
                break
            }
        }
        if blocks.isEmpty, !item.text.isEmpty {
            blocks.append(.text(item.text))
        }
        guard !blocks.isEmpty else { return false }
        segments.append(.steering(MessageTurn(
            id: turnID,
            role: .user,
            blocks: blocks,
            timestamp: item.createdAt
        )))
        return true
    }

    /// Delivered steering messages currently represented in the live stream.
    var steeringTurns: [MessageTurn] {
        segments.compactMap {
            if case .steering(let turn) = $0 { return turn }
            return nil
        }
    }

    /// Flush every text/reasoning run's pending coalesce immediately. Called when
    /// the turn ends so the finalized render sees complete text (no trailing
    /// reflow) and a snapshot taken right after is whole.
    func flushAllText() {
        for segment in segments {
            switch segment {
            case .text(let run), .thinking(let run): run.flushNow()
            case .tool, .steering: break
            }
        }
    }

    func upsertToolCall(id: String, title: String, kind: String, status: String, rawInput: String?, rawOutput: String?, content: String?, meta: AnyJSON? = nil) {
        cachedEditStats = nil
        if let existing = toolIndex[id] {
            existing.title = title.isEmpty ? existing.title : title
            if !kind.isEmpty { existing.kind = kind }
            if !status.isEmpty { existing.status = status }
            if let rawInput { existing.rawInput = rawInput }
            if let rawOutput { existing.rawOutput = rawOutput }
            if let content { existing.content = content }
            if let meta { existing.meta = meta }
        } else {
            let call = LiveToolCall(
                id: id,
                title: title.isEmpty ? "Tool" : title,
                kind: kind,
                status: status.isEmpty ? "in_progress" : status,
                rawInput: rawInput,
                rawOutput: rawOutput ?? "",
                content: content,
                meta: meta
            )
            toolIndex[id] = call
            segments.append(.tool(call))
        }
    }

    func updateToolCall(id: String, title: String?, status: String?, rawInput: String?, rawOutput: String?, content: String?, append: Bool, meta: AnyJSON? = nil) {
        cachedEditStats = nil
        guard let call = toolIndex[id] else {
            // An update for a tool we never saw a `tool_call` for — materialize it
            // so its input/output is not lost.
            upsertToolCall(
                id: id,
                title: title ?? "",
                kind: "",
                status: status ?? "",
                rawInput: rawInput,
                rawOutput: rawOutput,
                content: content,
                meta: meta
            )
            return
        }
        if let title, !title.isEmpty { call.title = title }
        if let status, !status.isEmpty { call.status = status }
        // Capture arguments arriving on an update (or replacing a partial input)
        // so companion classification can key off the input shape.
        if let rawInput, !rawInput.isEmpty { call.rawInput = rawInput }
        if let content { call.content = content }
        // A newer meta (e.g. the delegate lifecycle's terminal `codeg.delegation`)
        // replaces the prior one so the live delegate card stops reading "running".
        if let meta { call.meta = meta }
        if let rawOutput {
            if append { call.rawOutput += rawOutput } else { call.rawOutput = rawOutput }
        }
    }

    /// Short human-readable label for the currently active tool, for the compose
    /// status line ("Running Edit…").
    var activeToolTitle: String? {
        for segment in segments.reversed() {
            if case .tool(let call) = segment, !call.isFinished {
                return call.title
            }
        }
        return nil
    }

    /// Snapshot this finalized stream as immutable turns, splitting at every
    /// native-steering message. This lets an unreconciled reply survive a
    /// subsequent send without collapsing its mid-turn user boundaries.
    /// Segment→block mapping mirrors `MessageRender.adaptLive`; a tool's diff
    /// `content` rides in the result preview when there is no separate output.
    func snapshotAsMessageTurns() -> [MessageTurn] {
        var out: [MessageTurn] = []
        var assistantBlocks: [ContentBlock] = []
        var assistantIndex = 0

        func flushAssistant() {
            guard !assistantBlocks.isEmpty else { return }
            let turnID = assistantIndex == 0 ? id : "\(id)#assistant-\(assistantIndex)"
            out.append(MessageTurn(
                id: turnID,
                role: .assistant,
                blocks: assistantBlocks,
                timestamp: Date()
            ))
            assistantBlocks.removeAll(keepingCapacity: true)
            assistantIndex += 1
        }

        for segment in segments {
            switch segment {
            case .text(let run):
                if !run.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistantBlocks.append(.text(run.fullText))
                }
            case .thinking(let run):
                if !run.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistantBlocks.append(.thinking(run.fullText))
                }
            case .tool(let call):
                assistantBlocks.append(.toolUse(id: call.id, name: call.title, inputPreview: call.rawInput, meta: call.meta))
                let output = call.rawOutput.isEmpty ? call.content : call.rawOutput
                assistantBlocks.append(.toolResult(id: call.id, outputPreview: output, isError: call.isError))
            case .steering(let turn):
                flushAssistant()
                out.append(turn)
            }
        }
        flushAssistant()
        return out
    }
}


/// Rough token estimate for streamed text, mirroring the web client's heuristic:
/// CJK-family scripts tokenize denser (~1.8 chars/token) than Latin (~4), and
/// whitespace is skipped. Accuracy is intentionally approximate — this only feeds
/// the live tok/s gauge.
enum TokenEstimate {
    static func tokens(in text: String) -> Double {
        var dense = 0
        var other = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if isSpace(v) { continue }
            if isDense(v) { dense += 1 } else { other += 1 }
        }
        return Double(dense) / 1.8 + Double(other) / 4
    }

    private static func isSpace(_ v: UInt32) -> Bool {
        if v == 0x20 { return true }
        if v <= 0x0d { return v >= 0x09 }
        if v < 0xa0 { return false }
        return v == 0xa0 || v == 0x1680
            || (v >= 0x2000 && v <= 0x200a)
            || v == 0x2028 || v == 0x2029 || v == 0x202f
            || v == 0x205f || v == 0x3000 || v == 0xfeff
    }

    private static func isDense(_ v: UInt32) -> Bool {
        if v < 0x2e80 { return v >= 0x1100 && v <= 0x11ff }
        return (v >= 0x2e80 && v <= 0x303f)
            || (v >= 0x3040 && v <= 0x30ff)
            || (v >= 0x3130 && v <= 0x318f)
            || (v >= 0x31c0 && v <= 0x4dbf)
            || (v >= 0x4e00 && v <= 0x9fff)
            || (v >= 0xa960 && v <= 0xa97f)
            || (v >= 0xac00 && v <= 0xd7ff)
            || (v >= 0xf900 && v <= 0xfaff)
            || (v >= 0xfe30 && v <= 0xfe4f)
            || (v >= 0xff00 && v <= 0xffef)
    }
}
