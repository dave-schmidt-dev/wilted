import Foundation
import SwiftUI
import UIKit
import Vision
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

private actor RefreshPollTransport: LibraryTransport {
    let base: any LibraryTransport
    var failure = true
    private var generationDelta: UInt64 = 0
    private var heldPoll: CheckedContinuation<Void, Never>?
    private var pause = false
    private var pollArrived = false
    private var heldRecords: LibraryDeviceRecords?
    func pauseNextPoll(records: LibraryDeviceRecords) { pause = true; failure = false; heldRecords = records }
    func waitForPoll() async { while !pollArrived { await Task.yield() } }
    func invalidateAndRelease() { generationDelta &+= 1; heldPoll?.resume(); heldPoll = nil }
    init(_ base: any LibraryTransport) { self.base = base }
    func allowPoll() { failure = false }
    func operationGeneration() async -> UInt64 { await base.operationGeneration() + generationDelta }
    func verifiedOwnerToken() async -> String? { await base.verifiedOwnerToken() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await base.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await base.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await base.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await base.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await base.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await base.fetchDeviceRecords() }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await base.mediaOffers() }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await base.commitFetchedState(token) }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        if failure { throw LibraryTransportError.transport("required poll failed") }
        var result = try await base.poll(options)
        if pause {
            await withCheckedContinuation { heldPoll = $0; pollArrived = true }
            result.records = heldRecords
        }
        return result
    }
}

