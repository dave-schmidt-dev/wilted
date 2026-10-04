import Foundation
import Observation
import OSLog
import WiltedCloudKit
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer

private let libraryAccountLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacLibraryAccount")

// MARK: - Status

/// Whether the library publisher may reach the server for the current iCloud account.
///
/// Carries no account identifier, so any surface may show or log it.
enum WiltedMacLibraryAccountStatus: Equatable, Sendable, CustomStringConvertible {
    /// The transport reports no account changes (a test or no-network fixture), so it is
    /// not account-bound. A live CloudKit transport is never unmanaged.
    case unmanaged
    /// Waiting for this launch's account signal before anything is sent.
    case awaitingAccount
    /// The bound owner is signed in; publishing and polling run.
    case active
    /// Sending is held until the owner approves (`approveLibraryAccountReview`).
    case reviewRequired(LocalLibraryAccountBinding.Reason)
    /// Approved after a change that named no account; the next account seen becomes the owner.
    case approvedAwaitingAccount
    /// The binding could not be read or written; nothing is sent.
    case failed

    var allowsSync: Bool { self == .unmanaged || self == .active }
    var needsReview: Bool { if case .reviewRequired = self { true } else { false } }

    var description: String {
        switch self {
        case .unmanaged: "unmanaged"
        case .awaitingAccount: "awaiting account"
        case .active: "active"
        case let .reviewRequired(reason): "review required (\(reason.rawValue))"
        case .approvedAwaitingAccount: "approved, awaiting account"
        case .failed: "failed"
        }
    }
}

/// Why a library server call was refused. Carries no account identifier.
enum WiltedMacLibraryAccountError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The account is not approved for sending, so the call never reached the transport.
    case notApproved

    var description: String { "library sync is paused until the iCloud account is confirmed" }
}

// MARK: - Gate

/// The open/closed state every library server call checks, plus the generation that
/// invalidates work admitted before a close. Closing bumps the generation; reopening does not,
/// so a call admitted before a close can never complete after a reopen either.
final class WiltedMacLibraryAccountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool
    private var generationValue: UInt64 = 0

    init(open: Bool) { self.open = open }

    var isOpen: Bool { lock.withLock { open } }
    var generation: UInt64 { lock.withLock { generationValue } }

    /// Admits one call, returning the generation it must still hold when it finishes.
    func admit() throws -> UInt64 {
        try lock.withLock {
            guard open else { throw WiltedMacLibraryAccountError.notApproved }
            return generationValue
        }
    }

    /// Throws `superseded` when the gate closed (or closed and reopened) since `generation`.
    func verify(_ generation: UInt64) throws {
        try lock.withLock {
            guard open, generationValue == generation else { throw LibraryTransportError.superseded }
        }
    }

    func close() { lock.withLock { open = false; generationValue &+= 1 } }
    func reopen() { lock.withLock { open = true } }
}

/// A `LibraryTransport` whose every call, local commits included, runs only while the account
/// gate is open and returns only if it is still open at the same generation. A result that
/// arrives after an account change is discarded as `superseded`, so nothing it carried is
/// written locally. Wrap it inside `ThrottledLibraryTransport`, so admission happens when the
/// call actually runs, after any throttle wait.
struct WiltedMacAccountGatedLibraryTransport: LibraryTransport {
    let inner: any LibraryTransport
    let gate: WiltedMacLibraryAccountGate

    /// Runs `operation` under the gate; used for calls made outside the protocol (discovery).
    func run<Result: Sendable>(_ operation: () async throws -> Result) async throws -> Result {
        let generation = try gate.admit()
        let result = try await operation()
        try gate.verify(generation)
        return result
    }

