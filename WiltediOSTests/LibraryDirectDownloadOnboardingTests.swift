import Foundation
import SwiftUI
import UIKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Tests for Task 3.3: direct-download onboarding step and Settings row.
/// Asserts the step shows once for fresh and updated installs, defaults on,
/// no browse runs before Continue, off skips the browse, and denial shows the instruction.
@MainActor
final class LibraryDirectDownloadOnboardingTests: XCTestCase {
    private let suite = "library-direct-download-onboarding-tests"
    private var defaults: UserDefaults!
    private var fixture: LibraryViewFixture?

    override func setUp() async throws {
        await HostedAccessibility.prepare()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        fixture?.tearDown()
        fixture = nil
    }

    // MARK: - Step shows once for fresh and updated installs

    func testFreshInstallNeedsOnboardingOnce() {
        XCTAssertTrue(LibraryDirectDownloadOnboarding.needsOnboarding(in: defaults))
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertTrue(store.needsDirectDownloadsOnboarding)

        LibraryDirectDownloadOnboarding.recordOnboardingShown(in: defaults)
        XCTAssertFalse(LibraryDirectDownloadOnboarding.needsOnboarding(in: defaults))

        let reloaded = LibrarySettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.needsDirectDownloadsOnboarding)
    }

    func testUpdatedInstallNeedsOnboardingOnce() {
        // An existing user updating to this version has other preferences stored
        // but has never seen the direct download onboarding step.
        defaults.set(1.75, forKey: LibrarySettingsStore.speedKey)
        defaults.set(false, forKey: LibrarySettingsStore.autoPlayNextKey)
        defaults.set("title", forKey: LibrarySettingsStore.listSortKey)

        XCTAssertTrue(LibraryDirectDownloadOnboarding.needsOnboarding(in: defaults))
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertTrue(store.needsDirectDownloadsOnboarding)

        LibraryDirectDownloadOnboarding.recordOnboardingShown(in: defaults)
        XCTAssertFalse(LibraryDirectDownloadOnboarding.needsOnboarding(in: defaults))

        let reloaded = LibrarySettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.needsDirectDownloadsOnboarding)
    }

    // MARK: - Defaults on

    func testDefaultsOn() {
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertTrue(store.directDownloads, "direct downloads defaults to ON")
        XCTAssertTrue(LibrarySettingsStore.directDownloadsEnabled(in: defaults))

        let onboarding = LibraryDirectDownloadOnboarding(settings: store)
        XCTAssertTrue(onboarding.settings.directDownloads)
    }

    // MARK: - No browse runs before Continue

    func testNoBrowseRunsBeforeContinue() {
        let store = LibrarySettingsStore(defaults: defaults)
        let locator = DirectFakeLocator()
        let onboarding = LibraryDirectDownloadOnboarding(settings: store, locator: locator)

        let hosted = HostedView(onboarding)
        hosted.settle()

        XCTAssertEqual(locator.calls, 0, "no browse runs before Continue is tapped")
        XCTAssertNotNil(hosted.element("wilted-library-direct-downloads-onboarding-toggle"))
        XCTAssertNotNil(hosted.element("wilted-library-direct-downloads-onboarding-continue"))
    }

    // MARK: - Continue with ON starts one short browse

    func testContinueWithOnStartsOneShortBrowse() async {
        let store = LibrarySettingsStore(defaults: defaults)
        store.directDownloads = true
        let locator = DirectFakeLocator()
        var completed = false
        let onboarding = LibraryDirectDownloadOnboarding(
            settings: store,
            locator: locator,
            browseBudget: .milliseconds(50),
            onContinue: { completed = true }
        )

        await onboarding.continueAction()

        XCTAssertEqual(locator.calls, 1, "Continue with ON starts exactly one short browse")
        XCTAssertTrue(completed)
        XCTAssertFalse(LibraryDirectDownloadOnboarding.needsOnboarding(in: defaults))
    }

    // MARK: - Continue with OFF skips the browse

    func testContinueWithOffSkipsTheBrowse() async {
        let store = LibrarySettingsStore(defaults: defaults)
        store.directDownloads = false
        let locator = DirectFakeLocator()
        var completed = false
        let onboarding = LibraryDirectDownloadOnboarding(
            settings: store,
            locator: locator,
            browseBudget: .milliseconds(50),
            onContinue: { completed = true }
        )

        await onboarding.continueAction()

        XCTAssertEqual(locator.calls, 0, "Continue with OFF skips the browse entirely")
        XCTAssertTrue(completed)
        XCTAssertFalse(LibraryDirectDownloadOnboarding.needsOnboarding(in: defaults))
    }

    // MARK: - Denial shows instruction in onboarding

    func testDenialShowsInstructionInOnboarding() async throws {
        let store = LibrarySettingsStore(defaults: defaults)
        store.directDownloads = true
        let locator = DirectFakeLocator(.denied)
        var completed = false
        let onboarding = LibraryDirectDownloadOnboarding(
            settings: store,
            locator: locator,
            browseBudget: .milliseconds(50),
            onContinue: { completed = true }
        )

        let hosted = HostedView(onboarding)
        hosted.settle()
        XCTAssertNil(hosted.element("wilted-library-direct-downloads-denied"))

        await onboarding.continueAction()
        hosted.settle()

        XCTAssertTrue(onboarding.isDenied)
        XCTAssertFalse(completed, "does not dismiss immediately on denial so user sees instruction")

        let instruction = try XCTUnwrap(hosted.element("wilted-library-direct-downloads-denied"))
        let label = try XCTUnwrap(instruction.label)
        XCTAssertTrue(
            label.contains(LibraryDirectDownloadOnboarding.localNetworkDeniedInstruction),
            "expected denial instruction in label: \(label)"
        )
    }

    // MARK: - Denial shows instruction in Settings

    func testDenialShowsInstructionInSettings() async throws {
        let fix = try LibraryViewFixture(linked: true)
        fixture = fix
        let store = LibrarySettingsStore(defaults: fix.defaults)

        fix.model.directState.localNetworkDenied = false
        let allowedSettingsView = LibrarySettingsView(
            settings: store, model: fix.model, playingID: nil, onDone: {}
        )
        let hostedAllowed = HostedView(allowedSettingsView)
        hostedAllowed.settle()
        XCTAssertNil(hostedAllowed.element("wilted-library-settings-direct-downloads-denied"))

        fix.model.directState.localNetworkDenied = true
        let deniedSettingsView = LibrarySettingsView(
            settings: store, model: fix.model, playingID: nil, onDone: {}
        )
        let hostedDenied = HostedView(deniedSettingsView)
        hostedDenied.settle()

        let instruction = try XCTUnwrap(hostedDenied.element("wilted-library-settings-direct-downloads-denied"))
        let label = try XCTUnwrap(instruction.label)
        XCTAssertTrue(
            label.contains(LibraryDirectDownloadOnboarding.localNetworkDeniedInstruction),
            "expected denial instruction in settings label: \(label)"
        )
    }

    // MARK: - Settings row toggles direct downloads

    func testSettingsRowTogglesDirectDownloads() {
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertTrue(store.directDownloads)

        store.directDownloads = false
        XCTAssertFalse(store.directDownloads)
        XCTAssertFalse(defaults.bool(forKey: LibrarySettingsStore.directDownloadsKey))
        XCTAssertFalse(LibrarySettingsStore.directDownloadsEnabled(in: defaults))

        store.directDownloads = true
        XCTAssertTrue(store.directDownloads)
        XCTAssertTrue(defaults.bool(forKey: LibrarySettingsStore.directDownloadsKey))
        XCTAssertTrue(LibrarySettingsStore.directDownloadsEnabled(in: defaults))
    }
}