@MainActor
final class LibraryRefreshStatusTests: XCTestCase {
    override func setUp() async throws { await HostedAccessibility.prepare() }
    private func makeModel() -> (LibraryAppModel, RefreshPollTransport) {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = RefreshPollTransport(InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "owner"))
        let name = "refresh-status-\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        addTeardownBlock { preferences.removePersistentDomain(forName: name) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-state-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (LibraryAppModel(transport: transport, store: FileLibraryStore(url: url), deviceID: "phone", preferences: preferences), transport)
    }
    func testRequiredPollFailureIsVisibleAfterSuccessfulStateFetch() async {
        let (model, _) = makeModel()
        await model.refresh()
        XCTAssertTrue(model.errorMessage?.contains("required poll failed") == true)
        XCTAssertNil(model.lastSynchronizedAt, "A partial round is not a successful required phone read")
    }
    func testSuccessfulRoundClearsPreviousRequiredPollFailure() async {
        let (model, transport) = makeModel()
        await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        await transport.allowPoll()
        await model.refresh()
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.lastSynchronizedAt)
    }
    func testStartupNeverSilentlyOmitsAuthorAgeStatus() async {
        let (model, _) = makeModel()
        await model.loadLocalState()
        XCTAssertNotNil(model.syncBanner, "Unknown publication age must remain explicit at startup")
    }
    private func savedModel(failFetch: Bool = false, replacement: Bool = false) async throws -> (LibraryAppModel, RefreshPollTransport, [ItemID], URL) {
        let entryID = try ItemID(rawValue: "saved")
        let entry = try LibraryEntry(id: entryID, kind: .podcastEpisode, sourceID: ItemID(rawValue: "show"), title: "Saved episode", summary: "", publishedAt: Date(timeIntervalSince1970: 1000))
        let publication = try LibraryPublication(id: "author", publishedAt: Date(timeIntervalSince1970: 2000), writerDeviceID: "mac")
        let batch = LibraryChangeBatch(generationID: "saved", changes: [
            .init(version: 1, change: .entry(entry)), .init(version: 1, change: .slot(try QueueSlot(entryID: entryID, sortKey: 0)))], token: .init(rawValue: "saved-cursor"), provenance: .init(ownerToken: "owner", operationGeneration: 0, isFullBootstrap: true), observedPublication: publication)
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(entryID: entryID, revisionID: RevisionID(rawValue: "revision"), contentHash: PreparedMediaFixture.hash(Data(repeating: 7, count: 10)), byteCount: 10, mediaType: "audio/mpeg", state: .available))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-saved-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let preferences = UserDefaults(suiteName: "refresh-saved-\(UUID())")!
        let store = FileLibraryStore(url: url)
        let seed = LibraryAppModel(transport: OwnerCacheTransport(batch: batch, offers: [offer]), store: store, deviceID: "phone", preferences: preferences)
        await seed.refresh()
        XCTAssertEqual(seed.visibleRows.map(\.id), [entryID])
        let replacementID = try ItemID(rawValue: "replacement")
        let replacementEntry = try LibraryEntry(id: replacementID, kind: .podcastEpisode, sourceID: ItemID(rawValue: "show"), title: "New authoritative episode", summary: "", publishedAt: Date(timeIntervalSince1970: 3000))
        let next = replacement ? LibraryChangeBatch(generationID: "new-body", changes: [
            .init(version: 2, change: .entry(replacementEntry)), .init(version: 2, change: .slot(try QueueSlot(entryID: replacementID, sortKey: 0)))], token: .init(rawValue: "new-cursor"), provenance: .init(ownerToken: "owner", operationGeneration: 0, isFullBootstrap: true), observedPublication: publication) : batch
        let nextOffer = replacement ? try PreparedMediaFixture.certified(LibraryMediaOffer(entryID: replacementID, revisionID: RevisionID(rawValue: "new-revision"), contentHash: PreparedMediaFixture.hash(Data(repeating: 7, count: 10)), byteCount: 10, mediaType: "audio/mpeg", state: .available)) : offer
        let transport = RefreshPollTransport(OwnerCacheTransport(batch: next, failFetch: failFetch, offers: [nextOffer]))
        let model = LibraryAppModel(transport: transport, store: FileLibraryStore(url: url), deviceID: "phone", preferences: preferences)
        await model.loadLocalState()
        return (model, transport, [entryID], url)
    }
    func testFailedRequiredPollRetainsActualSavedUndownloadedRowsAndAuthorDate() async throws {
        let (model, _, ids, _) = try await savedModel()
        let author = model.lastObservedPublication
        await model.refresh()
        XCTAssertEqual(model.visibleRows.map(\.id), ids)
        XCTAssertEqual(model.lastObservedPublication, author)
        XCTAssertTrue(model.preparedIDs.onPhone.isEmpty)
        XCTAssertTrue(model.errorMessage?.contains("required poll failed") == true)
        XCTAssertNil(model.lastSynchronizedAt)
    }
    func testOfferOnlyFailureRemainsVisibleWithSavedRowsAndClearsAfterWholeSuccess() async throws {
        let (model, transport, ids, _) = try await savedModel()
        await model.refresh(.init(readsState: false, readsOffers: true, showsProgress: false))
        XCTAssertEqual(model.visibleRows.map(\.id), ids)
        XCTAssertNotNil(model.errorMessage)
        await transport.allowPoll()
        await model.refresh()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.visibleRows.map(\.id), ids)
    }
    func testChangedAuthorBodyThenPollFailureKeepsStaleDisplayWithoutPlaybackAuthority() async throws {
        let (model, _, ids, _) = try await savedModel(replacement: true)
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id), [try ItemID(rawValue: "replacement")])
        XCTAssertEqual(model.visibleRows.map(\.id), ids, "Failed required round must retain last completed display")
        XCTAssertFalse(model.playOrderRows.contains { ids.contains($0.id) })
    }
    func testRelaunchAfterChangedAuthorBodyAndPollFailureKeepsSavedDisplay() async throws {
        let (model, transport, ids, url) = try await savedModel(replacement: true)
        await model.refresh()
        let cold = LibraryAppModel(transport: transport, store: FileLibraryStore(url: url), deviceID: "phone",
            preferences: UserDefaults(suiteName: "refresh-reopen-\(UUID())")!)
        await cold.loadLocalState()
        XCTAssertEqual(cold.queued.map(\.id), [try ItemID(rawValue: "replacement")])
        XCTAssertEqual(cold.visibleRows.map(\.id), ids, "Completed saved display must survive process relaunch")
        XCTAssertFalse(cold.playOrderRows.contains { ids.contains($0.id) })
    }
    func testSuccessfulWholeRoundPromotesNewDisplayAndColdReopen() async throws {
        let (model, transport, oldIDs, url) = try await savedModel(replacement: true)
        await model.refresh(); XCTAssertEqual(model.visibleRows.map(\.id), oldIDs)
        await transport.allowPoll(); await model.refresh()
        let newID = try ItemID(rawValue: "replacement")
        XCTAssertEqual(model.visibleRows.map(\.id), [newID])
        let state = await FileLibraryStore(url: url).state(); XCTAssertFalse(state.displayRefreshPending)
        let cold = LibraryAppModel(transport: transport, store: FileLibraryStore(url: url), deviceID: "phone", preferences: UserDefaults(suiteName: "refresh-success-\(UUID())")!)
        await cold.loadLocalState(); XCTAssertEqual(cold.visibleRows.map(\.id), [newID])
    }
    func testOfferOnlySuccessDoesNotCreatePendingWholeRound() async throws {
        let (model, transport, ids, url) = try await savedModel()
        await transport.allowPoll(); await model.refresh()
        await model.refresh(.init(readsState: false, readsOffers: true, showsProgress: false))
        let state = await FileLibraryStore(url: url).state()
        XCTAssertFalse(state.displayRefreshPending)
        XCTAssertEqual(model.visibleRows.map(\.id), ids)
    }
    func testOfferOnlySuccessCannotPromoteAfterFailedStateRound() async throws {
        let (model, transport, ids, url) = try await savedModel(replacement: true)
        await model.refresh(); await transport.allowPoll()
        await model.refresh(.init(readsState: false, readsOffers: true, showsProgress: false))
        let state = await FileLibraryStore(url: url).state()
        XCTAssertTrue(state.displayRefreshPending)
        XCTAssertEqual(model.visibleRows.map(\.id), ids)
        XCTAssertNotNil(model.errorMessage)
    }
    func testCompletedDisplayWriteFailureKeepsPriorDisplayAndCurrentAuthorBody() async throws {
        let (_, transport, ids, url) = try await savedModel(replacement: true)
        let store = FileLibraryStore(url: url, writeData: { data, path in
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let entries = object?["entries"] as? [[String: Any]]
            if object?["displayRefreshPending"] as? Bool == false, entries?.contains(where: { String(describing: $0["id"] ?? "").contains("replacement") }) == true {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: path, options: .atomic)
        })
        let model = LibraryAppModel(transport: transport, store: store, deviceID: "phone", preferences: UserDefaults(suiteName: "refresh-writefail-\(UUID())")!)
        await model.loadLocalState(); await transport.allowPoll(); await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.visibleRows.map(\.id), ids)
        XCTAssertEqual(model.queued.map(\.id), [try ItemID(rawValue: "replacement")])
        let cold = LibraryAppModel(transport: transport, store: FileLibraryStore(url: url), deviceID: "phone", preferences: UserDefaults(suiteName: "refresh-writefail-cold-\(UUID())")!)
        await cold.loadLocalState(); XCTAssertEqual(cold.visibleRows.map(\.id), ids)
        XCTAssertFalse(cold.playOrderRows.contains { ids.contains($0.id) })
    }
    func testLatePollFromOldGenerationCannotReplaceCheckpointsOrSavedRows() async throws {
        let (model, transport, ids, _) = try await savedModel()
        let record = try DevicePlaybackPosition(deviceID: "prior-owner-mac", entryID: ids[0], revision: RevisionID(rawValue: "revision"), positionSeconds: 20, isPlaying: false, epoch: 1)
        await transport.pauseNextPoll(records: LibraryDeviceRecords(progress: [ObservedPlayback(record: record, serverModifiedAt: Date(timeIntervalSince1970: 5000))]))
        let refresh = Task { await model.refresh() }
        await transport.waitForPoll(); await transport.invalidateAndRelease(); await refresh.value
        XCTAssertTrue(model.checkpoints.isEmpty)
        XCTAssertNil(model.lastSynchronizedAt)
        XCTAssertEqual(model.visibleRows.map(\.id), ids)
    }
    func testDamagedOptionalCompletedDisplayCannotEraseValidAuthoritativeBody() async throws {
        let (model, _, _, url) = try await savedModel(replacement: true)
        await model.refresh()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["completedDisplay"] = ["entries": "damaged"]
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        let state = await FileLibraryStore(url: url).state()
        XCTAssertEqual(state.content.queue.map(\.entryID), [try ItemID(rawValue: "replacement")])
        XCTAssertNil(state.completedDisplay)
        XCTAssertEqual(state.ownerToken, "owner")
    }
    func testNativeReviewWaitsForConfirmationAndKeepHeldDoesNothing() async throws {
        var recoveries = 0
        let host = HostedView(WiltedAccountRecoveryNotice(role: .phone) { recoveries += 1 })
        let review = try XCTUnwrap(host.element(WiltedScreenCopy.useCurrentAccountIdentifier))
        XCTAssertTrue(review.activate())
        try await Task.sleep(for: .milliseconds(250)); host.settle()
        XCTAssertEqual(recoveries, 0, "Opening review must not reset owner, delete cache or fetch")
        let keep = try XCTUnwrap(host.elements().first { $0.identifier == "wilted-account-keep-held" || $0.label == "Keep held" })
        try activateNativeAlertControl(keep, in: host.window)
        try await Task.sleep(for: .milliseconds(100)); host.settle()
        XCTAssertEqual(recoveries, 0)
    }
    func testNativePhoneAndMacApprovalEachInvokesOnlyConfirmedAction() async throws {
        for role in [WiltedAccountRecoveryNotice.Role.phone, .mac] {
            var approvals = 0
            let host = HostedView(WiltedAccountRecoveryNotice(role: role) { approvals += 1 })
            XCTAssertTrue(try XCTUnwrap(host.element(WiltedScreenCopy.useCurrentAccountIdentifier)).activate())
            try await Task.sleep(for: .milliseconds(250)); host.settle()
            XCTAssertEqual(approvals, 0)
            let title = role == .phone ? "Replace saved library" : "Send this library"
            let confirm = try XCTUnwrap(host.elements().first { $0.identifier == "wilted-account-confirm" || $0.label == title })
            try activateNativeAlertControl(confirm, in: host.window)
            try await Task.sleep(for: .milliseconds(100)); host.settle()
            XCTAssertEqual(approvals, 1)
        }
    }
    func testActualSavedPhoneStatusAndRowsRenderAt390InLightAndDark() async throws {
        for context in ["cold", "unknown", "failed", "held"] {
            var (model, transport, ids, url) = try await savedModel()
            if context == "unknown" { model = makeModel().0; await model.loadLocalState(); ids = [] }
            if context == "failed" { await model.refresh() }
            if context == "held" {
                let heldStore = FileLibraryStore(url: url); try await heldStore.quarantine()
                model = LibraryAppModel(transport: transport, store: heldStore, deviceID: "phone", preferences: UserDefaults(suiteName: "refresh-held-render-\(UUID())")!)
                await model.loadLocalState()
            }
            for scheme in [ColorScheme.light, .dark] {
                let host = HostedView(NavigationStack { LibraryListView(model: model, playingID: nil) }, dark: scheme == .dark)
                try await Task.sleep(for: .milliseconds(250)); host.settle()
                let image = UIGraphicsImageRenderer(size: host.window.bounds.size).image { context in
                    host.window.layer.render(in: context.cgContext)
                }
                let attachment = XCTAttachment(image: image); attachment.name = "publication-phone-\(context)-\(scheme == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways; add(attachment)
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
                XCTAssertTrue(text.contains(context == "unknown" ? "mac publication unknown" : "saved mac last published"), text)
                if context == "cold" { XCTAssertTrue(text.contains("unverified"), text) }
                if context == "failed" { XCTAssertTrue(text.contains("refresh failed"), text) }
                if context == "held" { XCTAssertTrue(text.contains("account review required"), text) }
                XCTAssertEqual(model.visibleRows.map(\.id), ids)
            }
        }
    }
    /// UIKit alert accessibility elements do not implement accessibilityActivate on this simulator.
    /// Dispatch only through a public UIControl backing the actual native button, without HID.
    private func activateNativeAlertControl(_ element: HostedElement, in window: UIWindow) throws {
        if element.activate() { return }
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        var view = window.hitTest(window.convert(center, from: nil), with: nil)
        while let candidate = view {
            if let control = candidate as? UIControl {
                control.sendActions(for: .touchUpInside); return
            }
            view = candidate.superview
        }
        throw XCTSkip("Native UIAlert action has no public headless UIControl activation seam; existing accessibilityActivate returned false")
    }
    func testRecoveryStoreSwapRejectsLateStartingDisplayAndReviewHold() async throws {
        let (_, transport, ids, url) = try await savedModel(failFetch: true)
        let old = StartingMetadataReadStore(base: FileLibraryStore(url: url))
        let nextURL = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-next-\(UUID()).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: nextURL) }
        let next = FileLibraryStore(url: nextURL)
        let recovery = LibraryAccountRecovery(quarantineEvents: AsyncStream { $0.finish() }) { next }
        let model = LibraryAppModel(transport: transport, store: old, deviceID: "phone", recovery: recovery,
                                   preferences: UserDefaults(suiteName: "refresh-swap-\(UUID())")!)
        await model.loadLocalState(); XCTAssertEqual(model.visibleRows.map(\.id), ids)
        let refresh = Task { await model.refresh() }
        await old.waitForRead()
        let recover = Task { await model.recoverFromAccountChange() }
        while !model.visibleRows.isEmpty { await Task.yield() }
        XCTAssertFalse(model.accountQuarantined)
        await old.release(); await refresh.value; await recover.value
        XCTAssertTrue(model.visibleRows.isEmpty, "Old completed rows returned after the actual recovery store swap")
        XCTAssertFalse(model.accountQuarantined, "The old store's held read restored account quarantine")
        let fresh = await next.state()
        XCTAssertTrue(fresh.content.entries.isEmpty); XCTAssertFalse(fresh.reviewHold)
        XCTAssertNil(fresh.completedDisplay)
    }
    func testPhoneReviewExplainsReplacementAndUnavailableName() {
        let text = WiltedScreenCopy.useCurrentAccountDetail.lowercased()
        XCTAssertTrue(text.contains("replace"), text)
        XCTAssertTrue(text.contains("name unavailable"), text)
        XCTAssertTrue(text.contains("download"), text)
    }
}

