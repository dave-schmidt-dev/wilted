import Foundation
import WiltedDomain
import WiltedLibrary

/// One ad-feedback press the phone has not sent yet. It waits out its undo window first, so Undo
/// takes it back before the Mac ever sees it.
struct PendingAdFeedback: Equatable, Sendable {
    let intent: LibraryIntent
    /// Not sent before this; a press restored after a relaunch is due at once.
    let sendAfter: Date
    /// True while the transport has it; Undo can no longer take it back.
    var isSending = false

    var id: String { intent.id }
}

/// What the full player says right after a press, while Undo can still take it back.
struct LibraryAdFeedbackAcknowledgement: Equatable, Sendable {
    let intentID: String
    let kind: AdFeedbackKind
    let text: String
}

/// The listener's ad-removal feedback from the full player: "Ad here", "Good cut" and "Not an ad",
/// sent to the Mac as `adFeedback` intents for its review inbox. The phone sends only what it heard
/// (entry, revision, position); the Mac maps it onto the original episode.
extension LibraryAppModel {
    /// How long a press can be taken back before it is sent.
    static let adFeedbackUndoSeconds: TimeInterval = 8
    /// Presses kept while the Mac cannot take them; more are refused rather than grow the outbox.
    static let maximumPendingAdFeedback = 200
    /// The name the Mac lists in `supportedIntentActions` once it files feedback.
    static let adFeedbackAction = "adFeedback"

    /// What the player offers at `position` of `item`: nothing for anything but a prepared podcast
    /// episode; every verdict while the Mac has not said where its cuts are (an older Mac, or a
    /// transcript published before it did); otherwise "Ad here" always, and "Good cut" and
    /// "Not an ad" only just after a cut (`AdFeedbackWindow`).
    func adFeedbackKinds(for item: LibraryPlayer.Item?, at position: Double) -> [AdFeedbackKind] {
        guard let item, let revisionID = item.feedbackRevisionID, !accountQuarantined else { return [] }
        guard let transcript = transcripts[item.entryID], transcript.revisionID == revisionID,
              let cuts = transcript.cuts else { return AdFeedbackKind.allCases }
        return AdCut.nearest(to: position, in: cuts) == nil ? [.adHere] : AdFeedbackKind.allCases
    }

    /// Records a press at `playedSeconds` of `item`, shows it with Undo at once, and sends it once
    /// the undo window has passed. It is in the outbox before anything else happens.
    func recordAdFeedback(_ kind: AdFeedbackKind, item: LibraryPlayer.Item, playedSeconds: Double) {
        guard let revisionID = item.feedbackRevisionID, !accountQuarantined else { return }
        let clock = LibraryClockFormat.duration(playedSeconds)
        guard adFeedback.count < Self.maximumPendingAdFeedback,
              let intent = try? LibraryIntent.adFeedback(
                  entryID: item.entryID, revisionID: revisionID, kind: kind,
                  playedSeconds: max(0, playedSeconds.isFinite ? playedSeconds : 0), deviceID: deviceID, createdAt: now())
        else {
            adFeedbackAcknowledgement = LibraryAdFeedbackAcknowledgement(
                intentID: "", kind: kind, text: "\(kind.title) was not saved")
            return
        }
        adFeedback.append(PendingAdFeedback(intent: intent, sendAfter: now().addingTimeInterval(Self.adFeedbackUndoSeconds)))
        let acknowledgement = LibraryAdFeedbackAcknowledgement(
            intentID: intent.id, kind: kind, text: "\(kind.title) marked at \(clock)")
        adFeedbackAcknowledgement = acknowledgement
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.adFeedbackUndoSeconds))
            guard let self else { return }
            if self.adFeedbackAcknowledgement == acknowledgement { self.adFeedbackAcknowledgement = nil }
            await self.sendDueAdFeedback()
        }
    }

    /// Takes back the press the acknowledgement names, unless it is already on its way.
    func undoAdFeedback() {
        guard let acknowledgement = adFeedbackAcknowledgement else { return }
        adFeedbackAcknowledgement = nil
        adFeedback.removeAll { $0.id == acknowledgement.intentID && !$0.isSending }
    }

    /// Sends every press whose undo window has passed, once the Mac lists `adFeedback`. Until it
    /// does (an older Mac) they stay in the outbox; one the transport refused is tried next round.
    func sendDueAdFeedback() async {
        guard !accountQuarantined, adFeedback.contains(where: isDue) else { return }
        if macAddActions?.contains(Self.adFeedbackAction) != true || macAddCheckFailed { await loadAddCapability() }
        guard macAddActions?.contains(Self.adFeedbackAction) == true else { return }
        for pending in adFeedback where isDue(pending) {
            guard !accountQuarantined,
                  let index = adFeedback.firstIndex(where: { $0.id == pending.id && isDue($0) }) else { continue }
            adFeedback[index].isSending = true
            if adFeedbackAcknowledgement?.intentID == pending.id { adFeedbackAcknowledgement = nil }
            let sent = (try? await transport.send(intent: pending.intent)) != nil
            if sent {
                adFeedback.removeAll { $0.id == pending.id }
            } else if let index = adFeedback.firstIndex(where: { $0.id == pending.id }) {
                adFeedback[index].isSending = false
            }
        }
    }

    func discardAdFeedbackAfterAccountChange() {
        adFeedback = []
        adFeedbackAcknowledgement = nil
    }

    private func isDue(_ pending: PendingAdFeedback) -> Bool { !pending.isSending && now() >= pending.sendAfter }
}
