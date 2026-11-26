import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

private let playbackJournalLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "PlaybackJournalV2")

/// Durable, rotating playback boundaries for joining Mac handoff with the phone journal.
/// Private files retain a pseudonymous item tag; public OSLog contains only event fields.
final class WiltedMacPlaybackJournal {
    private let file: WiltedMacRotatingLogFile
    private let now: @Sendable () -> Date
    private let logLine: @Sendable (String) -> Void
    private let lock = NSLock()

    init(
        file: WiltedMacRotatingLogFile,
        now: @escaping @Sendable () -> Date = { Date() },
        logLine: @escaping @Sendable (String) -> Void = { playbackJournalLog.notice("\($0, privacy: .public)") }
    ) {
        self.file = file
        self.now = now
        self.logLine = logLine
    }

    convenience init(
        url: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        logLine: @escaping @Sendable (String) -> Void = { playbackJournalLog.notice("\($0, privacy: .public)") }
    ) {
        self.init(file: WiltedMacRotatingLogFile(url: url), now: now, logLine: logLine)
    }

    func note(_ record: PlaybackJournalRecord) {
        let body = record.line
        lock.withLock {
            let stamp = now().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            if preparePrivateStorage() {
                try? file.append(["\(stamp) \(body)"])
            }
            logLine(record.publicLogLine)
        }
    }

