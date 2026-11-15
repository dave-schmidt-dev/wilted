import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

/// The undo toast's own rules, on a clock the test moves by hand: an offer lasts five seconds,
/// running out undoes nothing, a second action is stacked rather than replacing the first, a held
/// toast waits, and the window's Undo command reaches the same offers.
@MainActor
final class WiltedMacUndoToastTests: XCTestCase {
    private final class Undone { var count = 0 }

    private func center(_ clock: VirtualTime, longOffer: Bool = false) -> WiltedMacUndoToastCenter {
        WiltedMacUndoToastCenter(
            now: { clock.now }, sleep: { try await clock.sleep($0) }, prefersLongOffer: { longOffer })
    }

    @discardableResult
    private func offer(
        _ title: String, on center: WiltedMacUndoToastCenter, subjects: Set<String> = [],
        availableUntil: Date? = nil, counting undone: Undone = Undone()
    ) -> UUID? {
        center.offer(
            message: "Marked \(title) completed.", actionName: "Mark Completed", subjects: subjects,
            availableUntil: availableUntil
        ) { undone.count += 1 }
    }

    func testAnOfferLastsFiveSecondsAndRunningOutUndoesNothing() async {
        let clock = VirtualTime()
        let center = center(clock)
        let undone = Undone()
        let id = offer("A", on: center, counting: undone)

        XCTAssertEqual(center.current?.message, "Marked A completed.")
        await clock.advance(by: 4)
        XCTAssertNotNil(center.current, "still offered a second before the five are up")
        await clock.advance(by: 1)
        XCTAssertNil(center.current, "the toast goes at five seconds")

        center.undoCurrent()
        if let id { center.undo(id) }
        XCTAssertEqual(undone.count, 0, "an offer that ran out can no longer be taken up, and never runs by itself")
    }

    func testUndoBeforeTheFiveSecondsRunsOnceAndClosesTheToast() async {
        let clock = VirtualTime()
        let center = center(clock)
        let undone = Undone()
        let id = offer("A", on: center, counting: undone)

        await clock.advance(by: 4)
        center.undoCurrent()
        XCTAssertEqual(undone.count, 1)
        XCTAssertNil(center.current)

        if let id { center.undo(id) }
        await clock.advance(by: 10)
        XCTAssertEqual(undone.count, 1, "a second press and the old deadline do nothing")
    }

    func testASecondActionIsStackedAndEachKeepsItsOwnFiveSeconds() async {
        let clock = VirtualTime()
        let center = center(clock)
        let first = Undone(), second = Undone()
        offer("A", on: center, counting: first)
        await clock.advance(by: 2)
        offer("B", on: center, counting: second)

        XCTAssertEqual(center.current?.message, "Marked B completed.", "the newest action is the one shown")
        XCTAssertEqual(center.earlierCount, 1, "the first is still on offer behind it")

        center.undoCurrent()
        XCTAssertEqual([first.count, second.count], [0, 1], "Undo takes back the newest first")
        XCTAssertEqual(center.current?.message, "Marked A completed.", "then the toast offers the earlier one")

        await clock.advance(by: 3)
        XCTAssertNil(center.current, "the first went at its own five seconds, not five after the second")
        XCTAssertEqual(first.count, 0)
    }

    func testAnEarlierOfferRunsOutBehindANewerOne() async {
        let clock = VirtualTime()
        let center = center(clock)
        offer("A", on: center)
        await clock.advance(by: 2)
        offer("B", on: center)

        await clock.advance(by: 3)
        XCTAssertEqual(center.offers.map(\.message), ["Marked B completed."])
        await clock.advance(by: 2)
        XCTAssertTrue(center.offers.isEmpty)
    }

    func testTheToastNeverOutlastsTheUndoItOffers() async {
        let clock = VirtualTime()
        let center = center(clock)
        offer("A", on: center, availableUntil: clock.now.addingTimeInterval(3))
        await clock.advance(by: 3)
        XCTAssertNil(center.current, "an undo that stops working at three seconds is offered for three")

        XCTAssertNil(offer("B", on: center, availableUntil: clock.now), "an undo that cannot work is not offered")
        XCTAssertNil(center.current)
    }

