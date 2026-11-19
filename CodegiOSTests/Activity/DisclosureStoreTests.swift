import Foundation
import Testing
@testable import Codeg

/// What the transcript's rows remember of the reader's toggles across the
/// list recycling them (``DisclosureStore``).
///
/// The upstream suite also asserted that a change WAKES a reader, via
/// `withObservationTracking` (iOS 17+). `DisclosureStore` is an
/// `ObservableObject` here (iOS 16), so that mechanism does not apply and those
/// three cases are gone; the observable behaviour they guarded is covered by
/// the reactive paths in the app, not by a unit test.
@MainActor
struct DisclosureStoreTests {

    // MARK: - Choices

    @Test func aRowNobodyToggledShowsItsOwnDefault() {
        let store = DisclosureStore()
        #expect(store.choice("tool-1/tool") == nil)
        // An auto-expanded row (failed, awaiting the user) stays open…
        #expect(store.isOpen("tool-1/tool", default: true))
        // …and a folded-by-default one stays shut.
        #expect(!store.isOpen("k-run/thought", default: false))
    }

    @Test func aChoiceOutlivesTheRowThatMadeIt() {
        let store = DisclosureStore()
        store.set(true, for: "k-run/thought")
        // The row scrolled away and back is a new view: it reads the same key.
        #expect(store.choice("k-run/thought") == true)
        #expect(store.isOpen("k-run/thought", default: false))
        // Closing a row that opened by itself sticks too.
        store.set(false, for: "tool-1/tool")
        #expect(!store.isOpen("tool-1/tool", default: true))
    }

    @Test func eachKeyKeepsItsOwnChoice() {
        let store = DisclosureStore()
        store.set(true, for: "toolgroup-1/group")
        #expect(store.choice("toolgroup-1/tool:a/tool") == nil)
        #expect(store.choice("toolgroup-2/group") == nil)
        store.set(false, for: "toolgroup-1/tool:a/tool")
        #expect(store.choice("toolgroup-1/group") == true)
    }

    @Test func clearingAChoiceGivesTheRowItsDefaultBack() {
        let store = DisclosureStore()
        store.set(false, for: "tool-1/tool")
        store.set(nil, for: "tool-1/tool")
        #expect(store.choice("tool-1/tool") == nil)
        #expect(store.isOpen("tool-1/tool", default: true))
        // Clearing a key never chosen for records nothing.
        store.set(nil, for: "tool-2/tool")
        #expect(store.choice("tool-2/tool") == nil)
    }

    @Test func aToggleFlipsWhatTheRowShows() {
        let store = DisclosureStore()
        store.toggle("tool-1/tool", default: true)
        #expect(store.choice("tool-1/tool") == false)
        store.toggle("tool-1/tool", default: true)
        #expect(store.choice("tool-1/tool") == true)
    }

    @Test func eachScreenHasItsOwnStore() {
        // codeg turn ids are not globally unique: another conversation's
        // `turn-3#thought@1` is another row.
        let one = DisclosureStore()
        let other = DisclosureStore()
        one.set(true, for: "turn-3#thought@1/thought")
        #expect(other.choice("turn-3#thought@1/thought") == nil)
    }

    // MARK: - Keys

    @Test func aKeyNamesTheRowAndTheDisclosureInIt() {
        #expect(DisclosureStore.key(scope: "tool-1", name: "tool") == "tool-1/tool")
        // A nested level is a scope of its own.
        let member = DisclosureStore.key(scope: "toolgroup-1", name: "tool:a")
        #expect(DisclosureStore.key(scope: member, name: "tool") == "toolgroup-1/tool:a/tool")
        // Outside a row there is nowhere to keep it.
        #expect(DisclosureStore.key(scope: nil, name: "tool") == nil)
    }

    // MARK: - Who is woken



}
