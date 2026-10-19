import SwiftUI
import Vision
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
extension WiltedMacFeedPolicyViewTests {
    func testPolicyAndRuleWritesDuringReloadRemainVisibleAndDurable() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "feed-policy-write-race"
        )
        addTeardownBlock { await model.close() }
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let feedID = try ItemID(rawValue: subscription.id)
        let store = try XCTUnwrap(model.store)
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()

        let policyGate = FeedPolicyReloadGate()
        board.afterFeedPolicyReadHookForTesting = { _ in await policyGate.pause() }
        let policyReload = Task { await board.reload() }
        await policyGate.waitUntilEntered()
        XCTAssertTrue(board.update(subscription.id, keptLimit: .explicit(3)))
        XCTAssertEqual(board.policy(for: subscription.id).keptLimit, .explicit(3))
        await board.settle()
        board.afterFeedPolicyReadHookForTesting = nil
        await policyGate.release()
        await policyReload.value
        XCTAssertEqual(board.policy(for: subscription.id).keptLimit, .explicit(3))
        let storedPolicy = try await store.feedAutomationPolicy(for: feedID)
        XCTAssertEqual(storedPolicy.keptLimit, .explicit(3))

        let rulesGate = FeedPolicyReloadGate()
        board.afterFeedPolicyReadHookForTesting = { _ in await rulesGate.pause() }
        let rulesReload = Task { await board.reload() }
        await rulesGate.waitUntilEntered()
        let savedRules = EpisodeMatchRules(rules: [
            EpisodeMatchRule(field: .title, includePattern: "never matches", action: .skip)
        ])
        XCTAssertTrue(board.replaceRules(savedRules, for: subscription.id))
        XCTAssertEqual(board.rules(for: subscription.id), savedRules)
        await board.settle()
        board.afterFeedPolicyReadHookForTesting = nil
        await rulesGate.release()
        await rulesReload.value
        XCTAssertEqual(board.rules(for: subscription.id), savedRules)
        let storedRules = try await store.episodeMatchRules(for: feedID)
        XCTAssertEqual(storedRules, savedRules)
    }

    func testNewsWriteDuringReloadRemainsVisibleAndDurable() async throws {
        let directory = wiltedTemporaryDirectory("feed-policy-news-race")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/news.xml"))
        let createdAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let articleFeed = try ArticleFeed(canonicalURL: feedURL, title: "News feed", createdAt: createdAt)
        let feedID = articleFeed.itemID
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(articleFeed: articleFeed)
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: createdAt))
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let subscription = try XCTUnwrap(model.subscriptions.first)
        XCTAssertEqual(subscription.id, feedID.rawValue)
        let store = try XCTUnwrap(model.store)
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        XCTAssertTrue(board.isArticleFeed(feedID.rawValue))

        let gate = FeedPolicyReloadGate()
        board.afterFeedPolicyReadHookForTesting = { _ in await gate.pause() }
        let reload = Task { await board.reload() }
        await gate.waitUntilEntered()
        XCTAssertTrue(board.setNews(true, for: feedID.rawValue))
        XCTAssertTrue(board.isNews(feedID.rawValue))
        await board.settle()
        board.afterFeedPolicyReadHookForTesting = nil
        await gate.release()
        await reload.value

        XCTAssertTrue(board.isNews(feedID.rawValue))
        let storedNews = try await store.isNews(feedID: feedID)
        XCTAssertTrue(storedNews)
    }

    func testCancelledPolicyReadReturnsToIdleAndAllowsReload() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "feed-policy-cancel"
        )
        addTeardownBlock { await model.close() }
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        let gate = FeedPolicyReloadGate()
        board.afterFeedPolicyReadHookForTesting = { _ in
            await gate.pause()
            throw CancellationError()
        }
        let reload = Task { await board.reload() }
        await gate.waitUntilEntered()
        reload.cancel()
        board.afterFeedPolicyReadHookForTesting = nil
        await gate.release()
        await reload.value

        XCTAssertFalse(board.isLoading)
        XCTAssertNil(board.loadFailureMessage)
        XCTAssertTrue(board.isLoaded(subscription.id))
        await board.reload()
        XCTAssertEqual(board.loadState, .loaded)
    }

    func testPreloadedCapacitySnapshotRemainsVisibleDuringBlockedReload() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "feed-policy-reload"
        )
        addTeardownBlock { await model.close() }
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        let committedPolicy = board.policy(for: subscription.id)
        XCTAssertTrue(board.isLoaded(subscription.id))

        let gate = FeedPolicyReloadGate()
        board.reloadReadHookForTesting = { await gate.pause() }
        let reload = Task { await board.reload() }
        await gate.waitUntilEntered()
        XCTAssertTrue(board.isLoading)
        XCTAssertTrue(board.isLoaded(subscription.id))
        XCTAssertEqual(board.policy(for: subscription.id), committedPolicy)

        let capacity: [String]
        do {
            capacity = try WiltedMacHeadless.recognizedText(
                WiltedMacFeedCapacityLabel(board: board, subscription: subscription),
                size: CGSize(width: 360, height: 80)
            )
        } catch {
            await gate.release()
            await reload.value
            throw error
        }
        let renderedCapacity = capacity.joined(separator: " ")
        XCTAssertFalse(renderedCapacity.contains("Loading settings"), renderedCapacity)
        XCTAssertTrue(renderedCapacity.contains("kept"), renderedCapacity)

        await gate.release()
        await reload.value
        XCTAssertTrue(board.isLoaded(subscription.id))
        XCTAssertEqual(board.policy(for: subscription.id), committedPolicy)
    }

    /// OCR uses the exact canvas: the shared 24pt margin clips a fixed-width popover's Done control.
    func capture<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) throws -> String {
        let size = CGSize(width: width, height: height)
        var text = ""
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let content = view.environment(\.colorScheme, scheme)
                .frame(width: width, height: height, alignment: .topLeading)
                .background(WiltedTheme.color(.card, scheme: scheme))
            let bitmap = try WiltedMacHeadless.render(content, size: size)
            if !dark {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.usesCPUOnly = true // Keep headless OCR off the shared neural-engine service.
                request.usesLanguageCorrection = true; request.recognitionLanguages = ["en-US"]
                request.customWords = ["Larder", "Processing"]; request.minimumTextHeight = 0.001
                try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
                text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                if name.hasPrefix("defaults-") {
                    let image = try XCTUnwrap(bitmap.cgImage)
                    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                    for observation in request.results ?? [] {
                        guard observation.topCandidates(1).first?.string.contains("Set in") == true else { continue }
                        let box = observation.boundingBox
                        let pixels = CGRect(x: box.minX * bounds.width,
                            y: (1 - box.maxY) * bounds.height, width: box.width * bounds.width,
                            height: box.height * bounds.height).insetBy(dx: -4, dy: -4).intersection(bounds).integral
                        let crop = try XCTUnwrap(image.cropping(to: pixels))
                        let line = VNRecognizeTextRequest(); line.recognitionLevel = .accurate
                        line.usesCPUOnly = true
                        line.usesLanguageCorrection = true; line.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: crop).perform([line])
                        text += " " + (line.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    }
                }
            }
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "feed-policy-\(name)-\(dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
        }
        return text
    }

    func testAutoPrepareBlockedExplanationRendersOnlyWhenSuppressedByGlobalManual() async throws {
        let model = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "auto-prepare-blocked"
        )
        addTeardownBlock { await model.close() }
        let subscription = try XCTUnwrap(model.subscriptions.first)
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()

        // 1. Initial / unblocked: default processing is immediate, feed is Use global (resolves to On)
        XCTAssertEqual(model.automationSettings.processingPolicy, .immediate)
        XCTAssertFalse(model.automationSettings.prepareEverythingDownloaded)
        XCTAssertEqual(board.policy(for: subscription.id).autoPrepare, .useGlobal)
        XCTAssertEqual(board.resolved(for: subscription.id).autoPrepare, true)

        let initialContent = WiltedMacFeedPolicyContent(board: board, subscription: subscription)
        XCTAssertFalse(initialContent.isAutoPrepareBlocked)
        let initialText = try capture(initialContent, "prepare-initial", width: 460, height: 700)
        XCTAssertFalse(initialText.contains("Processing is set to Manual"), initialText)
        XCTAssertFalse(initialText.contains("will not prepare automatically"), initialText)

        // 2. Explicit Auto prepare On under default immediate processing is not blocked
        XCTAssertTrue(board.update(subscription.id, autoPrepare: .on))
        await board.settle()
        XCTAssertEqual(board.policy(for: subscription.id).autoPrepare, .on)
        XCTAssertEqual(board.resolved(for: subscription.id).autoPrepare, true)

        let immediateContent = WiltedMacFeedPolicyContent(board: board, subscription: subscription)
        XCTAssertFalse(immediateContent.isAutoPrepareBlocked)
        let immediateText = try capture(immediateContent, "prepare-immediate-on", width: 460, height: 700)
        XCTAssertFalse(immediateText.contains("Processing is set to Manual"), immediateText)
        XCTAssertFalse(immediateText.contains("will not prepare automatically"), immediateText)

        // 3. Blocked: Processing is Manual, prepareEverythingDownloaded is Off, feed Auto prepare is On
        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .manual, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: settings.downloadEverythingOnLarder,
                prepareEverythingDownloaded: false,
                initialEpisodeMetadataCount: settings.initialEpisodeMetadataCount,
                autoKeepNewEpisodes: settings.autoKeepNewEpisodes,
                keptLimitPerFeed: settings.keptLimitPerFeed
            )
        }
        XCTAssertEqual(model.automationSettings.processingPolicy, .manual)
        XCTAssertFalse(model.automationSettings.prepareEverythingDownloaded)
        XCTAssertEqual(board.policy(for: subscription.id).autoPrepare, .on)
        XCTAssertEqual(board.resolved(for: subscription.id).autoPrepare, true)

        let blockedContent = WiltedMacFeedPolicyContent(board: board, subscription: subscription)
        XCTAssertTrue(blockedContent.isAutoPrepareBlocked)
        XCTAssertEqual(WiltedAutomationCoordinator.preparationPlan(
            processingPolicy: model.automationSettings.processingPolicy, at: Date()
        ), .skip)
        let blockedText = try capture(blockedContent, "prepare-manual-blocked", width: 460, height: 700)
        XCTAssertTrue(blockedText.contains("Processing is set to Manual"), blockedText)
        XCTAssertTrue(blockedText.contains("will not prepare automatically"), blockedText)
        XCTAssertTrue(blockedText.contains("Prepare everything downloaded"), blockedText)

        // 4. Non-blocked: Processing is Manual, but prepareEverythingDownloaded is On
        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .manual, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: settings.downloadEverythingOnLarder,
                prepareEverythingDownloaded: true,
                initialEpisodeMetadataCount: settings.initialEpisodeMetadataCount,
                autoKeepNewEpisodes: settings.autoKeepNewEpisodes,
                keptLimitPerFeed: settings.keptLimitPerFeed
            )
        }
        XCTAssertTrue(model.automationSettings.prepareEverythingDownloaded)
        XCTAssertEqual(board.resolved(for: subscription.id).autoPrepare, true)

        let manualPreparedContent = WiltedMacFeedPolicyContent(board: board, subscription: subscription)
        XCTAssertFalse(manualPreparedContent.isAutoPrepareBlocked)
        let manualPreparedText = try capture(manualPreparedContent, "prepare-manual-prepare-everything", width: 460, height: 700)
        XCTAssertFalse(manualPreparedText.contains("Processing is set to Manual"), manualPreparedText)

        // 5. Non-blocked: Processing is Manual and prepareEverythingDownloaded is Off, but feed Auto prepare is Off
        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .manual, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: settings.downloadEverythingOnLarder,
                prepareEverythingDownloaded: false,
                initialEpisodeMetadataCount: settings.initialEpisodeMetadataCount,
                autoKeepNewEpisodes: settings.autoKeepNewEpisodes,
                keptLimitPerFeed: settings.keptLimitPerFeed
            )
        }
        XCTAssertTrue(board.update(subscription.id, autoPrepare: .off))
        await board.settle()
        XCTAssertEqual(board.policy(for: subscription.id).autoPrepare, .off)
        XCTAssertEqual(board.resolved(for: subscription.id).autoPrepare, false)

        let explicitOffContent = WiltedMacFeedPolicyContent(board: board, subscription: subscription)
        XCTAssertFalse(explicitOffContent.isAutoPrepareBlocked)
        let explicitOffText = try capture(explicitOffContent, "prepare-manual-explicit-off", width: 460, height: 700)
        XCTAssertFalse(explicitOffText.contains("Processing is set to Manual"), explicitOffText)

        // 6. Non-blocked: Processing is Manual and prepareEverythingDownloaded is Off, feed Auto prepare is Use global (resolves to Off)
        XCTAssertTrue(board.update(subscription.id, autoPrepare: .useGlobal))
        await board.settle()
        XCTAssertEqual(board.policy(for: subscription.id).autoPrepare, .useGlobal)
        XCTAssertEqual(board.resolved(for: subscription.id).autoPrepare, false)

        let useGlobalContent = WiltedMacFeedPolicyContent(board: board, subscription: subscription)
        XCTAssertFalse(useGlobalContent.isAutoPrepareBlocked)
        let useGlobalText = try capture(useGlobalContent, "prepare-manual-use-global-off", width: 460, height: 700)
        XCTAssertFalse(useGlobalText.contains("Processing is set to Manual"), useGlobalText)
    }
}

private actor FeedPolicyReloadGate {
    private var hasEntered = false
    private var isReleased = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        hasEntered = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}
