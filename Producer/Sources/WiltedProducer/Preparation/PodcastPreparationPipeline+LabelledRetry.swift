import CryptoKit
import Foundation
import WiltedDomain

extension PodcastPreparationPipeline {
    /// The running generation of a first-time preparation, which a labelling failure may park.
    struct LabelledDeferralContext: Sendable {
        let episodeID: ItemID
        let attempt: PreparationAttemptIdentity
        /// Waits for the run's pending journal writes. The store refuses a write for a
        /// generation that is no longer running, so they must land before the ticket is deferred.
        let flushJournal: @Sendable () async -> Void
    }

    /// The verified transcript cues of one labelled run, with the bytes their digest covers.
    struct LabelledTranscript: Sendable {
        let cues: [LabellerCue]
        let cuesData: Data
        let digest: String
        let durationSeconds: Double
    }

    /// A labelling request that produced no usable answer, with the transcript it was asked about.
    struct LabelledAttemptFailure: Error {
        let failure: LabellerFailure
        let transcript: LabelledTranscript
    }

    /// What one deferral saves so the next attempt can skip the transcript stage.
    private struct LabellerCueFile: Codable {
        var cues: Data
        var digest: String
        var durationSeconds: Double
    }

    /// Only a first-time run with an acknowledged generation may be deferred.
    func labelledDeferral(
        episodeID: ItemID, attempt: PreparationAttemptIdentity?, writes: JournalWrites
    ) -> LabelledDeferralContext? {
        attempt.map { LabelledDeferralContext(episodeID: episodeID, attempt: $0, flushJournal: { await writes.drain() }) }
    }

    // MARK: Wait or stop

    /// Asks the retry policy what a failure (or the daily cap) leads to. A wait parks the
    /// ticket and throws ``PodcastPreparationError/labellerWaiting(until:kind:)``; a stop
    /// returns its reason. Without a `deferral` nothing waits: a wait becomes the wait-limit stop.
    func settleLabellerHold(
        _ trigger: LabellerRetryTrigger,
        transcript: LabelledTranscript?,
        deferral: LabelledDeferralContext?,
        services: PodcastLabellingServices,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) async throws -> LabellerStopReason {
        let preferences = services.preferences
        var ticket: WorkTicket?
        if let deferral {
            ticket = try? await store.workTicket(kind: .podcastPreparation, subjectID: deferral.episodeID.rawValue)
        }
        let moment = now()
        let decision = LabellerRetryPolicy.decide(LabellerRetryInput(
            trigger: trigger, deferralCount: ticket?.deferralCount ?? 0,
            firstDeferredAt: ticket?.firstDeferredAt?.date, now: moment,
            waitLimit: preferences.waitLimit, pausedSince: preferences.providerPausedSince))
        switch decision {
        case .stop(let reason):
            if reason == .waitLimit, deferral != nil, trigger == .failure(.temporary) {
                preferences.recordProviderWaitLimitStop(at: moment)
            }
            return reason
        case .wait(let until, let reason):
            // Nothing to park: a provider wait ends as the wait limit, the cap as the cap.
            guard let deferral else { return trigger == .dailyCap ? .dailyCap : .waitLimit }
            if let transcript { saveCueFile(transcript, for: deferral) }
            let kind: String
            switch trigger {
            case .failure(let failure): kind = failure.kind
            case .dailyCap: kind = LabellerStopReason.dailyCap.kind
            }
            // Reported and flushed first: once deferred, the store refuses this generation's journal rows.
            onStatus(PodcastPreparationProgress(
                stage: "ads.label.wait",
                detail: "Waiting to ask the labelling provider again",
                evidence: try? PreparationEvidence(kind: "labeller-wait", fields: [
                    "failureKind": kind,
                    "nextAttemptAt": until.formatted(.iso8601),
                    "deferral": String((ticket?.deferralCount ?? 0) + 1),
                ])))
            await deferral.flushJournal()
            guard try await store.deferRunningWorkTicket(
                subjectID: deferral.episodeID.rawValue, requestSequence: deferral.attempt.requestSequence,
                attemptCount: deferral.attempt.attemptCount, until: Timestamp(until), reason: reason,
                at: Timestamp(moment)) != nil else { throw CancellationError() }
            throw PodcastPreparationError.labellerWaiting(until: until, kind: kind)
        }
    }

    /// Reports the stop and returns the sentence the whole-original warning carries.
    func stopLabelledPath(
        _ reason: LabellerStopReason,
        onStatus: @escaping @Sendable (PodcastPreparationProgress) -> Void
    ) -> String {
        let sentence = reason.sentence(formatTime: { $0.formatted(date: .omitted, time: .shortened) })
        onStatus(PodcastPreparationProgress(
            stage: "ads.label.stop",
            detail: sentence,
            evidence: try? PreparationEvidence(kind: "labeller-stop", fields: ["kind": reason.kind])))
        return sentence
    }

    // MARK: Cue file

    private var cueDirectory: URL { workDirectory.appendingPathComponent("labeller-cues", isDirectory: true) }

    private static func cueFileStem(_ episodeID: ItemID) -> String {
        String(episodeID.rawValue.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": Character(scalar)
            default: "_"
            }
        })
    }

    private func cueFileURL(for deferral: LabelledDeferralContext) -> URL {
        cueDirectory.appendingPathComponent(
            "\(Self.cueFileStem(deferral.episodeID)).\(deferral.attempt.requestSequence).json")
    }

    /// Saves the cue list so the next attempt of this request skips the transcript stage.
    /// Failing to save only costs that stage later, so it never fails the run.
    func saveCueFile(_ transcript: LabelledTranscript, for deferral: LabelledDeferralContext) {
        let file = LabellerCueFile(
            cues: transcript.cuesData, digest: transcript.digest, durationSeconds: transcript.durationSeconds)
        guard let data = try? JSONEncoder().encode(file) else { return }
        let url = cueFileURL(for: deferral)
        let manager = FileManager.default
        try? manager.createDirectory(at: cueDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The saved cues of this request, when the file is there and its cue bytes match the digest
    /// it recorded. A file that does not match is removed.
    func loadCueFile(for deferral: LabelledDeferralContext) -> LabelledTranscript? {
        let url = cueFileURL(for: deferral)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let file = try? JSONDecoder().decode(LabellerCueFile.self, from: data),
              file.durationSeconds > 0,
              let cues = try? Self.decodeLabellerCues(file.cues, expectedDigest: file.digest) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return LabelledTranscript(
            cues: cues, cuesData: file.cues, digest: file.digest, durationSeconds: file.durationSeconds)
    }

    /// Deletes this request's cue file; any ending but a wait leaves none behind.
    func removeCueFile(for deferral: LabelledDeferralContext) {
        try? FileManager.default.removeItem(at: cueFileURL(for: deferral))
    }

    /// Deletes this episode's cue files from other requests: a newer request supersedes them.
    func removeStaleCueFiles(for deferral: LabelledDeferralContext) {
        let stem = Self.cueFileStem(deferral.episodeID)
        let current = cueFileURL(for: deferral).lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cueDirectory.path)) ?? []
        for name in names where name != current && name.hasSuffix(".json") {
            let base = String(name.dropLast(".json".count))
            guard let dot = base.lastIndex(of: "."), String(base[..<dot]) == stem else { continue }
            try? FileManager.default.removeItem(at: cueDirectory.appendingPathComponent(name))
        }
    }
}
