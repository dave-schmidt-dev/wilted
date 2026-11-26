import Foundation

/// Bounded operation names used to attribute request volume without recording record names.
public enum CloudKitOperationKind: String, Sendable, CaseIterable, Hashable {
    case unspecified
    case sendChanges
    case fetchRecordsIfPresent
    case fetchRecords
    case saveRecordRaw
    case fetchAssetRecordRaw
    case deleteRecordsRaw
    case fetchChanges
}

/// Why a live sync engine was replaced. Values contain no token data.
public enum CloudKitEngineRebuildReason: String, Sendable, CaseIterable, Hashable {
    case recovery
    case tokenMismatch
    case nilState
    case serverReset
}

enum CloudKitRecordFreshness: String, Sendable, CaseIterable, Hashable {
    case firstSeen
    case unchanged
    case changed
    case unknown
}

enum CloudKitProgressReadActivity: String, Sendable, CaseIterable, Hashable {
    case active
    case hot
    case inactive
    case unknown
}

enum CloudKitProgressReadOutcome: String, Sendable, CaseIterable, Hashable {
    case firstSeen
    case unchanged
    case changed
    case unknown
    case missing
}

struct CloudKitProgressReadMetrics: Sendable, Equatable {
    let activity: CloudKitProgressReadActivity
    let outcome: CloudKitProgressReadOutcome
    let records: Int
    let bytes: Int64
}

struct CloudKitProgressReadSample: Sendable, Equatable {
    let caller: CloudKitOperationCaller
    let activity: CloudKitProgressReadActivity
    let outcome: CloudKitProgressReadOutcome
    let records: Int
    let bytes: Int64
    let timestamp: Date
}

struct CloudKitProgressReadKey: Hashable, Sendable {
    let caller: CloudKitOperationCaller
    let activity: CloudKitProgressReadActivity
    let outcome: CloudKitProgressReadOutcome
}

struct CloudKitProgressReadValues: Equatable, Sendable {
    var records = 0
    var bytes: Int64 = 0

    mutating func add(_ sample: CloudKitProgressReadSample) {
        records += sample.records
        bytes += sample.bytes
    }
}

struct CloudKitNamedReadMetrics: Sendable, Equatable {
    let recordType: LibraryRecordType?
    let freshness: CloudKitRecordFreshness
    let records: Int
    let bytes: Int64
}

/// Counts returned by one CKSyncEngine fetch, split between delivered and mapped changes.
struct CloudKitEngineFetchMetrics: Sendable, Equatable {
    var receivedRecords = 0
    var receivedBytes: Int64 = 0
    var decodedRecords = 0
    var decodedBytes: Int64 = 0
    var receivedDeletions = 0
    var mappedDeletions = 0

    mutating func add(_ other: CloudKitEngineFetchMetrics) {
        receivedRecords += other.receivedRecords
        receivedBytes += other.receivedBytes
        decodedRecords += other.decodedRecords
        decodedBytes += other.decodedBytes
        receivedDeletions += other.receivedDeletions
        mappedDeletions += other.mappedDeletions
    }
}

struct CloudKitEngineFetchSample: Sendable, Equatable {
    let caller: CloudKitOperationCaller
    let metrics: CloudKitEngineFetchMetrics
    let timestamp: Date
}

struct CloudKitEngineRebuildSample: Sendable, Equatable {
    let reason: CloudKitEngineRebuildReason
    let timestamp: Date
}

struct CloudKitRecentOperationKey: Hashable, Sendable {
    let caller: CloudKitOperationCaller
    let operation: CloudKitOperationKind
}

struct CloudKitRecentOperationValues: Equatable, Sendable {
    var requests = 0
    var records = 0
    var bytes: Int64 = 0

    mutating func add(_ record: CloudKitOperationRecord) {
        requests += 1
        records += record.recordCount
        bytes += record.bytes
    }
}

struct CloudKitRecordReadKey: Hashable, Sendable {
    let caller: CloudKitOperationCaller
    let recordType: LibraryRecordType?
    let freshness: CloudKitRecordFreshness
}

struct CloudKitRecordReadSample: Sendable, Equatable {
    let caller: CloudKitOperationCaller
    let recordType: LibraryRecordType?
    let freshness: CloudKitRecordFreshness
    let records: Int
    let bytes: Int64
    let timestamp: Date
}

struct CloudKitRecordReadValues: Equatable, Sendable {
    var records = 0
    var bytes: Int64 = 0
}

