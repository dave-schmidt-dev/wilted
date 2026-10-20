import AppKit
import SwiftUI
import XCTest
import Vision
@testable import WiltedMac

@MainActor
final class WiltedMacFeedDetailsTests: XCTestCase {
    func testFeedNameOpensDetailsAndPencilStartsRenameAsSeparateActions() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(source.contains("Button { presentedSheet = .details(subscription.id) }"))
        XCTAssertTrue(source.contains("Button { beginFeedName(subscription) }"))
        XCTAssertTrue(source.contains("wilted-podcast-feed-name-\\(subscription.id)"))
        XCTAssertTrue(source.contains("wilted-podcast-feed-rename-\\(subscription.id)"))
        XCTAssertFalse(source.contains("Text(subscription.feedURL.host ?? subscription.feedURL.absoluteString)"))
    }

    func testBothFeedSheetsShareVisibleDoneCancelAction() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        let start = try XCTUnwrap(source.range(of: ".sheet(item: $presentedSheet) {"))
        let sheetSource = source[start.upperBound...]
        let end = try XCTUnwrap(sheetSource.range(of: "/// The count keeps the established Off the list"))
        let sheet = String(sheetSource[..<end.lowerBound])

        XCTAssertEqual(sheet.components(separatedBy: "wilted-feed-sheet-done").count - 1, 1)
        XCTAssertTrue(sheet.contains("Button(\"Done\") { presentedSheet = nil }"))
        XCTAssertTrue(sheet.contains(".keyboardShortcut(.cancelAction)"))
        let done = try XCTUnwrap(sheet.range(of: "Button(\"Done\")")).lowerBound
        let destinationSwitch = try XCTUnwrap(sheet.range(of: "switch sheet")).lowerBound
        XCTAssertLessThan(done, destinationSwitch, "one shared Done action wraps both sheet destinations")
        XCTAssertTrue(sheet.contains("case let .details(feedID):"))
        XCTAssertTrue(sheet.contains("case .history:"))
    }

    func testDetailsRenderStoredSourcePublisherFollowedRefreshSettingsAndHistory() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "feed-details"
        )
        addTeardownBlock { await model.close() }
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()

        let lines = try recognizedLines(
            WiltedMacFeedDetailsView(model: model, board: board, subscription: subscription),
            size: CGSize(width: 900, height: 2_000)
        )
        let recognizedText = lines.map(\.text).joined(separator: "\n")
        let text = recognizedText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(text.contains(subscription.title), text)
        XCTAssertTrue(text.contains(subscription.feedURL.absoluteString), text)
        XCTAssertTrue(text.contains(subscription.publisherTitle ?? "Publisher not provided"), text)
        XCTAssertTrue(text.contains("Followed"), text)
        let globalRefresh = model.lastPodcastRefreshAt?.formatted(date: .complete, time: .standard) ?? "Never"
        XCTAssertTrue(text.contains(globalRefresh), text)
        let globalLabel = try XCTUnwrap(lines.first { words(in: $0.text).contains("global") }, recognizedText)
        let rowLines = lines.filter { abs($0.top - globalLabel.top) <= 0.035 }
        let rowWords = rowLines.reduce(into: Set<String>()) { $0.formUnion(words(in: $1.text)) }
        let refreshValueWords = words(in: globalRefresh)
        let rowText = rowLines.map(\.text).joined(separator: " ")
        for word in ["global", "podcast", "refresh"] + Array(refreshValueWords) {
            XCTAssertTrue(rowWords.contains(word), "\(word) in the Global podcast refresh fact row: \(rowText)")
        }
        let valueLine = try XCTUnwrap(rowLines.first { refreshValueWords.isSubset(of: words(in: $0.text)) }, rowText)
        for labelLine in rowLines where
            ["global", "podcast", "refresh"].contains(where: { words(in: labelLine.text).contains($0) })
                && !refreshValueWords.isSubset(of: words(in: labelLine.text)) {
            XCTAssertLessThan(labelLine.bounds.midX, valueLine.bounds.midX, "label stays left of its value: \(rowText)")
        }
        XCTAssertFalse(text.contains("Last refreshed: Last refreshed"), text)
        XCTAssertTrue(text.contains("Current settings"), text)
        XCTAssertTrue(text.contains("Episode history"), text)
    }

    func testRenameSubmissionClosesImmediatelyAndFailureRestoresDraftAndError() throws {
        let subscription = WiltedMacSubscription(
            id: "fixture-feed", title: "Fixture feed",
            feedURL: URL(string: "https://feeds.example.test/show.xml")!, episodeCount: 0,
            subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        var interaction = WiltedMacFeedRenameInteraction()
        interaction.begin(subscription)
        interaction.update(subscription.id, text: "A new name")

        let submitted = interaction.submit(subscription.id)
        XCTAssertEqual(submitted, "A new name")
        XCTAssertNil(interaction.drafts[subscription.id], "the editor closes before asynchronous persistence starts")

        let submittedName = try XCTUnwrap(submitted)
        interaction.restoreFailure(subscription, text: submittedName, error: "Could not save. Try again.")
        XCTAssertEqual(interaction.drafts[subscription.id]?.text, "A new name")
        XCTAssertEqual(interaction.drafts[subscription.id]?.error, "Could not save. Try again.")
        XCTAssertFalse(interaction.drafts[subscription.id]?.isSaving ?? true)

        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        let submitRange = try XCTUnwrap(source.range(of: "private func submitFeedName"))
        let submitBody = source[submitRange.lowerBound...]
        XCTAssertLessThan(
            try XCTUnwrap(submitBody.range(of: "feedRenameInteraction.submit")).lowerBound,
            try XCTUnwrap(submitBody.range(of: "Task {")).lowerBound
        )
    }

    func testCapacityFailureIsVisibleAndRetryDoesNotLeaveTheBoardLoading() async throws {
        enum ExpectedFailure: LocalizedError {
            case open
            var errorDescription: String? { "Fixture store failure" }
        }

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("feed-capacity-failure"),
            storeBootstrap: { _ in throw ExpectedFailure.open },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        XCTAssertFalse(board.isLoading)
        XCTAssertNotNil(board.loadFailureMessage)
        XCTAssertFalse(board.isLoaded("missing-feed"), "a read failure must not resolve to default capacity")
        let subscription = WiltedMacSubscription(
            id: "missing-feed", title: "Missing feed", feedURL: URL(string: "https://example.test/feed.xml")!,
            episodeCount: 0, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), enabled: true
        )
        let capacity = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedCapacityLabel(board: board, subscription: subscription),
            size: CGSize(width: 360, height: 80)
        )
        XCTAssertTrue(capacity.contains("Settings unavailable"), "the failure is visible instead of a default count")

        await board.retryReload()
        XCTAssertFalse(board.isLoading)
        let failure = try XCTUnwrap(board.loadFailureMessage, "the failed retry stays visible")
        let details = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedDetailsView(model: model, board: board, subscription: subscription),
            size: CGSize(width: 900, height: 1_000)
        ).joined(separator: " ")
        // OCR can drop a sentence's closing period, so match the message without it.
        let visibleFailure = failure.hasSuffix(".") ? String(failure.dropLast()) : failure
        XCTAssertTrue(details.contains(visibleFailure), "actual safe startup error should be visible: \(details)")
        XCTAssertTrue(details.contains("Retry settings"), details)
    }

    func testFeedSettingsReadFailureIsPlainAndHidesErrorDetails() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "feed-settings-read-failure"
        )
        addTeardownBlock { await model.close() }
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let board = WiltedMacFeedPolicyBoard(model: model)
        board.afterFeedPolicyReadHookForTesting = { _ in
            throw URLError(.notConnectedToInternet, userInfo: [
                NSURLErrorFailingURLStringErrorKey: "https://feeds.example.test/x?token=SECRET-TOKEN",
            ])
        }
        await board.reload()

        XCTAssertEqual(board.loadFailureMessage, "Could not load settings for \(subscription.title). Try again.")
        let message = try XCTUnwrap(board.loadFailureMessage)
        XCTAssertFalse(message.contains("SECRET-TOKEN"), message)
        XCTAssertFalse(message.contains("Error Domain"), message)
        XCTAssertFalse(message.contains("NSURLErrorDomain"), message)
        XCTAssertFalse(message.contains("capacity"), message)
    }

    func testCompletionRetryMessageIsPlainAndSourceDropsAdmissionWording() throws {
        XCTAssertEqual(WiltedMacModel.completionRetryMessage,
                       "Some completions are still being finished. Wilted will retry.")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("WiltedMac/ViewModel/WiltedMacModel+EpisodeCompletion.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("admissions"))
    }

    private struct RecognizedLine {
        let text: String
        let bounds: CGRect
        var top: CGFloat { 1 - bounds.maxY }
    }

    private func recognizedLines<V: View>(_ view: V, size: CGSize) throws -> [RecognizedLine] {
        let scale = 2
        let hostingView = NSHostingView(rootView: AnyView(
            view.environment(\.colorScheme, .light).padding(24)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.white)
        ))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, bounds: observation.boundingBox) }
        }.sorted { $0.top < $1.top }
    }

    private func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
