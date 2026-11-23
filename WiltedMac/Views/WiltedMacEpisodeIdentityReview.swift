import SwiftUI
import WiltedDomain
import WiltedProducer

/// One Larder row's request to open the duplicate-review sheet.
struct WiltedMacEpisodeIdentityReviewRequest: Identifiable, Equatable {
    let id = UUID()
    let anchorID: String

    /// Podcast rows alone can carry a same-feed duplicate; audiobooks and
    /// reports have no feed identity to review.
    static func isAvailable(for episode: WiltedMacEpisode) -> Bool {
        !episode.isAudiobook && episode.feedID != nil
    }
}

/// The Larder context menu's duplicate review: candidates, side-effect-free
/// comparison evidence, the consequences of the confirmation the owner made,
/// and an explicit reversal. Discovery never applies anything; only the
/// owner's confirmed pair and its prepared preview may. Every read is owned by
/// this sheet and generation-fenced in the model.
struct WiltedMacEpisodeIdentityReview: View {
    static let width: CGFloat = 620
    static let height: CGFloat = 520

    let model: WiltedMacModel
    let anchorID: String
    @State private var review: WiltedMacEpisodeIdentityReviewModel?
    @State private var readTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(model: WiltedMacModel, anchorID: String, review: WiltedMacEpisodeIdentityReviewModel? = nil) {
        self.model = model
        self.anchorID = anchorID
        _review = State(initialValue: review)
    }

    var body: some View {
        presentation
        .task {
            if review == nil {
                review = WiltedMacEpisodeIdentityReviewModel(model: model, anchorID: anchorID)
            }
            if let review, !review.hasLoadedOnce { await review.load() }
        }
        .onDisappear {
            readTask?.cancel()
            readTask = nil
            review?.invalidatePendingReads()
        }
    }

    /// Hosting this child installs its environment before the layout reads it.
    private var presentation: some View {
        WiltedMacEpisodeIdentityReviewLayout(
            review: review, runRead: runRead, dismiss: { dismiss() })
    }

    /// Every read the sheet starts is owned here, so dismissal and a newer
    /// read cancel the one before.
    private func runRead(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        readTask?.cancel()
        readTask = Task { await operation() }
    }

}

/// The shared sheet layout without read-task ownership. Its dynamic properties
/// are installed normally for both the real sheet and offscreen renders.
struct WiltedMacEpisodeIdentityReviewLayout: View {
    let review: WiltedMacEpisodeIdentityReviewModel?
    let runRead: (@escaping @MainActor @Sendable () async -> Void) -> Void
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    static func audioFingerprintLabel(_ hash: String?) -> String {
        hash.map { "Audio fingerprint \($0)" } ?? "No completed original download"
    }

    static func preparedVersionLabel(_ revision: RevisionID?) -> String {
        revision.map { "Prepared version \($0.rawValue)" } ?? "Not prepared"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(WiltedTheme.Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: WiltedMacEpisodeIdentityReview.width, idealWidth: WiltedMacEpisodeIdentityReview.width, minHeight: WiltedMacEpisodeIdentityReview.height, idealHeight: WiltedMacEpisodeIdentityReview.height)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-identity-review")
    }

