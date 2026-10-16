import Foundation
import Observation
import WiltedDomain
import WiltedProducer

/// The owner's review of a possible same-feed duplicate, opened from a Larder
/// row. Discovery only lists same-show candidates and side-effect-free
/// comparison evidence; a typed confirmation exists only after the owner
/// picks an exact pair and representative, and Apply only accepts the preview
/// that confirmation captured. Reversal is equally explicit.
///
/// The visible picker selection is the one authoritative selection: changing
/// it synchronously voids any comparison, typed confirmation and preview,
/// supersedes in-flight reads and releases the busy state so the exact new
/// selection must be compared and confirmed again. Every read and preview is
/// generation-fenced, and an apply or reversal that is superseded or
/// cancelled before its store write begins is abandoned; once a store write
/// has committed, the result is reported and the parent library projection is
/// refreshed even if the sheet moved on.
@MainActor @Observable
final class WiltedMacEpisodeIdentityReviewModel {
    enum Stage: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// The one piece of ready-state work currently in flight. Drives the
    /// inline loading motif, the disabled controls and the busy ownership.
    enum Activity: Equatable {
        case comparingPair
        case preparingPreview
        case applyingAssociation
        case preparingReversal
        case reversingAssociation

        var statusText: String {
            switch self {
            case .comparingPair: return "Comparing the two episodes\u{2026}"
            case .preparingPreview: return "Preparing the pair preview\u{2026}"
            case .applyingAssociation: return "Applying the association\u{2026}"
            case .preparingReversal: return "Preparing the reversal preview\u{2026}"
            case .reversingAssociation: return "Reversing the association\u{2026}"
            }
        }
    }

    struct Candidate: Identifiable, Equatable {
        let id: String
        let title: String
        let rssGUID: String?
        let publishedAt: Date?
        let durationSeconds: TimeInterval?
    }

    /// The pair the owner explicitly compared: anchor first, candidate second.
    struct PairSelection: Equatable {
        let first: String
        let second: String
        let representative: String
    }

    static let confirmationRequiredMessage =
        "Choose the exact pair and representative, compare them, then confirm the pair before applying."
    static let reversalRequiredMessage =
        "Review the reversal and its per-member warnings before reversing."
    static let staleReviewMessage =
        "The library changed since this review was prepared. Nothing was applied. Review again."
    static let storeUnavailableMessage = "The library is still opening. Try again in a moment."

    let anchorID: String
    private let model: WiltedMacModel
    private let now: @MainActor () -> Date

    private(set) var hasLoadedOnce = false
    private(set) var stage: Stage = .loading
    private(set) var anchorTitle = ""
    private(set) var candidates: [Candidate] = []
    private(set) var activeAssociation: PodcastEpisodeAssociation?
    /// The visible picker selection; the only selection the owner can see.
    private(set) var visibleCandidateID: String?
    private(set) var visibleRepresentativeID: String?
    /// The pair the owner explicitly compared and confirmed for preview.
    private(set) var selection: PairSelection?
    private(set) var comparison: PodcastEpisodeAssociationComparison?
    private(set) var approvalPreview: PodcastEpisodeAssociationPreview?
    private(set) var reversalPreview: PodcastEpisodeAssociationReversalPreview?
    private(set) var message: String?
    private(set) var errorMessage: String?
    private(set) var activity: Activity?

    var isBusy: Bool { activity != nil }

    /// Test seam for pausing a read; nil in production.
    @ObservationIgnored var readHookForTesting: (@Sendable () async -> Void)?
    /// Test seam for pausing a commit before its store write; nil in production.
    @ObservationIgnored var applyHookForTesting: (@Sendable () async -> Void)?
    /// Test seam invoked once a store write has committed; nil in production.
    @ObservationIgnored var commitLandedHookForTesting: (@Sendable () async -> Void)?
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var activeOperationToken: UUID?
    @ObservationIgnored private var titles: [String: String] = [:]

    init(model: WiltedMacModel, anchorID: String, now: @escaping @MainActor () -> Date = { Date() }) {
        self.model = model
        self.anchorID = anchorID
        self.now = now
    }

    var candidateIDs: [String] { [anchorID] + candidates.map(\.id) }

