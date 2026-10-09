import XCTest
import AppKit
import SwiftUI
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// What every player shows for a command's pending and failed states, and
/// the speed picker's own save line. Scenario IDs come from the retired
/// Batch 1 prototype.
extension WiltedVisualSystemTests {
    // SPEED-FAIL: the live speed stays; the failure says what a restart uses.
    @MainActor
    func testSpeedSaveFailureKeepsLiveSpeedAndNamesRestartSpeed() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        model.playbackOperationStatus = "Added Quiet Machines to Larder."
        model.installSpeedSaveForTesting { _ in throw CocoaError(.fileWriteUnknown) }

        model.setPlaybackRate(1.5)
        XCTAssertEqual(model.currentSpeedSaveStatus?.phase, .saving)
        XCTAssertEqual(model.currentSpeedSaveStatus?.message, "Saving speed…")
        try await waitFor { model.currentSpeedSaveStatus?.phase == .failed }

        XCTAssertEqual(model.playbackRate, 1.5)
        XCTAssertEqual(model.playback?.playbackRate, 1.5, "the live speed is never rolled back")
        let message = try XCTUnwrap(model.currentSpeedSaveStatus?.message)
        XCTAssertTrue(message.hasPrefix("Speed save failed. Current speed 1.5×; restart uses "), message)
        XCTAssertEqual(model.playbackOperationStatus, "Added Quiet Machines to Larder.",
                       "a speed save never settles another operation's status")

