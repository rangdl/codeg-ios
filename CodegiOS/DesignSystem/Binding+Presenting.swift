import SwiftUI

extension Binding where Value == Bool {    /// A safe `isPresented` bridge for an optional "pending item".
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

extension Binding where Value: Equatable {
    /// A save-on-change binding whose setter drops writes that change nothing.
    ///
    /// `Picker` / `Toggle` / `TextField` / `Stepper` are wired to `@Published`
    /// properties through a hand-rolled `Binding(get:set:)`. SwiftUI writes
    /// bindings during its own update pass, and on iOS 16 `ObservableObject`
    /// invalidation is **object-wide** — so a write that stores the value the
    /// property already holds re-enters the pass. The value never differs, so the
    /// write never converges and the pass never ends.
    ///
    /// That is the freeze, and the sampler now shows its shape without ambiguity:
    /// 45-63 fps with a healthy main queue for seven seconds, then `fps=0` and the
    /// main thread gone into AttributeGraph in the eighth. Upstream's
    /// `@Observable` tracks per property, so the same write was inert there.
    ///
    /// ```swift
    /// Picker("Mode", selection: .changes(
    ///     get: { model.languageMode },
    ///     set: { model.languageMode = $0; model.scheduleLanguageSave() }
    /// ))
    /// ```
    static func changes(
        get: @escaping () -> Value,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: get,
            set: { newValue in
                guard newValue != get() else { return }
                set(newValue)
            }
        )
    }
}
