import SwiftUI

// TEMPORARY (CI repro harness, `repro-sim` branch only): drives the Settings
// navigation exactly the way a user's taps would — destination-style pushes on
// the deliberately *unbound* settings stack (`RootView.settingsTab`) — so the
// iOS 16 hang can be exercised headlessly on CI without a UI-automation
// framework. The simulator's `simctl openurl` for `codeg://` pops an "Open in
// Codeg?" alert that cannot be dismissed headlessly, and the stack must stay
// unbound for production (see the long comment in `RootView.settingsTab`), so
// the push is armed through the environment instead:
//
//   SIMCTL_CHILD_CODEG_REPRO_TAB=settings       pick the Settings tab (AppModel)
//   SIMCTL_CHILD_CODEG_REPRO_LEAF=chatchannels  auto-push a SettingsLeaf pane
//   SIMCTL_CHILD_CODEG_REPRO_LEAF_DELAY=<s>     delay that leaf push (default 0)
//   SIMCTL_CHILD_CODEG_REPRO_DEEP=1             auto-push Message Settings from
//                                               inside Chat Channels
//   SIMCTL_CHILD_CODEG_REPRO_DEEP_DELAY=<s>     delay that deep push (default 0)
//   SIMCTL_CHILD_CODEG_REPRO_SHEET=1            auto-open the add-channel sheet
//   SIMCTL_CHILD_CODEG_REPRO_SHEET_OPEN=<s>     open delay (default 2)
//   SIMCTL_CHILD_CODEG_REPRO_SHEET_CLOSE=<s>    close delay (default 7)
//
// With no environment set every hook is inert (the views are never even built),
// so production is unaffected. Remove this file and its `.background`
// call sites when the harness goes away.
enum ReproHooks {
    /// Read once: `ProcessInfo.environment` rebuilds the dictionary on every
    /// access, and these hooks are consulted from `body` on every evaluation —
    /// the harness must not add jank that could masquerade as the bug.
    private static let environment = ProcessInfo.processInfo.environment

    static func env(_ key: String) -> String? {
        environment[key]
    }

    /// Seconds for a delay key, or `fallback` when unset/unparseable.
    static func time(_ key: String, default fallback: TimeInterval) -> TimeInterval {
        environment[key].flatMap(TimeInterval.init) ?? fallback
    }
}

/// A hidden `NavigationLink` that activates itself once, on appear, after an
/// optional delay — the programmatic equivalent of the user tapping the
/// corresponding row. Deferred through the main queue so the `@State` write
/// lands outside SwiftUI's update pass (writing state from `onAppear` directly
/// is the exact "write during update" hazard this branch keeps tripping over).
struct ReproAutoPush<Destination: View>: View {
    /// Non-nil = armed (the caller passes the environment value).
    let trigger: String?
    /// Seconds to wait after appear before pushing (cold-start deferral).
    var delay: TimeInterval = 0
    let destination: () -> Destination

    @State private var pushed = false

    var body: some View {
        NavigationLink(isActive: $pushed) {
            destination()
        } label: {
            EmptyView()
        }
        .opacity(0)
        .accessibilityHidden(true)
        .onAppear {
            guard trigger != nil, !pushed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !pushed else { return }
                pushed = true
            }
        }
    }
}

/// TEMPORARY: opens (then closes) a sheet the way the user's "+" tap would —
/// used to exercise `ChatChannelEditorSheet`, a freeze point on the device.
/// Inert unless the trigger env is set; all writes deferred to the main queue
/// so they never land inside SwiftUI's update pass.
struct ReproAutoSheet: View {
    /// Non-nil = armed.
    let trigger: String?
    /// Seconds after appear to set `isPresented = true`.
    let openAfter: TimeInterval
    /// Seconds after appear to set `isPresented = false`.
    let closeAfter: TimeInterval
    @Binding var isPresented: Bool

    @State private var armed = false

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .opacity(0)
            .accessibilityHidden(true)
            .onAppear {
                guard trigger != nil, !armed else { return }
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + openAfter) {
                    isPresented = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + closeAfter) {
                    isPresented = false
                }
            }
    }
}