    /// The selection the visible controls currently show, as a pair.
    var visiblePair: PairSelection? {
        guard let candidate = visibleCandidateID, let representative = visibleRepresentativeID else {
            return nil
        }
        return PairSelection(first: anchorID, second: candidate, representative: representative)
    }

    // MARK: - Generation and busy ownership

    /// Invalidates every in-flight read and releases the busy owner. Called on
    /// reload, on any visible selection change and when the sheet closes; no
    /// read may publish state after the generation it captured has moved on.
    func invalidatePendingReads() {
        readGeneration += 1
        activeOperationToken = nil
        activity = nil
    }

    private func beginOperation(_ activity: Activity) -> UUID? {
        guard activeOperationToken == nil else { return nil }
        let token = UUID()
        activeOperationToken = token
        self.activity = activity
        return token
    }

    /// Only the operation that owns the current token may clear the spinner;
    /// an older completion can never clear a newer operation's busy state.
    private func endOperation(_ token: UUID) {
        guard activeOperationToken == token else { return }
        activeOperationToken = nil
        activity = nil
    }

    private func isCurrent(_ generation: Int, _ token: UUID) -> Bool {
        generation == readGeneration && activeOperationToken == token && !Task.isCancelled
    }

    // MARK: - Visible selection

    /// The owner changed the candidate picker. Synchronously voids the old
    /// comparison and typed confirmation and resets the representative.
    func setVisibleCandidate(_ id: String?) {
        guard id != visibleCandidateID else { return }
        visibleCandidateID = id
        visibleRepresentativeID = anchorID
        invalidateSelectionReview()
    }

    /// The owner changed the representative picker.
    func setVisibleRepresentative(_ id: String?) {
        guard id != visibleRepresentativeID else { return }
        visibleRepresentativeID = id
        invalidateSelectionReview()
    }

    private func invalidateSelectionReview() {
        invalidatePendingReads()
        selection = nil
        comparison = nil
        approvalPreview = nil
        errorMessage = nil
        message = nil
    }

    // MARK: - Loading

    /// Reads the anchor, its same-show candidates and any active association.
    /// The stage is `.loading` before the first await, a superseded read can
    /// never publish, and a cancelled read restores what the sheet already had.
    func load() async {
        invalidatePendingReads()
        let generation = readGeneration
        hasLoadedOnce = true
        let previousStage = stage
        stage = .loading
        errorMessage = nil
        message = nil
        await performLoad(generation: generation, fallbackStage: previousStage)
    }

    private func performLoad(generation: Int, fallbackStage: Stage) async {
        guard let store = model.store else {
            stage = .failed(Self.storeUnavailableMessage)
            return
        }
        do {
            if let hook = readHookForTesting { await hook() }
            try Task.checkCancellation()
            guard generation == readGeneration else { return }
            guard let anchorItemID = try? ItemID(rawValue: anchorID),
                  let anchor = try await store.podcastEpisode(for: anchorItemID) else {
                stage = .failed("This episode is no longer in the library.")
                return
            }
            let episodes = try await store.podcastEpisodes(for: anchor.feedID)
            let associations = try await store.episodeAssociations()
            try Task.checkCancellation()
            guard generation == readGeneration else { return }
            anchorTitle = anchor.title
            let anchorCandidate = Candidate(
                id: anchor.itemID.rawValue, title: anchor.title, rssGUID: anchor.rssGUID,
                publishedAt: anchor.publishedTime?.date, durationSeconds: anchor.durationSeconds
            )
            candidates = episodes
                .filter { $0.itemID.rawValue != anchorID }
                .map { Candidate(
                    id: $0.itemID.rawValue, title: $0.title, rssGUID: $0.rssGUID,
                    publishedAt: $0.publishedTime?.date, durationSeconds: $0.durationSeconds
                ) }
                .sorted { left, right in
                    let leftDate = left.publishedAt ?? .distantPast
                    let rightDate = right.publishedAt ?? .distantPast
                    return leftDate == rightDate ? left.title < right.title : leftDate > rightDate
                }
            titles = Self.memberLabels(for: [anchorCandidate] + candidates)
            activeAssociation = associations.first { association in
                association.memberIDs.contains { $0.rawValue == anchorID }
            }
            visibleCandidateID = nil
            visibleRepresentativeID = anchorID
            selection = nil
            comparison = nil
            approvalPreview = nil
            reversalPreview = nil
            errorMessage = nil
            stage = .ready
        } catch is CancellationError {
            guard generation == readGeneration else { return }
            // A cancelled read publishes nothing: a sheet that already had
            // content keeps it, an empty one offers Retry.
            stage = fallbackStage == .loading
                ? .failed("The library read was cancelled. Try again.")
                : fallbackStage
        } catch {
            guard generation == readGeneration else { return }
            stage = .failed(Self.message(for: error))
        }
    }

