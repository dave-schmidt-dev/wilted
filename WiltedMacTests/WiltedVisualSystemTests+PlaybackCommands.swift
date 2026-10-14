import XCTest
import AppKit
import SwiftUI
import Vision
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

private struct WiltedPlayerAnchor {
    let label: String
    let top: CGFloat
    let box: CGRect
}

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
        func capture(_ phase: String, matching baseline: [[WiltedPlayerAnchor]]? = nil) throws -> [[WiltedPlayerAnchor]] {
            try views.enumerated().map { index, entry in
                let (name, view, size) = entry
                let frame = try playerFrame(view, size: size)
                let text = frame.observations.map(\.label).joined(separator: " ")
                XCTAssertFalse(text.contains("Starting playback"), text)
                XCTAssertFalse(text.contains("Pausing"), text)
                let anchorLabels = [episode.title, "Mark completed", "Transcript", "Hide Transcript"]
                let anchors: [WiltedPlayerAnchor]
                if let expected = baseline?[index] {
                    // Read each known label in its own nearby pixels: the Play spinner
                    // cannot change Vision's segmentation for unrelated text.
                    anchors = try expected.map { anchor in
                        try XCTUnwrap(playerAnchor(matching: anchor, in: frame.bitmap),
                                      "\(name) \(phase): missing player anchor \(anchor.label)")
                    }
                } else {
                    let discovered = anchorLabels.compactMap { label in
                        frame.observations.first { $0.label == label }
                    }
                    anchors = try discovered.map { anchor in
                        try XCTUnwrap(playerAnchor(matching: anchor, in: frame.bitmap),
                                      "\(name) \(phase): missing baseline player anchor \(anchor.label)")
                    }
                    XCTAssertFalse(anchors.isEmpty, "\(name): player detail/transport anchors must be rendered")
                }
                let attachment = XCTAttachment(data: try XCTUnwrap(frame.bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "in-button-\(name)-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
                return anchors
            }
        }
        func sameGeometry(_ baseline: [[WiltedPlayerAnchor]], _ current: [[WiltedPlayerAnchor]]) -> Bool {
            guard baseline.count == current.count else { return false }
            return zip(baseline, current).enumerated().allSatisfy { index, pair in
                let (before, after) = pair
                guard before.map(\.label) == after.map(\.label) else { return false }
                return zip(before, after).allSatisfy { abs($0.top - $1.top) <= 2 / views[index].2.height }
            }
        }
        func compare(_ baseline: [[WiltedPlayerAnchor]], _ current: [[WiltedPlayerAnchor]]) {
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
            try actualLarderRowPixels(larder, size: larderSize, rect: larderRowRect, episode: larderEpisode)
        }
        let pausedRow = try rowPixels()
        let paused = try capture("paused")
        let insertedStatusRow = paused.enumerated().map { index, anchors in
            anchors.map { WiltedPlayerAnchor(label: $0.label, top: $0.top + 8 / views[index].2.height, box: $0.box) }
        }
        XCTAssertFalse(sameGeometry(paused, insertedStatusRow),
                       "The same geometry check must reject an eight-pixel status-row shift in every player")
        gate.arm(); model.togglePlayback(); await gate.waitUntilHeld()
        XCTAssertEqual(model.playbackCommands.pending?.command.kind, .start)
        XCTAssertEqual(model.playbackCommands.pending?.usesPlayPauseButtonFeedback, true)
        let generation = model.playbackCommands.generation; let starts = backend.playCount
        model.togglePlayback(); model.togglePlayback()
        XCTAssertEqual(model.playbackCommands.generation, generation)
        compare(paused, try capture("starting", matching: paused))
        XCTAssertEqual(try rowPixels(), pausedRow, "A player start must not spin the unrelated Larder Play now button")
        gate.release(); await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying); XCTAssertEqual(backend.playCount, starts + 1)
        _ = try capture("playing", matching: paused)
        // Pause is answered before the press returns: the audio has stopped and no
        // pending state shows, while its checkpoint is still held on the effect tail.
        let pauses = backend.pauseCount
        gate.arm(); model.togglePlayback()
        XCTAssertNil(model.playbackCommands.pending)
        XCTAssertFalse(backend.isPlaying); XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(backend.pauseCount, pauses + 1)
        await gate.waitUntilHeld()
        let pauseGeneration = model.playbackCommands.generation
        model.pausePlayback()
        XCTAssertEqual(model.playbackCommands.generation, pauseGeneration, "a repeated Pause issues nothing")
        XCTAssertEqual(backend.pauseCount, pauses + 1)
        compare(paused, try capture("pausing", matching: paused))
        XCTAssertEqual(try rowPixels(), pausedRow, "A player pause must not spin the unrelated Larder Play now button")
        gate.release(); await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(model.isPlaying); XCTAssertEqual(backend.pauseCount, pauses + 1)
        XCTAssertNil(model.playbackCommands.pending)
        compare(paused, try capture("settled", matching: paused))
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
            try actualLarderRowPixels(larder, size: larderSize, rect: larderRowRect, episode: episode)
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

    /// Captures one 2x native render and reads anchors from the same pixels that
    /// are retained as evidence; the shipping view still receives point `size`.
    @MainActor
    private func playerFrame<V: View>(_ view: V, size: CGSize) throws -> (bitmap: NSBitmapImageRep, observations: [WiltedPlayerAnchor]) {
        let scale: CGFloat = 2
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).padding(24)
            .frame(width: size.width, height: size.height, alignment: .topLeading).background(Color.white))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return (bitmap, try playerAnchors(in: bitmap.cgImage))
    }

    private func playerAnchor(matching expected: WiltedPlayerAnchor, in bitmap: NSBitmapImageRep) throws -> WiltedPlayerAnchor? {
        let image = try XCTUnwrap(bitmap.cgImage)
        let inset: CGFloat = 12
        let rect = CGRect(x: expected.box.minX * CGFloat(image.width) - inset,
                          y: (1 - expected.box.maxY) * CGFloat(image.height) - inset,
                          width: expected.box.width * CGFloat(image.width) + 2 * inset,
                          height: expected.box.height * CGFloat(image.height) + 2 * inset)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard let crop = image.cropping(to: rect) else { return nil }
        return try playerAnchors(in: crop).first { $0.label == expected.label }.map {
            WiltedPlayerAnchor(label: $0.label,
                               top: (rect.minY + $0.top * rect.height) / CGFloat(image.height), box: expected.box)
        }
    }

    private func playerAnchors(in image: CGImage?) throws -> [WiltedPlayerAnchor] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image)).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map {
                WiltedPlayerAnchor(label: $0.string, top: 1 - observation.boundingBox.maxY, box: observation.boundingBox)
            }
        }
    }

    @MainActor
    private func actualLarderRowPixels(
        _ view: WiltedMacLarderView, size: CGSize, rect: CGRect, episode: WiltedMacEpisode
    ) throws -> Data {
        let bitmap = try WiltedMacHeadless.render(view, size: size)
        let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: rect))
        let row = NSBitmapImageRep(cgImage: image)
        let control = view.nextStepControl(episode, group: .playable).fixedSize()
        let host = NSHostingView(rootView: control)
        host.layoutSubtreeIfNeeded()
        let actionSize = host.fittingSize
        XCTAssertEqual(actionSize, CGSize(width: WiltedMacLarderView.readyActionSlotWidth, height: 32),
                       "measure the installed fixed action, rather than the retired text button")
        // The native action follows the shipping trailing slot and gap, inside destination/card insets.
        let trailingInset = 2 * WiltedTheme.Spacing.large + WiltedMacLarderView.trailingActionSlotsWidth
            + WiltedTheme.Spacing.small
        let playSlot = NSRect(
            x: CGFloat(row.pixelsWide) - trailingInset - actionSize.width,
            y: 0, width: actionSize.width, height: CGFloat(row.pixelsHigh)
        )
        XCTAssertGreaterThan(WiltedMacHeadless.distinctColorCount(in: row, region: playSlot), 4,
                             "The visible fixed Play action must be painted in the captured row")
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
