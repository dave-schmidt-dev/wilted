import SwiftUI
import WiltedLibrary

/// Settings > Ad feedback: the review inbox for the listener's ad-removal presses from both players.
/// Each waiting entry is accepted with a corpus label or dismissed; reviewed ones can be reopened.
/// `make ad-feedback-drafts` turns the accepted ones into draft ad-corpus labels. Shown once there
/// is any feedback, so a library without it keeps its Settings as they were.
struct WiltedMacAdFeedbackCard: View {
    let feedback: WiltedMacAdFeedbackController
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsReviewed = false

    var body: some View {
        Group {
            if !feedback.entries.isEmpty || feedback.saveFailure != nil {
                WiltedSettingsCard(title: "Ad feedback") {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                        Text(summary)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .accessibilityIdentifier("wilted-ad-feedback-summary")
                        if let failure = feedback.saveFailure {
                            Text(failure)
                                .wiltedFont(.utility)
                                .foregroundStyle(WiltedStatusTone.failure.color(colorScheme))
                                .accessibilityIdentifier("wilted-ad-feedback-failure")
                        }
                        ForEach(feedback.pending) { entry in
                            WiltedMacAdFeedbackRow(feedback: feedback, entry: entry)
                            Divider()
                        }
                        if !feedback.reviewed.isEmpty {
                            DisclosureGroup("Reviewed (\(feedback.reviewed.count))", isExpanded: $showsReviewed) {
                                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                                    ForEach(feedback.reviewed) { entry in
                                        WiltedMacAdFeedbackRow(feedback: feedback, entry: entry)
                                    }
                                }
                                .padding(.top, WiltedTheme.Spacing.small)
                            }
                            .accessibilityIdentifier("wilted-ad-feedback-reviewed")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("wilted-ad-feedback-card")
            }
        }
        .task { await feedback.loadIfNeeded() }
    }

    private var summary: String {
        let waiting = feedback.pending.count
        let accepted = feedback.entries.filter { $0.review == .accepted }.count
        let head = waiting == 0 ? "Nothing waiting for review." : "\(waiting) waiting for review."
        return accepted == 0 ? head : "\(head) \(accepted) accepted for the ad corpus (make ad-feedback-drafts)."
    }
}

/// One entry: what was pressed, where, about which cut, and the review actions beside it.
struct WiltedMacAdFeedbackRow: View {
    let feedback: WiltedMacAdFeedbackController
    let entry: WiltedMacAdFeedbackEntry
    @State private var label: WiltedMacAdFeedbackEntry.CorpusLabel?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
            Image(systemName: entry.kind.systemImage)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text("\(entry.kind.title) · \(entry.episodeTitle ?? entry.itemID)")
                    .wiltedFont(.body)
                    .lineLimit(1)
                ForEach(Self.details(for: entry), id: \.self) { line in
                    Text(line)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-ad-feedback-row-\(entry.id)")
    }

    @ViewBuilder private var actions: some View {
        if entry.review == .pending {
            Picker("Label", selection: Binding(
                get: { label ?? .suggested(for: entry.kind) }, set: { label = $0 }
            )) {
                ForEach(WiltedMacAdFeedbackEntry.CorpusLabel.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("The corpus label this entry becomes")
            .accessibilityIdentifier("wilted-ad-feedback-label")
            Button("Accept") {
                let chosen = label ?? .suggested(for: entry.kind)
                Task { await feedback.accept(entry.id, as: chosen) }
            }
            .help("Keep this entry for the ad corpus with the chosen label")
            .accessibilityIdentifier("wilted-ad-feedback-accept")
            Button("Dismiss") { Task { await feedback.dismiss(entry.id) } }
                .help("Leave this entry out of the ad corpus")
                .accessibilityIdentifier("wilted-ad-feedback-dismiss")
        } else {
            Button("Reopen") { Task { await feedback.reopen(entry.id) } }
                .help("Return this entry to the review list")
                .accessibilityIdentifier("wilted-ad-feedback-reopen")
        }
    }

    /// The facts under the title, in words; no transcript text is ever shown or kept.
    static func details(for entry: WiltedMacAdFeedbackEntry) -> [String] {
        var lines: [String] = []
        let show = entry.showTitle.map { "\($0) · " } ?? ""
        let device = entry.source == .phone ? "iPhone" : "Mac"
        lines.append("\(show)\(device), \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
        var position = "At \(WiltedDuration.clock(entry.playedSeconds)) of the prepared audio"
        switch entry.mapping {
        case .mapped: position += entry.originalSeconds.map { ", \(WiltedDuration.clock($0)) in the original" } ?? ""
        case .clamped: position += entry.originalSeconds.map { ", after the last kept audio (\(WiltedDuration.clock($0)))" } ?? ""
        case .unmapped: position += ", original time unknown"
        }
        lines.append(position)
        if let cut = entry.nearestCut {
            lines.append("Cut \(cut.label): \(WiltedDuration.clock(cut.originalStartSeconds))–\(WiltedDuration.clock(cut.originalEndSeconds)) in the original")
        }
        switch entry.review {
        case .pending: break
        case .accepted: lines.append("Accepted as \(entry.effectiveLabel.title)")
        case .dismissed: lines.append("Dismissed")
        }
        return lines
    }
}
