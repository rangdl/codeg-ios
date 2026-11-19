import SwiftUI
import UIKit

/// Closes the keyboard for a screen that is being left.
///
/// A single `resignFirstResponder` is not enough on iOS 16: during a navigation
/// pop the first responder is re-established by the layout that runs after the
/// pop begins, so the keyboard reappears and rides into the screen behind it —
/// "返回上一页后键盘还留在列表上". This resigns, then re-checks on the next two
/// runloop turns and once after the transition would have finished, which covers
/// the re-assert without a timer or a repeating poll.
@MainActor
enum KeyboardDismiss {
    /// Resign now and again on the next two runloop turns.
    static func close() {
        endEditing()
        DispatchQueue.main.async {
            endEditing()
            DispatchQueue.main.async { endEditing() }
        }
        // A transition is ~0.35 s; one more pass after it covers a re-assert that
        // happened mid-animation. Cheap (one send to nil) and self-cancelling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { endEditing() }
    }

    private static func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        // Belt and braces: a field that ignores the action (a `UITextView` inside
        // a hosting controller does not always be first responder at the time the
        // action is sent) is reached through its window instead.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                window.endEditing(true)
            }
        }
    }
}