    /// The same unambiguous member label appears in pickers and consequences.
    func pickerLabel(for id: String) -> String { titles[id] ?? id }

    // MARK: - Explicit pair selection and captured preview

    /// The owner's explicit pair and representative choice. Loads only
    /// side-effect-free comparison evidence; no confirmation exists yet.
    /// The submitted pair becomes the authoritative visible selection.
    func selectPair(first: String, second: String, representative: String) async {
        guard first != second, representative == first || representative == second else {
            errorMessage = "Choose two different episodes and which one represents the pair."
            return
        }
        guard first == anchorID, candidateIDs.contains(second) else {
            errorMessage = "Only episodes from this show can be reviewed as a pair."
            return
        }
        guard let store = model.store else {
            errorMessage = Self.storeUnavailableMessage
            return
        }
        guard let firstID = try? ItemID(rawValue: first), let secondID = try? ItemID(rawValue: second) else {
            errorMessage = "Choose two different episodes and which one represents the pair."
            return
        }
        guard let token = beginOperation(.comparingPair) else { return }
        defer { endOperation(token) }
        readGeneration += 1
        let generation = readGeneration
        let chosen = PairSelection(first: first, second: second, representative: representative)
        visibleCandidateID = second
        visibleRepresentativeID = representative
        selection = chosen
        comparison = nil
        approvalPreview = nil
        errorMessage = nil
        message = nil
        do {
            if let hook = readHookForTesting { await hook() }
            try Task.checkCancellation()
            let result = try await store.podcastEpisodeAssociationComparison(first: firstID, second: secondID)
            guard isCurrent(generation, token) else { return }
            comparison = result
        } catch is CancellationError {
            // Superseded reads and invalidated operations publish nothing.
        } catch {
            guard isCurrent(generation, token) else { return }
            errorMessage = Self.message(for: error)
        }
    }

    /// The owner's explicit confirmation creates the typed confirmation only
    /// now, and only the store's captured preview can be applied later.
    func reviewPair() async {
        guard let token = beginOperation(.preparingPreview) else { return }
        defer { endOperation(token) }
        guard let selection, let comparison, selection == visiblePair else {
            errorMessage = Self.confirmationRequiredMessage
            return
        }
        guard let store = model.store else {
            errorMessage = Self.storeUnavailableMessage
            return
        }
        guard let firstID = try? ItemID(rawValue: selection.first),
              let secondID = try? ItemID(rawValue: selection.second),
              let representative = try? ItemID(rawValue: selection.representative) else {
            errorMessage = Self.confirmationRequiredMessage
            return
        }
        let generation = readGeneration
        approvalPreview = nil
        errorMessage = nil
        let confirmation = PodcastEpisodePairConfirmation(
            confirmationID: UUID(), feedID: comparison.feedID,
            first: firstID, second: secondID, confirmedAt: Timestamp(now())
        )
        do {
            if let hook = readHookForTesting { await hook() }
            try Task.checkCancellation()
            let preview = try await store.previewEpisodeAssociation(
                confirming: confirmation, representativeID: representative
            )
            guard isCurrent(generation, token) else { return }
            approvalPreview = preview
        } catch is CancellationError {
        } catch {
            guard isCurrent(generation, token) else { return }
            errorMessage = Self.message(for: error)
        }
    }