    /// Changes whenever the inner transport's generation or the account gate's does.
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() &+ gate.generation }

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        try await run { try await inner.fetchChanges(since: token) }
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        try await run { try await inner.push(changes: changes) }
    }
    func send(intent: LibraryIntent) async throws { try await run { try await inner.send(intent: intent) } }
    func listIntents() async throws -> [LibraryIntent] { try await run { try await inner.listIntents() } }
    func publishIntentOutcome(_ outcome: IntentOutcome) async throws {
        try await run { try await inner.publishIntentOutcome(outcome) }
    }
    func intentOutcomes() async throws -> [IntentOutcome] { try await run { try await inner.intentOutcomes() } }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await run { try await inner.publish(record, as: channel) }
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        try await run { try await inner.fetchDeviceRecords() }
    }
    func publish(_ records: [(record: DevicePlaybackPosition, channel: PlaybackChannel)]) async throws {
        let generation = try gate.admit()
        try await inner.publish(records)  // The tuple array is not Sendable, so not through `run`.
        try gate.verify(generation)
    }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        try await run { try await inner.poll(options) }
    }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        try await run { try await inner.publishMedia(offer: offer, fileURL: fileURL) }
    }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await run { try await inner.mediaOffers() } }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        try await run { try await inner.fetchMedia(offer, progress: progress) }
    }
    func removeMedia(entryID: ItemID) async throws { try await run { try await inner.removeMedia(entryID: entryID) } }
    func publishStats(_ stats: LibraryStats) async throws { try await run { try await inner.publishStats(stats) } }
    func readStats() async throws -> LibraryStats? { try await run { try await inner.readStats() } }
    func publishTranscript(_ transcript: LibraryTranscript) async throws {
        try await run { try await inner.publishTranscript(transcript) }
    }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await run { try await inner.transcript(entryID: entryID, revisionID: revisionID) }
    }
    func removeTranscript(entryID: ItemID) async throws {
        try await run { try await inner.removeTranscript(entryID: entryID) }
    }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws {
        try await run { try await inner.commitFetchedState(token) }
    }
    func commitSentState(_ token: LibraryChangeToken?) async throws {
        try await run { try await inner.commitSentState(token) }
    }
}

// MARK: - Account sources

/// Where account signals come from and how a reviewed transport is re-enabled.
struct WiltedMacLibraryAccountSource: Sendable {
    var signals: AsyncStream<CloudKitAccountChangeSignal>
    /// Clears the raw transport's own quarantine after review.
    var resetTransport: @Sendable () async -> Void
    /// Account log lines. Never given an account token or identifier.
    var log: @Sendable (String) -> Void = { message in
        libraryAccountLog.notice("\(message, privacy: .public)")
    }

    /// The live CloudKit transport's own signals, or nil for a transport that reports none.
    static func transport(_ raw: any LibraryTransport) -> Self? {
        guard let cloudKit = raw as? CloudKitLibraryTransport else { return nil }
        return Self(signals: cloudKit.accountChanges, resetTransport: { await cloudKit.resetAfterAccountChange() })
    }
}

/// A no-network account source for tests and account-review fixtures: it emits the same
/// data-free signals the CloudKit adapter does, and records resets and log lines.
final class WiltedMacLibraryAccountFixture: @unchecked Sendable {
    let signals: AsyncStream<CloudKitAccountChangeSignal>
    private let continuation: AsyncStream<CloudKitAccountChangeSignal>.Continuation
    private let lock = NSLock()
    private var resetsValue = 0
    private var linesValue: [String] = []

    init() { (signals, continuation) = AsyncStream<CloudKitAccountChangeSignal>.makeStream() }

    var resets: Int { lock.withLock { resetsValue } }
    var loggedLines: [String] { lock.withLock { linesValue } }

    func emit(_ signal: CloudKitAccountChangeSignal) { continuation.yield(signal) }

    /// A first sign-in, hashed exactly as the CloudKit adapter hashes the user record name.
    func signIn(recordName: String) { emit(.ownershipAdopted(token: CloudKitAccountIdentity.token(for: recordName))) }

    var source: WiltedMacLibraryAccountSource {
        WiltedMacLibraryAccountSource(
            signals: signals,
            resetTransport: { [self] in lock.withLock { resetsValue += 1 } },
            log: { [self] line in lock.withLock { linesValue.append(line) } })
    }
}

// MARK: - Account controller

/// Binds the library publisher to the iCloud account that owns this library, durably.
///
/// The gate starts closed and opens only once a hashed owner is persisted for the account signed
/// in now: a first owner of an empty library, or the recorded owner returning. Sign-out, an account
/// switch, a different owner or an unreadable identity close the gate at once (bumping its
/// generation, so delayed results are discarded), stop the poller, and persist a quarantine. Work
/// stays bound to the original owner until `approve()` deliberately resumes it. Signals, approval
/// and shutdown run on one serial chain, and nothing is sent before its outcome is persisted.
@MainActor
final class WiltedMacLibraryAccountController {
    let gate = WiltedMacLibraryAccountGate(open: false)
    private(set) var status: WiltedMacLibraryAccountStatus = .awaitingAccount
    private(set) var binding: LocalLibraryAccountBinding?
    /// Runs before the gate reopens: resets the publisher's baseline for the account it now serves.
    var willOpen: (@MainActor () async -> Void)?
    /// Runs after the gate reopens: restarts the poller and republishes.
    var didOpen: (@MainActor () -> Void)?
    /// Runs as the gate closes: stops the poller.
    var didClose: (@MainActor () -> Void)?
    var onStatus: (@MainActor (WiltedMacLibraryAccountStatus) -> Void)?