extension CloudKitOperationSummary {
    /// Aggregated detail lines used by both the unified log and the local archive.
    func diagnosticSummaryLines() -> [String] {
        var lines: [String] = []
        let operations = recentOperations.keys.sorted {
            ($0.caller.rawValue, $0.operation.rawValue) < ($1.caller.rawValue, $1.operation.rawValue)
        }.map { key in
            let values = recentOperations[key, default: CloudKitRecentOperationValues()]
            return "\(key.caller.rawValue).\(key.operation.rawValue): \(values.requests) reqs (\(values.records) records, \(values.bytes) B)"
        }.joined(separator: ", ")
        if !operations.isEmpty { lines.append("last 5m by operation: [\(operations)]") }

        let engine = engineFetchSummary(recentEngineFetches)
        if !engine.isEmpty { lines.append("last 5m engine changes: [\(engine)]") }
        let rebuilds = Self.rebuildSummary(recentEngineRebuilds.map(\.reason))
        if !rebuilds.isEmpty { lines.append("last 5m engine rebuilds: [\(rebuilds)]") }
        let totalRebuilds = Self.rebuildSummary(totalEngineRebuilds)
        if !totalRebuilds.isEmpty { lines.append("engine rebuilds since launch: [\(totalRebuilds)]") }
        let totalEngine = engineFetchSummary(totalEngineFetches)
        if !totalEngine.isEmpty { lines.append("engine changes since launch: [\(totalEngine)]") }
        let reads = recordReadSummary(recentRecordReads)
        if !reads.isEmpty { lines.append("last 5m named reads: [\(reads)]") }
        let progress = progressReadSummary(recentProgressReads)
        if !progress.isEmpty { lines.append("last 5m progress reads: [\(progress)]") }
        return lines
    }

    private static func rebuildSummary(_ counts: [CloudKitEngineRebuildReason: Int]) -> String {
        CloudKitEngineRebuildReason.allCases.compactMap { reason in
            guard let count = counts[reason], count > 0 else { return nil }
            return "\(reason.rawValue): \(count)"
        }.joined(separator: ", ")
    }

    private static func rebuildSummary(_ reasons: [CloudKitEngineRebuildReason]) -> String {
        rebuildSummary(reasons.reduce(into: [:]) { $0[$1, default: 0] += 1 })
    }

    private func engineFetchSummary(_ samples: [CloudKitEngineFetchSample]) -> String {
        let totals = samples.reduce(into: [CloudKitOperationCaller: CloudKitEngineFetchMetrics]()) { grouped, sample in
            var values = grouped[sample.caller, default: CloudKitEngineFetchMetrics()]
            values.add(sample.metrics)
            grouped[sample.caller] = values
        }
        return engineFetchSummary(totals)
    }

    private func engineFetchSummary(_ totals: [CloudKitOperationCaller: CloudKitEngineFetchMetrics]) -> String {
        CloudKitOperationCaller.allCases.compactMap { caller in
            guard let values = totals[caller] else { return nil }
            return "\(caller.rawValue): received \(values.receivedRecords) records/\(values.receivedBytes) B, mapped \(values.decodedRecords)/\(values.decodedBytes) B, deletions \(values.mappedDeletions)/\(values.receivedDeletions)"
        }.joined(separator: "; ")
    }

    private func recordReadSummary(_ samples: [CloudKitRecordReadSample]) -> String {
        let totals = samples.reduce(into: [CloudKitRecordReadKey: CloudKitRecordReadValues]()) { grouped, sample in
            let key = CloudKitRecordReadKey(caller: sample.caller, recordType: sample.recordType, freshness: sample.freshness)
            var values = grouped[key, default: CloudKitRecordReadValues()]
            values.records += sample.records
            values.bytes += sample.bytes
            grouped[key] = values
        }
        return totals.keys.sorted {
            ($0.caller.rawValue, $0.recordType?.rawValue ?? "unknown", $0.freshness.rawValue)
                < ($1.caller.rawValue, $1.recordType?.rawValue ?? "unknown", $1.freshness.rawValue)
        }.map { key in
            let values = totals[key, default: CloudKitRecordReadValues()]
            let type = key.recordType?.rawValue ?? "unknown"
            return "\(key.caller.rawValue).\(type).\(key.freshness.rawValue): \(values.records) records/\(values.bytes) B"
        }.joined(separator: ", ")
    }

    private func progressReadSummary(_ samples: [CloudKitProgressReadSample]) -> String {
        let totals = samples.reduce(into: [CloudKitProgressReadKey: CloudKitProgressReadValues]()) { grouped, sample in
            let key = CloudKitProgressReadKey(caller: sample.caller, activity: sample.activity, outcome: sample.outcome)
            grouped[key, default: CloudKitProgressReadValues()].add(sample)
        }
        return totals.keys.sorted {
            ($0.caller.rawValue, $0.activity.rawValue, $0.outcome.rawValue)
                < ($1.caller.rawValue, $1.activity.rawValue, $1.outcome.rawValue)
        }.map { key in
            let values = totals[key, default: CloudKitProgressReadValues()]
            let label = "\(key.caller.rawValue).\(key.activity.rawValue).\(key.outcome.rawValue)"
            if key.outcome == .missing { return "\(label): \(values.records) pairs" }
            return "\(label): \(values.records) records/\(values.bytes) B"
        }.joined(separator: ", ")
    }
}
