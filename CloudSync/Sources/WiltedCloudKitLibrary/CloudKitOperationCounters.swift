import CloudKit
import Foundation
import OSLog
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary

/// The functional caller of a CloudKit transport operation.
public enum CloudKitOperationCaller: String, Sendable, CaseIterable, CustomStringConvertible {
    case poll
    case handoff
    case offers
    case transcripts
    case media
    case stats
    case bulletins
    case scan
    case deviceLink
    case publication

    public var description: String { rawValue }
}

/// The result classification of a CloudKit transport operation.
public enum CloudKitOperationResult: Sendable, Hashable, CustomStringConvertible {
    case ok
    case throttled(retryAfter: TimeInterval?)
    case other

    public var description: String {
        switch self {
        case .ok:
            return "ok"
        case let .throttled(retryAfter):
            if let retryAfter {
                return "throttled(retryAfter: \(Int(retryAfter))s)"
            } else {
                return "throttled"
            }
        case .other:
            return "other"
        }
    }

    public var isThrottled: Bool {
        if case .throttled = self { return true }
        return false
    }

    public var retryAfter: TimeInterval? {
        if case let .throttled(retryAfter) = self { return retryAfter }
        return nil
    }
}

/// One recorded CloudKit transport operation.
public struct CloudKitOperationRecord: Sendable, Equatable {
    public let caller: CloudKitOperationCaller
    public let operation: CloudKitOperationKind
    public let recordCount: Int
    public let bytes: Int64
    public let result: CloudKitOperationResult
    public let timestamp: Date

    public init(caller: CloudKitOperationCaller, operation: CloudKitOperationKind = .unspecified,
                recordCount: Int, bytes: Int64, result: CloudKitOperationResult, timestamp: Date = Date()) {
        self.caller = caller
        self.operation = operation
        self.recordCount = recordCount
        self.bytes = bytes
        self.result = result
        self.timestamp = timestamp
    }
}

/// Task-local context for propagating the active caller through async operations.
public enum CloudKitOperationContext {
    @TaskLocal public static var caller: CloudKitOperationCaller?
}

/// Running totals since launch, kept as counts so a long-lived app holds a fixed amount of memory.
struct CloudKitOperationTotals: Sendable, Equatable {
    struct Key: Hashable, Sendable {
        let caller: CloudKitOperationCaller
        let result: CloudKitOperationResult
    }

    var requests = 0
    var recordCount = 0
    var bytes: Int64 = 0
    var byCallerAndResult: [Key: Int] = [:]
    var lastThrottle: CloudKitOperationRecord?

    mutating func add(_ record: CloudKitOperationRecord) {
        requests += 1
        recordCount += record.recordCount
        bytes += record.bytes
        byCallerAndResult[Key(caller: record.caller, result: record.result), default: 0] += 1
        if record.result.isThrottled { lastThrottle = record }
    }
}

/// A Sendable snapshot of CloudKit operations for diagnostics and status lines.
public struct CloudKitOperationSummary: Sendable, Equatable, CustomStringConvertible {
    public let timestamp: Date
    /// The operations inside the recent window, oldest first.
    public let recent: [CloudKitOperationRecord]
    public let recentRequests: Int
    public let recentRecordCount: Int
    public let recentBytes: Int64
    public let totalRequests: Int
    public let totalRecordCount: Int
    public let totalBytes: Int64
    public let lastThrottleDate: Date?
    public let lastThrottleRetryAfter: TimeInterval?
    public let callerCounts: [CloudKitOperationCaller: Int]
    public let recentCallerCounts: [CloudKitOperationCaller: Int]
    public let recentThrottleCounts: [CloudKitOperationCaller: Int]
    let totals: CloudKitOperationTotals
    let recentOperations: [CloudKitRecentOperationKey: CloudKitRecentOperationValues]
    let recentEngineFetches: [CloudKitEngineFetchSample]
    let totalEngineFetches: [CloudKitOperationCaller: CloudKitEngineFetchMetrics]
    let recentEngineRebuilds: [CloudKitEngineRebuildSample]
    let totalEngineRebuilds: [CloudKitEngineRebuildReason: Int]
    let recentRecordReads: [CloudKitRecordReadSample]
    let recentProgressReads: [CloudKitProgressReadSample]

