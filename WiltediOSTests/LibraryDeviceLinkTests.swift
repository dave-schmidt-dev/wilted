import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The phone's half of the device handshake: it announces itself until the Mac links it, reads the link
/// every round, and never goes back to unlinked on a bad read.
@MainActor
final class LibraryDeviceLinkTests: XCTestCase {
    private var rigs: [HandshakeRig] = []

    override func tearDown() async throws {
        rigs.forEach { $0.tearDown() }
        rigs = []
    }

    private func makeRig(
        storeOwner: String? = HandshakeRig.owner, verifiedOwner: String? = HandshakeRig.owner, deviceKind: String = "iPad"
    ) throws -> HandshakeRig {
        let rig = try HandshakeRig(storeOwner: storeOwner, verifiedOwner: verifiedOwner, deviceKind: deviceKind)
        rigs.append(rig)
        return rig
    }

    private var savedLinkKey: String { LibraryAppModel.savedMacLinkKey }

    // MARK: announcing

    func testAnnouncesOnTheFirstEligibleRoundWithOnlyTheModelFamily() async throws {
        let rig = try makeRig(deviceKind: "iPad")
        await rig.model.refresh()

        let sent = rig.probe.announcements
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.deviceID, "phone")
        XCTAssertEqual(sent.first?.kind, "iPad", "the model family only (W-INV-031), never the person's name for the device")
        XCTAssertEqual(sent.first?.announcedAt, rig.clock.now)
        let directory = try await rig.mac.fetchDeviceDirectory()
        XCTAssertEqual(directory?.devices.map(\.deviceID), ["phone"], "the Mac reads the announcement from the shared directory")
        XCTAssertFalse(rig.model.deviceLinked)
    }

    func testAnIphoneAnnouncesItselfAsAnIphone() async throws {
        let rig = try makeRig(deviceKind: "iPhone")
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announcements.map(\.kind), ["iPhone"])
    }

    func testAnnouncesOnceThenNotAgainUntilTenMinutesPass() async throws {
        let rig = try makeRig()
        await rig.model.refresh()
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announcements.count, 1, "a second round at once does not announce again")

        rig.clock.advance(LibraryAppModel.announceInterval - 1)
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announcements.count, 1, "one second short of ten minutes")

        rig.clock.advance(2)
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announcements.count, 2, "ten minutes after the last announcement")
        XCTAssertEqual(rig.probe.announcements.last?.announcedAt, rig.clock.now)
        XCTAssertEqual(LibraryAppModel.announceInterval, 600)
    }

    func testAClockSetBackNeverSilencesTheAnnouncement() async throws {
        let rig = try makeRig()
        await rig.model.refresh()
        rig.clock.advance(-3_600)
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announcements.count, 2, "a time before the last announcement counts as an interval passed")
    }

    func testAFailedAnnouncementWaitsForTheNextIntervalInsteadOfRetryingEveryRound() async throws {
        let rig = try makeRig()
        rig.probe.announcementsFail = true
        await rig.model.refresh()
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announceAttempts, 1, "a failure is not retried on every 30 s round")
        XCTAssertTrue(rig.probe.announcements.isEmpty)

        rig.probe.announcementsFail = false
        rig.clock.advance(LibraryAppModel.announceInterval + 1)
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announceAttempts, 2)
        XCTAssertEqual(rig.probe.announcements.count, 1, "the next interval tries again and reaches the Mac")
    }

    func testNeverAnnouncesWhileTheAccountIsHeldUnboundOrUnverified() async throws {
        let held = try makeRig()
        await held.store.hold()
        await held.model.refresh()
        XCTAssertTrue(held.probe.announcements.isEmpty, "held for review: W-INV-021")
        XCTAssertEqual(held.probe.announceAttempts, 0)

        let unbound = try makeRig(storeOwner: nil, verifiedOwner: nil)
        await unbound.model.refresh()
        XCTAssertEqual(unbound.probe.announceAttempts, 0, "no account bound to the saved library yet")

        let unverified = try makeRig(storeOwner: "saved-owner", verifiedOwner: nil)
        await unverified.model.refresh()
        XCTAssertEqual(unverified.probe.announceAttempts, 0, "the signed-in account is not proven this launch")

        let other = try makeRig(storeOwner: "saved-owner", verifiedOwner: "another-owner")
        await other.model.refresh()
        XCTAssertEqual(other.probe.announceAttempts, 0, "the signed-in account is not the saved library's")
    }

    // MARK: linking

    func testTheLinkIsReadEveryRoundAndEndsAnnouncing() async throws {
        let rig = try makeRig()
        await rig.model.refresh()
        XCTAssertFalse(rig.model.deviceLinked)
        XCTAssertEqual(rig.probe.announcements.count, 1)

        try await rig.macLinksPhone()
        await rig.model.refresh()
        XCTAssertTrue(rig.model.deviceLinked, "the next round sees the Mac's link")
        XCTAssertNotNil(rig.model.deviceLinkState.link)

        rig.clock.advance(LibraryAppModel.announceInterval * 3)
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announcements.count, 1, "a linked device never announces again")
    }

    func testALinkInTheSameRoundPreventsTheAnnouncement() async throws {
        let rig = try makeRig()
        try await rig.macLinksPhone()
        await rig.model.refresh()
        XCTAssertTrue(rig.model.deviceLinked)
        XCTAssertEqual(rig.probe.announceAttempts, 0, "the round reads the link before it decides to announce")
    }

    func testALinkedDeviceNeverGoesBackToUnlinkedOnABadRead() async throws {
        let modes: [HandshakeProbe.Read] = [.throwing, .unread, .absent, .otherDevice]
        for mode in modes {
            let rig = try makeRig()
            try await rig.macLinksPhone()
            await rig.model.refresh()
            XCTAssertTrue(rig.model.deviceLinked, "\(mode): linked first")

            rig.probe.readMode = mode
            rig.clock.advance(LibraryAppModel.announceInterval * 2)
            await rig.model.refresh()
            XCTAssertTrue(rig.model.deviceLinked, "\(mode): a read that failed or found nothing changes nothing")
            XCTAssertNotNil(rig.defaults.data(forKey: savedLinkKey), "\(mode): the saved fact stays")
            XCTAssertEqual(rig.probe.announceAttempts, 0, "\(mode): and the device does not announce itself again")
        }
    }

    func testALinkWrittenForAnotherDeviceDoesNotLinkThisOne() async throws {
        let rig = try makeRig()
        rig.probe.readMode = .otherDevice
        await rig.model.refresh()
        XCTAssertFalse(rig.model.deviceLinked)
        XCTAssertNil(rig.defaults.data(forKey: savedLinkKey))
        XCTAssertEqual(rig.probe.announcements.count, 1, "still unlinked, so it announces")
    }

    func testAFailedReadKeepsAnUnlinkedDeviceUnlinkedAndSilent() async throws {
        let rig = try makeRig()
        rig.probe.readMode = .throwing
        await rig.model.refresh()
        XCTAssertFalse(rig.model.deviceLinked)
        XCTAssertEqual(rig.probe.announceAttempts, 0, "a round that could not read is offline: nothing to announce over")
    }

    /// Regression (2026-10-20): the Mac had saved both devices' links, yet the iPhone and iPad stayed on
    /// "Connecting to your Mac", because the link was applied only after the round's offer step, which
    /// can end the round early.
    func testTheLinkLandsEvenWhenTheRoundsOfferStepEndsItEarly() async throws {
        let rig = try makeRig()
        await rig.store.refuseOffers()
        try await rig.macLinksPhone()
        await rig.model.refresh()
        XCTAssertTrue(rig.model.deviceLinked, "the link must not wait behind the offers")
        XCTAssertFalse(rig.model.showsMacLinkNotice)
    }

    /// Regression (2026-10-20): a relaunched phone's account stays unverified until something checks it, and
    /// the round's first check stopped every round, so the phone never synced, announced or picked up the link.
    func testARelaunchedPhoneChecksItsAccountFirstAndPicksUpTheLink() async throws {
        let rig = try makeRig()
        rig.probe.ownerUncheckedUntilAsked = true
        try await rig.macLinksPhone()
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.ownerChecks, 1, "the round checks the account before its first check")
        XCTAssertTrue(rig.model.deviceLinked)
        XCTAssertFalse(rig.model.showsMacLinkNotice)

        await rig.model.refresh()
        XCTAssertEqual(rig.probe.ownerChecks, 1, "a verified account is not checked again every round")
    }

    func testARelaunchedUnlinkedPhoneChecksItsAccountAndAnnounces() async throws {
        let rig = try makeRig()
        rig.probe.ownerUncheckedUntilAsked = true
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announcements.map(\.deviceID), ["phone"], "the Mac must learn of the device")
    }

    func testAnUnlinkedPhoneStillAnnouncesWhenTheRoundsOfferStepEndsItEarly() async throws {
        let rig = try makeRig()
        await rig.store.refuseOffers()
        await rig.model.refresh()
        XCTAssertEqual(rig.probe.announcements.map(\.deviceID), ["phone"], "the Mac must still learn of the device")
        XCTAssertFalse(rig.model.deviceLinked)
    }

    // MARK: remembering

    func testTheLinkSurvivesARelaunchWithNoSignal() async throws {
        let rig = try makeRig()
        try await rig.macLinksPhone()
        await rig.model.refresh()
        XCTAssertTrue(rig.model.deviceLinked)

        rig.probe.readMode = .throwing
        let relaunched = rig.makeModel(store: rig.store, verifiedOwner: HandshakeRig.owner)
        XCTAssertFalse(relaunched.deviceLinked, "nothing is known before the local state loads")
        await relaunched.loadLocalState()
        XCTAssertTrue(relaunched.deviceLinked, "the saved fact needs no network")
    }

    func testALinkLearnedUnderAnotherAccountIsNotInherited() async throws {
        let rig = try makeRig()
        try await rig.macLinksPhone()
        await rig.model.refresh()

        let otherAccount = HandshakeStore(owner: "someone-else")
        let relaunched = rig.makeModel(store: otherAccount, verifiedOwner: "someone-else")
        await relaunched.loadLocalState()
        XCTAssertFalse(relaunched.deviceLinked)
    }

    func testAnAccountChangeClearsTheLinkAndTheDeviceAnnouncesToTheNewLibrary() async throws {
        let nextURL = FileManager.default.temporaryDirectory.appendingPathComponent("handshake-next-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: nextURL) }
        let next = FileLibraryStore(url: nextURL) // the empty replica recovery hands back; the first sync binds its account
        let recovery = LibraryAccountRecovery(quarantineEvents: AsyncStream { $0.finish() }) { next }
        let rig = try HandshakeRig(recovery: recovery)
        rigs.append(rig)
        try await rig.macLinksPhone()
        try await rig.queue("a") // also gives the new account's empty replica something to bind to
        await rig.model.refresh()
        XCTAssertTrue(rig.model.deviceLinked)
        XCTAssertNotNil(rig.defaults.data(forKey: savedLinkKey))
        XCTAssertEqual(rig.probe.announceAttempts, 0)

        rig.probe.readMode = .absent // the new library's Mac has not linked this device
        await rig.model.recoverFromAccountChange()

        XCTAssertFalse(rig.model.deviceLinked, "the Mac that linked the phone belonged to the previous account")
        XCTAssertNil(rig.model.deviceLinkState.link)
        XCTAssertNil(rig.defaults.data(forKey: savedLinkKey), "and it is not remembered for the next launch")
        XCTAssertEqual(rig.probe.announcements.count, 1, "the new account's first verified round announces at once")
    }

    // MARK: a running tick

    func testTheRoundsOfARunningTickAnnounceOnceAndPickUpTheLink() async throws {
        let rig = try HandshakeRig(
            handoffTiming: LibraryHandoffTiming(observeInterval: 0.05, settleSleep: { _ in }), realClock: true)
        rigs.append(rig)
        await rig.model.sceneBecameActive()
        await rig.model.start()
        XCTAssertEqual(rig.probe.announcements.count, 1, "the first sync announces")
        XCTAssertFalse(rig.model.deviceLinked)

        try await rig.macLinksPhone()
        try await rig.eventually("the tick reads the link") { rig.model.deviceLinked }
        await rig.model.sceneBecameBackground()
        XCTAssertEqual(rig.probe.announcements.count, 1, "unlinked rounds inside ten minutes do not repeat it")
    }
}
