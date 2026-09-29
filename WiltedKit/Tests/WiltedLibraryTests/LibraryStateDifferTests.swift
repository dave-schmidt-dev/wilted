import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryStateDifferTests: XCTestCase {
    private func id(_ name: String) -> ItemID { try! ItemID(rawValue: "item-\(name)") }

    private func entry(_ name: String, removal: LibraryRemoval = .none, title: String? = nil) -> LibraryEntry {
        try! LibraryEntry(
            id: id(name), kind: .podcastEpisode, sourceID: id("feed"), title: title ?? "Episode \(name)",
            summary: "", publishedAt: Date(timeIntervalSince1970: 1_000), removal: removal
        )
    }

    private func slot(_ name: String, _ key: Double) -> QueueSlot { try! QueueSlot(entryID: id(name), sortKey: key) }

    private func snapshot(slots: [QueueSlot], entries: [LibraryEntry]? = nil) -> LibrarySnapshot {
        LibrarySnapshot(entries: entries ?? slots.map { entry($0.entryID.rawValue.replacingOccurrences(of: "item-", with: "")) }, slots: slots)
    }

    func testReorderProducesOnlyTheMovedSlot() {
        let before = snapshot(slots: [slot("a", 0), slot("b", 1), slot("c", 2)])
        // Move "c" between "a" and "b": only its key changes.
        let after = snapshot(slots: [slot("a", 0), slot("b", 1), slot("c", 0.5)])
        let changes = LibraryStateDiffer.diff(from: before, to: after)
        XCTAssertEqual(changes, [.slot(slot("c", 0.5))])
        XCTAssertEqual(after.queue.map(\.entryID), [id("a"), id("c"), id("b")])
    }

    func testRetirementProducesRemovalChange() {
        let before = snapshot(slots: [slot("a", 0)])
        var retired = before
        retired.entries[id("a")] = entry("a", removal: .retired)
        XCTAssertEqual(LibraryStateDiffer.diff(from: before, to: retired),
                       [.removal(entryID: id("a"), state: .retired)])

        // Retiring also drops the Larder slot, which is its own change.
        retired.slots[id("a")] = nil
        XCTAssertEqual(LibraryStateDiffer.diff(from: before, to: retired),
                       [.removal(entryID: id("a"), state: .retired), .slotRemoved(entryID: id("a"))])
    }

    func testRetirementCarryingRemovalDateSendsWholeEntryButRestoreIsRemovalOnly() throws {
        let before = snapshot(slots: [slot("a", 0)])
        var retired = before
        let dated = try entry("a").with(removal: .retired, removedAt: Date(timeIntervalSince1970: 2_000))
        retired.entries[id("a")] = dated
        XCTAssertEqual(LibraryStateDiffer.diff(from: before, to: retired), [.entry(dated)])

        var restored = retired
        restored.entries[id("a")] = entry("a")
        XCTAssertEqual(LibraryStateDiffer.diff(from: retired, to: restored),
                       [.removal(entryID: id("a"), state: .none)])
        XCTAssertNil(retired.applying(.removal(entryID: id("a"), state: .none)).entries[id("a")]?.removedAt)
        XCTAssertEqual(retired.applying(.removal(entryID: id("a"), state: .dismissed)).entries[id("a")]?.removedAt,
                       Date(timeIntervalSince1970: 2_000))
    }

    func testRetirementWithContentEditSendsWholeEntry() {
        let before = snapshot(slots: [])
        var after = LibrarySnapshot(entries: [entry("a")])
        let previous = after
        after.entries[id("a")] = entry("a", removal: .dismissed, title: "Renamed")
        XCTAssertEqual(LibraryStateDiffer.diff(from: previous, to: after),
                       [.entry(entry("a", removal: .dismissed, title: "Renamed"))])
        XCTAssertTrue(LibraryStateDiffer.diff(from: before, to: before).isEmpty)
    }

    func testFirstPublishSendsEverythingAndUnchangedSendsNothing() {
        let current = LibrarySnapshot(
            sources: [LibrarySource(id: id("feed"), kind: .podcastFeed, title: "Feed")],
            entries: [entry("a")], slots: [slot("a", 0)],
            listening: [ListeningRecord(itemID: id("a"), completedAt: nil, updatedAt: Date(timeIntervalSince1970: 5), deviceID: "phone")]
        )
        let first = LibraryStateDiffer.diff(from: nil, to: current)
        XCTAssertEqual(first.count, 4)
        XCTAssertTrue(LibraryStateDiffer.diff(from: current, to: current).isEmpty)
    }

    func testDiffAppliedToPreviousYieldsCurrent() {
        let before = snapshot(slots: [slot("a", 0), slot("b", 1)])
        var after = snapshot(slots: [slot("b", 0.5), slot("c", 2)])
        after.entries[id("a")] = entry("a", removal: .retired)
        let rebuilt = LibraryStateDiffer.diff(from: before, to: after).reduce(before) { $0.applying($1) }
        XCTAssertEqual(rebuilt, after)
    }

    func testRemovedSlotProducesSlotRemoved() {
        let before = snapshot(slots: [slot("a", 0), slot("b", 1)])
        let after = snapshot(slots: [slot("b", 1)], entries: before.entries.values.map { $0 })
        XCTAssertEqual(LibraryStateDiffer.diff(from: before, to: after), [.slotRemoved(entryID: id("a"))])
    }
}
