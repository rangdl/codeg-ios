import SwiftUI
import UIKit

// MARK: - Scroll action (environment)

/// A scroll capability the transcript publishes into the environment so any
/// descendant (an assistant reply's "scroll to question" button) can move the
/// viewport without threading the `ScrollViewProxy` down by hand.
struct TranscriptScrollAction {
    let perform: (String, UnitPoint) -> Void
    func callAsFunction(_ id: String, anchor: UnitPoint = .top) { perform(id, anchor) }
}

private struct TranscriptScrollKey: EnvironmentKey {
    static let defaultValue = TranscriptScrollAction { _, _ in }
}

extension EnvironmentValues {
    var transcriptScroll: TranscriptScrollAction {
        get { self[TranscriptScrollKey.self] }
        set { self[TranscriptScrollKey.self] = newValue }
    }
}

/// The transcript's scroll signals.
///
/// These live in their own object rather than on `SessionDetailViewModel` on
/// purpose: a tick every ~50 ms while a reply streams would otherwise invalidate
/// the whole session screen (header, transcript, compose bar) — and only the
/// transcript needs to see it. The transcript observes this object directly, so a
/// tick re-evaluates just the transcript.
@MainActor
final class TranscriptScrollSignals: ObservableObject {
    /// Bumped on streamed content growth; the transcript follows it ONLY while
    /// pinned to the bottom.
    @Published private(set) var scrollTick = 0
    /// Bumped on the user's own send / initial load; forces a re-pin regardless of
    /// the current scroll position.
    @Published private(set) var stickTick = 0

    /// Coalesces streamed follow requests to one per ~50 ms window: the ACP stream
    /// delivers tokens far faster than the display refreshes, and the text itself
    /// is coalesced on the same cadence, so this keeps them in step.
    private var pending = false

    func requestScroll() {
        guard !pending else { return }
        pending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            self.pending = false
            self.scrollTick &+= 1
        }
    }

    /// Force a re-pin to the bottom even if the reader had scrolled up.
    func requestStick() {
        stickTick &+= 1
    }
}

// MARK: - Transcript

/// The scrollable transcript, rendered as a **vertical timeline**: a continuous
/// rail runs top-to-bottom and every event — each user message, reasoning block,
/// tool call, tool group, assistant text segment, and system note — is a node on
/// it (`TranscriptTimeline.buildPersisted` flattens persisted + optimistic pending
/// turns and `buildLive` the live streaming turn, into `[TimelineNode]`). An
/// optional leading `header` scrolls away above the first node.
///
/// Backed by a `ScrollView` + `LazyVStack` so only on-screen rows are realized —
/// the iOS-native counterpart to the web client's `virtua` windowing — which
/// suits the timeline well (many small per-part rows).
///
/// The content is **inverted**: the stack is flipped with `scaleEffect(y: -1)` and
/// every row flipped back, so the newest node sits at the bottom and the bottom is
/// `contentOffset` 0. Streaming then grows *away* from the viewport, which is what
/// removes the need to measure anything — see the note in `body`. Going to the
/// bottom is a plain offset set on the backing `UIScrollView` (`scrollToBottom`),
/// never `ScrollViewProxy.scrollTo`, which lands on blank space for unrealized rows
/// and traps on iOS 16 when called from a stale proxy.
///
/// To keep opening a very long session fast, only a **window** of the most recent
/// turns is built and rendered initially; older turns are revealed as the user
/// scrolls up (see the windowing section below). This bounds the on-open work —
/// decode aside, both node construction and the initial layout become
/// O(window) rather than O(history).
struct TranscriptView<Header: View>: View {
    let turns: [MessageTurn]
    let pendingUserTurns: [MessageTurn]
    let liveTurn: LiveTurn?
    /// When the live turn was rebuilt from a reattach snapshot, it is the
    /// authoritative complete in-flight reply; the persisted partial copy the
    /// agent is concurrently writing into `turns` is hidden so it isn't doubled.
    var liveOwnsInFlightReply: Bool = false
    /// The session's agent, for the agent-branded marker on assistant nodes.
    let agent: AgentType
    /// A cheap, monotonic version of the view model's `turns`, bumped on every
    /// mutation. The persisted node tier is memoized on it (plus the window /
    /// pending / suppression signals), so a streamed token — which re-runs this
    /// view via `scrollTick` — no longer rebuilds and re-hashes the whole visible
    /// transcript to follow the scroll.
    let turnsVersion: Int
    /// Bumped on streamed content growth; the transcript follows it ONLY while
    /// pinned to the bottom.
    @ObservedObject var signals: TranscriptScrollSignals
    /// Reports whether the viewport is parked at the bottom. The owning view uses
    /// it to show/hide the floating "jump to latest" button (which lives above the
    /// compose bar, not here, so it is reliably tappable).
    let onPinnedChange: (Bool) -> Void
    /// Scrolls with the content as the first element (header above the first
    /// node). Kept generic so the transcript stays agnostic of the header's type.
    @ViewBuilder var header: () -> Header

