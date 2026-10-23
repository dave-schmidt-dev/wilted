import Foundation
import Observation
import WiltedLibrary

/// The Mac's ad-feedback state: the review inbox's entries for Settings and the one
/// acknowledgement the Now Playing pane shows after a press, with its Undo.
@MainActor
@Observable
final class WiltedMacAdFeedbackController {
    /// What the pane says right after a press. `entryID` is what Undo removes.
    struct Acknowledgement: Equatable, Sendable {
        let entryID: String
        let kind: AdFeedbackKind
        let text: String
        /// False once the save failed; the text then says so and Undo is gone.
        let saved: Bool
    }

    private(set) var entries: [WiltedMacAdFeedbackEntry] = []
    private(set) var acknowledgement: Acknowledgement?
    /// True from a press until its entry is saved, so a second click cannot race it and Undo
    /// cannot run before there is anything to take back.
    private(set) var isSaving = false
    /// The inbox could not be written; shown in the review card.
    private(set) var saveFailure: String?

    @ObservationIgnored let inbox: WiltedMacAdFeedbackInbox
    @ObservationIgnored var acknowledgementDuration: Duration = .seconds(8)
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    init(inbox: WiltedMacAdFeedbackInbox) { self.inbox = inbox }

    var pending: [WiltedMacAdFeedbackEntry] { entries.filter { $0.review == .pending } }
    var reviewed: [WiltedMacAdFeedbackEntry] { entries.filter { $0.review != .pending } }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        entries = await inbox.all()
    }

    /// Shows the acknowledgement at once, before anything is read or saved. The caller ends the
    /// press with `pressFinished()` whatever happens.
    func acknowledge(entryID: String, kind: AdFeedbackKind, playedSeconds: Double) {
        isSaving = true
        show(Acknowledgement(
            entryID: entryID, kind: kind,
            text: "\(kind.title) marked at \(WiltedDuration.clock(playedSeconds))", saved: true))
    }

    func pressFinished() { isSaving = false }

    /// Files `entry`; true once it is in the inbox file (or already was).
    @discardableResult
    func file(_ entry: WiltedMacAdFeedbackEntry) async -> Bool {
        await loadIfNeeded()
        do {
            try await inbox.add(entry)
            entries = await inbox.all()
            saveFailure = nil
            return true
        } catch {
            saveFailure = "Feedback could not be saved: \(error.localizedDescription)"
            if acknowledgement?.entryID == entry.id {
                show(Acknowledgement(entryID: entry.id, kind: entry.kind,
                                     text: "\(entry.kind.title) was not saved", saved: false))
            }
            return false
        }
    }

    /// Takes back the press the acknowledgement names.
    func undo() async {
        guard !isSaving, let acknowledgement, acknowledgement.saved else { return }
        self.acknowledgement = nil
        clearTask?.cancel()
        await perform { try await $0.remove(id: acknowledgement.entryID) }
    }

    func accept(_ id: String, as label: WiltedMacAdFeedbackEntry.CorpusLabel) async {
        let at = now()
        await perform { try await $0.review(id: id, as: .accepted, label: label, at: at) }
    }

    func dismiss(_ id: String) async {
        let at = now()
        await perform { try await $0.review(id: id, as: .dismissed, label: nil, at: at) }
    }

    /// Returns a reviewed entry to the inbox.
    func reopen(_ id: String) async {
        let at = now()
        await perform { try await $0.review(id: id, as: .pending, label: nil, at: at) }
    }

    private func perform(_ change: (WiltedMacAdFeedbackInbox) async throws -> Void) async {
        await loadIfNeeded()
        do {
            try await change(inbox)
            saveFailure = nil
        } catch {
            saveFailure = "Feedback could not be saved: \(error.localizedDescription)"
        }
        entries = await inbox.all()
    }

    private func show(_ next: Acknowledgement) {
        acknowledgement = next
        clearTask?.cancel()
        let duration = acknowledgementDuration
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.acknowledgement == next else { return }
            self.acknowledgement = nil
        }
    }
}