/// Fault injection on an actual FileLibraryStore actor read, after the caller's first guard.
private actor StartingMetadataReadStore: LibraryStore {
    let base: FileLibraryStore
    private var armed = false
    private var reads = 0
    private var held = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(base: FileLibraryStore) { self.base = base }
    func waitForRead() async { while !held { await Task.yield() } }
    func release() { waiter?.resume(); waiter = nil }
    func state() async -> LibraryStoreState {
        if armed {
            reads += 1
            if reads == 2 {
                try? await base.quarantine()
                let captured = await base.state()
                held = true
                await withCheckedContinuation { waiter = $0 }
                return captured
            }
        }
        return await base.state()
    }
    func fetchCursor() async -> LibraryChangeToken? { await base.fetchCursor() }
    func beginDisplayRefresh(transport: any LibraryTransport, expectedGeneration: UInt64) async throws {
        try await base.beginDisplayRefresh(transport: transport, expectedGeneration: expectedGeneration)
        armed = true; reads = 0
    }
    func completeDisplayRefresh(transport: any LibraryTransport, expectedGeneration: UInt64, expectedRevision: UInt64) async throws {
        try await base.completeDisplayRefresh(transport: transport, expectedGeneration: expectedGeneration, expectedRevision: expectedRevision)
    }
    func commit(_ staged: StagedLibraryBatch) async throws { try await base.commit(staged) }
    func commit(_ staged: StagedLibraryBatch, transport: any LibraryTransport, expectedGeneration: UInt64) async throws {
        try await base.commit(staged, transport: transport, expectedGeneration: expectedGeneration)
    }
    func enqueue(_ change: LibraryChange) async throws { try await base.enqueue(change) }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) async throws { try await base.acknowledge(result, sent: sent) }
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) async throws { try await base.resolveConflict(key, keepLocal: keepLocal) }
}