    /// Whether the viewport is parked at (or near) the bottom. Drives the
    /// auto-follow (only follow streamed tokens when true). Starts true so a fresh
    /// open follows.
    @State private var stuckToBottom = true
    /// The transcript's backing `UIScrollView`, resolved via introspection. It is
    /// needed for exactly one thing now — setting the offset to the bottom on an
    /// explicit request — because with the content flipped the bottom is the
    /// smallest offset the scroll view accepts, a constant that needs no
    /// measurement. (`ScrollViewProxy.scrollTo` is still not used for it: it lands
    /// on blank space when the target row isn't realized under a `LazyVStack`, and
    /// traps inside SwiftUI on iOS 16 when called from a proxy captured in an
    /// earlier update — `logs/*.ips`.)
    @State private var listScrollView: UIScrollView?
    /// Tracks the previous near-history-end state so we only page in older turns
    /// when *entering* the zone (iOS 16 has no Bool-mapping
    /// `onScrollGeometryChange`).
    @State private var lastNearTop = false


    // MARK: Windowing
    //
    // A very long transcript (thousands of turns) is expensive to open: the whole
    // history is decoded, every turn is flattened into nodes, and the stack lays
    // out the full set before the first frame — on a 6k-turn session that's
    // hundreds of ms of on-main work, exactly the cost the web client avoids by
    // virtualizing. So we only build + render a *window* of the most recent turns
    // initially, and load older ones when the user scrolls up. `build` + layout
    // become O(window) instead of O(history), so open time stops growing with
    // length.
    //
    // `windowStartTurn` is the absolute index into `turns` where the window begins;
    // `nil` means "not yet expanded" → the window is anchored to the tail and
    // follows new turns. Persisted turns only grow at the end, so an absolute index
    // stays valid as the conversation advances.

    /// How many trailing turns to show on first open. Enough to fill the viewport
    /// with room to spare; small enough that layout is instant.
    private let initialTurnWindow = 50
    /// How many older turns to reveal each time the user scrolls near the top.
    private let pageTurns = 150
    /// Distance from the top (pt) at which to begin loading older turns — generous
    /// so history is ready before the user reaches the very top.
    private let loadEarlierThreshold: CGFloat = 600

    @State private var windowStartTurn: Int?
    /// Re-entrancy guard so a burst of near-top scroll events loads one page, not many.
    @State private var isLoadingEarlier = false

    // MARK: Node memoization
    //
    // `body` re-runs on every streamed token (the scroll-follow bumps `scrollTick`),
    // but the *persisted* node tier changes only when `turns` / the window / pending
    // / in-flight suppression change — never per token. Rebuilding it per token is
    // O(all visible text): `MessageRender.adaptTurn`'s value-keyed cache hashes each
    // `MessageTurn`'s full content on lookup (`MessageTurn` is content-`Hashable`).
    // So the persisted tier is memoized behind this cheap, content-free key and only
    // rebuilt when the key changes. The live tier is always rebuilt fresh (cheap,
    // and required so live tool / plan state doesn't freeze — see `buildLive`).
    //
    // The cache lives in a reference holder (a plain class) so it survives the
    // per-token re-instantiation of this struct at its fixed position, and so the
    // `nodes` accessor can update it without tripping `@State` invalidation: we
    // mutate the holder's fields, never reassign the `@State`. Safe because `body`
    // and the builders are `@MainActor`, so every access is serialized.
    private struct PersistedKey: Equatable {
        var turnsVersion: Int
        var effectiveStart: Int
        var pendingIDs: [String]
        var suppressInFlight: Bool
        var agent: AgentType
    }
    private final class PersistedMemo {
        var key: PersistedKey?
        var nodes: [TimelineNode] = []
    }
    @State private var persistedMemo = PersistedMemo()

