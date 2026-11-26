import Foundation
import SwiftUI
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryBulletinAudioActionabilityTests: XCTestCase {
    private let suite = "library-bulletin-audio-actionability"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        await HostedAccessibility.prepare()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testWeatherCardExplainsUncheckedMacAudioAndOffersManualRetry() async throws {
        let speaker = StubSpeaker()
        speaker.bulletinAudioIssueMessage = "The Mac audio has no text check. Update Wilted on both devices, then retry."
        let channel = try LibraryBulletins(
            alertsEnabled: true, headlinesEnabled: false, headlines: [], updatedAt: Date())
        let rig = makeInterruptionRig(channel: channel, defaults: defaults, speaker: speaker)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        let bulletin = try Bulletin(
            id: "weather-audio-needs-update", kind: .alert,
            text: "A weather alert with verified wording.", severity: .severe,
            issuedAt: Date(), expiresAt: Date().addingTimeInterval(600))
        rig.controller.alertArrived(bulletin)

        let host = HostedView(LibraryNowPlayingWeatherAlertCard(controller: rig.controller))
        XCTAssertEqual(
            host.element("wilted-player-weather-alert-audio-issue")?.label,
            speaker.bulletinAudioIssueMessage)
        let position = rig.player.position
        XCTAssertTrue(try XCTUnwrap(host.element("wilted-player-weather-alert-audio-retry")).activate())
        host.settle()

        XCTAssertEqual(speaker.bulletinAudioRetries, [bulletin])
        XCTAssertNil(host.element("wilted-player-weather-alert-audio-issue"))
        XCTAssertTrue(speaker.spokenBulletins.isEmpty, "retry fetches audio but never starts speech")
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.player.position, position, accuracy: 0.01)
    }

    func testHeadlineCardKeepsAnUnstartedStoryVisibleWithRecoveryAction() async throws {
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        let speaker = StubSpeaker()
        speaker.bulletinAudioIssueMessage = "The bulletin text changed between devices. Update Wilted on both devices, then retry."
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults, speaker: speaker)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        let bulletin = try XCTUnwrap(rig.controller.availableHeadline)

        let host = HostedView(LibraryNowPlayingHeadlineCard(
            controller: rig.controller,
            headlineState: fixture.model.headlinePhoneState,
            model: fixture.model))
        XCTAssertEqual(host.element("wilted-player-headline-state")?.label, "Story available")
        XCTAssertEqual(
            host.element("wilted-player-headline-audio-issue")?.label,
            speaker.bulletinAudioIssueMessage)
        XCTAssertTrue(try XCTUnwrap(host.element("wilted-player-headline-audio-retry")).activate())
        host.settle()

        XCTAssertEqual(speaker.bulletinAudioRetries, [bulletin])
        XCTAssertTrue(speaker.spokenBulletins.isEmpty, "a retry remains silent until an ad break")
        XCTAssertFalse(rig.player.isHoldingForSpeech)
    }
}
