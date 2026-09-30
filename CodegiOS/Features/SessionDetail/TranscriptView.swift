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
/// One signal is left: an explicit re-pin to the bottom (the user's own send, the
/// "jump to latest" button, the initial load). Streamed growth needs none — with the
/// content flipped it grows at the anchored end and never moves the viewport, so
/// there is nothing to follow. The per-token follow that used to live here
/// (`scrollTick`, coalesced to one tick per ~50 ms) was left behind by the
/// inversion: the view model still asked for it on every streamed event, and every
/// one of those requests landed on a signal no view observed.
@MainActor
final class TranscriptScrollSignals: ObservableObject {
    /// Bumped on the user's own send / initial load; forces a re-pin regardless of
    /// the current scroll position.
    @Published private(set) var stickTick = 0

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
/// Backed by a **flipped** `List`: the content is inverted so the newest node sits
/// at the bottom and the bottom is `contentOffset` 0 — see the note in `body` for
/// why the inversion, and why the container has to be a `List`. Going to the bottom
/// is then a plain offset set (`scrollToBottom`), never `ScrollViewProxy.scrollTo`.
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
    /// pending / suppression signals), so a re-evaluation that is not a real
    /// persisted change no longer rebuilds and re-hashes the whole visible
    /// transcript.
    let turnsVersion: Int
    /// Not `@ObservedObject`: with the content flipped there is nothing to follow,
    /// and observing it would re-evaluate this whole view on every ~50ms streamed
    /// tick. Only `stickTick` still matters, and it is subscribed below.
    let signals: TranscriptScrollSignals
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
    /// smallest offset the list accepts, a constant that needs no measurement.
    /// (`ScrollViewProxy.scrollTo` is still not used for it: it lands on blank space
    /// for unrealized rows, and traps inside SwiftUI on iOS 16 when called from a
    /// proxy captured in an earlier update — `logs/*.ips`.)
    @State private var listScrollView: UIScrollView?
    /// Status bar + navigation bar (pt), measured once — how far the list's top edge
    /// sits below the top of the screen. `-1` means "not measured yet".
    @State private var topChromeHeight: CGFloat = -1

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
    /// Last-seen content/container/inset signature for the inset-maintenance block
    /// below. Scrolling changes ONLY the offset; the inset math reads none of it,
    /// so on an offset-only change the whole block is skipped — writing
    /// `contentInset` mid-scroll (SwiftUI re-applies its own value every layout
    /// pass, so the write was never once-and-done) fires the metrics KVO, breaks
    /// the scroll's momentum, and was the main cost of scrolling a streaming
    /// transcript.
    @State private var lastInsetInputs: InsetInputs?
    /// A programmatic jump is in flight. While set, near-history-end paging is
    /// suppressed: a jump toward an old question lands near the window's start,
    /// the paging that would otherwise fire there INSERTS rows above every
    /// existing one, and the just-computed target offset then points at a
    /// different row entirely — the "sometimes lands wrong" jump regression.
    /// Set at jump start, cleared (with a settle re-aim) after the animation.
    @State private var jumpInFlight = false
    /// Monotonic token for the jump currently in flight. A newer jump
    /// invalidates the older one's re-aim passes, so two quick taps can't fight
    /// (the first jump's settle-correction would otherwise drag the viewport
    /// back to its own target after the second jump landed).
    @State private var jumpToken = 0

