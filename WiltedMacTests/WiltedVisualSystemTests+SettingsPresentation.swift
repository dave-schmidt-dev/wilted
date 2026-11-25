import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedVisualSystemTests {
    func testEpisodeCountControlsOnlyExposeNumericInputForCustomAndKeepValidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // Settings keeps the saved default. The per-subscribe "Episodes listed" picker lived in the
        // Feeds popover, which the Add sheet replaced in B6.2 Task 3.1, so only Settings is pinned.
        let source = try String(
            contentsOf: root.appendingPathComponent("WiltedMac/Views/WiltedMacSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Picker(\"Episodes to list when adding a feed\""))
        XCTAssertTrue(source.contains("Text(\"Custom\").tag(0)"))
        XCTAssertTrue(source.contains("if initialMetadataPreset.wrappedValue == 0"))
        XCTAssertTrue(source.contains("Titles and notes only; audio follows your download settings."))
        XCTAssertTrue(source.contains("validInitialEpisodeMetadataCount(value)"))
        XCTAssertNil(WiltedAutomationSettings.validInitialEpisodeMetadataCount(0))
        XCTAssertNil(WiltedAutomationSettings.validInitialEpisodeMetadataCount(101))
        XCTAssertEqual(WiltedAutomationSettings.validInitialEpisodeMetadataCount(7), 7)
    }

    func testAutomationSettingsPresentationFollowsThePipelineAndOnlyShowsLiveControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let start = try XCTUnwrap(source.range(of: "var automationCard")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "var syncCard", range: start..<source.endIndex)?.lowerBound)
        let card = source[start..<end]

        let feeds = try XCTUnwrap(card.range(of: "automationSectionTitle(\"Feeds\")")?.lowerBound)
        let processing = try XCTUnwrap(card.range(of: "WiltedSettingsCard(title: \"Processing\")")?.lowerBound)
        XCTAssertLessThan(feeds, processing)
        XCTAssertFalse(card.contains("wilted-automation-download-policy"))
        XCTAssertFalse(card.contains("wilted-automation-feeds-admission-policy"))
        let settings = try String(contentsOf: root.appendingPathComponent("WiltedMac/Views/WiltedMacSettingsView.swift"), encoding: .utf8)
        let feedView = try String(contentsOf: root.appendingPathComponent("WiltedMac/Views/WiltedMacFeedsView.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains("WiltedScreenCopy.feedsPolicy"))
        XCTAssertTrue(feedView.contains("WiltedMacHelpButton(content: refreshHelp"))
        XCTAssertTrue(feedView.contains("WiltedMacHelpContent(title: \"Subscriptions\", text: WiltedScreenCopy.feedsPolicy)"))
        XCTAssertTrue(card.contains("wilted-automation-refresh-policy"))
        XCTAssertTrue(card.contains("wilted-automation-processing-policy"))
        XCTAssertTrue(card.contains("wilted-automation-transcript-policy"))
        XCTAssertTrue(card.contains("wilted-automation-remove-ads"))
        XCTAssertTrue(card.contains("wilted-automation-transcript-explanation"))
        XCTAssertTrue(card.contains("model.automationSettings.transcriptPolicyExplanation"))
        XCTAssertTrue(card.contains("wilted-automation-off-peak-start"))
        XCTAssertTrue(card.contains("wilted-automation-off-peak-end"))
        XCTAssertTrue(card.contains("Uses local time. The window may continue overnight."))
        XCTAssertTrue(card.contains("if isOffPeakProcessing"))
        XCTAssertTrue(card.contains("value: model.automationStatus.settingsStatusText"))
        XCTAssertTrue(card.contains("if model.automationStatus.isCancellable"))
        XCTAssertTrue(card.contains("wilted-automation-status"))
        XCTAssertTrue(card.contains("wilted-automation-stop"))
        XCTAssertTrue(card.contains("model.updateAutomationSettings"))
        XCTAssertFalse(card.contains("UserDefaults"), "Settings must reuse the model's validated persistence")
    }

    func testSettingsOffersTheRemovedAdChime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let removeAds = try XCTUnwrap(source.range(of: "wilted-automation-remove-ads")?.lowerBound)
        let marker = try XCTUnwrap(source.range(of: "wilted-automation-ad-marker")?.lowerBound)
        XCTAssertTrue(source.contains("Toggle(\"Chime where an ad was removed\""))
        XCTAssertLessThan(removeAds, marker)
    }

    /// Removed rows carry enough presentation metadata to name the episode,
    /// its feed, and its retained Prep history without reconstructing a deleted
    /// episode record.
    func testRemovedEpisodePresentationMetadataNamesPrepHistory() {
        let removed = WiltedMacDismissedEpisode(
            id: "episode-id", feedID: "feed-id", title: "Recovered episode",
            feedTitle: "Field Notes", dismissedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasPreparationHistory: true
        )
        XCTAssertEqual(removed.title, "Recovered episode")
        XCTAssertEqual(removed.feedTitle, "Field Notes")
        XCTAssertTrue(removed.hasPreparationHistory)
        XCTAssertEqual(removed.id, "episode-id", "Restore identity must remain stable across renders")
    }

    // The removed-episodes card and its rows were deleted with the Larder in
    // Phase 0b; the accessibility-containment assertion that lived here is
    // waiting on Task 2.4 to decide where restore lives. Reinstate it against
    // that surface rather than reconstructing the old one.

    /// The producer window has no Downloads destination, so its copy must not
    /// send the reader to one. This was shipped: the Mac empty player told the
    /// reader to visit Downloads, and no pixel baseline could catch it because
    /// the Mac baselines always render the player, never the empty state.
    func testProducerCopyNamesOnlyProducerDestinations() {
        let producerDestinations = WiltedMacNavigation.allCases
        XCTAssertEqual(producerDestinations.map(\.title), ["Larder", "Feeds", "Notebook", "Settings"])

        XCTAssertFalse(
            WiltedScreenCopy.nowPlayingEmptyDetailProducer.contains(WiltedScreenCopy.downloads),
            "Producer copy must not point at a destination the Mac window does not have."
        )
        XCTAssertTrue(
            WiltedScreenCopy.nowPlayingEmptyDetailProducer.contains(WiltedScreenCopy.library)
        )
        // The listener does have Downloads, so its wording legitimately differs.
        XCTAssertTrue(WiltedScreenCopy.nowPlayingEmptyDetailListener.contains(WiltedScreenCopy.library))
        XCTAssertFalse(WiltedScreenCopy.nowPlayingEmptyDetailListener.contains(WiltedScreenCopy.downloads))
        XCTAssertFalse(
            WiltedScreenCopy.libraryEmptyDetailProducer.contains(WiltedScreenCopy.downloads)
        )
    }

    /// Emphasis without letting colour carry state alone: every phase still
    /// renders its own name, and only the phases that mean something distinct
    /// get a non-neutral tone.
    func testSyncPhasesCarryTheirOwnToneAndText() {
        let expected: [(WiltedMacSyncPhase, WiltedStatusTone)] = [
            (.disabled, .neutral), (.idle, .neutral), (.cancelled, .neutral),
            (.staging, .active), (.fetching, .active), (.sending, .active),
            (.completed, .positive), (.quarantined, .caution), (.failed, .failure)
        ]
        for (phase, tone) in expected {
            XCTAssertEqual(phase.tone, tone, "wrong tone for \(phase.rawValue)")
            XCTAssertFalse(phase.rawValue.isEmpty)
        }
        XCTAssertEqual(WiltedMacSyncPhase.quarantined.rawValue.capitalized, "Quarantined")
    }

    func testDeterministicRenderArtifactDoesNotDrift() {
        let variant = WiltedVisualVariant(
            appearance: .light,
            dynamicType: .xxxLarge,
            reduceMotion: true
        )
        XCTAssertEqual(
            WiltedPreviewState.emptyLibrary.renderSignature(variant: variant),
            "2ba6962858bc3fb7"
        )
        let signatures = Set(
            WiltedPreviewState.allCases.flatMap { state in
                WiltedVisualVariant.matrix.map { state.renderSignature(variant: $0) }
            }
        )
        XCTAssertEqual(signatures.count, WiltedPreviewState.allCases.count * WiltedVisualVariant.matrix.count)
    }

    /// The reported defect: a 29-minute article read "1743 seconds" on both
    /// platforms. These lock the format, not just the fix.
    func testDurationsReadAsClockTimeRatherThanRawSeconds() {
        XCTAssertEqual(WiltedDuration.clock(1743), "29:03")
        XCTAssertEqual(WiltedDuration.clock(120), "2:00")
        XCTAssertEqual(WiltedDuration.clock(0), "0:00")
        XCTAssertEqual(WiltedDuration.clock(9), "0:09")
        XCTAssertEqual(WiltedDuration.clock(3600), "1:00:00")
        XCTAssertEqual(WiltedDuration.clock(3661), "1:01:01")
        // Nothing may print a negative or non-finite clock.
        XCTAssertEqual(WiltedDuration.clock(-90), "0:00")
        XCTAssertEqual(WiltedDuration.clock(.infinity), "0:00")
        XCTAssertEqual(WiltedDuration.clock(.nan), "0:00")
        XCTAssertEqual(WiltedDuration.progress(position: 31, duration: 1743), "0:31 of 29:03")
    }

    /// VoiceOver cannot infer units from a colon, so the spoken form must carry
    /// the words. Reading "twenty-nine oh three" is the same defect as printing
    /// "1743".
    func testSpokenDurationsCarryUnitsRatherThanColons() {
        for value in [WiltedDuration.spoken(1743), WiltedDuration.spokenProgress(position: 31, duration: 1743)] {
            XCTAssertFalse(value.contains(":"), "spoken duration must not rely on a colon: \(value)")
            XCTAssertTrue(value.lowercased().contains("minute"), "spoken duration must name its units: \(value)")
        }
    }
}
