import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let pollerLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacInboundPoller")

/// The Mac's sync round, run by its one `SyncTick` (30 s, `SyncCadence.tickInterval`): it reads
/// follower intents and every device's playback records as one batch (`LibraryTransport.poll`),
/// hands the records to `onDeviceRecords` (where the Mac adopts the phone's positions), and then
/// runs `publishRound`, the Mac's own batched writes (library state, statistics, the playing
/// checkpoint), so a round is one read and the few writes that are due, never a request per loop.
///
/// Every read is by record name; a cycle never scans the zone. The one scan is `discover`, run at
/// startup (retried until it succeeds) and again every `rediscoverEveryCycles` cycles while no other
/// device is known, or every `rediscoverEveryCyclesWithPeers` once one is, which teaches the
/// transport the device and entry names to ask for. Nothing in the background is faster than the
/// tick, and a Mac Play press reads the phone's position itself. `pollNow()` runs a cycle on demand
/// and joins one already running.
actor WiltedMacInboundPoller {
    static let pollInterval: Duration = .seconds(SyncCadence.tickInterval)
    static let rediscoverEveryCycles = SyncCadence.rediscoverEveryCycles
    static let rediscoverEveryCyclesWithPeers = SyncCadence.rediscoverEveryCyclesWithPeers

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let transport: any LibraryTransport
    private let sink: any LibraryIntentSink
    private let deviceID: String?
    private let gate: TransportGate?
    private let discover: (@Sendable () async throws -> Void)?
    private let onDeviceRecords: (@Sendable (LibraryDeviceRecords) async -> Void)?
    private let publishRound: (@Sendable () async -> Void)?
    private let maintenance: (@Sendable () async -> Void)?
    private let onStop: (@Sendable () async -> Void)?
    private let sleep: Sleep
    private let clock: @Sendable () -> Date
    private var tick: SyncTick?
    private var lifecycleGeneration: UInt64 = 0
    private var inFlight: Task<Void, Never>?
    private var discovered = false
    private(set) var cycleCount = 0
    private(set) var lastFailure: String?
    private(set) var latestDeviceRecords = LibraryDeviceRecords()

    /// - Parameters:
    ///   - deviceID: this Mac, to tell its own records from a peer's when choosing how often to rescan.
    ///   - gate: the device's shared gate; a closed gate holds the whole tick until its retry time.
    ///   - publishRound: the Mac's own writes for this round, run after the reads.
    init(
        transport: any LibraryTransport,
        sink: any LibraryIntentSink,
        deviceID: String? = nil,
        gate: TransportGate? = nil,
        discover: (@Sendable () async throws -> Void)? = nil,
        onDeviceRecords: (@Sendable (LibraryDeviceRecords) async -> Void)? = nil,
        publishRound: (@Sendable () async -> Void)? = nil,
        maintenance: (@Sendable () async -> Void)? = nil,
        onStop: (@Sendable () async -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.clock = clock
        self.transport = transport
        self.sink = sink
        self.deviceID = deviceID
        self.gate = gate
        self.discover = discover
        self.onDeviceRecords = onDeviceRecords
        self.publishRound = publishRound
        self.maintenance = maintenance
        self.onStop = onStop
        self.sleep = sleep
    }

    /// Starts the tick; the first round runs at once. Calling it again while running does nothing.
    func start() async {
        guard tick == nil else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let sleep = sleep
        let tick = SyncTick(gate: gate, clock: clock, sleep: { try await sleep(.seconds($0)) }, round: { [weak self] _ in
            await self?.pollFromTick(generation: generation)
        })
        self.tick = tick
        await tick.start()
        if lifecycleGeneration != generation { await tick.stop() }
    }

    func stop() async {
        lifecycleGeneration &+= 1
        let stopping = tick
        tick = nil
        await stopping?.stop()
        await onStop?()
        // SyncTick deliberately lets a round finish. Its maintenance can still
        // write accounting, so shutdown must join it before the root is removed.
        await inFlight?.value
    }

    var isRunning: Bool { tick != nil }

    private func pollFromTick(generation: UInt64) async {
        guard lifecycleGeneration == generation, tick != nil else { return }
        await pollNow()
    }

    /// A refresh the person asked for: a round now, the timer restarted from it, nothing sent while
    /// the gate is closed.
    func refreshNow() async -> SyncTick.RefreshOutcome? { await tick?.refreshNow() }

    /// Runs a cycle now. A call made while a cycle is running waits for that cycle instead of
    /// queueing another, so a burst of callers costs one round.
    func pollNow() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.cycle() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Whether any device other than this Mac has published, so the costly scan can be rare.
    private var knowsAPeer: Bool {
        (latestDeviceRecords.nowPlaying + latestDeviceRecords.progress).contains { $0.record.deviceID != deviceID }
    }

    private func cycle() async {
        var failure: String?
        var received = 0
        var scanned = false
        let every = knowsAPeer ? Self.rediscoverEveryCyclesWithPeers : Self.rediscoverEveryCycles
        let rediscoverDue = discovered && cycleCount % every == 0
        if !discovered || rediscoverDue, let discover {
            do {
                try await discover()
                if !discovered { pollerLog.notice("Peer discovery finished") }
                discovered = true
                scanned = true
            } catch {
                failure = "discovery: \(error)"
            }
        }
        do {
            let polled = try await transport.poll([.intents, .deviceRecords])
            received = polled.intents.count
            for intent in polled.intents {
                do { try await sink.receive(intent) } catch {
                    pollerLog.error("Intent \(intent.id, privacy: .public) was not applied: \(String(describing: error), privacy: .public)")
                }
            }
            if let records = polled.records {
                latestDeviceRecords = records
                await onDeviceRecords?(records)
            }
        } catch {
            failure = failure ?? "poll: \(error)"
        }
        await publishRound?()
        await maintenance?()
        cycleCount += 1
        // A failure repeats every cycle while offline, so only a change is logged. A closed gate is
        // reported by its own status, not once per cycle here.
        if let failure, failure != lastFailure, !failure.contains("throttled until") {
            pollerLog.error("Poll failed: \(failure, privacy: .public)")
        }
        lastFailure = failure
        // One line per round, so the request rate can be read from the unified log.
        pollerLog.notice("Sync round \(self.cycleCount): intents \(received), scan \(scanned ? "yes" : "no", privacy: .public), \(failure == nil ? "ok" : "failed", privacy: .public)")
    }
}

/// Everything the Mac needs to answer media intents: the ledger, the media service and the
/// poller, started and stopped together. Owned by the sync controller.
@MainActor
final class WiltedMacInboundRuntime {
    let ledger: WiltedMacIntentLedger
    let service: WiltedMacMediaService
    private let transport: any LibraryTransport
    private let deviceID: String?
    private let gate: TransportGate?
    private let discover: (@Sendable () async throws -> Void)?
    private let onDeviceRecords: (@Sendable (LibraryDeviceRecords) async -> Void)?
    private let maintenance: (@Sendable () async -> Void)?
    private let beforePollerStart: (@Sendable () async -> Void)?
    private let onPollerStop: (@Sendable () async -> Void)?
    private var startup: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private(set) var poller: WiltedMacInboundPoller?

    init(
        source: any WiltedMacReadyAudioSource,
        transport: any LibraryTransport,
        directory: URL,
        deviceID: String? = nil,
        gate: TransportGate? = nil,
        discover: (@Sendable () async throws -> Void)? = nil,
        onDeviceRecords: (@Sendable (LibraryDeviceRecords) async -> Void)? = nil,
        maintenance: (@Sendable () async -> Void)? = nil,
        beforePollerStart: (@Sendable () async -> Void)? = nil,
        onPollerStop: (@Sendable () async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.deviceID = deviceID
        self.gate = gate
        self.discover = discover
        self.onDeviceRecords = onDeviceRecords
        self.maintenance = maintenance
        self.beforePollerStart = beforePollerStart
        self.onPollerStop = onPollerStop
        ledger = WiltedMacIntentLedger(fileURL: directory.appendingPathComponent("intent-ledger.json"), now: now)
        service = WiltedMacMediaService(
            source: source, transport: transport,
            accountingURL: directory.appendingPathComponent("media-accounting.json"), now: now
        )
    }

    /// Records the intent id durably, then applies it; an id already recorded is skipped.
    nonisolated func consume(_ intent: LibraryIntent) async {
        do {
            guard try await ledger.recordIfNew(intent.id) else { return }
        } catch {
            pollerLog.error("Intent \(intent.id, privacy: .public) was not recorded and is not applied: \(String(describing: error), privacy: .public)")
            return
        }
        await service.handle(intent)
    }

    /// Starts the tick; intents reach `sink`, which routes media intents to `consume`. `publishRound`
    /// is the Mac's own batched writes, run in every round after the reads.
    @discardableResult
    func start(sink: any LibraryIntentSink, publishRound: (@Sendable () async -> Void)? = nil) -> Task<Void, Never>? {
        guard poller == nil else { return nil }
        let service = service
        let poller = WiltedMacInboundPoller(
            transport: transport, sink: sink, deviceID: deviceID, gate: gate, discover: discover,
            onDeviceRecords: onDeviceRecords, publishRound: publishRound,
            maintenance: maintenance ?? { await service.sweepExpired() }, onStop: onPollerStop
        )
        self.poller = poller
        let beforePollerStart = beforePollerStart
        let previousShutdown = shutdown
        let task = Task {
            await previousShutdown?.value
            guard !Task.isCancelled else { return }
            await beforePollerStart?()
            guard !Task.isCancelled else { return }
            await poller.start()
        }
        startup = task
        return task
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard let poller else { return shutdown }
        self.poller = nil
        let startup = startup
        startup?.cancel()
        let task = Task {
            // Stop promptly, then settle a startup already suspended on an actor
            // or injected wait, and stop again to cover its last possible start.
            await poller.stop()
            await startup?.value
            await poller.stop()
        }
        shutdown = task
        return task
    }

    func close() async { await stop()?.value }
}
