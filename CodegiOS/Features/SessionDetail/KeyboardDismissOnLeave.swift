import SwiftUI
import UIKit

/// Drops the keyboard the moment the hosting screen starts leaving, instead of
/// when it has already gone.
///
/// Why this exists: `onDisappear` on the compose bar fires **after** the pop has
/// begun on iOS 16, so the keyboard rode into the session list and then lingered
/// there — "回到上一页之后键盘还在". Resigning from a hosted view controller's
/// `viewWillDisappear` fires as the interactive back-swipe *starts* (and
/// `viewWillAppear` cancels it if the swipe is abandoned), which is the timing
/// the system's own screens use.
///
/// Zero-size and non-interactive: it contributes no layout, it only borrows the
/// view controller lifecycle.
struct KeyboardDismissOnLeave: UIViewControllerRepresentable {
    /// Called as the screen begins to disappear, so the owner can clear its own
    /// focus flag too (otherwise the field re-becomes first responder the next
    /// time it updates).
    var onLeave: () -> Void = {}

    func makeUIViewController(context: Context) -> Controller {
        Controller(onLeave: onLeave)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onLeave = onLeave
    }

    final class Controller: UIViewController {
        var onLeave: () -> Void

        init(onLeave: @escaping () -> Void) {
            self.onLeave = onLeave
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func loadView() {
            // A real (empty) view: the controller has to be in the hierarchy for
            // its lifecycle callbacks to arrive.
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            onLeave()
            // Target nil = the current first responder, which is the composer
            // field while the keyboard is up. Doing it here (rather than on the
            // field) also covers a presented sheet holding focus.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
    }
}
