import SwiftUI
import WiltedDomain
import WiltedProducer

// MARK: - Live preview and Apply

/// What the rules decide for the feed's episodes, beside the editor. It
/// previews again whenever the rules change; only Apply to existing and Undo
/// write anything.
struct WiltedMacFeedRulesPreview: View {
    let editor: WiltedMacFeedRulesEditor
    let subscription: WiltedMacSubscription
    @Environment(\.colorScheme) private var colorScheme
    /// The last plan, shown dimmed while an edit's preview is on its way so
    /// the rows do not vanish at every keystroke. Apply never uses it.
    @State private var lastPlan: FeedRulesPlan?
    @State private var isConfirmingApply = false

    /// How many episodes' downloaded audio Apply would delete, counting every
    /// episode Apply commits, not only the rows shown. Undo brings the episodes
    /// back but not their audio, so Apply asks first when this is not 0.
    static func audioDeletions(in plan: FeedRulesPlan?) -> Int {
        plan?.audioDeletions ?? 0
    }

    /// An edit cleared the plan and its preview has not finished yet.
    private var isUpdating: Bool { editor.plan == nil && editor.message == nil && !editor.hasProblems }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            actions
            status
            if let plan = editor.plan ?? (isUpdating ? lastPlan : nil) {
                ScrollView { results(plan).padding(.trailing, WiltedTheme.Spacing.small) }
                    .opacity(editor.plan == nil ? 0.5 : 1)
            }
        }
        .onChange(of: editor.plan, initial: true) { _, plan in
            if let plan { lastPlan = plan }
        }
        .onChange(of: editor.message) { _, message in
            if message != nil { lastPlan = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-rules-preview-section")
    }

    private var actions: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Text("Rule results")
                .wiltedFont(.body)
                .fontWeight(.semibold)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            if editor.undo != nil {
                Button("Undo") { editor.undoLastApply() }
                    .disabled(editor.isBusy)
                    .accessibilityLabel("Undo applied match rules for \(subscription.title)")
                    .accessibilityIdentifier("wilted-feed-rules-undo")
            }
            Button("Apply to existing") {
                if Self.audioDeletions(in: editor.plan) > 0 { isConfirmingApply = true } else { editor.apply() }
            }
            .buttonStyle(.borderedProminent)
            .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            .disabled(!editor.canApply)
            .fixedSize()
            .accessibilityLabel("Apply match rules to existing episodes of \(subscription.title)")
            .accessibilityIdentifier("wilted-feed-rules-apply")
        }
        .confirmationDialog(
            "Apply match rules to \(subscription.title)?", isPresented: $isConfirmingApply, titleVisibility: .visible
        ) {
            Button("Apply and Delete Audio", role: .destructive) { editor.apply() }
                .accessibilityLabel("Apply match rules and delete downloaded audio")
                .accessibilityIdentifier("wilted-feed-rules-apply-confirm")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel applying match rules")
                .accessibilityIdentifier("wilted-feed-rules-apply-cancel")
        } message: {
            let count = Self.audioDeletions(in: editor.plan)
            Text("This deletes the downloaded audio of \(count) episode\(count == 1 ? "" : "s"). Undo brings the episodes back, not their audio.")
        }
    }

    /// One line, always the same height, so the rows below never jump.
    private var status: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            if let progress = editor.progress {
                ProgressView().controlSize(.small)
                Text(progress.total == 0 ? "Checking episodes…" : "Checked \(progress.done) of \(progress.total) episodes")
                    .accessibilityLabel("Checked \(progress.done) of \(progress.total) episodes")
                    .accessibilityIdentifier("wilted-feed-rules-progress")
                Button("Cancel") { editor.cancel() }
                    .controlSize(.small)
                    .accessibilityLabel("Cancel checking rules for \(subscription.title)")
                    .accessibilityIdentifier("wilted-feed-rules-cancel")
            } else if editor.isBusy {
                // Only Undo works without a count.
                ProgressView().controlSize(.small)
                Text("Undoing…")
            } else if isUpdating {
                ProgressView().controlSize(.small)
                Text("Checking episodes…")
                    .accessibilityIdentifier("wilted-feed-rules-updating")
            } else if let message = editor.message {
                Text(message)
                    .accessibilityIdentifier("wilted-feed-rules-message")
            } else if editor.hasProblems {
                Text("Results appear when every rule is valid.")
                    .accessibilityIdentifier("wilted-feed-rules-waiting")
            }
        }
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .frame(minHeight: 22, alignment: .leading)
    }

    private func results(_ plan: FeedRulesPlan) -> some View {
        let counts = plan.counts
        return VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            if plan.rows.isEmpty {
                Text("This feed has no current episodes to check.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            group(
                "Undecided episodes", "\(counts.keeps) to keep, \(counts.skips) to skip",
                rows: plan.rows.filter { $0.outcome == .keep || $0.outcome == .skip }, identifier: "undecided"
            )
            group(
                "Automatic decisions", "\(counts.keepToSkip) Keep to Skip, \(counts.skipToKeep) Skip to Keep",
                rows: plan.rows.filter { $0.outcome == .keepToSkip || $0.outcome == .skipToKeep }, identifier: "automatic"
            )
            group(
                "Left as they are",
                "\(counts.protectedManual) yours, \(counts.heldStarted) started, \(counts.waiting) held by the kept limit",
                rows: plan.rows.filter { !$0.outcome.isChange }, identifier: "unchanged"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-rules-results")
    }

    private func group(_ title: String, _ summary: String, rows: [FeedRulesPreviewRow], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text("\(title): \(summary)")
                .wiltedFont(.utility)
                .fontWeight(.semibold)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-feed-rules-summary-\(identifier)")
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        WiltedMacFeedRulesPreviewRow(
                            row: row, source: editor.episodeInfoSource(forRowID: row.episodeID))
                    }
                }
                .wiltedCard(colorScheme, padding: WiltedTheme.Spacing.medium)
            }
        }
    }
}

