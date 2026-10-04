import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Holds a transport call after the server answered and before the caller sees the result.
private actor HeldCall {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        arrived = true
        arrivals.forEach { $0.resume() }
        arrivals.removeAll()
        if !released { await withCheckedContinuation { releases.append($0) } }
    }

    func waitUntilHeld() async { if !arrived { await withCheckedContinuation { arrivals.append($0) } } }

    func release() {
        released = true
        releases.forEach { $0.resume() }
        releases.removeAll()
    }
}

/// Task 5.0: the library publisher sends only for the persisted, hashed owner of this library.
@MainActor
final class WiltedMacLibraryAccountTests: XCTestCase {
    private let flagOn = ["WILTED_LIBRARY_SYNC": "1"]
    private let ownerName = "_a71c-raw-icloud-owner-record"
    private let otherName = "_b82d-raw-icloud-other-record"
    private let feedURL = URL(string: "https://feeds.example.test/account.xml")!
    private let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    private func launch(_ directory: URL) async throws -> (WiltedMacModel, LocalLibraryStore) {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { try LocalLibraryStore(url: $0) }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return (model, try XCTUnwrap(model.store))
    }

    @discardableResult
    private func start(
        _ model: WiltedMacModel, _ fixture: WiltedMacLibraryAccountFixture, _ transport: InMemoryLibraryTransport
    ) throws -> WiltedMacLibrarySyncController {
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: transport, debounce: .milliseconds(10), account: fixture.source))
        return try XCTUnwrap(model.librarySyncController)
    }

    private func relaunchBoundary(_ model: WiltedMacModel) async {
        model.stopLibrarySync()
        await model.waitForLibrarySyncShutdown()
    }

    private func seed(_ store: LocalLibraryStore) async throws {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        let enclosure = URL(string: "https://media.example.test/account-a.mp3")!
        try await store.save(episode: try PodcastEpisode(
            itemID: try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "a", enclosureURL: enclosure),
            feedID: feedID, feedURL: feedURL, rssGUID: "a", title: "Episode a", publishedTime: created,
            enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created))
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    private func pair() -> (InMemoryLibraryServer, InMemoryLibraryTransport) {
        let server = InMemoryLibraryServer(writerDeviceID: "mac-account")
        return (server, InMemoryLibraryTransport(deviceID: "mac-account", server: server))
    }

    private func token(_ name: String) -> String { CloudKitAccountIdentity.token(for: name) }

    // MARK: First approval and relaunch

    func testFirstOwnerOfAnEmptyLibraryBindsAndSurvivesRelaunchWithoutReview() async throws {
        let directory = wiltedTemporaryDirectory("account-first-owner")
        let (model, store) = try await launch(directory)
        let fixture = WiltedMacLibraryAccountFixture()
        let (server, transport) = pair()
        let controller = try start(model, fixture, transport)
        XCTAssertEqual(model.libraryAccountStatus, .awaitingAccount, "nothing is sent before the account is known")
        XCTAssertNil(controller.inbound?.poller, "the poller waits for the account")

        fixture.signIn(recordName: ownerName)
        try await eventually("first owner bound") { model.libraryAccountStatus == .active }
        let bound = try await store.libraryAccountBinding()
        XCTAssertEqual(bound?.state, .bound)
        XCTAssertEqual(bound?.ownerToken, token(ownerName), "the owner is stored hashed")
        XCTAssertNotNil(controller.inbound?.poller, "the poller starts once the owner is bound")
        try await seed(store)
        controller.requestPublish()
        try await eventually("publish for the owner") { await server.currentSnapshot.entries.count == 1 }
        await relaunchBoundary(model)

        let (relaunched, _) = try await launch(directory)
        let next = WiltedMacLibraryAccountFixture()
        let (_, nextTransport) = pair()
        try start(relaunched, next, nextTransport)
        next.signIn(recordName: ownerName)
        try await eventually("same owner resumes after relaunch") { relaunched.libraryAccountStatus == .active }
        XCTAssertEqual(next.resets, 0, "the same owner needs no review and no transport reset")
        await relaunchBoundary(relaunched)
    }

    func testUnboundLibraryWithDataNeedsApprovalEvenAfterRelaunch() async throws {
        let directory = wiltedTemporaryDirectory("account-unbound-review")
        let (model, store) = try await launch(directory)
        try await seed(store)
        let fixture = WiltedMacLibraryAccountFixture()
        let (server, transport) = pair()
        let controller = try start(model, fixture, transport)
        fixture.signIn(recordName: ownerName)
        try await eventually("review required") { model.libraryAccountStatus == .reviewRequired(.unboundLibrary) }
        await controller.tickRound()
        XCTAssertEqual(model.libraryAccountStatus, .reviewRequired(.unboundLibrary))
        let unsent = await server.currentSnapshot.entries
        XCTAssertTrue(unsent.isEmpty, "an unbound library with data publishes nothing before review")
        await relaunchBoundary(model)

        let (relaunched, reopened) = try await launch(directory)
        let next = WiltedMacLibraryAccountFixture()
        let relaunchedController = try start(relaunched, next, transport)
        try await eventually("review state hydrated") { relaunched.libraryAccountStatus == .reviewRequired(.unboundLibrary) }
        next.signIn(recordName: ownerName)
        await relaunchedController.tickRound()
        do {
            _ = try await relaunchedController.publisher.sync()
            XCTFail("relaunch must reject publishing before approval")
        } catch {
            XCTAssertEqual(error as? WiltedMacLibraryAccountError, .notApproved)
        }
        let stillUnsent = await server.currentSnapshot.entries
        XCTAssertTrue(stillUnsent.isEmpty)

        let approved = await relaunched.approveLibraryAccountReview()
        XCTAssertTrue(approved)
        try await eventually("approval resumes") { relaunched.libraryAccountStatus == .active }
        try await eventually("approval publishes") { await server.currentSnapshot.entries.count == 1 }
        let binding = try await reopened.libraryAccountBinding()
        XCTAssertEqual(binding?.state, .bound)
        XCTAssertEqual(binding?.ownerToken, token(ownerName))
        await relaunchBoundary(relaunched)
    }

    // MARK: Quarantine and recovery

    func testSignOutQuarantinesStopsThePollerAndTheSameOwnerRecovers() async throws {
        let directory = wiltedTemporaryDirectory("account-sign-out")
        let (model, store) = try await launch(directory)
        let fixture = WiltedMacLibraryAccountFixture()
        let (_, transport) = pair()
        let controller = try start(model, fixture, transport)
        fixture.signIn(recordName: ownerName)
        try await eventually("bound") { model.libraryAccountStatus == .active }

        fixture.emit(.quarantineRequired(.signOut))
        try await eventually("quarantined") { model.libraryAccountStatus == .reviewRequired(.signOut) }
        XCTAssertFalse(controller.account?.gate.isOpen ?? true)
        XCTAssertNil(controller.inbound?.poller, "sign-out halts the poller")
        let quarantined = try await store.libraryAccountBinding()
        XCTAssertEqual(quarantined?.state, .quarantined)
        XCTAssertEqual(quarantined?.ownerToken, token(ownerName), "pending work stays bound to the original owner")

        // The transport confirms the account it adopted this session is back.
        fixture.emit(.ownershipConfirmed)
        try await eventually("same owner recovered") { model.libraryAccountStatus == .active }
        XCTAssertEqual(fixture.resets, 1, "recovery clears the transport's own quarantine")
        XCTAssertNotNil(controller.inbound?.poller)
        let recovered = try await store.libraryAccountBinding()
        XCTAssertEqual(recovered?.state, .bound)
        await relaunchBoundary(model)
    }

    func testADifferentAccountIsRetainedAsAConflictUntilApproved() async throws {
        let directory = wiltedTemporaryDirectory("account-conflict")
        let (model, store) = try await launch(directory)
        let first = WiltedMacLibraryAccountFixture()
        let (_, ownerTransport) = pair()
        try start(model, first, ownerTransport)
        first.signIn(recordName: ownerName)
        try await eventually("bound") { model.libraryAccountStatus == .active }
        try await seed(store)
        await relaunchBoundary(model)

        let (otherServer, otherTransport) = pair()
        for launchIndex in 0..<2 {
            let (relaunched, reopened) = try await launch(directory)
            let fixture = WiltedMacLibraryAccountFixture()
            let controller = try start(relaunched, fixture, otherTransport)
            fixture.signIn(recordName: otherName)
            try await eventually("conflict \(launchIndex)") { relaunched.libraryAccountStatus == .reviewRequired(.ownerMismatch) }
            await controller.tickRound()
            let binding = try await reopened.libraryAccountBinding()
            XCTAssertEqual(binding?.state, .quarantined)
            XCTAssertEqual(binding?.ownerToken, token(ownerName), "the original owner is retained across relaunch")
            XCTAssertEqual(binding?.candidateToken, token(otherName))
            let entries = await otherServer.currentSnapshot.entries
            XCTAssertTrue(entries.isEmpty, "nothing reaches the other account before approval")
            if launchIndex == 1 {
                let approved = await relaunched.approveLibraryAccountReview()
                XCTAssertTrue(approved)
                XCTAssertEqual(fixture.resets, 1)
                try await eventually("approved account receives the library") {
                    await otherServer.currentSnapshot.entries.count == 1
                }
                let rebound = try await reopened.libraryAccountBinding()
                XCTAssertEqual(rebound?.ownerToken, token(otherName))
            }
            await relaunchBoundary(relaunched)
        }
    }

    // MARK: Delayed callbacks and shutdown

    func testDelayedFetchAfterAnAccountChangeWritesNothing() async throws {
        let (model, store) = try await launch(wiltedTemporaryDirectory("account-delayed-fetch"))
        let fixture = WiltedMacLibraryAccountFixture()
        let (server, transport) = pair()
        let held = HeldCall()
        await transport.setAfterFetchHook { await held.hold() }
        let controller = try start(model, fixture, transport)
        fixture.signIn(recordName: ownerName)
        await held.waitUntilHeld()
        try await seed(store)

        fixture.emit(.quarantineRequired(.switchAccounts))
        try await eventually("quarantined") { model.libraryAccountStatus == .reviewRequired(.switchAccounts) }
        await held.release()
        await controller.tickRound()  // Joins the held pass.
        let committed = await transport.committedFetchToken
        XCTAssertNil(committed, "a fetch that returns after the change commits nothing")
        let entries = await server.currentSnapshot.entries
        XCTAssertTrue(entries.isEmpty, "and its pass sends nothing")
        XCTAssertNil(controller.lastReport)
        await relaunchBoundary(model)
    }

    func testDelayedSendAfterAnAccountChangeCommitsNothingAndLaterSendsNeverLeave() async throws {
        let (model, store) = try await launch(wiltedTemporaryDirectory("account-delayed-send"))
        let fixture = WiltedMacLibraryAccountFixture()
        let (server, transport) = pair()
        let controller = try start(model, fixture, transport)
        fixture.signIn(recordName: ownerName)
        try await eventually("bound") { model.libraryAccountStatus == .active }
        await controller.tickRound()
        let held = HeldCall()
        await transport.setAfterPushHook { await held.hold() }
        try await seed(store)
        controller.requestPublish()
        await held.waitUntilHeld()

        fixture.emit(.quarantineRequired(.signOut))
        try await eventually("quarantined") { model.libraryAccountStatus == .reviewRequired(.signOut) }
        await held.release()
        await controller.tickRound()
        let committed = await transport.committedSentToken
        XCTAssertNil(committed, "a send acknowledged after the change commits nothing locally")
        XCTAssertEqual(controller.lastReport?.acknowledged ?? 0, 0, "and its acknowledgement is discarded")

        let before = await server.currentSnapshot.entries.count
        do {
            _ = try await controller.publisher.sync()
            XCTFail("a send started after the change must not reach the transport")
        } catch {
            XCTAssertEqual(error as? WiltedMacLibraryAccountError, .notApproved)
        }
        let after = await server.currentSnapshot.entries.count
        XCTAssertEqual(after, before)
        await relaunchBoundary(model)
    }

    func testStopDuringAnInFlightCallCommitsNothingAndLaterSignalsPersistNothing() async throws {
        let (model, store) = try await launch(wiltedTemporaryDirectory("account-shutdown"))
        let fixture = WiltedMacLibraryAccountFixture()
        let (_, transport) = pair()
        let held = HeldCall()
        await transport.setAfterFetchHook { await held.hold() }
        let controller = try start(model, fixture, transport)
        fixture.signIn(recordName: ownerName)
        await held.waitUntilHeld()
        let account = try XCTUnwrap(controller.account)

        model.stopLibrarySync()
        XCTAssertFalse(account.gate.isOpen, "stop closes the gate synchronously")
        fixture.emit(.quarantineRequired(.signOut))
        await held.release()
        await model.waitForLibrarySyncShutdown()
        let committed = await transport.committedFetchToken
        XCTAssertNil(committed, "an in-flight fetch finishing after stop commits nothing")
        let binding = try await store.libraryAccountBinding()
        XCTAssertEqual(binding?.state, .bound, "a signal after stop persists nothing")
        XCTAssertNil(model.libraryAccountStatus)
        let approved = await account.approve()
        XCTAssertFalse(approved, "a stopped binding cannot be approved")
    }

    // MARK: Privacy and unmanaged transports

    func testAccountLogsAndStatusCarryNoRawIdentifierOrToken() async throws {
        let (model, store) = try await launch(wiltedTemporaryDirectory("account-logs"))
        try await seed(store)
        let fixture = WiltedMacLibraryAccountFixture()
        let (_, transport) = pair()
        let controller = try start(model, fixture, transport)
        fixture.signIn(recordName: ownerName)
        try await eventually("review") { model.libraryAccountStatus == .reviewRequired(.unboundLibrary) }
        _ = await model.approveLibraryAccountReview()
        fixture.emit(.ownershipAdopted(token: otherName))  // An identity the adapter failed to hash.
        try await eventually("ambiguous identity quarantined") {
            model.libraryAccountStatus == .reviewRequired(.ownerMismatch)
        }
        fixture.emit(.quarantineRequired(.switchAccounts))
        try await eventually("switch") { model.libraryAccountStatus == .reviewRequired(.switchAccounts) }
        await controller.tickRound()

        let texts = fixture.loggedLines + [
            String(describing: model.libraryAccountStatus), controller.lastFailure ?? "",
            String(describing: WiltedMacLibraryAccountError.notApproved),
        ]
        XCTAssertFalse(fixture.loggedLines.isEmpty)
        for text in texts {
            for secret in [ownerName, otherName, token(ownerName), token(otherName), "sha256:"] {
                XCTAssertFalse(text.contains(secret), "account output must not carry identifiers: \(text)")
            }
        }
        await relaunchBoundary(model)
    }

    // MARK: Startup account check (Task 5.1)

    @discardableResult
    private func startProbed(
        _ model: WiltedMacModel, _ fixture: WiltedMacLibraryAccountFixture
    ) throws -> WiltedMacLibrarySyncController {
        let (_, transport) = pair()
        return try start(model, fixture, transport)
    }

    func testWithNoSignalTheCheckResolvesTheBoundOwnerAfterRelaunch() async throws {
        let directory = wiltedTemporaryDirectory("account-probe-owner")
        let (model, _) = try await launch(directory)
        let first = WiltedMacLibraryAccountFixture()
        try startProbed(model, first)
        first.signIn(recordName: ownerName)
        try await eventually("bound") { model.libraryAccountStatus == .active }
        await relaunchBoundary(model)

        // A relaunched engine rebuilt from saved state reports no sign-in at all.
        let (relaunched, _) = try await launch(directory)
        let silent = WiltedMacLibraryAccountFixture()
        silent.answerProbe(.signedIn(token: token(ownerName)))
        let controller = try startProbed(relaunched, silent)
        XCTAssertEqual(relaunched.libraryAccountStatus, .awaitingAccount)
        try await eventually("the check reopens for the same owner") { relaunched.libraryAccountStatus == .active }
        XCTAssertEqual(silent.probes, 1)
        XCTAssertEqual(silent.resets, 0, "the same owner needs no review and no transport reset")
        XCTAssertNotNil(controller.inbound?.poller)
        await relaunchBoundary(relaunched)
    }

    func testACheckThatFindsNoAccountKeepsSendingClosedWithAClearStatus() async throws {
        let (model, store) = try await launch(wiltedTemporaryDirectory("account-probe-none"))
        let fixture = WiltedMacLibraryAccountFixture()
        fixture.answerProbe(.noAccount)
        let controller = try startProbed(model, fixture)
        try await eventually("no account reported") { model.libraryAccountStatus == .noAccount }
        XCTAssertFalse(controller.account?.gate.isOpen ?? true)
        XCTAssertNil(controller.inbound?.poller)
        let binding = try await store.libraryAccountBinding()
        XCTAssertNil(binding, "no account binds nothing")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.probes, 1, "a definite answer is not re-checked")
        XCTAssertEqual(model.libraryAccountStatus.map(String.init(describing:)), "no iCloud account")

        // A later sign-in still binds the first owner of the empty library.
        fixture.signIn(recordName: ownerName)
        try await eventually("bound after sign-in") { model.libraryAccountStatus == .active }
        await relaunchBoundary(model)
    }

    func testAnUnavailableCheckRetriesThenReportsTheAccountUnavailable() async throws {
        let (model, _) = try await launch(wiltedTemporaryDirectory("account-probe-unavailable"))
        let fixture = WiltedMacLibraryAccountFixture()
        fixture.answerProbe(.unavailable)
        let controller = try startProbed(model, fixture)
        try await eventually("retries exhausted") { fixture.probes == 3 }
        try await eventually("unavailable reported") { model.libraryAccountStatus == .accountUnavailable }
        XCTAssertFalse(controller.account?.gate.isOpen ?? true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.probes, 3, "the check is bounded")
        await relaunchBoundary(model)
    }

    func testASignalThatArrivesFirstWinsOverTheCheck() async throws {
        let (model, _) = try await launch(wiltedTemporaryDirectory("account-probe-signal-first"))
        let fixture = WiltedMacLibraryAccountFixture()
        fixture.probeDelay = .milliseconds(300)
        fixture.answerProbe(.noAccount)
        try startProbed(model, fixture)
        fixture.signIn(recordName: ownerName)
        try await eventually("bound by the signal") { model.libraryAccountStatus == .active }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(fixture.probes, 0, "no check runs once a signal named the account")
        XCTAssertEqual(model.libraryAccountStatus, .active)
        await relaunchBoundary(model)
    }

    func testATransportWithoutAccountSignalsIsUnmanaged() async throws {
        let (model, _) = try await launch(wiltedTemporaryDirectory("account-unmanaged"))
        let (_, transport) = pair()
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: flagOn, transport: transport))
        XCTAssertEqual(model.libraryAccountStatus, .unmanaged)
        XCTAssertNil(model.libraryAccount)
        XCTAssertNotNil(model.librarySyncController?.inbound?.poller)
        let approved = await model.approveLibraryAccountReview()
        XCTAssertFalse(approved)
        await relaunchBoundary(model)
    }
}
