import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import WiltedWeather

@MainActor
final class WiltedMacBulletinReadinessViewTests: XCTestCase {
    func testNewsWeatherDeniedLocationPausedAndReadyLinesRenderInReportsCard() throws {
        let (model, location) = makeEmptyRig()
        let states: [(BulletinReadiness, String, String)] = [
            (.init(hasNewsSource: false, hasWeatherLocation: true, soundCheckPaused: false),
             "Turn on Headlines only for an article feed.", "Add headline feed"),
            (.init(hasNewsSource: true, hasWeatherLocation: false, soundCheckPaused: false),
             "Weather alerts need a location.", "Set location"),
            (.init(hasNewsSource: true, hasWeatherLocation: false, soundCheckPaused: false,
                   locationAccessDenied: true),
             "Location access is off. Allow access or enter a location for weather alerts.", "Set location"),
            (.init(hasNewsSource: true, hasWeatherLocation: true, soundCheckPaused: true),
             "Bulletins are paused because Wilted couldn’t check the sound output.", "Try again"),
            (.init(hasNewsSource: true, hasWeatherLocation: true, soundCheckPaused: false),
             "Ready: Wilted can read bulletins while an episode plays.", "Play a test bulletin")
        ]

        for (readiness, expectedLine, expectedButton) in states {
            let card = WiltedMacReportsCard(
                model: model, location: location, readinessOverride: readiness)
                .padding(12)
            let text = try WiltedMacHeadless.recognizedText(
                card, size: CGSize(width: 760, height: 300)).joined(separator: " ")
            // OCR reads the button beside a wrapped line in the middle of it and prints ’ as ', so
            // the full line is compared with the button title lifted out and apostrophes unified.
            let unified = { (value: String) in value.replacingOccurrences(of: "\u{2019}", with: "'") }
            let lineText = unified(text.replacingOccurrences(of: " \(expectedButton) ", with: " ")
                .split(separator: " ").joined(separator: " "))
            XCTAssertTrue(unified(text).contains(unified(expectedLine)) || lineText.contains(unified(expectedLine)),
                          "Reports did not render the line: \(expectedLine). Text: \(text)")
            XCTAssertTrue(text.contains(expectedButton), "Reports did not render the action: \(expectedButton)")
            if readiness.lines.contains(.ready) {
                XCTAssertTrue(text.contains("waits for a break or until the wait time runs out"),
                              "the ready line must explain when Wilted can speak")
                XCTAssertTrue(text.contains("most serious weather alerts play right away"),
                              "the ready line must explain urgent alerts")
            }
        }
    }

