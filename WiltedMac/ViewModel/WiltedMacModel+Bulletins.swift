import Foundation
import Observation
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedLibrary
import WiltedProducer

private let bulletinLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "bulletins")
private nonisolated(unsafe) var bulletinHubKey: UInt8 = 0

/// Owns what Reports needs beyond the settings file: the location provider, and the
/// `BulletinProducer` that publishes the interruption switches and news headlines.
///
/// The producer runs while interruptions are on, and until the channel it last published is back
/// to all-off, so turning them off reaches the phones. A Mac that never turned them on does no work.
/// Nothing starts for a fixture launch, without a store, or while the model is closing.
@MainActor
@Observable
final class WiltedMacBulletinHub {
    /// Whether the channel last published (or read back) had a switch on. Survives relaunch, so a
    /// Mac that was quit with interruptions on and failed to publish the off state still retries it.
    static let activePreferenceKey = "wilted.bulletins.publishedActive"

    /// The latest poll result, for Settings.
    private(set) var status = BulletinProducerStatus()

    @ObservationIgnored private weak var model: WiltedMacModel?
    @ObservationIgnored private var ownedLocation: WiltedLocationProvider?
    @ObservationIgnored private var producer: BulletinProducer?

    init(model: WiltedMacModel, location: WiltedLocationProvider? = nil) {
        self.model = model
        ownedLocation = location
    }

    deinit {
        if let producer { Task { await producer.stop() } }
    }

    /// The one location provider on this Mac, created on first use. Settings reads it; it is
    /// started in `reconcile` once interruptions or the daily report are on.
    var location: WiltedLocationProvider {
        if let ownedLocation { return ownedLocation }
        let provider = WiltedLocationProvider(manager: WiltedCoreLocationManager(), wifi: WiltedCoreWLANPower())
        ownedLocation = provider
        return provider
    }

    var producerIsRunning: Bool { producer != nil }

    /// Starts, nudges or stops the producer to match the settings. Safe to call at any time.
    func reconcile() {
        guard let model else { return }
        let settings = model.automationSettings
        let canRun = model.store != nil && !model.fixtureMode && !model.isClosingTemporaryState
        // The morning report needs a location too, even with interruptions off.
        if canRun, settings.interruptionsEnabled || settings.reportEnabled {
            let provider = location
            provider.typedCoordinates = settings.typedCoordinates
            provider.start()
        }
        let wanted = canRun && (settings.interruptionsEnabled || model.preferences.bool(forKey: Self.activePreferenceKey))
        if wanted {
            if let producer {
                Task { await producer.settingsChanged() }
            } else {
                let made = makeProducer()
                producer = made
                Task { await made.start() }
            }
        } else if let producer {
            self.producer = nil
            Task { await producer.stop() }
            status = BulletinProducerStatus()
        }
    }

    private func makeProducer() -> BulletinProducer {
        BulletinProducer(
            settings: { [weak self] in
                await MainActor.run { self?.currentSettings ?? Self.allOff }
            },
            newsItems: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.newsCandidates()
            },
            fetchPublished: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.publisher().fetchBulletins()
            },
            publish: { [weak self] bulletins in
                guard let self else { throw CancellationError() }
                try await self.publisher().publishBulletins(bulletins)
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.apply(status) }
            })
    }

    private static let allOff = BulletinProducerSettings(
        interruptionsEnabled: false, alertsEnabled: false, headlinesEnabled: false, headlineMinimumGapMinutes: 30)

    private var currentSettings: BulletinProducerSettings {
        guard let model else { return Self.allOff }
        let settings = model.automationSettings
        return BulletinProducerSettings(
            interruptionsEnabled: settings.interruptionsEnabled, alertsEnabled: settings.alertsEnabled,
            headlinesEnabled: settings.headlinesEnabled, headlineMinimumGapMinutes: settings.headlineMinimumGapMinutes)
    }

    /// The running library publisher, whose transport holds the account gate and the rate limit.
    private func publisher() throws -> WiltedMacLibraryPublisher {
        guard let model, !model.isClosingTemporaryState else { throw CancellationError() }
        guard let controller = model.librarySyncController else {
            throw BulletinProducerUnavailable(reason: "Library sync is not running")
        }
        return controller.publisher
    }

    /// The posts of every followed article feed marked as news. A feed that fails is skipped; the
    /// poll fails only when every feed did.
    private func newsCandidates() async throws -> [NewsHeadlineCandidate] {
        guard let model, let store = model.store else { throw CancellationError() }
        var candidates: [NewsHeadlineCandidate] = []
        var attempted = 0
        var failed = 0
        var lastFailure: Error?
        for feed in try await store.articleFeeds() where (try? await store.isNews(feedID: feed.itemID)) == true {
            attempted += 1
            do {
                let document = try await model.podcastFeedClient.loadArticleFeed(feed.canonicalURL)
                for item in document.items.prefix(50) {
                    guard let id = try? item.id(feedURL: feed.canonicalURL) else { continue }
                    candidates.append(NewsHeadlineCandidate(
                        id: id.rawValue, feedTitle: feed.title, title: item.title, publishedAt: item.publishedAt))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
                lastFailure = error
            }
        }
        if attempted > 0, failed == attempted, let lastFailure { throw lastFailure }
        return candidates
    }

    private func apply(_ value: BulletinProducerStatus) {
        guard producer != nil else { return }
        status = value
        guard !value.isPolling, value.lastError == nil, value.waitingFor == nil,
              let active = value.publishedActive, let model else { return }
        model.preferences.set(active, forKey: Self.activePreferenceKey)
        if !active, !model.automationSettings.interruptionsEnabled {
            bulletinLog.info("Interruptions are off everywhere; the bulletin producer is idle")
            reconcile()
        }
    }

    /// One line for Settings, or nil while there is nothing to say.
    static func statusLine(_ status: BulletinProducerStatus, now: Date = Date()) -> String? {
        if status.isPolling { return "Checking news feeds\u{2026}" }
        if let waiting = status.waitingFor { return "Waiting: \(waiting)" }
        if let error = status.lastError {
            let retry = status.nextPollAt.map { " Next try \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            return "Last check failed: \(error).\(retry)"
        }
        if let last = status.lastPollAt { return "Last checked \(last.formatted(date: .omitted, time: .shortened))" }
        return nil
    }
}

extension WiltedMacModel {
    /// The hub, created on first use and kept for the model's life.
    var bulletinHub: WiltedMacBulletinHub {
        if let hub = objc_getAssociatedObject(self, &bulletinHubKey) as? WiltedMacBulletinHub { return hub }
        let hub = WiltedMacBulletinHub(model: self)
        objc_setAssociatedObject(self, &bulletinHubKey, hub, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return hub
    }

    /// Called when the store opens or closes and when the settings change. Does nothing, and
    /// creates nothing, for a Mac that has never used interruptions.
    func bulletinLifecycleChanged() {
        let existing = objc_getAssociatedObject(self, &bulletinHubKey) as? WiltedMacBulletinHub
        guard existing != nil || automationSettings.interruptionsEnabled || automationSettings.reportEnabled
            || preferences.bool(forKey: WiltedMacBulletinHub.activePreferenceKey) else { return }
        (existing ?? bulletinHub).reconcile()
    }
}
#endif