    /// The first turn index currently shown. When not explicitly expanded, anchors
    /// to the tail (most recent `initialTurnWindow` turns), snapped back to a
    /// user/system boundary so an assistant reply is never split and keeps its
    /// originating question in-window (jump-to-question stays correct).
    private var effectiveStart: Int {
        if let s = windowStartTurn { return min(max(0, s), turns.count) }
        guard turns.count > initialTurnWindow else { return 0 }
        return snappedStart(turns.count - initialTurnWindow)
    }

    /// Whether the window reaches the true start of the conversation (everything
    /// loaded). Only then is the scrollaway `header` shown and the rail's top capped.
    private var headLoaded: Bool { effectiveStart == 0 }

    /// Walk back from `desired` to the nearest non-assistant (user/system) turn so
    /// the window never starts in the middle of a merged assistant reply.
    private func snappedStart(_ desired: Int) -> Int {
        guard !turns.isEmpty else { return 0 }
        var i = min(max(0, desired), turns.count - 1)
        while i > 0, turns[i].role == .assistant { i -= 1 }
        return i
    }

    /// The flattened timeline: a memoized **persisted** tier + a fresh **live**
    /// tier. The persisted tier is expensive (it hashes every visible turn's content
    /// through `adaptTurn`'s cache), so it is reused whenever the cheap `PersistedKey`
    /// is unchanged — which is every streamed token. The live tier is rebuilt each
    /// pass (cheap; keeps live tool / plan cards updating). Rail endpoints are
    /// terminated on the *combined* list so the tail's `connectBottom` lands on the
    /// live node while a reply streams.
    private var nodes: [TimelineNode] {
        let start = effectiveStart
        let suppressInFlight = liveTurn != nil && liveOwnsInFlightReply
        let key = PersistedKey(
            turnsVersion: turnsVersion,
            effectiveStart: start,
            pendingIDs: pendingUserTurns.map(\.id),
            suppressInFlight: suppressInFlight,
            agent: agent
        )

        let persisted: [TimelineNode]
        if persistedMemo.key == key {
            persisted = persistedMemo.nodes
        } else {
            let slice = start == 0 ? turns : Array(turns[start...])
            persisted = TranscriptTimeline.buildPersisted(
                turns: slice, pending: pendingUserTurns, agent: agent,
                suppressInFlight: suppressInFlight
            )
            persistedMemo.key = key
            persistedMemo.nodes = persisted
        }

        var all = persisted
        if let liveTurn {
            all.append(contentsOf: TranscriptTimeline.buildLive(liveTurn, agent: agent))
        }
        // Terminate the rail at its endpoints, on the *combined* list. The top
        // terminates only when the window starts at the true beginning of the
        // conversation; otherwise the spine continues up into the not-yet-loaded
        // turns.
        if !all.isEmpty {
            if start == 0 { all[0].connectTop = false }
            all[all.count - 1].connectBottom = false
        }
        return all
    }

