import SwiftUI

extension Binding where Value == Bool {
    /// A safe `isPresented` bridge for an optional "pending item".
    ///
    /// **Why this exists.** SwiftUI writes `false` into an `isPresented` binding
    /// as part of its own update pass. The obvious hand-rolled spelling —
    ///
    /// ```swift
    /// Binding(get: { item != nil }, set: { if !$0 { item = nil } })
    /// ```
    ///
    /// therefore writes `nil` over a value that is *already* `nil`, and on
    /// iOS 16 that write lands **during the update pass**. `@State` and
    /// `@Published` are object-wide: any assignment invalidates the observers
    /// currently being evaluated, so the body re-enters. Because the value never
    /// actually differs, the write never converges — the body re-evaluates at
    /// display rate, no frame is ever committed, and the scene-update watchdog
    /// kills the app after 10 s (`bug_type 509`).
    ///
    /// Upstream (iOS 17 `@Observable`) only tracks the properties a body actually
    /// *reads*; nothing reads the optional, so the same write was inert there.
    /// This is the one downgrade that keeps biting: it has caused the
    /// "Message Settings" freeze three separate times, each time in a different
    /// screen, because the fix was applied per-screen instead of per-pattern.
    ///
    /// **Use this everywhere** an optional backs an `isPresented:` (alert,
    /// confirmationDialog, sheet, popover). It clears the value only when one is
    /// actually set, so SwiftUI's redundant `false` is a no-op and the loop
    /// cannot start.
    ///
    /// ```swift
    /// .alert("Couldn't Save", isPresented: .presenting($saveError)) { … }
    /// ```
    static func presenting<Wrapped>(_ source: Binding<Wrapped?>) -> Binding<Bool> {
        Binding<Bool>(
            get: { source.wrappedValue != nil },
            set: { newValue in
                // The guard is the whole point: `!newValue` alone would write on
                // every update pass, including when nothing is pending.
                guard !newValue, source.wrappedValue != nil else { return }
                source.wrappedValue = nil
            }
        )
    }
}