    func testAHeldToastWaitsUntilTheUndoItselfStopsWorking() async {
        let clock = VirtualTime()
        let center = center(clock)
        offer("A", on: center)
        await clock.advance(by: 1)
        center.setHeld(true)
        await clock.advance(by: 8)
        XCTAssertNotNil(center.current, "the pointer resting on the toast keeps it past five seconds")
        await clock.advance(by: 1)
        XCTAssertNil(center.current, "but not past the ten the undo allows")
    }

    func testReleasingAHeldToastAfterFiveSecondsClosesIt() async {
        let clock = VirtualTime()
        let center = center(clock)
        offer("A", on: center)
        center.setHeld(true)
        await clock.advance(by: 7)
        XCTAssertNotNil(center.current)
        center.setHeld(false)
        await clock.settle()
        XCTAssertNil(center.current)
    }

    func testVoiceOverGetsTheWholeUndoWindow() async {
        let clock = VirtualTime()
        let center = center(clock, longOffer: true)
        offer("A", on: center)
        XCTAssertEqual(center.current?.offeredUntil, clock.now.addingTimeInterval(10))
        await clock.advance(by: 9)
        XCTAssertNotNil(center.current, "five seconds is too short to reach Undo with VoiceOver")
        await clock.advance(by: 1)
        XCTAssertNil(center.current)
    }

    func testWithdrawingStopsOnlyTheOffersForThoseRows() {
        let clock = VirtualTime()
        let center = center(clock)
        let gone = Undone()
        offer("A", on: center, subjects: ["a"], counting: gone)
        offer("B", on: center, subjects: ["b"])

        center.withdraw(subjects: ["a", "z"])
        XCTAssertEqual(center.offers.map(\.subjects), [["b"]])
        center.withdrawAll()
        XCTAssertTrue(center.offers.isEmpty)
        XCTAssertEqual(gone.count, 0, "withdrawing an offer never runs its undo")
    }