    private let source: WiltedMacLibraryAccountSource
    private let persistence: WiltedMacLibraryAccountPersistence
    private let isLibraryEmpty: @Sendable () async -> Bool
    /// The hashed account signed in this session, as last adopted by the transport.
    private var sessionAdoptedToken: String?
    private var chain: Task<Void, Never>?
    private var consumer: Task<Void, Never>?
    private var hydrated = false
    private var stopped = false

    init(
        source: WiltedMacLibraryAccountSource, persistence: WiltedMacLibraryAccountPersistence,
        isLibraryEmpty: @escaping @Sendable () async -> Bool
    ) {
        self.source = source
        self.persistence = persistence
        self.isLibraryEmpty = isLibraryEmpty
    }

    /// Hydrates the persisted binding, then consumes the transport's account signals in order.
    func start() {
        guard consumer == nil, !stopped else { return }
        enqueue { await $0.hydrate() }
        let signals = source.signals
        consumer = Task { [weak self] in
            for await signal in signals {
                guard let self, !self.stopped else { return }
                self.receive(signal)
            }
        }
    }

    /// Resumes after review: binds the account signed in now, or, when this session has seen no
    /// account yet, records the approval so the next account seen becomes the owner. Returns
    /// whether the review was accepted.
    func approve() async -> Bool {
        guard !stopped else { return false }
        let previous = chain
        let task = Task { @MainActor [weak self] () -> Bool in
            await previous?.value
            return await self?.performApproval() ?? false
        }
        chain = Task { _ = await task.value }
        return await task.value
    }

    /// Closes the gate (bumping its generation) and ignores any later signal. Synchronous.
    func stop() {
        stopped = true
        gate.close()
        consumer?.cancel()
    }

    /// Joins the transition chain, so a quarantine received before `stop()` is persisted.
    func close() async {
        stop()
        await chain?.value
        await consumer?.value
    }

    // MARK: Transitions

