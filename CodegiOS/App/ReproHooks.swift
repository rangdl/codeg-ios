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
//   SIMCTL_CHILD_CODEG_REPRO_DEEP=1             auto-push Message Settings from
//                                               inside Chat Channels
//
// With no environment set every hook is inert (the views are never even built),
// so production is unaffected. Remove this file and its two `.background`
// call sites when the harness goes away.
enum ReproHooks {
    /// Read once: `ProcessInfo.environment` rebuilds the dictionary on every
    /// access, and these hooks are consulted from `body` on every evaluation —
    /// the harness must not add jank that could masquerade as the bug.
    private static let environment = ProcessInfo.processInfo.environment

    static func env(_ key: String) -> String? {
        environment[key]
    }
}

/// A hidden `NavigationLink` that activates itself once, on appear, when the
/// given environment trigger is present — the programmatic equivalent of the
/// user tapping the corresponding row. Deferred through the main queue so the
/// `@State` write lands outside SwiftUI's update pass (writing state from
/// `onAppear` directly is the exact "write during update" hazard this branch
/// keeps tripping over).
struct ReproAutoPush<Destination: View>: View {
    /// Non-nil = armed (the caller passes the environment value).
    let trigger: String?
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
            DispatchQueue.main.async { pushed = true }
        }
    }
}