    func testNewsReadinessUsesArticleFeedNewsMarkAndRendersTheDerivedReadyState() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("reports-news-readiness"))
        let model = library.model
        let location = locationProvider(authorization: .denied)
        let hub = WiltedMacBulletinHub(
            model: model, location: location, makeSpeaker: { ReadinessSpeaker() },
            makeRouteSource: { ReadinessRoute() })
        model.installBulletinHubForTesting(hub)
        model.updateAutomationSettings { current in
            current.updatingReports {
                $0.interruptionsEnabled = true
                $0.headlinesEnabled = true
                $0.alertsEnabled = true
            }
        }
        await hub.refreshNewsSourceReadiness()
        XCTAssertEqual(hub.readiness.lines, [.news, .locationDenied],
                       "denied permission without saved coordinates needs a plain next step")

        model.updateAutomationSettings { current in
            current.updatingReports {
                $0.typedLatitude = 38.9
                $0.typedLongitude = -77.04
            }
        }

        await hub.refreshNewsSourceReadiness()
        XCTAssertEqual(hub.readiness.lines, [.news], "a podcast feed cannot supply headlines")

        let store = try XCTUnwrap(model.store)
        let createdAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feed = try ArticleFeed(
            canonicalURL: XCTUnwrap(URL(string: "https://feeds.example.test/readiness.xml")),
            title: "Readiness news", createdAt: createdAt)
        try await store.save(articleFeed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: createdAt))
        await hub.refreshNewsSourceReadiness()
        XCTAssertEqual(hub.readiness.lines, [.news], "an article feed must be marked as News")

        try await store.save(isNews: true, feedID: feed.itemID)
        await hub.refreshNewsSourceReadiness()
        XCTAssertEqual(hub.readiness.lines, [.ready])

        let card = WiltedMacReportsCard(model: model, location: location)
            .padding(12)
        let text = try WiltedMacHeadless.recognizedText(
            card, size: CGSize(width: 760, height: 300)).joined(separator: " ")
        XCTAssertTrue(text.contains("Ready: Wilted can read bulletins while an episode plays."),
                      "the Reports card did not show the state derived from the saved News feed")
        XCTAssertTrue(text.contains("waits for a break or until the wait time runs out"))
        XCTAssertTrue(text.contains("most serious weather alerts play right away"))
        XCTAssertFalse(text.contains("Weather alerts need a location."),
                       "saved coordinates remain usable when permission is denied")
        await model.close()
    }

    func testRetryButtonImmediatelyClearsPausedStateWithFakeRoute() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("reports-retry-button"))
        let model = library.model
        let route = ReadinessRoute()
        route.canStart = false
        let location = locationProvider(authorization: .denied)
        let hub = WiltedMacBulletinHub(
            model: model, location: location, makeSpeaker: { ReadinessSpeaker() },
            makeRouteSource: { route },
            retrySleep: { _ in try await Task.sleep(for: .seconds(600)) })
        model.installBulletinHubForTesting(hub)
        model.updateAutomationSettings { current in
            current.updatingReports { $0.interruptionsEnabled = true }
        }
        XCTAssertEqual(hub.routeProtectionStatus, WiltedMacBulletinHub.unavailableRouteMessage)
        XCTAssertFalse(hub.interruptionsAreAttached)

        route.canStart = true
        let card = WiltedMacReportsCard(model: model, location: location).padding(12)
        let shown = try WiltedMacHeadless.recognizedText(card, size: CGSize(width: 760, height: 300)).joined(separator: " ")
        XCTAssertTrue(shown.contains("Try again"), "the paused card offers Try again: \(shown)")
        // Hidden SwiftUI hosts vend no accessibility tree to press (see the AppKit probe in
        // WiltedMacPlaylistDiscoverabilityTests), so the test runs the action the button calls.
        model.bulletinHub.retryBulletinOutputCheck()

        let reattached = await WiltedMacHeadless.eventually("the retry button reattaches bulletin speech") {
            hub.interruptionsAreAttached
        }
        XCTAssertTrue(reattached)
        XCTAssertNil(hub.routeProtectionStatus, "the immediate retry clears the paused message")
        XCTAssertTrue(route.starts >= 2, "the button starts a fresh sound-output check")
        await model.close()
    }

    func testTestBulletinButtonSpeaksOnceWithoutPlaybackOrLibraryWork() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("reports-test-bulletin"))
        let model = library.model
        let store = try XCTUnwrap(model.store)
        let createdAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feed = try ArticleFeed(
            canonicalURL: try XCTUnwrap(URL(string: "https://feeds.example.test/test-bulletin.xml")),
            title: "Test bulletin news", createdAt: createdAt)
        try await store.save(articleFeed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: createdAt))
        try await store.save(isNews: true, feedID: feed.itemID)

        let location = locationProvider(authorization: .denied)
        let speaker = ReadinessSpeaker()
        let testHub = WiltedMacBulletinHub(
            model: model, location: location, makeSpeaker: { speaker },
            makeRouteSource: { ReadinessRoute() })
        model.installBulletinHubForTesting(testHub)
        model.updateAutomationSettings { current in
            current.updatingReports {
                $0.interruptionsEnabled = true
                $0.headlinesEnabled = true
                $0.alertsEnabled = true
                $0.typedLatitude = 38.9
                $0.typedLongitude = -77.04
            }
        }
        await testHub.refreshNewsSourceReadiness()
        XCTAssertEqual(testHub.readiness.lines, [.ready])
        let feedIDsBefore = try await store.articleFeeds().map(\.itemID)
        let playbackBefore = model.playback
        let syncControllerBefore = model.librarySyncController

        let card = WiltedMacReportsCard(model: model, location: location).padding(12)
        let shown = try WiltedMacHeadless.recognizedText(card, size: CGSize(width: 760, height: 300)).joined(separator: " ")
        XCTAssertTrue(shown.contains("Play a test bulletin"), "the ready card offers a test bulletin: \(shown)")
        XCTAssertTrue(model.bulletinHub.playTestBulletin(), "the test bulletin starts speaking")

        XCTAssertEqual(speaker.texts, [WiltedMacBulletinHub.testBulletinText])
        XCTAssertEqual(speaker.callCount, 1)
        let feedIDsAfter = try await store.articleFeeds().map(\.itemID)
        XCTAssertEqual(feedIDsAfter, feedIDsBefore,
                       "a test sample leaves saved News feeds unchanged")
        XCTAssertTrue(model.playback === playbackBefore, "a test sample leaves playback untouched")
        XCTAssertTrue(model.librarySyncController === syncControllerBefore,
                      "a test sample leaves library sync untouched")
        XCTAssertTrue(model.bulletinHub === testHub)
        await model.close()
    }

    private func makeEmptyRig() -> (WiltedMacModel, WiltedLocationProvider) {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("reports-readiness-view"),
            preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        let location = locationProvider(authorization: .denied)
        let hub = WiltedMacBulletinHub(
            model: model, location: location, makeSpeaker: { ReadinessSpeaker() },
            makeRouteSource: { ReadinessRoute() })
        model.installBulletinHubForTesting(hub)
        model.updateAutomationSettings { current in
            current.updatingReports {
                $0.interruptionsEnabled = true
                $0.headlinesEnabled = true
                $0.alertsEnabled = true
            }
        }
        return (model, location)
    }

    private func locationProvider(authorization: WiltedLocationAuthorization) -> WiltedLocationProvider {
        WiltedLocationProvider(
            manager: ReadinessLocationManager(authorization: authorization),
            wifi: ReadinessWiFi())
    }
}

@MainActor
final class ReadinessLocationManager: WiltedLocationManaging {
    var authorization: WiltedLocationAuthorization
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double) -> Void)?
    var onFailure: (() -> Void)?

    init(authorization: WiltedLocationAuthorization) { self.authorization = authorization }
    func requestPermission() {}
    func requestOneFix() {}
}

@MainActor
final class ReadinessWiFi: WiltedWiFiPowerReading {
    var isPoweredOn = false
}

@MainActor
final class ReadinessRoute: MacAudioRouteSource {
    var canStart = true
    var starts = 0
    var changed: (@MainActor () -> Void)?

    func start(changed: @escaping @MainActor () -> Void) -> Bool {
        starts += 1
        self.changed = changed
        return canStart
    }
    func currentRoute() -> MacAudioRoute? { MacAudioRoute(device: 10) }
    func stop() { changed = nil }
}

@MainActor
final class ReadinessSpeaker: BulletinSpeaking {
    private(set) var callCount = 0
    private(set) var texts: [String] = []

    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        callCount += 1
        texts.append(text)
        return true
    }
    func stop() {}
}