    /// Applies nothing without an explicitly confirmed pair and the preview
    /// that confirmation captured. A stale capture is discarded so the owner
    /// must review again.
    func applyAssociation() async {
        guard let token = beginOperation(.applyingAssociation) else { return }
        defer { endOperation(token) }
        guard let preview = approvalPreview, let selection, selection == visiblePair else {
            errorMessage = Self.confirmationRequiredMessage
            return
        }
        guard let store = model.store else {
            errorMessage = Self.storeUnavailableMessage
            return
        }
        let generation = readGeneration
        do {
            if let hook = applyHookForTesting { await hook() }
            // A commit superseded or cancelled before its store write begins
            // is abandoned: nothing is applied and nothing is claimed.
            guard isCurrent(generation, token) else { return }
            let association = try await store.applyEpisodeAssociation(preview)
            if let hook = commitLandedHookForTesting { await hook() }
            // The write is durable now: refresh the parent projection and ask
            // the existing debounced publisher for a pass even if this sheet
            // was dismissed or superseded while the write ran.
            await refreshParentLibraryProjection()
            if isCurrent(generation, token) {
                await load()
            }
            message = "Associated \(association.memberIDs.count) episodes. Each source episode keeps its own media, progress, decisions and queue slot."
        } catch is CancellationError {
            // Cancelled before the store write began; nothing was applied.
        } catch {
            guard isCurrent(generation, token) else { return }
            if Self.isStale(error) {
                await load()
                approvalPreview = nil
                errorMessage = Self.staleReviewMessage
            } else {
                errorMessage = Self.message(for: error)
            }
        }
    }

    // MARK: - Explicit reversal

    /// Prepares the reversal preview; the owner sees each member's loss before
    /// anything is reversed.
    func reviewReversal() async {
        guard let token = beginOperation(.preparingReversal) else { return }
        defer { endOperation(token) }
        guard let association = activeAssociation else {
            errorMessage = Self.reversalRequiredMessage
            return
        }
        guard let store = model.store else {
            errorMessage = Self.storeUnavailableMessage
            return
        }
        let generation = readGeneration
        reversalPreview = nil
        errorMessage = nil
        do {
            if let hook = readHookForTesting { await hook() }
            try Task.checkCancellation()
            let preview = try await store.previewEpisodeAssociationReversal(
                association.associationID, expectedVersion: association.version
            )
            guard isCurrent(generation, token) else { return }
            reversalPreview = preview
        } catch is CancellationError {
        } catch {
            guard isCurrent(generation, token) else { return }
            if Self.isStale(error) {
                await load()
                errorMessage = Self.staleReviewMessage
            } else {
                errorMessage = Self.message(for: error)
            }
        }
    }

    /// Reverses only the reviewed preview. A stale one is discarded.
    func applyReversal() async {
        guard let token = beginOperation(.reversingAssociation) else { return }
        defer { endOperation(token) }
        guard let preview = reversalPreview else {
            errorMessage = Self.reversalRequiredMessage
            return
        }
        guard let store = model.store else {
            errorMessage = Self.storeUnavailableMessage
            return
        }
        let generation = readGeneration
        do {
            if let hook = applyHookForTesting { await hook() }
            guard isCurrent(generation, token) else { return }
            _ = try await store.reverseEpisodeAssociation(preview)
            if let hook = commitLandedHookForTesting { await hook() }
            await refreshParentLibraryProjection()
            if isCurrent(generation, token) {
                await load()
            }
            message = "Association reversed. Each episode keeps its current progress, decisions and queue slot."
        } catch is CancellationError {
            // Cancelled before the store write began; nothing was reversed.
        } catch {
            guard isCurrent(generation, token) else { return }
            if Self.isStale(error) {
                await load()
                reversalPreview = nil
                errorMessage = Self.staleReviewMessage
            } else {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func discardReversal() { reversalPreview = nil }

    /// The parent model's existing read, then the existing debounced library
    /// publisher: the Larder's own projection and publication follow a
    /// committed association or reversal, not only this sheet's reload.
    private func refreshParentLibraryProjection() async {
        await model.reloadLibraryRows()
        model.librarySyncController?.requestPublish()
    }

    // MARK: - Approval and reversal text

    /// The Apply text, derived only from the captured approval consequences
    /// the store will validate again on apply.
    var approvalSummary: String {
        Self.approvalSummary(for: approvalPreview?.approvalConsequences, titles: titles)
    }

    var reversalSummary: String {
        Self.reversalSummary(for: reversalPreview?.consequences, titles: titles)
    }
}