    // MARK: The window's Undo command

    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        // No run loop closes groups in a unit test; the center opens its own.
        manager.groupsByEvent = false
        return manager
    }

    func testTheWindowsUndoCommandTakesBackTheNewestOffer() {
        let clock = VirtualTime()
        let center = center(clock)
        let manager = undoManager()
        center.attach(manager)
        let first = Undone(), second = Undone()
        offer("A", on: center, counting: first)
        offer("B", on: center, counting: second)

        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Mark Completed")
        manager.undo()
        XCTAssertEqual([first.count, second.count], [0, 1])
        XCTAssertEqual(center.current?.message, "Marked A completed.")
        manager.undo()
        XCTAssertEqual([first.count, second.count], [1, 1])
        XCTAssertNil(center.current)
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo, "taking a removal back is not itself offered for redo")
    }

    func testAnOfferThatRanOutOrWasTakenUpLeavesTheUndoCommand() async {
        let clock = VirtualTime()
        let center = center(clock)
        let manager = undoManager()
        center.attach(manager)
        let undone = Undone()
        offer("A", on: center, counting: undone)
        await clock.advance(by: 5)
        XCTAssertFalse(manager.canUndo, "Edit > Undo must not keep naming a removal it can no longer take back")

        offer("B", on: center, counting: undone)
        center.undoCurrent()
        XCTAssertFalse(manager.canUndo, "the toast's button and the command are one offer, not two")
        XCTAssertEqual(undone.count, 1)
    }

    func testOffersFollowTheWindowTheyAreAttachedTo() {
        let clock = VirtualTime()
        let center = center(clock)
        offer("A", on: center)
        let first = undoManager(), second = undoManager()

        center.attach(first)
        XCTAssertTrue(first.canUndo, "an offer made before the window appeared is registered when it does")
        center.attach(second)
        XCTAssertFalse(first.canUndo)
        XCTAssertTrue(second.canUndo)
        center.attach(nil)
        XCTAssertFalse(second.canUndo)
    }

    func testTheUndoCommandLeavesATextFieldsOwnEntriesAlone() async {
        final class Typing: NSObject { var undone = 0 }
        let clock = VirtualTime()
        let center = center(clock)
        let manager = undoManager()
        center.attach(manager)
        let typing = Typing()
        let removal = Undone()

        offer("A", on: center, counting: removal)
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: typing) { $0.undone += 1 }
        manager.setActionName("Typing")
        manager.endUndoGrouping()

        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Typing", "the newest change is undone first")
        await clock.advance(by: 5)
        XCTAssertTrue(manager.canUndo, "the toast running out removes only its own entry")
        manager.undo()
        XCTAssertEqual([typing.undone, removal.count], [1, 0])
    }

    /// Command-Z reaches the toast through the window's own undo stack. A shortcut on the toast, or
    /// a replaced Undo command, would take Command-Z away from the search and link fields.
    func testCommandZIsTheWindowsOwnUndoNotAShortcutOfTheToasts() throws {
        let root = WiltedMacHeadless.sourceRoot()
        let toast = try WiltedMacHeadless.viewSource("WiltedMacUndoToastView.swift")
        let app = try String(
            contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacApp.swift"), encoding: .utf8)
        XCTAssertFalse(toast.contains("keyboardShortcut"))
        XCTAssertFalse(app.contains(".undoRedo"))
        XCTAssertTrue(toast.contains("@Environment(\\.undoManager)"))
    }

    func testTheHostConnectsTheToastToItsWindowsUndoStack() async throws {
        let clock = VirtualTime()
        let center = center(clock)
        // Offscreen: the window is never ordered in, so nothing reaches the screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: Color.clear.frame(width: 480, height: 320).modifier(WiltedMacUndoToastHost(center: center)))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let undone = Undone()
        offer("A", on: center, counting: undone)

        let manager = try XCTUnwrap(window.undoManager)
        await WiltedMacHeadless.eventually("the host hands the window's undo stack to the toast") { manager.canUndo }
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Mark Completed")
        manager.undo()
        XCTAssertEqual(undone.count, 1)
        XCTAssertNil(center.current)
    }

    // MARK: What is drawn

    /// The toast as a person sees it: the newest action, Undo beside it, over the bottom of the view.
    func testTheToastDrawsTheNewestActionWithUndoOverTheBottomOfTheWindow() throws {
        let clock = VirtualTime()
        let center = center(clock)
        offer("Quiet Machines", on: center)
        offer("Second Show", on: center)

        let lines = try WiltedMacHeadless.recognizedLines(
            Color.clear.frame(width: 600, height: 300).modifier(WiltedMacUndoToastHost(center: center)),
            size: CGSize(width: 648, height: 348))
        let shown = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(shown.contains("Marked Second Show completed"), shown)
        XCTAssertTrue(shown.contains("Undo"), shown)
        XCTAssertTrue(shown.contains("1 earlier change can also be undone"), shown)
        XCTAssertFalse(shown.contains("Quiet Machines"), "one toast, for the newest action: \(shown)")
        let message = try XCTUnwrap(lines.first { $0.text.contains("Marked") })
        XCTAssertGreaterThan(message.top, 0.6, "the toast sits over the bottom, clear of the list's own header")

        let covered = try WiltedMacHeadless.recognizedText(
            Color.clear.frame(width: 600, height: 300)
                .modifier(WiltedMacUndoToastHost(center: center, isPresenting: false)),
            size: CGSize(width: 648, height: 348))
        XCTAssertFalse(covered.joined().contains("Undo"), "a host that is covered draws no second toast")
    }

    // MARK: Copy

    func testTheToastSaysWhatVoiceOverNeedsAndCountsEarlierOffers() {
        let offer = WiltedMacUndoOffer(
            id: UUID(), message: "Marked A completed.", actionName: "Mark Completed", subjects: [],
            offeredUntil: Date(), availableUntil: Date())
        XCTAssertEqual(WiltedMacUndoToastCenter.announcement(for: offer),
                       "Marked A completed. Press Command-Z to undo.")
        XCTAssertEqual(WiltedMacUndoToastView.earlierCopy(1), "1 earlier change can also be undone.")
        XCTAssertEqual(WiltedMacUndoToastView.earlierCopy(3), "3 earlier changes can also be undone.")
    }
}