// MARK: - One episode

/// One episode's verdict and what Apply would do. A row Apply would change
/// leads with an arrow; a retired or finished one with the history clock,
/// because its verdict is shown but never acted on. The title itself is the
/// button: it opens the same episode info popover every other episode-name
/// surface uses, while the row keeps its verdict and its identity.
private struct WiltedMacFeedRulesPreviewRow: View {
    let row: FeedRulesPreviewRow
    let source: WiltedMacEpisodeInfoSource
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingNotes = false

    private var symbol: String {
        if row.outcome.isChange { return "arrow.right.circle.fill" }
        return row.outcome == .history ? "clock.arrow.circlepath" : "minus.circle"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(WiltedTheme.color(row.outcome.isChange ? .progress : .secondaryText, scheme: colorScheme))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                WiltedMacEpisodeNotesTitle(
                    id: row.episodeID, title: row.title, prefix: "wilted-feed-rules",
                    isPresented: $isShowingNotes, titleLineLimit: 2,
                    attributedTitle: row.highlight?.title.map { highlighted($0) }
                ) {
                    WiltedMacEpisodeInfoPopoverContent(
                        id: row.episodeID, seed: nil, prefix: "wilted-feed-rules",
                        source: source, initialSection: .notes, actions: { EmptyView() })
                }
                Text("\(row.verdict) · \(row.outcome.explanation)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                if let notes = row.highlight?.notes {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Match in notes")
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        Text(highlighted(notes))
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("wilted-feed-rules-notes-\(row.episodeID)")
                    }
                }
                if row.deletesDownloadedAudio {
                    Label("Deletes downloaded audio", systemImage: "trash")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, WiltedTheme.Spacing.xSmall)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.title): \(row.verdict) · \(row.outcome.explanation)")
        .accessibilityIdentifier("wilted-feed-rules-row-\(row.episodeID)")
    }

    /// The matched text with the theme's highlight, so a match reads without
    /// relying on color alone.
    private func highlighted(_ match: WiltedMacRuleMatchHighlight.TextMatch) -> AttributedString {
        match.attributed(scheme: colorScheme)
    }
}

// MARK: - Highlighting

extension WiltedMacRuleMatchHighlight.TextMatch {
    /// The text with each matched range made bold and backed by the theme's
    /// highlight background. The plan found the ranges; this only draws them.
    func attributed(scheme: ColorScheme) -> AttributedString {
        var attributed = AttributedString(text)
        let highlight = WiltedTheme.color(.steel, scheme: scheme)
        let ink = WiltedTheme.color(.primaryText, scheme: scheme)
        for range in ranges {
            guard range.lowerBound >= 0, range.lowerBound < range.upperBound,
                  range.upperBound <= text.count else { continue }
            let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
            let upper = text.index(lower, offsetBy: range.upperBound - range.lowerBound)
            guard let attributedRange = Range(lower..<upper, in: attributed) else { continue }
            attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
            attributed[attributedRange].backgroundColor = highlight
            attributed[attributedRange].foregroundColor = ink
        }
        return attributed
    }
}

// MARK: - Wording

extension FeedRulesPreviewRow {
    /// The rule engine's verdict, with the rule that gave it.
    var verdict: String {
        let rule = ruleNumber.map { " (rule \($0))" } ?? ""
        switch result {
        case .keep: return "Keep\(rule)"
        case .skip: return "Skip\(rule)"
        case .noMatch: return outcome == .keep ? "No match (Kept by Auto keep)" : "No match"
        case .timedOut: return "Timed out\(rule)"
        }
    }
}

extension FeedRulesOutcome {
    /// What Apply to existing would do, in the words the preview shows.
    var explanation: String {
        switch self {
        case .keep: "will keep"
        case .skip: "will skip"
        case .keepToSkip: "Keep becomes Skip"
        case .skipToKeep: "Skip becomes Keep"
        case .unchanged: "no change"
        case .protectedManual: "your choice, left as is"
        case .heldStarted: "started, left as is"
        case .waiting: "held by the kept limit"
        case .unfinished: "rule timed out, left as is"
        case .inactive: "Auto keep is Off"
        case .history: "retired or finished, left as is"
        }
    }
}