        model.installSpeedSaveForTesting(nil)
        model.retrySpeedSave()
        try await waitFor { model.currentSpeedSaveStatus?.phase == .saved }
        let store = try XCTUnwrap(model.store)
        let saved = try await store.playbackSpeed(for: ItemID(rawValue: episode.id))
        XCTAssertEqual(saved?.speed, 1.5)
    }

    // SPEED-FAIL reordered: an older save finishing last cannot settle.
    @MainActor
    func testReorderedSpeedSavesSettleOnlyTheNewest() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let saves = WiltedMacSpeedSaveScript()
        model.installSpeedSaveForTesting { try await saves.save($0) }

        model.setPlaybackRate(1.5)
        model.setPlaybackRate(2)
        try await waitFor { saves.pendingCount == 2 }
        saves.finish(speed: 2, failing: false)
        try await waitFor { model.currentSpeedSaveStatus?.phase == .saved }
        saves.finish(speed: 1.5, failing: true)
        try await waitFor { model.playbackCommands.settledSpeedSaves == 2 }

        XCTAssertEqual(model.currentSpeedSaveStatus?.phase, .saved, "the stale failure did not settle")
        XCTAssertEqual(model.currentSpeedSaveStatus?.speed, 2)
        XCTAssertEqual(model.playbackRate, 2)
    }

    // PLAY-NOTREADY: an unprepared episode is not missing media.
    @MainActor
    func testUnpreparedEpisodeReportsNotReadyWhileIdle() async throws {
        let (model, backend, episode) = makePlaybackCommandModel(prepared: false)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.playbackCommands.failure?.kind, .notReady)
        XCTAssertFalse(model.hasCurrentPlayback)
        XCTAssertEqual(model.playbackStatusMessage, "Audio is not ready. Finish preparation first.",
                       "the failure outranks the idle line")
        XCTAssertEqual(model.playbackStatusTone, .failure)
        XCTAssertEqual(backend.loadCount, 0)
        XCTAssertFalse(model.audioRouteRecoveryAttempted)
    }

    // RACE-rail/side/full and FAIL-rail/side/full: the rail, side and full
    // players all render `playbackStatusMessage`, its tone, the answer line
    // and the retry predicate, so the states are asserted at that source,
    // idle and loaded alike.
    @MainActor
    func testCommandStatesOutrankIdleAndRestingStatusForEveryPlayer() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        XCTAssertFalse(model.showsPlaybackCommandResult)

        gate.arm()
        model.playEpisode(episode)
        XCTAssertFalse(model.hasCurrentPlayback, "the idle players are showing")
        XCTAssertTrue(model.showsPlaybackCommandResult)
        XCTAssertEqual(model.playbackStatusMessage, "Opening \(episode.title)…")
        XCTAssertFalse(model.canRetryPlayback)
        await gate.waitUntilHeld()
        gate.release()
        await model.waitForPlaybackOperationForTesting()
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playbackStatusMessage, "Paused")
        XCTAssertFalse(model.showsPlaybackCommandResult)

        gate.arm()
        model.togglePlayback()
        XCTAssertEqual(model.playbackStatusMessage, "Starting playback…")
        XCTAssertEqual(model.playbackStatusTone, .caution)
        await gate.waitUntilHeld()
        backend.refusesPlay = true
        gate.release()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playbackStatusMessage, "Playback refused. Your position is kept.")
        XCTAssertEqual(model.playbackStatusTone, .failure)
        XCTAssertTrue(model.canRetryPlayback)
        XCTAssertFalse(model.audioRouteFault, "one fault, one button: no Recover audio beside Retry")
    }

    @MainActor
    func testDelayedPlayPauseUsesButtonFeedbackWithoutMovingPlayerDetails() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        await loadPausedThroughOwner(model, episode)
        let larderEpisode = WiltedMacEpisode(
            id: "larder-pixel-control-fixture", title: "Larder Pixel Control",
            feedTitle: "Fixture", summary: "Ready fixture row", artworkURL: nil,
            releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 600,
            playbackSeconds: 0, downloadState: .completed, preparationState: .prepared(summary: "Ready")
        )
        model.installEpisodeForTesting(larderEpisode)
        model.podcastQueueIDs.append(larderEpisode.id)
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        defer { gate.release() }
        let views: [(String, AnyView, CGSize)] = [
            ("rail-min", AnyView(WiltedMacCompactPlayer(model: model)), CGSize(width: 800, height: 300)),
            ("rail-normal", AnyView(WiltedMacCompactPlayer(model: model)), CGSize(width: 1100, height: 300)),
            ("pane-min", AnyView(WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))), CGSize(width: 400, height: 700)),
            ("pane-normal", AnyView(WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))), CGSize(width: 520, height: 700)),
            ("full-min", AnyView(WiltedMacFullWindowPlayer(model: model, presentation: .constant(.transcript), onSelect: { _ in }, onCollapse: { _ in })), CGSize(width: 800, height: 700)),
            ("full-normal", AnyView(WiltedMacFullWindowPlayer(model: model, presentation: .constant(.transcript), onSelect: { _ in }, onCollapse: { _ in })), CGSize(width: 1100, height: 700)),
            ("root-min", AnyView(WiltedMacRootView(model: model)), CGSize(width: 800, height: 700)),
            ("root-normal", AnyView(WiltedMacRootView(model: model)), CGSize(width: 1100, height: 700))
        ]
        func capture(_ phase: String) throws -> [[(String, CGFloat)]] {
            try views.map { name, view, size in
                let lines = try WiltedMacHeadless.recognizedLines(view, size: size)
                let text = lines.map(\.text).joined(separator: " ")
                XCTAssertFalse(text.contains("Starting playback"), text)
                XCTAssertFalse(text.contains("Pausing"), text)
                let anchorLabels = [episode.title, "Mark completed", "Transcript", "Hide Transcript"]
                let anchors = lines.filter { anchorLabels.contains($0.text) }
                XCTAssertFalse(anchors.isEmpty, "\(name): player detail/transport anchors must be rendered")
                let bitmap = try WiltedMacHeadless.render(view, size: size)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "in-button-\(name)-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
                return anchors.map { ($0.text, $0.top) }
            }
        }
        func sameGeometry(_ baseline: [[(String, CGFloat)]], _ current: [[(String, CGFloat)]]) -> Bool {
            guard baseline.count == current.count else { return false }
            return zip(baseline, current).enumerated().allSatisfy { index, pair in
                let (before, after) = pair
                guard before.map({ $0.0 }) == after.map({ $0.0 }) else { return false }
                return zip(before, after).allSatisfy { abs($0.1 - $1.1) <= 2 / views[index].2.height }
            }
        }
        func compare(_ baseline: [[(String, CGFloat)]], _ current: [[(String, CGFloat)]]) {
            XCTAssertTrue(sameGeometry(baseline, current), "Player anchors stay within two rendered pixels of their steady frames")
        }
        let larder = WiltedMacLarderView(model: model, paneMode: .side)
        let larderSize = CGSize(width: 1100, height: 700)
        XCTAssertEqual(WiltedMacModel.larderGroup(for: larderEpisode), .playable)
        XCTAssertFalse(model.isEpisodeFinished(larderEpisode), "The visible row must render its Play now control")
        XCTAssertTrue(model.larderUnfilteredEpisodes(in: .playable).contains { $0.id == larderEpisode.id })
        let larderFrame = try WiltedMacHeadless.render(larder, size: larderSize)
        let larderRowRect = try actualLarderRowCaptureRect(
            larder, size: larderSize, bitmap: larderFrame, episode: larderEpisode)
        func rowPixels() throws -> Data {
            try actualLarderRowPixels(larder, size: larderSize, rect: larderRowRect)
        }
        let pausedRow = try rowPixels()
        let paused = try capture("paused")
        let insertedStatusRow = paused.enumerated().map { index, anchors in
            anchors.map { ($0.0, $0.1 + 8 / views[index].2.height) }
        }
        XCTAssertFalse(sameGeometry(paused, insertedStatusRow),
                       "The same geometry check must reject an eight-pixel status-row shift in every player")
        gate.arm(); model.togglePlayback(); await gate.waitUntilHeld()
        XCTAssertEqual(model.playbackCommands.pending?.command.kind, .start)
        XCTAssertEqual(model.playbackCommands.pending?.usesPlayPauseButtonFeedback, true)
        let generation = model.playbackCommands.generation; let starts = backend.playCount
        model.togglePlayback(); model.togglePlayback()
        XCTAssertEqual(model.playbackCommands.generation, generation)
        compare(paused, try capture("starting"))
        XCTAssertEqual(try rowPixels(), pausedRow, "A player start must not spin the unrelated Larder Play now button")
        gate.release(); await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying); XCTAssertEqual(backend.playCount, starts + 1)
        let playing = try capture("playing"); let playingRow = try rowPixels()
        gate.arm(); model.togglePlayback(); await gate.waitUntilHeld()
        XCTAssertEqual(model.playbackCommands.pending?.command.kind, .pause)
        XCTAssertEqual(model.playbackCommands.pending?.usesPlayPauseButtonFeedback, true)
        let pauseGeneration = model.playbackCommands.generation; let pauses = backend.pauseCount
        model.togglePlayback(); model.pausePlayback()
        XCTAssertEqual(model.playbackCommands.generation, pauseGeneration)
        compare(playing, try capture("pausing"))
        XCTAssertEqual(try rowPixels(), playingRow, "A player pause must not spin the unrelated Larder Play now button")
        gate.release(); await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(model.isPlaying); XCTAssertEqual(backend.pauseCount, pauses + 1)
        XCTAssertNil(model.playbackCommands.pending)
        compare(paused, try capture("settled"))
        backend.refusesPlay = true; model.togglePlayback(); await model.waitForPlaybackOperationForTesting()
        XCTAssertNil(model.playbackCommands.pending); XCTAssertTrue(model.canRetryPlayback)
        let fault = try WiltedMacHeadless.recognizedText(
            WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState())), size: CGSize(width: 520, height: 700)).joined(separator: " ")
        XCTAssertTrue(fault.contains("Playback refused"), fault); XCTAssertTrue(fault.contains("Retry playback"), fault)
    }

    @MainActor
    func testFirstSelectionKeepsIdlePlayerGeometryWhileItsLarderRowIsBusy() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        model.selectedNavigation = .larder
        model.podcastQueueIDs = [episode.id]
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        defer { gate.release() }
        func capture(_ phase: String) throws -> [CGFloat] {
            try [CGFloat(800), 1100].map { width in
                let view = WiltedMacRootView(model: model); let size = CGSize(width: width, height: 700)
                let lines = try WiltedMacHeadless.recognizedLines(view, size: size)
                let text = lines.map(\.text).joined(separator: " ")
                XCTAssertFalse(text.contains("Opening"), "Opening feedback belongs to the clicked row's button")
                let anchor = try XCTUnwrap(lines.first { $0.text == "Nothing is playing" })
                let bitmap = try WiltedMacHeadless.render(view, size: size)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "in-button-first-selection-root-\(Int(width))-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
                return anchor.top
            }
        }
        let larder = WiltedMacLarderView(model: model, paneMode: .side)
        let larderSize = CGSize(width: 1100, height: 700)
        XCTAssertEqual(WiltedMacModel.larderGroup(for: episode), .playable)
        XCTAssertFalse(model.isEpisodeFinished(episode), "The visible row must render its Play now control")
        XCTAssertTrue(model.larderUnfilteredEpisodes(in: .playable).contains { $0.id == episode.id })
        let larderFrame = try WiltedMacHeadless.render(larder, size: larderSize)
        let larderRowRect = try actualLarderRowCaptureRect(
            larder, size: larderSize, bitmap: larderFrame, episode: episode)
        func rowPixels() throws -> Data {
            try actualLarderRowPixels(larder, size: larderSize, rect: larderRowRect)
        }
        let idleRow = try rowPixels()
        let idle = try capture("idle")
        gate.arm(); model.playLarderEpisode(episode); await gate.waitUntilHeld()
        XCTAssertFalse(model.hasCurrentPlayback); XCTAssertEqual(backend.loadCount, 0)
        XCTAssertEqual(model.playbackCommands.pending?.command.kind, .select)
        XCTAssertEqual(model.playbackCommands.pending?.command.itemID, episode.id)
        XCTAssertEqual(model.playbackCommands.pending?.usesInitiatingButtonFeedback, true)
        XCTAssertNotEqual(try rowPixels(), idleRow, "The clicked first-selection row must still render its spinner")
        for (before, held) in zip(idle, try capture("opening")) { XCTAssertEqual(before, held, accuracy: 0.004) }
        model.handleRemoteCommand(.pause); gate.release(); await model.waitForPlaybackOperationForTesting()
        XCTAssertNil(model.playbackCommands.pending); XCTAssertEqual(backend.loadCount, 0)
        for (before, cancelled) in zip(idle, try capture("cancelled")) { XCTAssertEqual(before, cancelled, accuracy: 0.004) }
    }

    // MARK: Helpers

    @MainActor
    private func actualLarderRowCaptureRect(
        _ view: WiltedMacLarderView, size: CGSize, bitmap: NSBitmapImageRep, episode: WiltedMacEpisode
    ) throws -> CGRect {
        let image = try XCTUnwrap(bitmap.cgImage)
        let lines = try WiltedMacHeadless.recognizedLines(view, size: size)
        let title = try XCTUnwrap(
            lines.first { $0.text.contains(episode.title) },
            "The installed Larder row must remain visible in the pixel capture; recognized: "
                + lines.map(\.text).joined(separator: " | ")
        )
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // recognizedLines uses a 24pt margin around a 2× view render. Translate its normalized
        // title top back to the 1× Larder image, then keep the surrounding row and trailing controls.
        let titleTop = title.top * size.height - 24
        let rowTop = max(0, titleTop - 36)
        let rowBottom = min(CGFloat(image.height), titleTop + 51)
        return CGRect(x: 0, y: rowTop, width: CGFloat(image.width), height: rowBottom - rowTop)
            .integral.intersection(imageBounds)
    }

    @MainActor
    private func actualLarderRowPixels(
        _ view: WiltedMacLarderView, size: CGSize, rect: CGRect
    ) throws -> Data {
        let bitmap = try WiltedMacHeadless.render(view, size: size)
        let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: rect))
        let row = NSBitmapImageRep(cgImage: image)
        // The 28pt Play now slot follows the 58pt trailing actions, one 8pt gap,
        // and the view's 16pt destination and card insets.
        let playSlot = NSRect(
            x: CGFloat(row.pixelsWide - 126), y: 0, width: 28, height: CGFloat(row.pixelsHigh)
        )
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: row, region: playSlot), 4,
                             "The visible Play now control must be painted in the captured row")
        return Data(bytes: try XCTUnwrap(row.bitmapData), count: row.bytesPerRow * row.pixelsHigh)
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}

/// Speed saves that finish when the test says so, in any order.
@MainActor
final class WiltedMacSpeedSaveScript {
    private var pending: [(speed: Double, continuation: CheckedContinuation<Void, Error>)] = []
    var pendingCount: Int { pending.count }

    func save(_ speed: Double) async throws {
        try await withCheckedThrowingContinuation { pending.append((speed, $0)) }
    }

    func finish(speed: Double, failing: Bool) {
        guard let index = pending.firstIndex(where: { $0.speed == speed }) else { return }
        let entry = pending.remove(at: index)
        if failing {
            entry.continuation.resume(throwing: CocoaError(.fileWriteUnknown))
        } else {
            entry.continuation.resume()
        }
    }
}