    private var header: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Text("Review Possible Duplicate")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("wilted-identity-review-title")
            Spacer(minLength: WiltedTheme.Spacing.medium)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close duplicate review")
                .accessibilityIdentifier("wilted-identity-review-done")
        }
        .padding(.horizontal, WiltedTheme.Spacing.large)
        .padding(.vertical, WiltedTheme.Spacing.medium)
    }

    @ViewBuilder private var content: some View {
        if let review {
            switch review.stage {
            case .loading:
                loadingContent
            case .failed(let message):
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                    Text(message)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                    Button("Retry") { runRead { await review.load() } }
                        .accessibilityIdentifier("wilted-identity-review-retry")
                }
                .accessibilityIdentifier("wilted-identity-review-failed")
            case .ready:
                readyContent(review)
            }
        } else {
            loadingContent
        }
    }

    private var loadingContent: some View {
        VStack(spacing: WiltedTheme.Spacing.medium) {
            WiltedLoadingMotif()
            Text("Checking this episode for duplicates\u{2026}")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("wilted-identity-review-loading")
    }

    /// Immediate, named feedback for ready-state work: the existing motif
    /// plus what exactly is running, so disabled controls are never the only
    /// sign that something is happening.
    @ViewBuilder private func activityStatus(_ activity: WiltedMacEpisodeIdentityReviewModel.Activity) -> some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            WiltedLoadingMotif(size: .compact)
                .accessibilityHidden(true)
            Text(activity.statusText)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.statusText)
        .accessibilityIdentifier("wilted-identity-review-activity")
    }

    @ViewBuilder private func readyContent(_ review: WiltedMacEpisodeIdentityReviewModel) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(review.anchorTitle)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(2)
            if let message = review.errorMessage {
                Text(message)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-identity-review-error")
            }
            if let message = review.message {
                Text(message)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-identity-review-message")
            }
            if review.separateDecisionID != nil {
                Button("Undo Different episodes") { runRead { await review.undoSeparate() } }
                    .disabled(review.isBusy)
            }
            if let activity = review.activity {
                activityStatus(activity)
            }
            if let association = review.activeAssociation {
                reversalSection(review, association: association)
            } else {
                pairSection(review)
            }
        }
    }

    // MARK: - Pair comparison

    @ViewBuilder private func pairSection(_ review: WiltedMacEpisodeIdentityReviewModel) -> some View {
        if review.candidates.isEmpty {
            Text("No likely duplicate found.")
                .wiltedFont(.utility)
                .accessibilityIdentifier("wilted-identity-review-no-candidates")
        } else {
            Picker("Possible duplicate", selection: Binding(
                get: { review.visibleCandidateID },
                set: {
                    review.setVisibleCandidate($0)
                    runRead { await review.compareVisiblePair() }
                }
            )) {
                ForEach(review.candidates) { candidate in
                    Text(review.pickerLabel(for: candidate.id)).tag(Optional(candidate.id))
                }
            }
            .disabled(review.isBusy)
            .accessibilityIdentifier("wilted-identity-review-candidate")
            if let candidate = review.candidates.first(where: { $0.id == review.visibleCandidateID }) {
                Text(candidate.reason).wiltedFont(.utility)
            }
        }
        if let comparison = review.comparison {
            if review.approvalPreview == nil {
                HStack {
                    Button("Same episode") { runRead { await review.chooseSameEpisode() } }
                        .disabled(review.isBusy || !comparison.existingAssociationIDs.isEmpty)
                        .accessibilityIdentifier("wilted-identity-review-confirm-pair")
                    Button("Different episodes") { runRead { await review.keepSeparate() } }
                        .disabled(review.isBusy)
                        .accessibilityIdentifier("wilted-identity-review-different")
                }
            }
            DisclosureGroup("Details") {
                comparisonEvidence(comparison)
                if !comparison.ambiguities.isEmpty {
                    Text(ambiguitySummary(comparison)).wiltedFont(.utility)
                }
            }
        } else if review.errorMessage != nil && review.visibleCandidateID != nil {
            Button("Retry comparison") { runRead { await review.compareVisiblePair() } }
                .disabled(review.isBusy)
        }
        if review.approvalPreview != nil {
            Divider()
            Text(review.approvalSummary)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-identity-review-consequences")
            Button("Apply Association") { runRead { await review.applyAssociation() } }
                .disabled(review.isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wilted-identity-review-apply")
        }
    }

    @ViewBuilder private func comparisonEvidence(_ comparison: PodcastEpisodeAssociationComparison) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Comparison evidence")
                .wiltedFont(.utility)
                .accessibilityIdentifier("wilted-identity-review-evidence-title")
            memberEvidence(comparison.first)
            memberEvidence(comparison.second)
        }
        .accessibilityIdentifier("wilted-identity-review-evidence")
    }

    @ViewBuilder private func memberEvidence(_ member: PodcastEpisodeAssociationComparisonMember) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(member.title).wiltedFont(.body)
            Text("ID \(member.episodeID.rawValue)")
                .wiltedFont(.caption)
                .textSelection(.enabled)
            if let guid = member.rssGUID {
                Text("GUID \(guid)").wiltedFont(.caption).textSelection(.enabled)
            }
            Text(Self.audioFingerprintLabel(member.originalMediaContentHash))
                .wiltedFont(.caption)
                .textSelection(.enabled)
            Text(Self.preparedVersionLabel(member.preparedRevisionID))
                .wiltedFont(.caption)
            Text(progressLabel(member))
                .wiltedFont(.caption)
            Text(decisionLabel(member))
                .wiltedFont(.caption)
            Text(queueLabel(member))
                .wiltedFont(.caption)
        }
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressLabel(_ member: PodcastEpisodeAssociationComparisonMember) -> String {
        if let completedAt = member.listeningCompletedAt {
            return "Completed \(completedAt.date.formatted(date: .abbreviated, time: .shortened))"
        }
        if let position = member.playbackPositionSeconds {
            return "Playback position \(Int(position))s\(member.playbackCompleted ? ", completed" : "")"
        }
        return "No progress recorded"
    }

    private func decisionLabel(_ member: PodcastEpisodeAssociationComparisonMember) -> String {
        guard let decision = member.decision else { return "No decision" }
        let source = member.decisionSource.map { " (\($0.rawValue))" } ?? ""
        return "Decision: \(decision.rawValue)\(source)"
    }

    private func queueLabel(_ member: PodcastEpisodeAssociationComparisonMember) -> String {
        guard let position = member.queuePosition else { return "No queue slot" }
        return member.isQueueCurrent ? "Queue slot \(position), current" : "Queue slot \(position)"
    }

    private func ambiguitySummary(_ comparison: PodcastEpisodeAssociationComparison) -> String {
        var parts: [String] = []
        for ambiguity in comparison.ambiguities {
            switch ambiguity {
            case .metadataDiffers:
                parts.append("The pair does not match on title, date and duration.")
            case .otherMetadataCandidates:
                parts.append("\(comparison.otherCandidateIDs.count) other same-show episode(s) share this metadata.")
            case .crossFeedGUIDCandidate:
                parts.append("A publisher GUID also appears in another show; a feed move is never assumed.")
            case .existingAssociation:
                parts.append("An episode here already belongs to an active association.")
            case .conflictingManualChoices:
                parts.append("The pair's newest manual choices conflict; Keep is preserved.")
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Reversal

    @ViewBuilder private func reversalSection(
        _ review: WiltedMacEpisodeIdentityReviewModel,
        association: PodcastEpisodeAssociation
    ) -> some View {
        Text(association.confirmation.source == .feedMatch
             ? "Wilted matched these copies by show, title, publication time and length."
             : "These copies are linked as one episode.")
            .wiltedFont(.body)
            .accessibilityIdentifier("wilted-identity-review-active-association")
        if review.reversalPreview == nil {
            Button("Review Reversal\u{2026}") { runRead { await review.reviewReversal() } }
                .disabled(review.isBusy)
                .accessibilityIdentifier("wilted-identity-review-reversal")
        } else {
            Text(review.reversalSummary)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.stale, scheme: colorScheme))
                .accessibilityIdentifier("wilted-identity-review-reversal-consequences")
            HStack(spacing: WiltedTheme.Spacing.medium) {
                Button("Reverse Association") { runRead { await review.applyReversal() } }
                    .disabled(review.isBusy)
                    .accessibilityIdentifier("wilted-identity-review-apply-reversal")
                Button("Keep Association") { review.discardReversal() }
                    .disabled(review.isBusy)
                    .accessibilityIdentifier("wilted-identity-review-cancel-reversal")
            }
        }
    }
}