    private func enqueue(_ work: @escaping @MainActor (WiltedMacLibraryAccountController) async -> Void) {
        let previous = chain
        chain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Closes at once, before anything is persisted, when a signal can only end in a closed gate.
    private func receive(_ signal: CloudKitAccountChangeSignal) {
        switch signal {
        case .quarantineRequired:
            closeNow()
        case let .ownershipAdopted(token) where gate.isOpen && token != binding?.ownerToken:
            closeNow()
        default:
            break
        }
        enqueue { await $0.handle(signal) }
    }

    private func closeNow() {
        gate.close()
        didClose?()
    }

    private func hydrate() async {
        do {
            binding = try await persistence.load()
            hydrated = true
            switch binding?.state {
            case .reviewRequired?, .quarantined?: setStatus(.reviewRequired(binding?.reason ?? .ownerMismatch))
            case .approved?: setStatus(.approvedAwaitingAccount)
            case .bound?, nil: setStatus(.awaitingAccount)
            }
        } catch {
            source.log("Library account binding could not be read; library sync stays paused")
            setStatus(.failed)
        }
    }

    private func handle(_ signal: CloudKitAccountChangeSignal) async {
        guard hydrated else { return }
        switch signal {
        case let .quarantineRequired(type):
            await quarantine(reason: Self.reason(for: type), candidate: nil)
        case let .ownershipAdopted(token):
            guard LocalLibraryAccountBinding.isHashedToken(token) else {
                source.log("Library account identity was not hashed; quarantined")
                closeNow()
                await quarantine(reason: .ownerMismatch, candidate: nil)
                return
            }
            sessionAdoptedToken = token
            await adopt(token)
        case .ownershipConfirmed:
            if let token = sessionAdoptedToken { await adopt(token) }
        }
    }

    private func adopt(_ token: String) async {
        switch binding?.state {
        case nil:
            if await isLibraryEmpty() {
                source.log("Library account: first owner bound to an empty library")
                await bind(token, resetTransport: false)
            } else {
                source.log("Library account: library has data and no owner; review required")
                await persist(try? LocalLibraryAccountBinding(
                    state: .reviewRequired, candidateToken: token, reason: .unboundLibrary))
            }
        case .bound?:
            if binding?.ownerToken == token {
                if !gate.isOpen { await open(resetTransport: false) }
            } else {
                source.log("Library account: a different account is signed in; quarantined")
                closeNow()
                await quarantine(reason: .ownerMismatch, candidate: token)
            }
        case .approved?:
            source.log("Library account: approved review bound to the signed-in account")
            await bind(token, resetTransport: false)
        case .reviewRequired?:
            if binding?.candidateToken != token {
                await persist(try? LocalLibraryAccountBinding(
                    state: .reviewRequired, candidateToken: token, reason: binding?.reason ?? .unboundLibrary))
            }
        case .quarantined?:
            if let owner = binding?.ownerToken, owner == token {
                source.log("Library account: the original owner returned; resuming")
                await bind(owner, resetTransport: true)
            } else if binding?.candidateToken != token {
                await persist(try? LocalLibraryAccountBinding(
                    state: .quarantined, ownerToken: binding?.ownerToken, candidateToken: token,
                    reason: binding?.reason ?? .ownerMismatch))
            }
        }
    }

    private func performApproval() async -> Bool {
        guard hydrated, !stopped, let current = binding,
              current.state == .reviewRequired || current.state == .quarantined else { return false }
        let wasQuarantined = current.state == .quarantined
        if let candidate = current.candidateToken, candidate == sessionAdoptedToken {
            source.log("Library account: review approved; resuming for the signed-in account")
            await bind(candidate, resetTransport: wasQuarantined)
            return status == .active
        }
        source.log("Library account: review approved; waiting for the next account")
        guard await persist(try? LocalLibraryAccountBinding(state: .approved)) else { return false }
        if wasQuarantined { await source.resetTransport() }
        return true
    }

    private func quarantine(reason: LocalLibraryAccountBinding.Reason, candidate: String?) async {
        source.log("Library account quarantined (\(reason.rawValue)); sending paused")
        await persist(try? LocalLibraryAccountBinding(
            state: .quarantined, ownerToken: binding?.ownerToken, candidateToken: candidate, reason: reason))
    }

    private func bind(_ token: String, resetTransport: Bool) async {
        guard await persist(try? LocalLibraryAccountBinding(state: .bound, ownerToken: token)) else { return }
        await open(resetTransport: resetTransport)
    }

    /// Opens only for a persisted owner, after the transport and publisher are reset for it.
    private func open(resetTransport: Bool) async {
        guard !stopped, binding?.state == .bound else { return }
        if resetTransport { await source.resetTransport() }
        await willOpen?()
        guard !stopped, binding?.state == .bound else { return }
        gate.reopen()
        setStatus(.active)
        didOpen?()
    }

    /// Writes `next` first; the in-memory binding and status change only once it is durable.
    @discardableResult
    private func persist(_ next: LocalLibraryAccountBinding?) async -> Bool {
        guard let next else {
            closeNow()
            setStatus(.failed)
            return false
        }
        do {
            try await persistence.save(next)
        } catch {
            source.log("Library account binding could not be saved; library sync stays paused")
            closeNow()
            setStatus(.failed)
            return false
        }
        binding = next
        switch next.state {
        case .reviewRequired, .quarantined: setStatus(.reviewRequired(next.reason ?? .ownerMismatch))
        case .approved: setStatus(.approvedAwaitingAccount)
        case .bound: if !gate.isOpen { setStatus(.awaitingAccount) }
        }
        return true
    }

    private func setStatus(_ next: WiltedMacLibraryAccountStatus) {
        guard status != next else { return }
        status = next
        if !stopped { onStatus?(next) }
    }

    private static func reason(for type: CloudKitAccountChangeType) -> LocalLibraryAccountBinding.Reason {
        switch type {
        case .signIn: .signIn
        case .signOut: .signOut
        case .switchAccounts: .switchAccounts
        }
    }
}

/// Reads and writes the persisted binding.
struct WiltedMacLibraryAccountPersistence: Sendable {
    var load: @Sendable () async throws -> LocalLibraryAccountBinding?
    var save: @Sendable (LocalLibraryAccountBinding) async throws -> Void

    static func store(_ store: LocalLibraryStore) -> Self {
        Self(load: { try await store.libraryAccountBinding() },
             save: { try await store.save(libraryAccountBinding: $0) })
    }
}

extension LibraryStateSnapshot {
    /// Nothing that an owner could lose: no feeds, episodes, queue or listening history.
    var isEmptyLibrary: Bool { feeds.isEmpty && episodes.isEmpty && queue.isEmpty && listening.isEmpty }
}

// MARK: - Model surface

extension WiltedMacModel {
    /// The running account binding, or nil when library sync is off or unmanaged.
    var libraryAccount: WiltedMacLibraryAccountController? { librarySyncController?.account }

    /// Approves a pending account review (`libraryAccountStatus == .reviewRequired`). Returns
    /// whether the review was accepted; `libraryAccountStatus` says whether sending resumed.
    @discardableResult
    func approveLibraryAccountReview() async -> Bool { await libraryAccount?.approve() ?? false }
}
#endif
