import CloudKit
import Foundation
import Testing
@testable import WiltedCloudKit

private actor SaveGate {
    private(set) var calls = 0
    var released = false

    func save() async throws {
        calls += 1
        while !released { await Task.yield() }
    }

    func release() { released = true }

    func waitForCalls(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(5)
        while clock.now < end {
            if calls >= expected { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return calls >= expected
    }
}

private actor LiveRecordFetchProbe {
    private let firstRecord: CKRecord
    private let secondRecord: CKRecord
    private let firstReleaseStream: AsyncStream<Void>
    private let firstRelease: AsyncStream<Void>.Continuation
    private(set) var calls = 0
    private(set) var cancellationCount = 0

    init(firstRecord: CKRecord, secondRecord: CKRecord) {
        self.firstRecord = firstRecord
        self.secondRecord = secondRecord
        (firstReleaseStream, firstRelease) = AsyncStream<Void>.makeStream()
    }

    func fetch(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        calls += 1
        let call = calls
        if call == 1 {
            await withTaskCancellationHandler {
                for await _ in firstReleaseStream { break }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        let requested = Set(ids)
        let available = call == 1 ? [firstRecord] : [secondRecord]
        return available.filter { requested.contains($0.recordID) }
    }

    func waitForFirstFetch() async -> Bool { await until { calls >= 1 } }
    func waitForCancellation() async -> Bool { await until { cancellationCount >= 1 } }
    func releaseFirstFetch() { firstRelease.yield(()) }
    private func recordCancellation() { cancellationCount += 1 }

    private func until(_ satisfied: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(5)
        while clock.now < end {
            if satisfied() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return satisfied()
    }
}

@Test("live explicit record fetch cancellation reaches the active task and rejects late records")
func liveExplicitRecordFetchCancellationRejectsLateRecords() async throws {
    let zoneID = CKRecordZone.ID(zoneName: "WiltedZone", ownerName: CKCurrentUserDefaultName)
    let firstID = CKRecord.ID(recordName: "item:cancelled-fetch", zoneID: zoneID)
    let secondID = CKRecord.ID(recordName: "item:later-fetch", zoneID: zoneID)
    let firstRecord = CKRecord(recordType: "Item", recordID: firstID)
    let secondRecord = CKRecord(recordType: "Item", recordID: secondID)
    let probe = LiveRecordFetchProbe(firstRecord: firstRecord, secondRecord: secondRecord)
    let coordinator = CloudKitRecordFetchCoordinator(recordFetcher: { ids in try await probe.fetch(ids) })

    let firstFetch = Task { try await coordinator.fetch([firstID]) }
    guard await probe.waitForFirstFetch() else {
        firstFetch.cancel()
        Issue.record("live explicit record fetch did not start")
        return
    }

    await coordinator.cancelAll()
    #expect(await probe.waitForCancellation())
    await probe.releaseFirstFetch()
    do {
        let records = try await firstFetch.value
        Issue.record("cancelled live fetch delivered \(records.count) late record(s)")
    } catch {
        #expect(error is CancellationError)
    }

    let laterRecords = try await coordinator.fetch([secondID])
    #expect(laterRecords.map(\.recordID) == [secondID])
    #expect(await probe.cancellationCount == 1)
}

@Test("zone bootstrap cancellation cannot publish a stale save generation")
func zoneBootstrapCancellationGeneration() async throws {
    let gate = SaveGate()
    let state = CloudKitZoneBootstrapState { try await gate.save() }
    let first = Task { try await state.ensureZone() }
    #expect(await gate.waitForCalls(1))

    await state.cancel()
    await gate.release()
    try await first.value

    try await state.ensureZone()
    #expect(await gate.calls == 2)
    await state.cancel()
    try await state.ensureZone()
    #expect(await gate.calls == 2)

    await state.invalidate()
    try await state.ensureZone()
    #expect(await gate.calls == 3)
}

@Test("account ownership tokens are derived, stable, and not the account identifier")
func accountOwnershipTokens() {
    let token = CloudKitAccountIdentity.token(for: "_abc123")
    #expect(token == CloudKitAccountIdentity.token(for: "_abc123"))
    #expect(token != CloudKitAccountIdentity.token(for: "_abc124"))
    #expect(token.hasPrefix("sha256:"))
    #expect(!token.contains("abc123"))
}

@Test("a first sign-in with no recorded owner adopts the current owner token")
func firstSignInAdoptsOwnership() {
    let token = CloudKitAccountIdentity.token(for: "_owner-one")
    let identity = CloudKitAccountIdentity(currentOwnerToken: token, hadPreviousOwner: false)
    let resolution = CloudKitAccountOwnership.resolve(
        changeType: .signIn,
        identity: identity,
        recordedOwnerToken: nil
    )
    #expect(resolution == .adopt(token: token))
}

@Test("the recorded owner signing in again is confirmed without quarantine")
func recordedOwnerSignInResumes() {
    let token = CloudKitAccountIdentity.token(for: "_owner-one")
    let identity = CloudKitAccountIdentity(currentOwnerToken: token, hadPreviousOwner: false)
    let resolution = CloudKitAccountOwnership.resolve(
        changeType: .signIn,
        identity: identity,
        recordedOwnerToken: token
    )
    #expect(resolution == .confirmed)
}

@Test("a different account signing in requires quarantine")
func differentAccountSignInQuarantines() {
    let recordedToken = CloudKitAccountIdentity.token(for: "_owner-one")
    let currentToken = CloudKitAccountIdentity.token(for: "_owner-two")
    let identity = CloudKitAccountIdentity(currentOwnerToken: currentToken, hadPreviousOwner: false)
    let resolution = CloudKitAccountOwnership.resolve(
        changeType: .signIn,
        identity: identity,
        recordedOwnerToken: recordedToken
    )
    #expect(resolution == .quarantine)
}

@Test("an account switch requires quarantine even when the token matches the recorded owner")
func accountSwitchAlwaysQuarantines() {
    // No previous owner and a matching token: only the change type can quarantine this.
    let token = CloudKitAccountIdentity.token(for: "_owner-one")
    let identity = CloudKitAccountIdentity(currentOwnerToken: token, hadPreviousOwner: false)
    let resolution = CloudKitAccountOwnership.resolve(
        changeType: .switchAccounts,
        identity: identity,
        recordedOwnerToken: token
    )
    #expect(resolution == .quarantine)
}

@Test("a sign-out requires quarantine")
func signOutRequiresQuarantine() {
    let token = CloudKitAccountIdentity.token(for: "_owner-one")
    let identity = CloudKitAccountIdentity(currentOwnerToken: nil, hadPreviousOwner: true)
    let resolution = CloudKitAccountOwnership.resolve(
        changeType: .signOut,
        identity: identity,
        recordedOwnerToken: token
    )
    #expect(resolution == .quarantine)
}

@Test("a sign-in with a missing owner token requires quarantine")
func signInWithMissingTokenQuarantines() {
    let identity = CloudKitAccountIdentity(currentOwnerToken: nil, hadPreviousOwner: false)
    let resolution = CloudKitAccountOwnership.resolve(
        changeType: .signIn,
        identity: identity,
        recordedOwnerToken: nil
    )
    #expect(resolution == .quarantine)
}

@Test("a sign-in reporting a previous owner requires quarantine")
func signInWithPreviousOwnerQuarantines() {
    let token = CloudKitAccountIdentity.token(for: "_owner-one")
    let identity = CloudKitAccountIdentity(currentOwnerToken: token, hadPreviousOwner: true)
    let resolution = CloudKitAccountOwnership.resolve(
        changeType: .signIn,
        identity: identity,
        recordedOwnerToken: token
    )
    #expect(resolution == .quarantine)
}
