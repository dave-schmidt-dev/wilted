import SwiftUI
import WiltedLibrary

/// Settings > Ad feedback: the listener's ad-removal presses from both players. Every press counts
/// for the ad corpus with its default label as soon as it is filed; here it can be relabelled or
/// removed, and a removed one restored. `make ad-feedback-drafts` turns the counted ones into draft
/// ad-corpus labels. Shown once there is any feedback, so a library without it keeps its Settings
/// as they were.
struct WiltedMacAdFeedbackCard: View {
    let feedback: WiltedMacAdFeedbackController
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsRemoved = false

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
                        ForEach(feedback.counted) { entry in
                            WiltedMacAdFeedbackRow(feedback: feedback, entry: entry)
                            Divider()
                        }
                        if !feedback.removed.isEmpty {
                            DisclosureGroup("Removed (\(feedback.removed.count))", isExpanded: $showsRemoved) {
                                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                                    ForEach(feedback.removed) { entry in
                                        WiltedMacAdFeedbackRow(feedback: feedback, entry: entry)
                                    }
                                }
                                .padding(.top, WiltedTheme.Spacing.small)
                            }
                            .accessibilityIdentifier("wilted-ad-feedback-removed")
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
        let counted = feedback.counted.count
        let presses = counted == 1 ? "1 press counts" : "\(counted) presses count"
        return "\(presses) for the ad corpus (make ad-feedback-drafts). Change a label or remove a press here."
    }
}

/// One entry: what was pressed, where, about which cut, and its label and Remove or Restore.
struct WiltedMacAdFeedbackRow: View {
    let feedback: WiltedMacAdFeedbackController
    let entry: WiltedMacAdFeedbackEntry
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
        if entry.counts {
            Picker("Label", selection: Binding(
                get: { entry.effectiveLabel },
                set: { chosen in Task { await feedback.relabel(entry.id, as: chosen) } }
            )) {
                ForEach(WiltedMacAdFeedbackEntry.CorpusLabel.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("The corpus label this press becomes")
            .accessibilityIdentifier("wilted-ad-feedback-label")
            Button("Remove") { Task { await feedback.remove(entry.id) } }
                .help("Stop this press counting for the ad corpus")
                .accessibilityIdentifier("wilted-ad-feedback-remove")
        } else {
            Button("Restore") { Task { await feedback.restore(entry.id) } }
                .help("Count this press for the ad corpus again")
                .accessibilityIdentifier("wilted-ad-feedback-restore")
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
        return lines
    }
}
