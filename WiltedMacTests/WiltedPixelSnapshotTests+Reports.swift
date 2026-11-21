import AppKit
import SwiftUI
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

extension WiltedPixelSnapshotTests {
    // MARK: Reports settings

    /// The Reports section with interruptions on, the daily report on and typed coordinates in use.
    func testReportsSettingsPixelBaselines() async throws {
        for appearance in WiltedAppearance.allCases {
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("reports-pixel"),
                preferences: WiltedMacTestPreferences.ephemeral())
            model.updateAutomationSettings { current in
                current.updatingReports {
                    $0.interruptionsEnabled = true
                    $0.reportEnabled = true
                    $0.typedLatitude = 38.9
                    $0.typedLongitude = -77.04
                    $0.nwsContact = "listener@example.test"
                }
            }
            let location = WiltedLocationProvider(
                manager: PixelFakeLocationManager(), wifi: PixelFakeWiFi(),
                typedCoordinates: model.automationSettings.typedCoordinates)
            let content = WiltedMacReportsCard(model: model, location: location, startsExpanded: true)
                .padding(WiltedTheme.Spacing.large)
                .environment(\.wiltedTextScale, model.textScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(WiltedTheme.color(.page, scheme: appearance == .dark ? .dark : .light))
            let image = render(
                content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                size: CGSize(width: 760, height: 560))
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the Reports section drew")
            assertSnapshot(
                image, named: WiltedSnapshotContract.shellName(kind: "settings-reports", appearance: appearance),
                testName: "testReportsSettingsPixelBaselines")
        }

        for state in ["not-ready", "ready"] {
            let library = try await AccountingLibrary.make(
                in: wiltedTemporaryDirectory("reports-pixel-\(state)"))
            let model = library.model
            let location = WiltedLocationProvider(
                manager: ReadinessLocationManager(authorization: .denied), wifi: ReadinessWiFi())
            let hub = WiltedMacBulletinHub(
                model: model, location: location, makeSpeaker: { ReadinessSpeaker() },
                makeRouteSource: { ReadinessRoute() })
            model.installBulletinHubForTesting(hub)

            if state == "ready" {
                let store = try XCTUnwrap(model.store)
                let createdAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                let feed = try ArticleFeed(
                    canonicalURL: try XCTUnwrap(URL(string: "https://feeds.example.test/reports-pixel.xml")),
                    title: "Reports snapshot news", createdAt: createdAt)
                try await store.save(articleFeed: feed)
                try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: createdAt))
                try await store.save(isNews: true, feedID: feed.itemID)
            }

            model.updateAutomationSettings { current in
                current.updatingReports {
                    $0.interruptionsEnabled = true
                    $0.headlinesEnabled = true
                    $0.alertsEnabled = true
                    $0.reportEnabled = true
                    $0.typedLatitude = 38.9
                    $0.typedLongitude = -77.04
                    $0.nwsContact = "listener@example.test"
                }
            }
            await hub.refreshNewsSourceReadiness()
            XCTAssertEqual(hub.readiness.lines, state == "ready" ? [.ready] : [.news])

            for appearance in WiltedAppearance.allCases {
                let content = WiltedMacReportsCard(model: model, location: location)
                    .padding(WiltedTheme.Spacing.large)
                    .environment(\.wiltedTextScale, model.textScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(WiltedTheme.color(
                        .page, scheme: appearance == .dark ? .dark : .light))
                let image = render(
                    content, variant: .init(appearance: appearance, dynamicType: .standard, reduceMotion: false),
                    size: CGSize(width: 760, height: 560))
                let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                XCTAssertGreaterThan(distinctColorCount(in: bitmap), 8, "the Reports readiness state drew")
                assertSnapshot(
                    image,
                    named: WiltedSnapshotContract.shellName(kind: "settings-reports-\(state)", appearance: appearance),
                    testName: "testReportsSettingsPixelBaselines")
            }
            await model.close()
        }
    }

    /// Settings is scrollable at window scale, so this focused render check
    /// guards against the automation card collapsing the destination to a
    /// blank surface without requiring a new unreviewed pixel baseline.
    func testSettingsAutomationSurfaceRendersAtWindowScale() throws {
        for appearance in WiltedAppearance.allCases {
            let variant = WiltedVisualVariant(
                appearance: appearance,
                dynamicType: .standard,
                reduceMotion: false
            )
            let model = WiltedMacModel(
                arguments: ["--wilted-ui-fixture-ready"],
                stateDirectoryOverride: wiltedTemporaryDirectory("fixture"),
                preferences: WiltedMacTestPreferences.ephemeral()
            )
            model.selectedNavigation = .settings
            let image = render(WiltedMacRootView(model: model), variant: variant, size: windowCanvas)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let detail = NSRect(x: 260, y: 0, width: bitmap.pixelsWide - 260, height: bitmap.pixelsHigh)
            XCTAssertGreaterThan(
                distinctColorCount(in: bitmap, region: detail), 8,
                "Settings automation surface is blank in \(appearance.rawValue) mode."
            )
        }
    }
}

@MainActor
private final class PixelFakeLocationManager: WiltedLocationManaging {
    var authorization = WiltedLocationAuthorization.authorized
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double) -> Void)?
    var onFailure: (() -> Void)?
    func requestPermission() {}
    func requestOneFix() {}
}

@MainActor
private final class PixelFakeWiFi: WiltedWiFiPowerReading {
    var isPoweredOn = false
}
