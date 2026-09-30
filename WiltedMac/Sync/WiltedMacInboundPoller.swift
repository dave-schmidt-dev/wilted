import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let pollerLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacInboundPoller")

/// Reads follower intents and every device's playback records on a timer, because the Mac has
/// no other inbound trigger while idle. Each fetch of the device records is handed to
/// `onDeviceRecords`, where the Mac adopts the phone's positions.
///
/// Every read is a targeted fetch by record name (`listIntents`, `fetchDeviceRecords`); a cycle
/// never scans the zone. The one scan is `discover`, run at startup (retried until it succeeds)
/// and again every `rediscoverEveryCycles` cycles, which teaches the transport the device and
/// entry names to ask for; a phone that first publishes after startup is otherwise never heard.
/// The interval is `SyncCadence.pollInterval` (30 s) whether or not the Mac plays: nothing in the
/// background needs to be faster, and a Mac Play press reads the phone's position itself.
/// `pollNow()` runs a cycle on demand.
actor WiltedMacInboundPoller {
    static let pollInterval: Duration = .seconds(SyncCadence.pollInterval)
    static let rediscoverEveryCycles = SyncCadence.rediscoverEveryCycles

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let transport: any LibraryTransport
    private let sink: any LibraryIntentSink
    private let discover: (@Sendable () async throws -> Void)?
    private let onDeviceRecords: (@Sendable (LibraryDeviceRecords) async -> Void)?
    private let maintenance: (@Sendable () async -> Void)?
    private let sleep: Sleep
    private var loop: Task<Void, Never>?
    private var discovered = false
    private var polling = false
    private var rerun = false
    private(set) var cycleCount = 0
    private(set) var lastFailure: String?
    private(set) var latestDeviceRecords = LibraryDeviceRecords()
    /// The wait chosen after each cycle, in order.
    private(set) var scheduledIntervals: [Duration] = []

    init(
        transport: any LibraryTransport,
        sink: any LibraryIntentSink,
        discover: (@Sendable () async throws -> Void)? = nil,
        onDeviceRecords: (@Sendable (LibraryDeviceRecords) async -> Void)? = nil,
        maintenance: (@Sendable () async -> Void)? = nil,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.sink = sink
        self.discover = discover
        self.onDeviceRecords = onDeviceRecords
        self.maintenance = maintenance
        self.sleep = sleep
    }

    /// Starts the loop; a first cycle runs at once. Calling it again while running does nothing.
    func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Runs a cycle now. A call made while a cycle is running schedules one more right after it.
    func pollNow() async {
        if polling {
            rerun = true
            return
        }
        polling = true
        repeat {
            rerun = false
            await cycle()
        } while rerun && !Task.isCancelled
        polling = false
    }

    private func run() async {
        while !Task.isCancelled {
            await pollNow()
            let interval = Self.pollInterval
            scheduledIntervals.append(interval)
            do { try await sleep(interval) } catch { return }
        }
    }

    private func cycle() async {
        var failure: String?
        let rediscoverDue = discovered && cycleCount % Self.rediscoverEveryCycles == 0
        if !discovered || rediscoverDue, let discover {
            do {
                try await discover()
                if !discovered { pollerLog.notice("Peer discovery finished") }
                discovered = true
            } catch {
                failure = "discovery: \(error)"
            }
        }
        do {
            for intent in try await transport.listIntents() {
                do { try await sink.receive(intent) } catch {
                    pollerLog.error("Intent \(intent.id, privacy: .public) was not applied: \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            failure = failure ?? "intents: \(error)"
        }
        do {
            latestDeviceRecords = try await transport.fetchDeviceRecords()
            await onDeviceRecords?(latestDeviceRecords)
        } catch {
            failure = failure ?? "device records: \(error)"
        }
        await maintenance?()
        cycleCount += 1
        // A failure repeats every cycle while offline, so only a change is logged. A closed gate is
        // reported by its own status, not once per cycle here.
        if let failure, failure != lastFailure, !failure.contains("throttled until") {
            pollerLog.error("Poll failed: \(failure, privacy: .public)")
        }
        lastFailure = failure
    }
}

/// Everything the Mac needs to answer media intents: the ledger, the media service and the
/// poller, started and stopped together. Owned by the sync controller.
@MainActor
final class WiltedMacInboundRuntime {
    let ledger: WiltedMacIntentLedger
    let service: WiltedMacMediaService
    private let transport: any LibraryTransport
    private let discover: (@Sendable () async throws -> Void)?
    private let onDeviceRecords: (@Sendable (LibraryDeviceRecords) async -> Void)?
    private(set) var poller: WiltedMacInboundPoller?

    init(
        source: any WiltedMacReadyAudioSource,
        transport: any LibraryTransport,
        directory: URL,
        discover: (@Sendable () async throws -> Void)? = nil,
        onDeviceRecords: (@Sendable (LibraryDeviceRecords) async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.discover = discover
        self.onDeviceRecords = onDeviceRecords
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

    /// Starts polling; intents reach `sink`, which routes media intents to `consume`.
    func start(sink: any LibraryIntentSink) {
        guard poller == nil else { return }
        let service = service
        let poller = WiltedMacInboundPoller(
            transport: transport, sink: sink, discover: discover,
            onDeviceRecords: onDeviceRecords,
            maintenance: { await service.sweepExpired() }
        )
        self.poller = poller
        Task { await poller.start() }
    }

    func stop() {
        guard let poller else { return }
        self.poller = nil
        Task { await poller.stop() }
    }
}
