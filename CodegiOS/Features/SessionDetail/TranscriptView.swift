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
/// suits the timeline well (many small per-part rows). The first paint is put at
/// the newest node by snapping the backing `UIScrollView` to its bottom
/// (`scrollToBottomOffset`), never by `ScrollViewProxy.scrollTo` — see the note
/// on that method for why.
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
    /// The transcript's backing `UIScrollView`, resolved via introspection. Every
    /// bottom-snap goes through it: `ScrollViewProxy.scrollTo` both lands on blank
    /// space when the target row isn't realized under a `LazyVStack` **and** traps
    /// inside SwiftUI on iOS 16 when a proxy captured in an earlier update is used
    /// later (`logs/*.ips` — `TranscriptView.scrollToBottom` called from a
    /// `_dispatch_call_block_and_release` block). So `scrollTo` is never used to
    /// reach the bottom.
    @State private var listScrollView: UIScrollView?
    /// Tracks the previous near-top state so we only page in history when
    /// *entering* the zone (iOS 16 has no Bool-mapping `onScrollGeometryChange`).
    @State private var lastNearTop = false
    /// Previous content height, so we can snap to the bottom *after* the scroll
    /// view has actually laid out the newly appended row (driving it while
    /// `contentSize` is still stale lands short of the bottom).
    @State private var lastContentHeight: CGFloat = 0
    /// Previous bottom inset, so a keyboard show/hide (which moves "the bottom")
    /// also re-snaps while pinned.
    @State private var lastBottomInset: CGFloat = 0
    /// Previous container height. The keyboard is hosted by a `VStack` (not a
    /// `safeAreaInset`), so it can shrink the scroll view's frame instead of
    /// changing the inset — either way "the bottom" moved, so both are tracked.
    /// This is what makes dropping the old `scrollTo` retry ladder safe: the snap
    /// is re-issued for as long as the geometry keeps settling.
    @State private var lastContainerHeight: CGFloat = 0
    /// Previous content offset, so an upward move can be recognised as the user's
    /// even when the interaction flags have already cleared by the time the
    /// (one-tick-later) metrics report runs. See the pin logic in `body`.
    @State private var lastOffsetY: CGFloat = 0

    /// The offset our own last bottom-snap set. A shrink (the reasoning block
    /// auto-collapsing, a tool card folding) moves the bottom *up*, so our snap moves
    /// the offset up too — and the pin rule below reads an upward move as "the user
    /// scrolled away" and un-pins. The transcript then stops following, and a snap
    /// taken while a collapse is still animating can leave the viewport parked past
    /// the new end of the content (a blank screen until the user scrolls). Knowing
    /// which offset we set ourselves keeps the pin honest.
    @State private var lastSnapOffsetY: CGFloat?

    /// A coalesced bottom-snap is already queued (see `scheduleSnap`).
    @State private var pendingSnap = false


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

    /// The flattened timeline — a memoized **persisted** tier plus a fresh **live**
    /// tier — together with the boundary between them, which the body needs to know
    /// how much of the tail to render eagerly (see `eagerPersistedTail`).
    private struct Timeline {
        var nodes: [TimelineNode] = []
        /// How many leading nodes came from the persisted tier.
        var persistedCount = 0
    }

    /// The flattened timeline: a memoized **persisted** tier + a fresh **live**
    /// tier. The persisted tier is expensive (it hashes every visible turn's content
    /// through `adaptTurn`'s cache), so it is reused whenever the cheap `PersistedKey`
    /// is unchanged — which is every streamed token. The live tier is rebuilt each
    /// pass (cheap; keeps live tool / plan cards updating). Rail endpoints are
    /// terminated on the *combined* list so the tail's `connectBottom` lands on the
    /// live node while a reply streams.
    private var timeline: Timeline {
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
        return Timeline(nodes: all, persistedCount: persisted.count)
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

    /// How many trailing nodes are laid out eagerly (see the body). The live turn's
    /// nodes are always in that range — they are the ones being appended while a
    /// reply streams — plus this many persisted nodes under them.
    private let eagerPersistedTail = 4

    /// One timeline row. Shared by the lazy and eager halves so both render
    /// identically.
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
        // Fade newly-inserted nodes in (the optimistic user bubble on send, the
        // thinking tick, each streamed segment) instead of a hard cut. Pure opacity
        // only — a geometric transition would seam the continuous rail. Driven by the
        // `.animation(value:)` on the transcript in `SessionDetailView`.
        .transition(.opacity)
        .id(node.id)
    }

    var body: some View {
        // Evaluated once per pass: the live tier is rebuilt on every access, and the
        // lazy/eager split below would otherwise ask for it three times.
        let timeline = timeline
        let eagerStart = max(0, timeline.persistedCount - eagerPersistedTail)
        return ScrollViewReader { proxy in
            ScrollView {
            LazyVStack(spacing: 0) {
                // Top of the list. When the whole history is loaded, the `header`
                // scrolls above the first node (no gutter marker, standard margin).
                // While older turns are still windowed out, show a compact spinner
                // there during a load instead — the rail keeps `connectTop` so the
                // spine reads as continuing up into the not-yet-loaded history.
                if headLoaded {
                    header()
                        .modifier(TimelineRowChrome(top: 12, leading: TimelineMetrics.rowTrailingInset))
                } else if isLoadingEarlier {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .modifier(TimelineRowChrome(top: 14, leading: TimelineMetrics.rowTrailingInset))
                }

                // Everything up to the eager tail is lazy: a long window is
                // expensive to lay out and most of it is off screen.
                ForEach(timeline.nodes[..<eagerStart]) { node in
                    timelineRow(node)
                }
                // The tail — the live turn's nodes plus the last few persisted ones —
                // is laid out eagerly, and that is load-bearing rather than a perf
                // choice. A `LazyVStack` reports a height for rows it has not laid
                // out, and a viewport placed against that reported height does not
                // make it lay them out: the device trace caught the estimate 87,285pt
                // past the deepest realized row, with the viewport parked in the gap
                // and nothing to draw — the blank screen. With the end of the content
                // always realized, the reported bottom is the real bottom, so a single
                // snap reaches it and there is no gap to land in. The cost is bounded
                // (one turn's segments plus a few rows), and the boundary only moves
                // when a turn ends — a node shifting across it keeps its `id`, so
                // SwiftUI treats it as the same row in a new position.
                VStack(spacing: 0) {
                    ForEach(timeline.nodes[eagerStart...]) { node in
                        timelineRow(node)
                    }
                }

                // Trailing breathing room: keeps the last node clear of the
                // compose bar. Outside the rail (no gutter). Not an `id` anchor —
                // the bottom is reached by offset, never by `scrollTo`.
                Color.clear
                    .frame(height: 1)
                    .padding(.top, 8)
            }
            }
            .scrollDismissesKeyboard(.interactively)
            // iOS 17+ puts the first paint on the newest node natively; on iOS 16
            // the shim is a no-op and `scrollToBottomOffset()` does it.
            .codegDefaultScrollAnchorBottom()
            // Publish a scroll capability so a reply's "scroll to question" button
            // (deep inside a row) can move the viewport to the user message.
            .environment(\.transcriptScroll, TranscriptScrollAction { id, anchor in
                withAnimation(Theme.Motion.scroll) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            })
            // Bottom-pin tracking + auto-follow.
            //
            // The pin is deliberately ASYMMETRIC: landing at the bottom always
            // pins, and only a *user* scroll may un-pin. Content growth and
            // keyboard/layout changes move "the bottom" too, and reading those as
            // "the user scrolled away" is what broke the transcript before:
            // a single `setContentOffset` can only reach the `contentSize` the
            // LazyVStack has realised *so far*; the stack then realises more and
            // the height grows, which used to flip the pin off — so a long session
            // opened at the top, and jump-to-latest needed several taps, each one
            // only reaching the next estimate.
            //
            // `bottomInset` / `containerHeight` keep the math right across
            // keyboard and compose-bar changes.
            .codegOnScrollMetricsChange { metrics, sv in
                if listScrollView !== sv { listScrollView = sv }
                // "At the bottom" is measured against the same target
                // `scrollToBottomOffset` uses — content height minus container
                // height, with no bottom inset (see that method). Keeping the two
                // in step matters: a stale inset here would report "scrolled away"
                // for a viewport that is actually pinned.
                let atBottom = (metrics.contentHeight - metrics.containerHeight) - metrics.offsetY
                    <= bottomThreshold
                let geometryChanged = metrics.contentHeight != lastContentHeight
                    || metrics.bottomInset != lastBottomInset
                    || metrics.containerHeight != lastContainerHeight
                // A scroll that moved *up* while the geometry stood still is the
                // user's even if the interaction flags have already cleared by the
                // time this (one tick later) report runs — e.g. a status-bar tap to
                // scroll to top. Unless it is the offset our own bottom-snap just
                // set: a shrink moves the bottom up, so that snap moves the offset up
                // as well, and reading it as a user scroll un-pins the transcript —
                // which is what makes the pin (and the snap) cycle while a command
                // streams.
                let movedUp = metrics.offsetY < lastOffsetY - 1
                lastOffsetY = metrics.offsetY
                let isOwnSnap = lastSnapOffsetY.map { abs(metrics.offsetY - $0) <= 1 } ?? false

                // TEMPORARY scroll trace (CodegiOS/Diagnostics/ScrollTrace.swift).
                if ScrollTrace.shouldReport(force: geometryChanged) {
                    let deep = sv.codegDeepestRealizedView()
                    let svWin = sv.convert(sv.bounds, to: nil)
                    // Where that view sits on screen, derived rather than converted
                    // (the walk keeps to one conversion per view).
                    let endWinB = deep.map { svWin.maxY + ($0.bottom - (sv.contentOffset.y + sv.bounds.height)) }
                    ScrollTrace.note("report off=\(Int(metrics.offsetY)) ch=\(Int(metrics.contentHeight)) vh=\(Int(metrics.containerHeight)) top=\(Int(metrics.topInset)) stuck=\(stuckToBottom ? 1 : 0) user=\(metrics.isUserInteracting ? 1 : 0) geo=\(geometryChanged ? 1 : 0) end=\(deep.map { Int($0.bottom) } ?? -1) gap=\(deep.map { Int(metrics.contentHeight - $0.bottom) } ?? -1) endA=\(deep.map { String(format: "%.1f", $0.alpha) } ?? "-") endWinB=\(endWinB.map { Int($0) } ?? -1) svWinB=\(Int(svWin.maxY))")
                }

                if atBottom {
                    if !stuckToBottom {
                        stuckToBottom = true
                        ScrollTrace.note("pin on (atBottom)")
                        onPinnedChange(true)
                    }
                } else if metrics.isUserInteracting || (movedUp && !geometryChanged && !isOwnSnap) {
                    if stuckToBottom {
                        stuckToBottom = false
                        ScrollTrace.note("pin off (user=\(metrics.isUserInteracting ? 1 : 0) movedUp=\(movedUp ? 1 : 0) geo=\(geometryChanged ? 1 : 0) ownSnap=\(isOwnSnap ? 1 : 0))")
                        onPinnedChange(false)
                    }
                }
                // Reveal older turns as the user scrolls toward the top. Fire only
                // when entering the near-top zone; `!stuckToBottom` rejects the
                // transient near-top geometry reported while the list is still
                // settling onto the bottom at open.
                let nearTop = (metrics.offsetY + metrics.topInset) < loadEarlierThreshold
                if nearTop, !lastNearTop, !stuckToBottom, !headLoaded, !isLoadingEarlier {
                    loadEarlier()
                }
                lastNearTop = nearTop
                // Auto-follow: once the scroll view has laid out grown content —
                // or the geometry that defines "the bottom" moved (keyboard
                // inset, container resize) — snap to the bottom. Doing it here
                // (not on the tick that bumped the content) guarantees
                // `contentSize`/inset already reflect the new layout, which is
                // what makes a single non-animated offset set enough: a snap that
                // lands short because the content was still measuring is simply
                // re-issued on the next geometry change, until it converges on the
                // settled bottom.
                if stuckToBottom, geometryChanged {
                    lastContentHeight = metrics.contentHeight
                    lastBottomInset = metrics.bottomInset
                    lastContainerHeight = metrics.containerHeight
                    scheduleSnap()
                }
                // A node can also shrink *under* a pinned viewport — the reasoning
                // block auto-collapses a second after it stops streaming — and a snap
                // taken while that height change is still animating lands past the new
                // end of the content. The viewport then shows blank until the user
                // scrolls it back, so pull it in whenever it sits past where
                // `scrollToBottomOffset` would rest and the user isn't rubber-banding
                // there.
                let restingOffset = max(-metrics.topInset, metrics.contentHeight - metrics.containerHeight)
                if !metrics.isUserInteracting, metrics.offsetY > restingOffset + 1 {
                    lastContentHeight = metrics.contentHeight
                    lastBottomInset = metrics.bottomInset
                    lastContainerHeight = metrics.containerHeight
                    scheduleSnap()
                }
            }
            // Streamed growth: follow instantly, but ONLY while pinned. A single
            // plain offset set per tick (no re-assert) — the content is already
            // moving, so anything heavier stacks and stutters.
            .onChange(of: signals.scrollTick) { _ in
                guard stuckToBottom else {
                    ScrollTrace.note("tick ignored (unpinned)")
                    return
                }
                DispatchQueue.main.async { scrollToBottomOffset() }
            }
            //
            // `onPinnedChange` writes an `@Published` on the view model, so it
            // must NOT run inside SwiftUI's view-update transaction (that trips
            // "Publishing changes from within view updates"); defer it one tick.
            .onChange(of: signals.stickTick) { _ in
                stuckToBottom = true
                DispatchQueue.main.async {
                    onPinnedChange(true)
                    scrollToBottomOffset(trustingEstimate: true)
                }
            }
            .onAppear {
                // A fresh open always lands on the newest node. The jump has to
                // trust the estimate — the tail is not realized yet, and the
                // viewport's position is what makes the stack realize it. The
                // follow-mode snaps take over from the metrics callback as rows
                // realize and the real content height settles.
                stuckToBottom = true
                DispatchQueue.main.async { scrollToBottomOffset(trustingEstimate: true) }
            }
            // Keyboard show/hide moves the bottom. The metrics callback above
            // usually catches it (inset or container height changes), but SwiftUI
            // doesn't reliably surface every one of those through the scroll
            // view's KVO, so re-snap explicitly. Cheap and idempotent.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if stuckToBottom { scrollToBottomOffset() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if stuckToBottom { scrollToBottomOffset() }
            }
            // Hiding matters as much as showing: the frame grows, which is exactly
            // when a snap taken with the pre-hide height would overshoot. (Reached
            // when the keyboard is dismissed from its own hide key while a menu is
            // up, so SwiftUI's own compensation doesn't run.)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                if stuckToBottom { scrollToBottomOffset() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                if stuckToBottom { scrollToBottomOffset() }
            }
        }
    }

    /// Snap the scroll view to its bottom via `contentOffset`.
    ///
    /// This is the **only** way the transcript reaches the bottom, on every path
    /// (open, send, jump-to-latest, keyboard, streamed growth). `ScrollViewProxy`
    /// is deliberately not used for it:
    ///
    /// - the bottom anchor row may not be realized under a `LazyVStack`, so
    ///   `scrollTo` lands on blank space, and
    /// - a `scrollTo` issued from a proxy captured in an earlier update — exactly
    ///   what the removed `reassert` ladder did, `asyncAfter`-ing 6 more
    ///   `scrollTo` calls out to 800 ms — traps inside SwiftUI on iOS 16. That is
    ///   the crash in `logs/*.ips`: `TranscriptView.scrollToBottom` invoked from
    ///   `_dispatch_call_block_and_release`, plus 3 more where it was called
    ///   synchronously from `body`'s `stickTick` closure.
    ///
    /// Landing short because `contentSize` was still stale is handled by the
    /// metrics callback: while pinned it re-snaps on every content-height /
    /// bottom-inset / container-height change, so the last snap always reflects
    /// the settled layout. `scrollTo` survives only for `\.transcriptScroll`
    /// (the user tapping "jump to question"), where the call is synchronous and
    /// the target is in already-realized content.
    ///
    /// The bottom inset is deliberately NOT added to the target. The transcript
    /// sits directly above the compose bar in a `VStack`, so nothing is ever
    /// covering its bottom edge and it needs no bottom inset — while a *stale* one
    /// (SwiftUI's keyboard inset, after the keyboard goes away) would push the
    /// target exactly one keyboard height past the end of the content, which is
    /// the blank strip under the last message. Only the top inset matters (the
    /// content scrolls under the frosted nav bar).
    /// Two modes, because "jump" and "follow" need opposite sources of truth:
    ///
    /// **Jump** (`trustingEstimate: true` — a fresh open, "jump to latest", the
    /// user's own send): target the estimate unconditionally. The viewport position
    /// is what makes the lazy stack realize rows, so on a fresh open the tail does
    /// not exist yet and nothing else can take us there. That is also this mode's
    /// danger — an overshooting estimate parks the viewport in the phantom — which
    /// is exactly why every other path uses the other mode.
    ///
    /// **Follow** (default — streamed growth, the keyboard, and the convergence
    /// after a rebuild): target `min(estimate, realized end + slack)`. A wholesale
    /// rebuild's estimate overshoots by ~14% and converges over ~400ms (the trace
    /// caught 43,821pt claimed vs 38,301pt real); following the estimate chases that
    /// convergence (the jump) and parks in the phantom (the blank). The realized end
    /// is stable but only a lower bound — it stops at the eager tail — so it is only
    /// trusted while it is more than one at-bottom slack short of the estimate; once
    /// the gap closes, the estimate takes over and the target is the exact bottom.
    /// Nothing realized at all — the first ticks of a rebuild — is no information,
    /// so no action.
    private func scrollToBottomOffset(trustingEstimate: Bool = false) {
        guard let sv = listScrollView else {
            ScrollTrace.note("snap SKIPPED (no scroll view)")
            return
        }
        let minY = -sv.adjustedContentInset.top
        let contentBottom = sv.contentSize.height
        var end = contentBottom
        if !trustingEstimate {
            guard let drawnEnd = sv.codegDeepestRealizedView()?.bottom else {
                ScrollTrace.note("snap SKIPPED (nothing realized) ch=\(Int(contentBottom))")
                return
            }
            end = min(contentBottom, drawnEnd + bottomThreshold)
        }
        let target = max(minY, end - sv.bounds.height)
        // Remember what we set: the report that follows must not be read as the user
        // scrolling away (see `lastSnapOffsetY`).
        lastSnapOffsetY = target
        let before = sv.contentOffset.y
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: false)
        ScrollTrace.note("snap mode=\(trustingEstimate ? "jump" : "follow") target=\(Int(target)) before=\(Int(before)) after=\(Int(sv.contentOffset.y)) ch=\(Int(contentBottom)) vh=\(Int(sv.bounds.height))")
    }

    /// Coalesced bottom-snap for the geometry-driven path.
    ///
    /// A lazy stack refines its height estimates continuously — the device trace
    /// showed ~60 content-height changes a second while idle — and one snap per
    /// report was ~130/s, most of them no-ops but the rest dragging the viewport
    /// with every wobble of the estimate. One snap per ~80ms still converges on the
    /// settled bottom (the next report re-schedules if it moved again) without
    /// fighting the layout it is reacting to.
    private func scheduleSnap() {
        guard !pendingSnap else { return }
        pendingSnap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
            pendingSnap = false
            guard stuckToBottom else { return }
            scrollToBottomOffset()
        }
    }

    /// Slack (pt) below which the viewport counts as "at the bottom" — a few body
    /// lines, comfortably larger than one ~50ms streamed chunk's height delta so
    /// a single chunk can't flip auto-follow off.
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
