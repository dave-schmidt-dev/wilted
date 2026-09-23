import Foundation
import XCTest
@testable import WiltedMac

final class WiltedMacSeamMarkerTests: XCTestCase {
    func testTheToneIsShortQuietAndFadesAtBothEnds() {
        let data = WiltedMacSeamMarkerTone.wavData()
        XCTAssertEqual(Array(data.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(data.dropFirst(8).prefix(4)), Array("WAVE".utf8))

        let samples = pcmSamples(in: data)
        XCTAssertLessThanOrEqual(abs(samples.count - Int(WiltedMacSeamMarkerTone.duration * 44_100)), 1)
        let normalized = samples.map { abs(Double($0) / Double(Int16.max)) }
        XCTAssertLessThanOrEqual(normalized.first ?? .infinity, 0.01)
        XCTAssertLessThanOrEqual(normalized.last ?? .infinity, 0.01)
        XCTAssertLessThanOrEqual(normalized.max() ?? .infinity, WiltedMacSeamMarkerTone.peakAmplitude + 0.001)
        XCTAssertGreaterThanOrEqual(normalized.max() ?? -Double.infinity, WiltedMacSeamMarkerTone.peakAmplitude - 0.01)
    }

    func testTheScheduleMarksTheNextSeamAheadAtTheListeningRate() {
        struct Case {
            let seams: [TimeInterval]
            let position: TimeInterval
            let rate: Double
            let isPlaying: Bool
            let enabled: Bool
            let lastMarked: TimeInterval?
            let seam: TimeInterval?
            let delay: TimeInterval?
        }
        let cases = [
            Case(seams: [0, 30, 90], position: 10, rate: 1, isPlaying: true, enabled: true,
                 lastMarked: nil, seam: 30, delay: 20),
            Case(seams: [0, 30, 90], position: 10, rate: 2, isPlaying: true, enabled: true,
                 lastMarked: nil, seam: 30, delay: 10),
            Case(seams: [0, 30, 90], position: 30.02, rate: 1, isPlaying: true, enabled: true,
                 lastMarked: nil, seam: 90, delay: 59.98),
            Case(seams: [0, 30, 90], position: 29.9, rate: 1, isPlaying: true, enabled: true,
                 lastMarked: 30, seam: 90, delay: 60.1),
            Case(seams: [0.2], position: 0, rate: 1, isPlaying: true, enabled: true,
                 lastMarked: nil, seam: nil, delay: nil),
            Case(seams: [30], position: 10, rate: 1, isPlaying: false, enabled: true,
                 lastMarked: nil, seam: nil, delay: nil),
            Case(seams: [30], position: 10, rate: 1, isPlaying: true, enabled: false,
                 lastMarked: nil, seam: nil, delay: nil),
            Case(seams: [30], position: 10, rate: 0, isPlaying: true, enabled: true,
                 lastMarked: nil, seam: nil, delay: nil),
            Case(seams: [90, 30], position: 10, rate: 1, isPlaying: true, enabled: true,
                 lastMarked: nil, seam: 30, delay: 20),
        ]

        for test in cases {
            let result = WiltedMacSeamMarkerSchedule.next(
                seams: test.seams, position: test.position, rate: test.rate,
                isPlaying: test.isPlaying, enabled: test.enabled, lastMarked: test.lastMarked
            )
            XCTAssertEqual(result?.seam, test.seam)
            XCTAssertEqual(result?.delay ?? 0, test.delay ?? 0, accuracy: 0.000_001)
        }
    }

    func testTheWakeCheckFiresOnlyWhilePlayingNearTheSeam() {
        let seam: TimeInterval = 30
        let tolerance = WiltedMacSeamMarkerSchedule.fireTolerance
        let cases = [
            (position: seam, isPlaying: true, expected: true),
            // Just inside the edge: `30 - 0.3` is not exactly 29.7 in binary floating point.
            (position: seam - tolerance + 0.001, isPlaying: true, expected: true),
            (position: seam + tolerance - 0.001, isPlaying: true, expected: true),
            (position: seam - tolerance - 0.01, isPlaying: true, expected: false),
            (position: seam + tolerance + 0.01, isPlaying: true, expected: false),
            (position: seam, isPlaying: false, expected: false),
        ]

        for test in cases {
            XCTAssertEqual(
                WiltedMacSeamMarkerSchedule.shouldFire(
                    seam: seam, livePosition: test.position, isPlaying: test.isPlaying
                ),
                test.expected
            )
        }
    }

    func testAMarkBelongsToItsEpisodeAndARewindClearsIt() {
        let seam: TimeInterval = 30
        let episodeID = "episode-a"
        let cases: [(last: (episodeID: String, seconds: TimeInterval)?, episodeID: String, position: TimeInterval, expected: TimeInterval?)] = [
            (last: nil, episodeID: episodeID, position: seam, expected: nil),
            (last: (episodeID: episodeID, seconds: seam), episodeID: episodeID, position: seam + 1, expected: seam),
            (last: (episodeID: episodeID, seconds: seam), episodeID: episodeID,
             position: seam - WiltedMacSeamMarkerSchedule.rewindAllowance + 0.01, expected: seam),
            (last: (episodeID: episodeID, seconds: seam), episodeID: episodeID,
             position: seam - WiltedMacSeamMarkerSchedule.rewindAllowance - 0.01, expected: nil),
            (last: (episodeID: episodeID, seconds: seam), episodeID: "episode-b", position: seam, expected: nil),
        ]

        for test in cases {
            XCTAssertEqual(
                WiltedMacSeamMarkerSchedule.effectiveLastMarked(
                    test.last, episodeID: test.episodeID, position: test.position
                ),
                test.expected
            )
        }
    }

    @MainActor
    func testAPreparedEpisodeSchedulesItsFirstCutAndTheSwitchClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiltedMacModel(
            arguments: [
                "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                "--wilted-ui-fixture-prepared", "--wilted-ui-fixture-long-transcript",
            ],
            stateDirectoryOverride: root,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        XCTAssertTrue(
            model.seamMarkerOutput is WiltedMacSilentSeamMarkerOutput,
            "tests and fixtures must never sound"
        )

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        for _ in 0..<100 {
            if model.isPlaying, !model.currentRemovedSpans.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isPlaying, "fixture playback must report playing")
        XCTAssertFalse(model.currentRemovedSpans.isEmpty, "prepared fixture must provide removed spans")

        model.refreshPlaybackReadout()
        let firstSeam = try XCTUnwrap(model.currentRemovedSpans.map(\.preparedSeconds).filter { $0 >= 0.5 }.min())
        XCTAssertEqual(model.pendingSeamMarkerForTesting, firstSeam)

        model.marksRemovedAds = false
        XCTAssertNil(model.pendingSeamMarkerForTesting)

        model.marksRemovedAds = true
        model.togglePlayback()
        for _ in 0..<100 {
            if !model.isPlaying { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isPlaying, "fixture playback must pause")
        XCTAssertNil(model.pendingSeamMarkerForTesting)
    }

    @MainActor
    func testTheMarkerPreferenceDefaultsOnAndPersists() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = WiltedMacTestPreferences.ephemeral()
        let first = WiltedMacModel(stateDirectoryOverride: root, preferences: preferences)
        XCTAssertTrue(first.marksRemovedAds)
        first.marksRemovedAds = false

        let second = WiltedMacModel(stateDirectoryOverride: root, preferences: preferences)
        XCTAssertFalse(second.marksRemovedAds)
    }

    @MainActor
    func testTheMarkerSoundsOnceAtTheSeamAndAgainAfterARewind() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WiltedMacModel(
            arguments: [
                "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                "--wilted-ui-fixture-prepared", "--wilted-ui-fixture-long-transcript",
            ],
            stateDirectoryOverride: root,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let output = try XCTUnwrap(model.seamMarkerOutput as? WiltedMacSilentSeamMarkerOutput)

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        for _ in 0..<100 {
            if model.isPlaying, !model.currentRemovedSpans.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isPlaying, "fixture playback must report playing")
        let seam = try XCTUnwrap(model.currentRemovedSpans.map(\.preparedSeconds).filter { $0 >= 0.5 }.min())

        await model.seekPlaybackForTesting(to: seam - 0.1)
        // A 0.1 s wake; the wider budget is for a loaded gate host, not the marker.
        for _ in 0..<300 {
            if output.playCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(output.playCount, 1)
        XCTAssertNotEqual(model.pendingSeamMarkerForTesting, seam)

        try await Task.sleep(for: .milliseconds(400))
        model.refreshPlaybackReadout()
        XCTAssertEqual(output.playCount, 1)

        await model.seekPlaybackForTesting(to: max(0, seam - 5))
        XCTAssertEqual(model.pendingSeamMarkerForTesting, seam)
    }

    private func pcmSamples(in data: Data) -> [Int16] {
        let bytes = Array(data)
        guard bytes.count >= 44 else { return [] }
        return stride(from: 44, to: bytes.count - 1, by: 2).map { index in
            Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
        }
    }
}
