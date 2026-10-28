import Foundation
import WiltedDomain
import XCTest
@testable import WiltedMac

/// Show in Finder on a Larder row selects the episode's prepared audio file.
@MainActor
final class WiltedMacShowInFinderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-show-in-finder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheMenuOffersShowInFinderOnlyForAPreparedEpisode() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertTrue(model.canShowInFinder(episode(.prepared(summary: "Ready"))))
        XCTAssertFalse(model.canShowInFinder(episode(.notPrepared)), "an unprepared episode has no audio of its own")
    }

    func testRevealSelectsThePreparedFile() async throws {
        let file = directory.appendingPathComponent("rev-1.mp3")
        try Data([1, 2, 3]).write(to: file)
        var presented: [URL] = []
        let reveal = WiltedMacFinderReveal(audioFile: { _ in file }, present: { presented.append($0) })

        let shown = await reveal.reveal(try ItemID(rawValue: "item-finder"))

        XCTAssertTrue(shown)
        XCTAssertEqual(presented, [file])
    }

    func testRevealShowsNothingWhenThereIsNoFileOnDisk() async throws {
        let missing = directory.appendingPathComponent("gone.mp3")
        var presented: [URL] = []
        let entry = try ItemID(rawValue: "item-finder")

        let noAudio = await WiltedMacFinderReveal(audioFile: { _ in nil }, present: { presented.append($0) }).reveal(entry)
        let gone = await WiltedMacFinderReveal(audioFile: { _ in missing }, present: { presented.append($0) }).reveal(entry)
        let failed = await WiltedMacFinderReveal(audioFile: { _ in throw CocoaError(.fileReadUnknown) },
                                                 present: { presented.append($0) }).reveal(entry)

        XCTAssertFalse(noAudio)
        XCTAssertFalse(gone)
        XCTAssertFalse(failed)
        XCTAssertTrue(presented.isEmpty)
    }

    private func episode(_ preparation: WiltedMacEpisodePreparationState) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: "item-finder", title: "Episode", feedTitle: "Show", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0, downloadState: .completed, preparationState: preparation)
    }
}
