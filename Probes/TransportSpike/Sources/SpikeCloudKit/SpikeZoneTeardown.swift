import CloudKit
import Foundation

/// What the teardown removed, and anything it could not.
public struct SpikeTeardownReport: Codable, Sendable, Equatable {
    public var zoneDeleted = false
    public var deletedSubscriptionIDs: [String] = []
    public var ubiquityDirectoryRemoved = false
    /// Why the iCloud Drive cleanup did nothing (capability absent), when it did nothing.
    public var ubiquitySkippedReason: String?
    public var errors: [String] = []

    public init() {}

    public var isClean: Bool { errors.isEmpty }
}

/// Removes everything the spike created: `SpikeZone` (and so every `Spike*` record), the spike
/// database subscriptions, and the iCloud Drive files. Each step runs even when an earlier one fails.
public struct SpikeZoneTeardown: Sendable {
    private let context: SpikeCloudKitContext
    private let ubiquityContainerIdentifier: String?

    public init(context: SpikeCloudKitContext = SpikeCloudKitContext(), ubiquityContainerIdentifier: String? = nil) {
        self.context = context
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
    }

    public func run() async -> SpikeTeardownReport {
        var report = SpikeTeardownReport()
        let database = context.database

        do {
            let subscriptions = try await database.allSubscriptions()
            for subscription in subscriptions where subscription.subscriptionID.hasPrefix(SpikeNames.subscriptionPrefix) {
                do {
                    _ = try await database.deleteSubscription(withID: subscription.subscriptionID)
                    report.deletedSubscriptionIDs.append(subscription.subscriptionID)
                } catch {
                    report.errors.append("subscription \(subscription.subscriptionID): \(error)")
                }
            }
        } catch {
            report.errors.append("list subscriptions: \(error)")
        }

        do {
            let result = try await database.modifyRecordZones(saving: [], deleting: [context.zoneID])
            report.zoneDeleted = true
            for (_, deleted) in result.deleteResults {
                do { try deleted.get() } catch let error as CKError where error.code == .zoneNotFound {
                    // Already gone counts as deleted.
                } catch {
                    report.zoneDeleted = false
                    report.errors.append("delete zone: \(error)")
                }
            }
        } catch {
            report.errors.append("delete zone: \(error)")
        }

        switch await UbiquityDriveStrategy.availability(containerIdentifier: ubiquityContainerIdentifier) {
        case .skipped(let reason):
            report.ubiquitySkippedReason = reason
        case .available(let container):
            let directory = UbiquityDriveStrategy.spikeDirectory(in: container)
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                report.ubiquityDirectoryRemoved = true
            } catch {
                report.errors.append("remove ubiquity files: \(error)")
            }
        }
        return report
    }
}
