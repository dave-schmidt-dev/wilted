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
    /// A direct check found no iCloud account signed in; nothing is sent until one is.
    case noAccount
    /// Neither a signal nor a direct check could establish the account; nothing is sent.
    case accountUnavailable
    /// The default could not start: the transport reports no account changes (live CloudKit
    /// could not start), so nothing runs rather than sending unbound.
    case transportUnavailable

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
        case .noAccount: "no iCloud account"
        case .accountUnavailable: "iCloud account unavailable"
        case .transportUnavailable: "iCloud library sync could not start"
        }
    }
}

// MARK: - Account sources

/// What a direct, read-only account check found. The token is hashed exactly as the CloudKit
/// adapter hashes it (`CloudKitAccountIdentity.token(for:)`); the record name never leaves the check.
enum WiltedMacLibraryAccountProbeResult: Equatable, Sendable {
    case signedIn(token: String)
    case noAccount
    case unavailable
}

/// Where account signals come from and how a reviewed transport is re-enabled.
struct WiltedMacLibraryAccountSource: Sendable {
    var signals: AsyncStream<CloudKitAccountChangeSignal>
    /// Clears the raw transport's own quarantine after review.
    var resetTransport: @Sendable () async -> Void
    /// Account log lines. Never given an account token or identifier.
    var log: @Sendable (String) -> Void = { message in
        libraryAccountLog.notice("\(message, privacy: .public)")
    }
    /// Resolves the account directly when no signal arrives within `probeDelay`: an engine
    /// rebuilt from saved state reports no sign-in, and must not wait for one forever.
    var probe: (@Sendable () async -> WiltedMacLibraryAccountProbeResult)?
    var probeDelay: Duration = .seconds(5)
    /// Checks made while the account stays undetermined (`unavailable`). The wait doubles after
    /// each one up to `probeMaxDelay`, so a Mac that launched offline still resolves later.
    var probeAttempts = 12
    var probeMaxDelay: Duration = .seconds(300)

    /// The live CloudKit transport's own signals, or nil for a transport that reports none.
    static func transport(
        _ raw: any LibraryTransport, probe: (@Sendable () async -> WiltedMacLibraryAccountProbeResult)? = nil
    ) -> Self? {
        guard let cloudKit = raw as? CloudKitLibraryTransport else { return nil }
        return Self(
            signals: cloudKit.accountChanges, resetTransport: { await cloudKit.resetAfterAccountChange() },
            probe: probe)
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
    private var probeValue: WiltedMacLibraryAccountProbeResult?
    private var probesValue = 0
    /// How long the controller waits for a signal before the probe runs, and how often it retries.
    var probeDelay: Duration = .milliseconds(50)
    var probeAttempts = 3

    init() { (signals, continuation) = AsyncStream<CloudKitAccountChangeSignal>.makeStream() }

    var resets: Int { lock.withLock { resetsValue } }
    var loggedLines: [String] { lock.withLock { linesValue } }
    var probes: Int { lock.withLock { probesValue } }

    /// Answers the startup probe with `result`; without one the source has no probe.
    func answerProbe(_ result: WiltedMacLibraryAccountProbeResult) { lock.withLock { probeValue = result } }

    func emit(_ signal: CloudKitAccountChangeSignal) { continuation.yield(signal) }

    /// A first sign-in, hashed exactly as the CloudKit adapter hashes the user record name.
    func signIn(recordName: String) { emit(.ownershipAdopted(token: CloudKitAccountIdentity.token(for: recordName))) }

    var source: WiltedMacLibraryAccountSource {
        let answers = lock.withLock { probeValue != nil }
        let probe: @Sendable () async -> WiltedMacLibraryAccountProbeResult = { [self] in
            lock.withLock {
                probesValue += 1
                return probeValue ?? .unavailable
            }
        }
        return WiltedMacLibraryAccountSource(
            signals: signals,
            resetTransport: { [self] in lock.withLock { resetsValue += 1 } },
            log: { [self] line in lock.withLock { linesValue.append(line) } },
            probe: answers ? probe : nil,
            probeDelay: probeDelay, probeAttempts: probeAttempts, probeMaxDelay: probeDelay)
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
    private var prober: Task<Void, Never>?
    private var signalsReceived = 0
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
        if let probe = source.probe {
            prober = Task { [weak self] in await self?.runProbes(probe) }
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
        prober?.cancel()
    }

    /// Joins the transition chain, so a quarantine received before `stop()` is persisted.
    func close() async {
        stop()
        await prober?.value
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
        signalsReceived += 1
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

    /// Checks the account directly while no signal has named it: an engine rebuilt from saved
    /// state reports no sign-in. A signal that arrives first, or during a check, always wins.
    private func runProbes(_ probe: @escaping @Sendable () async -> WiltedMacLibraryAccountProbeResult) async {
        var delay = source.probeDelay
        for _ in 0..<max(1, source.probeAttempts) {
            do { try await Task.sleep(for: delay) } catch { return }
            delay = min(delay * 2, max(source.probeDelay, source.probeMaxDelay))
            guard !stopped, signalsReceived == 0, sessionAdoptedToken == nil else { return }
            let result = await probe()
            guard !Task.isCancelled, !stopped, signalsReceived == 0 else { return }
            enqueue { await $0.applyProbe(result) }
            if result != .unavailable { return }
        }
    }

    private func applyProbe(_ result: WiltedMacLibraryAccountProbeResult) async {
        guard hydrated, !stopped, signalsReceived == 0, sessionAdoptedToken == nil else { return }
        let undetermined = binding.map { $0.state == .bound || $0.state == .approved } ?? true
        switch result {
        case let .signedIn(token) where LocalLibraryAccountBinding.isHashedToken(token):
            source.log("Library account resolved by a direct check")
            sessionAdoptedToken = token
            await adopt(token)
        case .signedIn:
            source.log("Library account check returned an unhashed identity; ignored")
            if undetermined { setStatus(.accountUnavailable) }
        case .noAccount:
            source.log("Library account check found no iCloud account; sending paused")
            if undetermined { setStatus(.noAccount) }
        case .unavailable:
            source.log("Library account check could not reach iCloud; sending paused")
            if undetermined { setStatus(.accountUnavailable) }
        }
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
