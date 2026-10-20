import Foundation

/// Tracks the journal writes one run has started.
///
/// A progress callback must never block the worker, so each write is enqueued
/// rather than awaited where it is reported. Recording them synchronously here
/// means the run can drain the exact set before announcing its outcome, so the
/// journal a reader sees afterwards is complete rather than still arriving.
final class JournalWrites: @unchecked Sendable {
    /// Stages the worker re-emits on a timer, listed from the worker sources:
    /// - "ads.model.wait" (gpu_admission.py)
    /// - "ads.cut.render.progress" (cue_timing.py)
    /// - "audio.silence.detect.progress" (silence_trim.py)
    /// - "transcript.glossary.progress" (glossary.py)
    /// - "summary.wait" (transcript_summary.py)
    /// - "summary.model.verify" (transcript_summary.py)
    /// - "summary.load" (transcript_summary.py)
    /// - "summary.generate" (transcript_summary.py)
    static let heartbeatStages: Set<String> = [
        "ads.model.wait",
        "ads.cut.render.progress",
        "audio.silence.detect.progress",
        "transcript.glossary.progress",
        "summary.wait",
        "summary.model.verify",
        "summary.load",
        "summary.generate",
    ]

    private let lock = NSLock()
    private var pending: [Task<Void, Never>] = []
    private var nextOrdinal = 0

    func eventID(for stage: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if Self.heartbeatStages.contains(stage) {
            return "\(stage)#heartbeat"
        }
        nextOrdinal += 1
        return "\(stage)#\(nextOrdinal)"
    }

    func track(_ write: Task<Void, Never>) {
        lock.lock(); pending.append(write); lock.unlock()
    }

    func drain() async {
        for write in take() { await write.value }
    }

    private func take() -> [Task<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        let writes = pending
        pending = []
        return writes
    }
}