    // MARK: Node memoization
    //
    // The *persisted* node tier changes only when `turns` / the window / pending /
    // in-flight suppression change — never per streamed token: the live tier's leaves
    // read the run directly, so a token does not re-run this view at all any more.
    // Rebuilding it needlessly is
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
    /// The inputs the inset-maintenance math reads: everything EXCEPT the offset.
    /// An equal signature means the scroll changed none of them — insets are
    /// already correct, and rewriting them mid-scroll only fires the KVO and
    /// breaks momentum.
    private struct InsetInputs: Equatable {
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var adjustedTop: CGFloat
        var adjustedBottom: CGFloat
    }

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
        guard cur > 0, !isLoadingEarlier, !jumpInFlight else { return }
        isLoadingEarlier = true
        windowStartTurn = snappedStart(cur - pageTurns)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            isLoadingEarlier = false
            // The next metrics callback (this page's contentSize change already
            // fired one) re-evaluates the level condition; if the reader is
            // still inside the threshold zone — a short page — the next page
            // loads immediately, and continuous upward scrolling never stalls.
        }
    }

    /// One timeline row: flipped back upright (the list it lives in is flipped),
    /// plus the list-row chrome that hides the cell separators, insets and
    /// background so the row renders exactly as it did inside the stack.
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
        .id(node.id)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// Nodes in render order — newest first (the list is flipped, so index 0 is
    /// the screen's bottom). Shared by the List's `ForEach` and the jump-to-
    /// question row mapping; keeping it one property means the jump can never
    /// drift from what's on screen.
    private var reversedNodes: [TimelineNode] { Array(nodes.reversed()) }

    var body: some View {
        // The transcript is rendered **upside down**: the list is flipped and every
        // row flipped back, so the newest node sits at the bottom of the screen and
        // the bottom is `contentOffset` 0. A reply streams into that end, which grows
        // *away* from the viewport — so there is nothing to follow, nothing to
        // measure, and no target to compute. Chat UIs have worked this way since
        // UITableView.
        //
        // The container matters, and this is why it is a `List` rather than the
        // `ScrollView` + `LazyVStack` it used to be: a lazy stack decides which rows
        // to realize from the content coordinate system, which the flip inverts —
        // realize a row, the content height changes, the offset is re-anchored, which
        // realizes different rows. That loop is stable in the normal direction and
        // divergent in the flipped one: the list scrolls by itself and the reader
        // cannot win. `List` is a UITableView, whose offset management has no such
        // loop.
        return ScrollViewReader { proxy in
            List {
                // No spacer row at the tail. There used to be a 1pt `Color.clear`
                // here as "breathing room" above the compose bar, but the row is
                // laid out at UITableView's default row height (~44pt) instead of
                // the 1pt it asks for — measured on device as a constant 127px gap
                // across two conversations of very different length, with the list
                // parked at the bottom and no inset anywhere. The newest node's own
                // 9pt bottom inset plus the compose bar's 8pt already keep it clear.
                //
                // Newest first: with the flip, index 0 is the bottom of the screen.
                ForEach(reversedNodes) { node in
                    timelineRow(node)
                }

                // Oldest end (visually the top of the screen). When the whole history
                // is loaded the `header` sits above the first node; while older turns
                // are still windowed out a compact spinner stands in for them.
                if headLoaded {
                    header()
                        .modifier(TimelineRowChrome(top: 12, leading: TimelineMetrics.rowTrailingInset))
                        .scaleEffect(x: 1, y: -1)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } else if isLoadingEarlier {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .modifier(TimelineRowChrome(top: 14, leading: TimelineMetrics.rowTrailingInset))
                        .scaleEffect(x: 1, y: -1)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scaleEffect(x: 1, y: -1)
            .scrollDismissesKeyboard(.interactively)
            // The flip moves the list's *top* safe-area inset to the visual bottom,
            // where it would hold the newest message a nav bar's height above the
            // compose bar. Ignoring the top safe area removes it; the history end may
            // run under the frosted nav bar, as before.
            .ignoresSafeArea(.container, edges: .top)
            // Publish a scroll capability so a reply's "scroll to question" button
            // (deep inside a row) can move the viewport to the user message. The
            // anchor flips with the content: `.top` in content coordinates is the
            // visual bottom.
            //
            // It routes through UIKit (`jumpToNode`) — NOT `proxy.scrollTo`: that
            // traps inside SwiftUI on iOS 16 when the proxy was captured in an
            // earlier update (same crash as the old bottom jump, `logs/*.ips`),
            // and it lands on blank space for rows the list hasn't realized yet.
            // Tapping through an older history is exactly when both bite — the
            // reader keeps jumping to questions that have scrolled out of the
            // realized window, and the fifth tap or so hits the stale proxy.
            .environment(\.transcriptScroll, TranscriptScrollAction { id, anchor in
                jumpToNode(id: id, anchor: anchor)
            })
            // Pin tracking only — there is nothing to snap *to* and nothing to
            // follow. With the flip, growth happens at offset 0 and never moves the
            // viewport, so an offset that is not at the bottom can only be the
            // reader's own scroll, and the only signal needed to tell is whether a
            // finger is down.
            .codegOnScrollMetricsChange { metrics, sv in
                if listScrollView !== sv { listScrollView = sv }
                // UIKit's automatic inset adjustment stacks the list's safe area on
                // top of the `contentInset` computed below. The list ignores the top
                // safe area (see the flip note on the modifier), but UIKit still sees
                // a scroll view overlapping the status bar and adds its height to
                // `adjustedContentInset.top` — and the flip lands that inset exactly
                // above the compose bar, as a gap nothing in this file asks for. So
                // turn the adjustment off and let `contentInset` be the only input:
                // the offset floor is then `-contentInset.top`, as computed.
                if sv.contentInsetAdjustmentBehavior != .never {
                    sv.contentInsetAdjustmentBehavior = .never
                }
                // The bottom is the offset floor, and the floor is `-topInset`.
                let distanceFromBottom = metrics.offsetY + metrics.topInset
                if distanceFromBottom <= bottomThreshold {
                    if !stuckToBottom {
                        stuckToBottom = true
                        onPinnedChange(true)
                    }
                } else if stuckToBottom, metrics.isUserInteracting {
                    stuckToBottom = false
                    onPinnedChange(false)
                }
                // Page in older turns while the reader is near the history end
                // (on flipped content, the far side). LEVEL-triggered, gated by
                // isLoadingEarlier: the previous edge-trigger design
                // (lastNearTop) kept a latched "entered" flag that ANY metrics
                // callback — including ones from image loads and row-height
                // corrections long after a jump settled — could re-poison, so
                // scrolling up sometimes paged nothing until the reader backed
                // off and re-entered. Level triggering with the in-flight guard
                // is equivalent while scrolling (each page's contentSize change
                // re-evaluates) and immune to stale latches.
                let maxOffset = max(0, metrics.contentHeight - metrics.containerHeight + metrics.bottomInset)
                let nearHistoryEnd = (maxOffset - metrics.offsetY) < loadEarlierThreshold
                if nearHistoryEnd, !stuckToBottom, !headLoaded, !isLoadingEarlier, !jumpInFlight {
                    loadEarlier()
                }
                // Inset maintenance: only when one of its INPUTS changed. A pure
                // scroll (offset moved; content/container/insets identical) skips
                // this whole block — the insets are already what they should be,
                // and rewriting them mid-scroll fires the KVO re-entry below and
                // breaks the scroll's momentum (the "streaming + scroll-up is
                // janky" regression).
                let insetInputs = InsetInputs(
                    contentHeight: metrics.contentHeight,
                    containerHeight: metrics.containerHeight,
                    adjustedTop: sv.adjustedContentInset.top,
                    adjustedBottom: sv.adjustedContentInset.bottom
                )
                guard insetInputs != lastInsetInputs else { return }
                lastInsetInputs = insetInputs
                // A transcript shorter than the viewport. With the flip, the content's
                // own top edge is the *bottom* of the screen, so a short conversation
                // sits on the compose bar with all the empty space above it. Handing
                // the list a top inset of exactly the shortfall pushes the content to
                // the visual top instead — and the inset is what `contentInset.top`
                // means in flipped coordinates, i.e. the visual bottom.
                //
                // Measured against the *usable* height, not the whole list: the list
                // ignores the top safe area (otherwise the flip moves that inset to
                // the visual bottom, which is the wrong end), so nothing reserves room
                // for the navigation bar — without subtracting it here the content is
                // pushed up underneath the bar.
                //
                // Safe to compute: it is non-zero only while the content is shorter
                // than the viewport, when every row is laid out and `contentSize` is
                // exact — the estimates this screen has been fighting only exist for
                // unrealized rows. And `contentInset` does not change `contentSize`,
                // so this cannot feed back into itself.
                // The bar is measured, not assumed. 44 is what it comes out as on
                // device (the status bar sits *above* the list, since the list ignores
                // the top safe area, so the bar is the only thing overlapping it) — and
                // do NOT "fix" this to status bar + nav bar (91): that drops the content
                // another 47pt and the gap becomes obviously too large.
                if topChromeHeight < 0 {
                    topChromeHeight = topChromeHeight(in: sv)
                }
                let chrome = topChromeHeight > 0 ? topChromeHeight : Self.standardTopChromeHeight
                let usableHeight = metrics.containerHeight - chrome
                let shortfall = max(0, usableHeight - metrics.contentHeight)
                // `adjustedContentInset` is `contentInset` plus whatever UIKit adds for
                // the safe area — and it keeps adding it even with the adjustment
                // turned off above, because SwiftUI re-applies its own value on every
                // layout pass. Everything below reads the *adjusted* inset, so instead
                // of assuming which value wins, read the difference back and subtract
                // it: the adjusted inset then lands on `shortfall` either way.
                let safeAreaExtra = sv.adjustedContentInset.top - sv.contentInset.top
                let targetTopInset = shortfall - safeAreaExtra
                if abs(sv.contentInset.top - targetTopInset) > 0.5 {
                    sv.contentInset.top = targetTopInset
                }
                // The HISTORY end needs the same chrome buffer: with the flip,
                // `contentInset.bottom` IS the visual top. Without it the reader who
                // scrolls to the head — or jumps to a question — lands the row
                // directly under the translucent nav bar (the same missing buffer,
                // measured from the other end of the flip; the composer end has its
                // own via `contentInset.top` above).
                if abs(sv.contentInset.bottom - chrome) > 0.5 {
                    sv.contentInset.bottom = chrome
                }
            }
            // An explicit request to go to the bottom: the user's own send, or the
            // "jump to latest" button. Streamed growth needs no equivalent — it grows
            // at the anchored end.
            .onReceive(signals.$stickTick) { _ in
                stuckToBottom = true
                DispatchQueue.main.async {
                    onPinnedChange(true)
                    scrollToBottom()
                }
            }
            .onAppear {
                stuckToBottom = true
                DispatchQueue.main.async { scrollToBottom() }
            }
        }
    }

    /// The standard inline navigation bar height. Only used when the live bar cannot
    /// be reached — the value the inset above was calibrated against on device.
    /// (A computed property because `static let` is not allowed in a generic type.)
    private static var standardNavigationBarHeight: CGFloat { 44 }

    /// Status bar + navigation bar, measured from the live window and bar. The list
    /// ignores the top safe area, so neither is otherwise accounted for, and the
    /// inset above wants their sum: on this device 47 + 44 = 91.
    private func topChromeHeight(in sv: UIScrollView) -> CGFloat {
        let statusBar = sv.window?.safeAreaInsets.top ?? 0
        let navBar = Self.navigationBar()?.bounds.height ?? 0
        return statusBar + navBar
    }

    /// Fallback for `topChromeHeight(in:)` when neither the window nor the bar can be
    /// reached: status bar + the standard inline bar.
    private static var standardTopChromeHeight: CGFloat { 47 + standardNavigationBarHeight }

    /// The live `UINavigationBar`, if the hierarchy exposes one — SwiftUI's navigation
    /// bar is a `UINavigationBar` underneath (that is what `.toolbarBackground(_:for:)`
    /// styles).
    private static func navigationBar() -> UINavigationBar? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.first?.windows.first
        guard let root = window?.rootViewController?.view else { return nil }
        return navigationBar(in: root)
    }

    private static func navigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar, bar.bounds.height > 0 { return bar }
        for subview in view.subviews {
            if let found = navigationBar(in: subview) { return found }
        }
        return nil
    }

    /// Put the viewport at the bottom: with the list flipped, that is simply the
    /// smallest offset it accepts. No measurement, no estimate, no chase — which is
    /// the whole point of the inversion.
    ///
    /// `ScrollViewProxy.scrollTo` is still not used for it: it lands on blank space
    /// for rows a lazy container has not realized, and it traps inside SwiftUI on
    /// iOS 16 when called from a proxy captured in an earlier update (`logs/*.ips`).
    /// It survives only for `\.transcriptScroll` (the user tapping "jump to
    /// question"), where the target is a single row the reader is already looking at.
    private func scrollToBottom() {
        guard let sv = listScrollView else { return }
        sv.setContentOffset(CGPoint(x: 0, y: -sv.adjustedContentInset.top), animated: false)
    }

    /// Jump the viewport to the row with `id` (the user message that prompted a
    /// reply) — via UIKit, never `ScrollViewProxy.scrollTo` (traps on iOS 16; see
    /// ``scrollToBottom()``).
    ///
    /// The scroll view's concrete class is NOT assumed: on iOS 16 a SwiftUI
    /// `List` is backed by a `UICollectionView` (older releases backed it with
    /// `UITableView`), and a wrong cast would make the whole jump silently do
    /// nothing. Both native `scrollToRow/Item` calls are estimate-aware, so they
    /// work for rows the container hasn't realized yet — exactly the case where
    /// the old proxy crashed. `at: .bottom` places the row at the container's
    /// visual bottom, which the flip turns into the SCREEN's top — the anchor
    /// semantics the button asks for (`.top` = visual top).
    private func jumpToNode(id: String, anchor: UnitPoint) {
        guard let sv = listScrollView else { return }
        // `reversedNodes` is the same array the ForEach renders, so the mapping
        // can't drift from what's on screen.
        guard let idx = reversedNodes.firstIndex(where: { $0.id == id }) else { return }
        // The header / loading row sit AFTER all node rows in ForEach order, so a
        // node's container row is exactly its reversed index.
        let ip = IndexPath(row: idx, section: 0)
        // The target row's rect in content coordinates. Both lookups work for
        // rows the container has NOT realized (layout/data driven), which is
        // exactly where the old proxy path trapped.
        let rowRect: CGRect?
        if let table = sv as? UITableView {
            rowRect = table.rectForRow(at: ip)
        } else if let collection = sv as? UICollectionView,
                  idx < collection.numberOfItems(inSection: 0) {
            rowRect = collection.layoutAttributesForItem(at: ip)?.frame
        } else {
            rowRect = nil
        }
        let target: CGPoint
        if let rect = rowRect {
            // Align the row's far edge with the viewport's inset-respecting
            // bottom edge: with the flip that edge is the SCREEN's top, just
            // under the nav bar — the anchor the button asks for. Computing the
            // offset by hand (instead of `scrollToRow/Item`) is what makes this
            // respect the hand-set bottom inset those APIs ignore, and it still
            // scrolls when the row is already fully visible (where they no-op'd).
            target = CGPoint(x: 0, y: rect.maxY - (sv.bounds.height - sv.adjustedContentInset.bottom))
        } else {
            // Unknown backing store: center the target by fractional position so
            // the jump at least moves.
            let n = reversedNodes.count
            guard n > 0 else { return }
            let maxOffset = sv.contentSize.height - sv.bounds.height
                + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom
            target = CGPoint(x: 0, y: CGFloat(idx) / CGFloat(n) * maxOffset)
        }
        // Clamp: the floor is the pinned bottom, the ceiling the history end.
        let floor = -sv.adjustedContentInset.top
        let ceiling = max(floor, sv.contentSize.height - sv.bounds.height
            + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom)
        let clamped = min(max(target.y, floor), ceiling)
        // Suppress paging for the whole jump window BEFORE moving: the animated
        // scroll itself can cross the paging threshold, and rows inserted
        // mid-animation would invalidate the target below.
        jumpInFlight = true
        jumpToken &+= 1
        let token = jumpToken
        // The viewport is leaving the bottom under program control. Clear the
        // pin NOW (not on the next user drag): while it stayed pinned, the
        // paging gate (!stuckToBottom) blocked loadEarlier after a jump to the
        // window's top — scroll up loaded nothing until the reader first
        // dragged downward (which finally cleared the pin) and then up again.
        // It also leaves the jump-to-latest button hidden on arrival.
        if clamped - floor > bottomThreshold {
            stuckToBottom = false
            onPinnedChange(false)
        }
        sv.setContentOffset(CGPoint(x: 0, y: clamped), animated: true)
        // Re-aim after the animation settles. `rectForRow` for a NOT-yet-realized
        // row is built on the table's row-height ESTIMATE, so the offset computed
        // above can be off by tens of points once the row actually lays out and
        // the content size corrects — the "sometimes lands wrong" drift. After
        // the animated scroll the target row IS realized; re-reading its rect
        // and re-clamping (no animation) snaps onto the true position. One
        /// extra pass covers a settle that paginated content growth caused.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard token == self.jumpToken else { return }
            self.reaim(id: id, floor: floor)
            try? await Task.sleep(for: .milliseconds(250))
            guard token == self.jumpToken else { return }
            self.jumpInFlight = false
            self.reaim(id: id, floor: floor)
        }
    }

    /// Second-pass aim: re-read the target row's now-realized rect and, if the
    /// estimate drifted, correct without animation. No-op when the row has left
    /// the node list (window shrank) or nothing moved.
    private func reaim(id: String, floor: CGFloat) {
        guard let sv = listScrollView,
              let idx = reversedNodes.firstIndex(where: { $0.id == id }) else { return }
        let ip = IndexPath(row: idx, section: 0)
        let rect: CGRect?
        if let table = sv as? UITableView {
            rect = table.rectForRow(at: ip)
        } else if let collection = sv as? UICollectionView,
                  idx < collection.numberOfItems(inSection: 0) {
            rect = collection.layoutAttributesForItem(at: ip)?.frame
        } else {
            rect = nil
        }
        guard let rect else { return }
        let ceiling = max(floor, sv.contentSize.height - sv.bounds.height
            + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom)
        let target = min(max(rect.maxY - (sv.bounds.height - sv.adjustedContentInset.bottom), floor), ceiling)
        // Only correct a real drift: a no-op setContentOffset still kills momentum.
        if abs(sv.contentOffset.y - target) > 2 {
            sv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
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