    init(timestamp: Date, recent: [CloudKitOperationRecord], totals: CloudKitOperationTotals,
         recentEngineFetches: [CloudKitEngineFetchSample],
         totalEngineFetches: [CloudKitOperationCaller: CloudKitEngineFetchMetrics],
         recentEngineRebuilds: [CloudKitEngineRebuildSample],
         totalEngineRebuilds: [CloudKitEngineRebuildReason: Int],
         recentRecordReads: [CloudKitRecordReadSample],
         recentProgressReads: [CloudKitProgressReadSample]) {
        self.timestamp = timestamp
        self.recent = recent
        self.totals = totals
        self.recentEngineFetches = recentEngineFetches
        self.totalEngineFetches = totalEngineFetches
        self.recentEngineRebuilds = recentEngineRebuilds
        self.totalEngineRebuilds = totalEngineRebuilds
        self.recentRecordReads = recentRecordReads
        self.recentProgressReads = recentProgressReads
        recentRequests = recent.count
        recentRecordCount = recent.reduce(0) { $0 + $1.recordCount }
        recentBytes = recent.reduce(0) { $0 + $1.bytes }
        totalRequests = totals.requests
        totalRecordCount = totals.recordCount
        totalBytes = totals.bytes
        lastThrottleDate = totals.lastThrottle?.timestamp
        lastThrottleRetryAfter = totals.lastThrottle?.result.retryAfter
        callerCounts = totals.byCallerAndResult.reduce(into: [:]) { $0[$1.key.caller, default: 0] += $1.value }
        recentCallerCounts = recent.reduce(into: [:]) { $0[$1.caller, default: 0] += 1 }
        recentThrottleCounts = recent.reduce(into: [:]) { result, record in
            if record.result.isThrottled { result[record.caller, default: 0] += 1 }
        }
        recentOperations = recent.reduce(into: [:]) { result, record in
            let key = CloudKitRecentOperationKey(caller: record.caller, operation: record.operation)
            result[key, default: CloudKitRecentOperationValues()].add(record)
        }
    }

    /// Operations by `caller` since launch.
    public func count(for caller: CloudKitOperationCaller) -> Int {
        callerCounts[caller, default: 0]
    }

    /// Operations by `caller` since launch that ended with `result`.
    public func count(for caller: CloudKitOperationCaller, result: CloudKitOperationResult) -> Int {
        totals.byCallerAndResult[.init(caller: caller, result: result), default: 0]
    }

    /// Operations by `caller` inside the recent window.
    public func recentCount(for caller: CloudKitOperationCaller) -> Int {
        recentCallerCounts[caller, default: 0]
    }

    public var description: String {
        summaryString()
    }

    /// The one-line Settings diagnostics text, the same on Mac and iPhone:
    /// "iCloud: N requests in the last 5 minutes · last limit 10:45" (or "no limits since launch").
    public func statusLine(timeZone: TimeZone? = nil) -> String {
        Self.statusLine(recentRequests: recentRequests, lastThrottleDate: lastThrottleDate, timeZone: timeZone)
    }

    /// `statusLine(timeZone:)` from its two inputs.
    public static func statusLine(recentRequests: Int, lastThrottleDate: Date?, timeZone: TimeZone? = nil) -> String {
        let requests = recentRequests == 1 ? "1 request" : "\(recentRequests) requests"
        let limit = lastThrottleDate.map { date in
            let time = timeZone.map { date.formatted(Date.FormatStyle(time: .shortened, timeZone: $0)) }
                ?? date.formatted(date: .omitted, time: .shortened)
            return "last limit \(time)"
        } ?? "no limits since launch"
        return "iCloud: \(requests) in the last 5 minutes · \(limit)"
    }