    /// Refuses to write if the dedicated v2 directory or journal cannot be owner-only.
    private func preparePrivateStorage() -> Bool {
        let fileManager = FileManager.default
        let directory = file.url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            guard permissions(at: directory) == 0o700 else { return false }
            if !fileManager.fileExists(atPath: file.url.path) {
                guard fileManager.createFile(
                    atPath: file.url.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else { return false }
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
            guard permissions(at: file.url) == 0o600 else { return false }
            for index in 1...3 {
                let backup = file.backupURL(index)
                guard fileManager.fileExists(atPath: backup.path) else { continue }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                guard permissions(at: backup) == 0o600 else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    private func permissions(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
        return permissions.intValue
    }

    @MainActor
    static var launch: WiltedMacPlaybackJournal?

    /// Starts the app-owned journal under the Mac's existing state directory.
    @MainActor
    static func startForLaunch(stateDirectory: URL) {
        guard launch == nil else { return }
        let directory = stateDirectory.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("playback-v2", isDirectory: true)
        let url = directory
            .appendingPathComponent("playback-journal.log")
        let journal = WiltedMacPlaybackJournal(url: url)
        guard journal.preparePrivateStorage() else { return }
        launch = journal
    }
}

/// One locally observed boundary in a playback command's life.
///
/// Every stage is a boundary on this machine: `acknowledged` is the
/// synchronous publication of the pending state, `playCalled` the return of
/// the backend's play call. None of them is rendered, scheduled or audible
/// timing, so a derived wait must never be read as "time to sound".
enum WiltedMacPlaybackTraceStage: String, CaseIterable, Sendable {
    case acknowledged
    case inheritedWaitEnded
    case effectAdmitted
    case outgoingCheckpointCalled
    case loadCalled
    case playCalled
    case transcriptTailBegan
    case transcriptTailEnded
    case checkpointEnqueued
    case settled
}

/// A wait the trace derives from two stages of one command, named for its
/// boundaries so a report cannot be mistaken for rendered-timing evidence.
enum WiltedMacPlaybackTraceWait: String, CaseIterable, Sendable {
    case acknowledgedToInheritedWait = "acknowledged-to-inheritedWait"
    case acknowledgedToEffectAdmitted = "acknowledged-to-effectAdmitted"
    case acknowledgedToPlayCalled = "acknowledged-to-playCalled"
    case inheritedWaitToPlayCalled = "inheritedWait-to-playCalled"
    case playCalledToTranscriptTailEnded = "playCalled-to-transcriptTailEnded"
    case transcriptTailDuration = "transcriptTail-began-to-ended"
    case acknowledgedToSettled = "acknowledged-to-settled"

    fileprivate var from: WiltedMacPlaybackTraceStage {
        switch self {
        case .acknowledgedToInheritedWait: .acknowledged
        case .acknowledgedToEffectAdmitted: .acknowledged
        case .acknowledgedToPlayCalled: .acknowledged
        case .inheritedWaitToPlayCalled: .inheritedWaitEnded
        case .playCalledToTranscriptTailEnded: .playCalled
        case .transcriptTailDuration: .transcriptTailBegan
        case .acknowledgedToSettled: .acknowledged
        }
    }

    fileprivate var to: WiltedMacPlaybackTraceStage {
        switch self {
        case .acknowledgedToInheritedWait: .inheritedWaitEnded
        case .acknowledgedToEffectAdmitted: .effectAdmitted
        case .acknowledgedToPlayCalled: .playCalled
        case .inheritedWaitToPlayCalled: .playCalled
        case .playCalledToTranscriptTailEnded: .transcriptTailEnded
        case .transcriptTailDuration: .transcriptTailEnded
        case .acknowledgedToSettled: .settled
        }
    }
}

/// A bounded, monotonic, owner-data-free trace of command stages.
///
/// It stores stage names, opaque generation tokens and monotonic offsets
/// only: no episode or article titles, no item, revision or session
/// identifiers, no URLs and no file paths. The event buffer is fixed-size and
/// drops its oldest entry when full, so tracing memory never grows with
/// library size.
struct WiltedMacPlaybackTrace: Sendable {
    struct Event: Equatable, Sendable {
        let sequence: UInt64
        let stage: WiltedMacPlaybackTraceStage
        let token: UInt64
        let offsetNanos: UInt64
    }

    /// One measured wait with its sample count, in whole microseconds.
    struct Summary: Equatable, Sendable {
        let wait: WiltedMacPlaybackTraceWait
        let sampleCount: Int
        let medianMicros: Int
        let p95Micros: Int
        let maxMicros: Int
    }

    static let capacity = 4096
    /// Qualified synthetic pre-audio budget: max(50ms scheduling floor, 4 × baseline
    /// p95 of 0.093ms). Applied to p95 of
    /// `acknowledged-to-playCalled` on the synthetic held-presentation and
    /// scaled-catalog fixtures. It bounds dispatch work only; it says nothing
    /// about when audio becomes audible.
    static let preAudioTargetMilliseconds = 50

    private(set) var events: [Event] = []
    private var origin: ContinuousClock.Instant?
    private var nextSequence: UInt64 = 0

    mutating func record(_ stage: WiltedMacPlaybackTraceStage, token: UInt64) {
        let now = ContinuousClock.now
        let origin = origin ?? now
        self.origin = origin
        let nanos = Self.nanoseconds(origin.duration(to: now))
        nextSequence &+= 1
        if events.count >= Self.capacity { events.removeFirst(events.count - Self.capacity + 1) }
        events.append(Event(sequence: nextSequence, stage: stage, token: token, offsetNanos: nanos))
    }

    mutating func reset() {
        events.removeAll(keepingCapacity: true)
        origin = nil
        nextSequence = 0
    }

    func offsetNanos(_ stage: WiltedMacPlaybackTraceStage, token: UInt64) -> UInt64? {
        events.last { $0.token == token && $0.stage == stage }?.offsetNanos
    }

    func measuredWait(_ wait: WiltedMacPlaybackTraceWait, token: UInt64) -> UInt64? {
        guard let from = offsetNanos(wait.from, token: token),
              let to = offsetNanos(wait.to, token: token),
              to >= from else { return nil }
        return to - from
    }

    /// One summary per wait that has at least one complete sample pair.
    func summaries() -> [Summary] {
        let tokens = Set(events.map(\.token))
        return WiltedMacPlaybackTraceWait.allCases.compactMap { wait in
            let samples = tokens.compactMap { measuredWait(wait, token: $0) }.sorted()
            guard !samples.isEmpty else { return nil }
            return Summary(
                wait: wait, sampleCount: samples.count,
                medianMicros: Self.micros(Self.percentile(samples, 0.5)),
                p95Micros: Self.micros(Self.percentile(samples, 0.95)),
                maxMicros: Self.micros(samples[samples.count - 1])
            )
        }
    }

    /// The trace as bounded text. It names the call-boundary limits of its own
    /// stages, so no reader can mistake acknowledgment or a play call for
    /// rendered or audible timing, and it carries no owner data.
    func report() -> String {
        var lines = [
            "playback-stage-trace events=\(events.count) tokens=\(Set(events.map(\.token)).count) capacity=\(Self.capacity)",
            "limits: acknowledged=dispatch-boundary playCalled=call-boundary transcriptTail=post-play-call; not rendered-or-audible timing",
            "qualified synthetic target: acknowledged-to-playCalled p95<=\(Self.preAudioTargetMilliseconds)ms (backend call boundary only)"
        ]
        for summary in summaries() {
            lines.append(
                "wait \(summary.wait.rawValue) n=\(summary.sampleCount) medianUs=\(summary.medianMicros) "
                    + "p95Us=\(summary.p95Micros) maxUs=\(summary.maxMicros)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(max(0, components.seconds)) * 1_000_000_000
            + UInt64(max(0, components.attoseconds)) / 1_000_000_000
    }

    private static func micros(_ nanos: UInt64) -> Int { Int(nanos / 1_000) }

    private static func percentile(_ sorted: [UInt64], _ fraction: Double) -> UInt64 {
        let rank = max(1, Int((Double(sorted.count) * fraction).rounded(.up)))
        return sorted[min(sorted.count, rank) - 1]
    }
}