    /// Reveal an older page of turns. Cheap (build + layout are O(window)); the
    /// bottom scroll anchor keeps the user's current position from jumping as rows
    /// are inserted above.
    private func loadEarlier() {
        let cur = effectiveStart
        guard cur > 0, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        windowStartTurn = snappedStart(cur - pageTurns)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            isLoadingEarlier = false
        }
    }

    /// One timeline row, flipped back upright because the stack it lives in is
    /// flipped (see `body`).
    @ViewBuilder
    private func timelineRow(_ node: TimelineNode) -> some View {
        TimelineRailRow(
            marker: node.marker,
            connectTop: node.connectTop,
            connectBottom: node.connectBottom,
            startsGroup: node.startsGroup
        ) {
            NodeBody(node: node)
        }
        .modifier(TimelineRowChrome())
        .scaleEffect(x: 1, y: -1)
        // No `.transition(.opacity)` here, deliberately. Rows are torn down and
        // re-created whenever the timeline rebuilds — a send, a turn finalizing, a
        // reconcile — and each re-insert replayed the fade. The device trace caught
        // the deepest realized row sitting at alpha 0.0-0.5 for ~2s around a turn
        // boundary: the viewport's bottom edge showed content that had been laid out
        // but was still (re-)fading in, which is the blank. A hard cut is
        // unglamorous and invisible; a fade that restarts is neither.
        .id(node.id)
    }

    var body: some View {
        // The transcript is rendered **upside down**. The content is flipped with
        // `scaleEffect(y: -1)` and every row is flipped back, so the list runs
        // newest-first and index 0 lands at the bottom of the screen.
        //
        // That inversion is the entire "stick to the bottom" mechanism, and it is why
        // none of the measuring that used to live here is left. A reply streams into
        // the node at offset 0, which grows *away* from the viewport, so the viewport
        // needs no correction at all — no `contentSize` (a lazy stack only estimates
        // it, and the estimate swings by tens of thousands of points), no probe for
        // the realized end, no snap, no chase, no rate-limited escalation. Chat UIs
        // have done this since the UITableView era; on iOS 16, where
        // `defaultScrollAnchor(.bottom)` does not exist, it is the only approach that
        // does not fight the lazy stack's height model.
        // Newest first: the flip below turns this list's start into the screen's
        // bottom, so index 0 is the newest node. No eager/lazy split is needed any
        // more — the newest nodes are the ones next to the viewport, which is
        // exactly what the lazy stack realizes first. (The old split also made
        // nodes migrate between two containers as the turn boundary moved, and a
        // migrating node is a re-created node.)
        let reversedNodes = Array(nodes.reversed())
        return ScrollViewReader { proxy in
            ScrollView {
            LazyVStack(spacing: 0) {
                // Breathing room under the newest node (visually below it, since the
                // stack is flipped): keeps it clear of the compose bar.
                Color.clear
                    .frame(height: 1)
                    .padding(.top, 8)

                // Newest first. The stack is lazy, and the newest rows are the ones
                // nearest the viewport, so they are the ones it lays out.
                ForEach(reversedNodes) { node in
                    timelineRow(node)
                }

                // Oldest end (visually the top of the screen). When the whole history
                // is loaded, the `header` scrolls above the first node; while older
                // turns are still windowed out, a compact spinner stands in for them.
                // Both are flipped back upright like the rows.
                if headLoaded {
                    header()
                        .modifier(TimelineRowChrome(top: 12, leading: TimelineMetrics.rowTrailingInset))
                        .scaleEffect(x: 1, y: -1)
                } else if isLoadingEarlier {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .modifier(TimelineRowChrome(top: 14, leading: TimelineMetrics.rowTrailingInset))
                        .scaleEffect(x: 1, y: -1)
                }
            }
            .scaleEffect(x: 1, y: -1)
            }
            .scrollDismissesKeyboard(.interactively)
            // The flip moves the scroll view's *top* inset to the visual bottom,
            // where it would hold the newest message a nav-bar's height above the
            // compose bar. Ignoring the top safe area removes it; the history end may
            // run under the frosted nav bar, as it did before.
            .ignoresSafeArea(.container, edges: .top)
            // Deliberately no `.codegDefaultScrollAnchorBottom()`: on iOS 17+ it would
            // fight the flip, and on iOS 16 the flip is itself the bottom anchor.
            // Publish a scroll capability so a reply's "scroll to question" button
            // (deep inside a row) can move the viewport to the user message.
            .environment(\.transcriptScroll, TranscriptScrollAction { id, anchor in
                // The content is flipped, so an anchor's meaning flips with it:
                // `.top` in content coordinates is the visual bottom.
                withAnimation(Theme.Motion.scroll) {
                    proxy.scrollTo(id, anchor: anchor == .top ? .bottom : .top)
                }
            })
            // Pin tracking only — there is nothing to snap *to*, and nothing to
            // follow. With the content flipped, growth happens at offset 0 and never
            // moves the viewport, so an offset that is not at the bottom can only be
            // the reader's own scroll. Compare with what used to live here: a
            // `contentSize` target, a realized-end probe, a glue pad, a coalesced
            // snap, an attach jump and a rate-limited escalation, all of it trying to
            // predict a lazy stack's height.
            .codegOnScrollMetricsChange { metrics, sv in
                if listScrollView !== sv { listScrollView = sv }
                // Distance from the bottom is measured from the offset floor, and the
                // floor is `-topInset` (the smallest offset the scroll view accepts).
                let distanceFromBottom = metrics.offsetY + metrics.topInset
                let atBottom = distanceFromBottom <= bottomThreshold

                if ScrollTrace.shouldReport(force: false) {
                    ScrollTrace.note("report off=\(Int(metrics.offsetY)) ch=\(Int(metrics.contentHeight)) vh=\(Int(metrics.containerHeight)) top=\(Int(metrics.topInset)) stuck=\(stuckToBottom ? 1 : 0) user=\(metrics.isUserInteracting ? 1 : 0) fromBottom=\(Int(distanceFromBottom))")
                }

                if atBottom {
                    if !stuckToBottom {
                        stuckToBottom = true
                        onPinnedChange(true)
                    }
                } else if stuckToBottom, metrics.isUserInteracting || distanceFromBottom > 2 * bottomThreshold {
                    stuckToBottom = false
                    onPinnedChange(false)
                }

                // Page in older turns when the reader reaches the history end, which
                // on flipped content is the *far* side.
                let maxOffset = max(0, metrics.contentHeight - metrics.containerHeight + metrics.bottomInset)
                let nearHistoryEnd = (maxOffset - metrics.offsetY) < loadEarlierThreshold
                if nearHistoryEnd, !lastNearTop, !stuckToBottom, !headLoaded, !isLoadingEarlier {
                    loadEarlier()
                }
                lastNearTop = nearHistoryEnd
            }
            // An explicit request to go to the bottom: the user's own send, or the
            // "jump to latest" button. Streamed growth needs no equivalent — it grows
            // at the anchored end.
            .onChange(of: signals.stickTick) { _ in
                stuckToBottom = true
                DispatchQueue.main.async {
                    onPinnedChange(true)
                    scrollToBottom()
                }
            }
            .onAppear { stuckToBottom = true }

        }
    }

    /// Put the viewport at the bottom: with the content flipped, that is simply the
    /// smallest offset the scroll view accepts. No measurement, no estimate, no
    /// chase — which is the whole point of the inversion.
    private func scrollToBottom() {
        guard let sv = listScrollView else { return }
        let target = -sv.adjustedContentInset.top
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: false)
        ScrollTrace.note("bottom target=\(Int(target)) after=\(Int(sv.contentOffset.y))")
    }

    /// Slack (pt) below which the viewport counts as "at the bottom". With the flip
    /// nothing but the reader can move the offset away from it, so this only has to
    /// absorb rounding and a rubber-band settle.
    private let bottomThreshold: CGFloat = 80
}

/// Shared chrome for a timeline row: transparent background, no separators, and
/// the timeline's leading/trailing insets (the leading one lines the gutter marker
/// up with the nav bar's leading button). Vertical insets are 0 — the per-node
/// vertical rhythm is baked into `TimelineRailRow` so the continuous rail
/// background spans the inter-node spacing (a `listRowInsets` gap would break the
/// spine). The header row passes a small `top` since it has no rail of its own.
private struct TimelineRowChrome: ViewModifier {
    var top: CGFloat = 0
    /// Leading inset. Defaults to the rail's wider inset (which lines the gutter
    /// marker up with the nav button); the marker-less header overrides it to the
    /// standard symmetric margin.
    var leading: CGFloat = TimelineMetrics.rowLeadingInset

    func body(content: Content) -> some View {
        content
            .padding(.top, top)
            .padding(.leading, leading)
            .padding(.trailing, TimelineMetrics.rowTrailingInset)
    }
}