    /// Status line summary text. Contains no record names, tokens, device or account IDs.
    public func summaryString() -> String {
        var parts: [String] = []
        parts.append("CloudKit operations: last 5m \(recentRequests) reqs (\(recentRecordCount) records, \(recentBytes) B)")
        parts.append("since launch: \(totalRequests) reqs (\(totalRecordCount) records, \(totalBytes) B)")
        let callers = CloudKitOperationCaller.allCases.compactMap { c -> String? in
            let count = callerCounts[c, default: 0]
            guard count > 0 else { return nil }
            return "\(c.rawValue): \(count)"
        }.joined(separator: ", ")
        if !callers.isEmpty {
            parts.append("callers: [\(callers)]")
        }
        let recentThrottles = CloudKitOperationCaller.allCases.compactMap { caller -> String? in
            guard let count = recentThrottleCounts[caller], count > 0 else { return nil }
            return "\(caller.rawValue): \(count)"
        }.joined(separator: ", ")
        if !recentThrottles.isEmpty { parts.append("last 5m throttles: [\(recentThrottles)]") }
        parts.append(contentsOf: diagnosticSummaryLines())
        if let lastThrottleDate {
            let timeStr = lastThrottleDate.formatted(date: .omitted, time: .shortened)
            let retryStr = lastThrottleRetryAfter.map { " (retry-after: \(Int($0))s)" } ?? ""
            parts.append("last limit: \(timeStr)\(retryStr)")
        } else {
            parts.append("no limits since launch")
        }
        return parts.joined(separator: " · ")
    }

}

