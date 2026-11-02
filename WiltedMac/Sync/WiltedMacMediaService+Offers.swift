import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let offersLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacMedia")

// The available offers shown for every prepared Larder entry, and the transcripts published
// with the audio. Split from the request path so each file stays small.
extension WiltedMacMediaService {
    // MARK: - Available offers

    /// Learns the published offers once per launch, so neither a reconcile nor a request that
    /// arrives before one republishes or re-uploads what iCloud already holds.
    func seedOffers() async throws {
        guard !offersSeeded else { return }
        for offer in try await transport.mediaOffers() { offered[offer.entryID.rawValue] = offer }
        offersSeeded = true
    }

    func reconcile() async -> Bool {
        let prepared: [ItemID: WiltedMacReadyAudio]
        do {
            prepared = try await source.preparedQueuedAudio()
            try await seedOffers()
        } catch {
            lastFailure = String(describing: error)
            offersLog.error("Could not read the prepared Larder to publish offers: \(String(describing: error), privacy: .public)")
            return false
        }
        var desired: [String: LibraryMediaOffer] = [:]
        for (entryID, audio) in prepared where audio.byteCount <= Self.maximumByteCount && Self.fileSize(audio.fileURL) == audio.byteCount {
            desired[entryID.rawValue] = try? LibraryMediaOffer(
                entryID: entryID, revisionID: audio.revisionID, contentHash: audio.contentHash, byteCount: audio.byteCount,
                mediaType: audio.mediaType, durationSeconds: audio.durationSeconds, state: .available, preparation: audio.preparation
            )
        }
        availableOffers = desired
        var succeeded = true
        // A `notReady` offer answers a request rather than describing the Larder, so it is left alone.
        for (raw, offer) in offered.sorted(by: { $0.key < $1.key }) where desired[raw] == nil && offer.state != .notReady {
            do {
                await withdrawTranscript(for: raw)
                try await transport.publishMedia(offer: .notReady(entryID: offer.entryID), fileURL: URL(fileURLWithPath: "/dev/null"))
                dropBooks(for: raw)
                offered[raw] = .notReady(entryID: offer.entryID)
                offersLog.notice("Withdrew the offer for \(raw, privacy: .public): it left the Larder or is no longer prepared")
            } catch {
                succeeded = false
                offersLog.error("Could not withdraw the offer for \(raw, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        for (raw, want) in desired.sorted(by: { $0.key < $1.key }) {
            if let current = offered[raw], current.revisionID == want.revisionID,
               current.contentHash == want.contentHash, current.byteCount == want.byteCount,
               current.mediaType == want.mediaType, current.preparation == want.preparation {
                if current.state == .available { continue }
                if current.state == .ready, published[raw] == want.revisionID?.rawValue { continue }
            }
            do {
                try await transport.publishMedia(offer: want, fileURL: URL(fileURLWithPath: "/dev/null"))
                // A transcript belongs to its revision; a republish of the same revision keeps it.
                if publishedTranscripts[raw] != want.revisionID?.rawValue { await withdrawTranscript(for: raw) }
                dropBooks(for: raw)
                offered[raw] = want
            } catch {
                succeeded = false
                offersLog.error("Could not publish the available offer for \(raw, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        await publishMissingTranscripts(for: desired)
        do { try persist() } catch { offersLog.error("Could not save media accounting: \(String(describing: error), privacy: .public)") }
        if succeeded { lastFailure = nil }
        return succeeded
    }

    /// Publishes the transcript of every prepared Larder entry that has one and is not yet published
    /// at its revision, without a request. A phone that downloaded audio before transcripts existed
    /// never asks again, so this is the only way it gets one. Entries without a transcript are left
    /// alone; a failure is logged and retried by the next reconcile.
    private func publishMissingTranscripts(for desired: [String: LibraryMediaOffer]) async {
        var pending: [ItemID: RevisionID] = [:]
        for (raw, offer) in desired {
            guard let revisionID = offer.revisionID, publishedTranscripts[raw] != revisionID.rawValue else { continue }
            pending[offer.entryID] = revisionID
        }
        guard !pending.isEmpty else { return }
        let found: [ItemID: LibraryTranscript]
        do { found = try await source.transcripts(for: pending) } catch {
            offersLog.error("Could not read transcripts to publish: \(String(describing: error), privacy: .public)")
            return
        }
        for (entryID, transcript) in found.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard transcript.revisionID == pending[entryID] else { continue }
            do {
                try await transport.publishTranscript(transcript)
                publishedTranscripts[entryID.rawValue] = transcript.revisionID.rawValue
                offersLog.notice("Published the transcript for \(entryID.rawValue, privacy: .public) without a request")
            } catch {
                offersLog.error("Transcript for \(entryID.rawValue, privacy: .public) was not published: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Transcript (published with the audio, withdrawn with it)

    /// Publishes the Mac's transcript for `revisionID` once. A missing transcript, or a failure,
    /// never affects the audio: the transcript is retried by the next request for the entry.
    func publishTranscript(for entryID: ItemID, revisionID: RevisionID) async {
        if publishedTranscripts[entryID.rawValue] == revisionID.rawValue { return }
        do {
            guard let transcript = try await source.transcript(for: entryID, revisionID: revisionID) else {
                // A transcript left over from an older revision would never be asked for; drop it.
                await withdrawTranscript(for: entryID.rawValue)
                return
            }
            try await transport.publishTranscript(transcript)
            publishedTranscripts[entryID.rawValue] = revisionID.rawValue
            try persist()
            offersLog.notice("Published the transcript for \(entryID.rawValue, privacy: .public)")
        } catch {
            offersLog.error("Transcript for \(entryID.rawValue, privacy: .public) was not published: \(String(describing: error), privacy: .public)")
        }
    }

    /// Withdraws a held transcript, logging rather than failing; the audio flow must not depend on it.
    func withdrawTranscript(for entryID: String) async {
        do { try await removeTranscriptIfHeld(for: entryID) } catch {
            offersLog.error("Could not withdraw the transcript for \(entryID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func removeTranscriptIfHeld(for entryID: String) async throws {
        guard publishedTranscripts[entryID] != nil else { return }
        try await transport.removeTranscript(entryID: try ItemID(rawValue: entryID))
        publishedTranscripts[entryID] = nil
        try persist()
    }
}