/// Accumulates per-operation CloudKit transport metrics and logs a summary every `logInterval`.
/// Memory stays bounded: totals are counts, and only the recent window keeps individual records.
public final class CloudKitOperationCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var recent: [CloudKitOperationRecord] = []
    private var recentEngineFetches: [CloudKitEngineFetchSample] = []
    private var totalEngineFetches: [CloudKitOperationCaller: CloudKitEngineFetchMetrics] = [:]
    private var recentEngineRebuilds: [CloudKitEngineRebuildSample] = []
    private var totalEngineRebuilds: [CloudKitEngineRebuildReason: Int] = [:]
    private var recentRecordReads: [CloudKitRecordReadSample] = []
    private var recentProgressReads: [CloudKitProgressReadSample] = []
    private var totals = CloudKitOperationTotals()
    private let clock: @Sendable () -> Date
    private let logInterval: TimeInterval
    private var lastLogTime: Date
    private let log = Logger(subsystem: "com.zerodelta.wilted", category: "CloudKitOperationCounters")
    private var loggingTask: Task<Void, Never>?
    private let archive: CloudKitOperationArchive?

    /// - Parameters:
    ///   - logInterval: the recent window and how often a summary is logged.
    ///   - startLoggingTask: also log on a timer, so an idle app still reports.
    ///   - archive: also append each summary to this file, starting with a launch line.
    public init(clock: @escaping @Sendable () -> Date = { Date() },
                logInterval: TimeInterval = 300,
                startLoggingTask: Bool = true,
                archive: CloudKitOperationArchive? = nil) {
        self.clock = clock
        self.logInterval = logInterval
        self.lastLogTime = clock()
        self.archive = archive
        archive?.append("launch", at: lastLogTime)
        if startLoggingTask {
            self.loggingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(logInterval * 1_000_000_000))
                    guard !Task.isCancelled, let self else { break }
                    self.logNoticeSummary()
                }
            }
        }
    }

    deinit {
        loggingTask?.cancel()
    }

    public func record(caller: CloudKitOperationCaller, operation: CloudKitOperationKind = .unspecified,
                       recordCount: Int, bytes: Int64,
                       result: CloudKitOperationResult, timestamp: Date? = nil) {
        let now = timestamp ?? clock()
        let entry = CloudKitOperationRecord(caller: caller, operation: operation, recordCount: recordCount,
                                            bytes: bytes, result: result, timestamp: now)
        let logDue = lock.withLock { () -> Bool in
            totals.add(entry)
            recent.append(entry)
            prune(now: now)
            guard now.timeIntervalSince(lastLogTime) >= logInterval else { return false }
            lastLogTime = now
            return true
        }
        // Logged outside the lock: the summary takes it again.
        if logDue { logNoticeSummary(now: now) }
    }

    func recordEngineFetch(caller: CloudKitOperationCaller, metrics: CloudKitEngineFetchMetrics,
                           timestamp: Date? = nil) {
        let now = timestamp ?? clock()
        lock.withLock {
            recentEngineFetches.append(CloudKitEngineFetchSample(caller: caller, metrics: metrics, timestamp: now))
            var total = totalEngineFetches[caller, default: CloudKitEngineFetchMetrics()]
            total.add(metrics)
            totalEngineFetches[caller] = total
            prune(now: now)
        }
    }

    func recordEngineRebuild(_ reason: CloudKitEngineRebuildReason, timestamp: Date? = nil) {
        let now = timestamp ?? clock()
        lock.withLock {
            recentEngineRebuilds.append(CloudKitEngineRebuildSample(reason: reason, timestamp: now))
            totalEngineRebuilds[reason, default: 0] += 1
            prune(now: now)
        }
    }

    func recordNamedReads(caller: CloudKitOperationCaller, metrics: [CloudKitNamedReadMetrics], timestamp: Date? = nil) {
        let now = timestamp ?? clock()
        lock.withLock {
            recentRecordReads.append(contentsOf: metrics.filter { $0.records > 0 }.map {
                CloudKitRecordReadSample(caller: caller, recordType: $0.recordType, freshness: $0.freshness,
                                         records: $0.records, bytes: $0.bytes, timestamp: now)
            })
            prune(now: now)
        }
    }

    func recordProgressReads(caller: CloudKitOperationCaller, metrics: [CloudKitProgressReadMetrics], timestamp: Date? = nil) {
        let now = timestamp ?? clock()
        lock.withLock {
            recentProgressReads.append(contentsOf: metrics.filter { $0.records > 0 }.map {
                CloudKitProgressReadSample(caller: caller, activity: $0.activity, outcome: $0.outcome,
                                           records: $0.records, bytes: $0.bytes, timestamp: now)
            })
            prune(now: now)
        }
    }

    public func summary(now: Date? = nil) -> CloudKitOperationSummary {
        let current = now ?? clock()
        return lock.withLock {
            let cutoff = current.addingTimeInterval(-logInterval)
            return CloudKitOperationSummary(
                timestamp: current, recent: recent.filter { $0.timestamp >= cutoff }, totals: totals,
                recentEngineFetches: recentEngineFetches.filter { $0.timestamp >= cutoff },
                totalEngineFetches: totalEngineFetches,
                recentEngineRebuilds: recentEngineRebuilds.filter { $0.timestamp >= cutoff },
                totalEngineRebuilds: totalEngineRebuilds,
                recentRecordReads: recentRecordReads.filter { $0.timestamp >= cutoff },
                recentProgressReads: recentProgressReads.filter { $0.timestamp >= cutoff })
        }
    }

    public func logNoticeSummary(now: Date? = nil) {
        let summary = self.summary(now: now)
        log.notice("\(summary.description, privacy: .public)")
        archive?.append(summary.description, at: summary.timestamp)
    }

    public func reset() {
        lock.withLock {
            recent.removeAll()
            recentEngineFetches.removeAll()
            totalEngineFetches.removeAll()
            recentEngineRebuilds.removeAll()
            recentRecordReads.removeAll()
            recentProgressReads.removeAll()
            totalEngineRebuilds.removeAll()
            totals = CloudKitOperationTotals()
            lastLogTime = clock()
        }
    }

    /// Drops records older than the recent window. Called with the lock held.
    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-logInterval)
        if let keep = recent.firstIndex(where: { $0.timestamp >= cutoff }) {
            if keep > 0 { recent.removeFirst(keep) }
        } else {
            recent.removeAll()
        }
        recentEngineFetches.removeAll { $0.timestamp < cutoff }
        recentEngineRebuilds.removeAll { $0.timestamp < cutoff }
        recentRecordReads.removeAll { $0.timestamp < cutoff }
        recentProgressReads.removeAll { $0.timestamp < cutoff }
    }

    /// Throttled when `TransportPressureClassifier` sees server pressure (with its Retry-After), else other.
    public static func classifyResult(error: Error?) -> CloudKitOperationResult {
        guard let error else { return .ok }
        if let pressure = TransportPressureClassifier.classify(error) {
            return .throttled(retryAfter: pressure.retryAfter)
        }
        return .other
    }
}
