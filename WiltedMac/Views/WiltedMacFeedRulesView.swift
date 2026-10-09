import SwiftUI
import WiltedDomain
import WiltedProducer

// MARK: - Page

/// One feed's match rules: an ordered editor, a preview of what they decide for
/// the feed's current episodes, and Apply to existing with Undo. It replaces the
/// feed-settings page inside the same popover.
struct WiltedMacFeedRulesView: View {
    static let width: CGFloat = 460

    let editor: WiltedMacFeedRulesEditor
    let subscription: WiltedMacSubscription
    let resolved: EffectiveFeedAutomationPolicy
    let back: () -> Void
    var dismiss: () -> Void = {}
    /// How tall the rules and preview may grow before they scroll. Nil never
    /// scrolls, which is how a headless render sees all of it.
    var maximumHeight: CGFloat? = 460
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            header
            if let maximumHeight {
                ScrollView { content.padding(.trailing, WiltedTheme.Spacing.small) }
                    .frame(maxHeight: maximumHeight)
            } else {
                content
            }
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-rules-\(subscription.id)")
        .task { editor.loadIfNeeded() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            notes
            ForEach(Array(editor.drafts.enumerated()), id: \.element.id) { index, draft in
                WiltedMacFeedRuleRow(
                    editor: editor, draft: draft, number: index + 1, count: editor.drafts.count,
                    feedTitle: subscription.title
                )
            }
            Button {
                editor.addRule()
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .accessibilityLabel("Add a match rule for \(subscription.title)")
            .accessibilityIdentifier("wilted-feed-rules-add")
            Divider()
            WiltedMacFeedRulesPreview(editor: editor, subscription: subscription)
        }
    }

    private var header: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Button(action: back) {
                Label("Feed settings", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Feed settings")
            .accessibilityLabel("Back to feed settings for \(subscription.title)")
            .accessibilityIdentifier("wilted-feed-rules-back")
            Text("Match rules")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Spacer()
            Button("Done", action: dismiss)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Close feed settings for \(subscription.title)")
                .accessibilityIdentifier("wilted-feed-rules-done")
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text("The first rule that matches decides. Matching ignores case.")
            if !resolved.autoKeep {
                Text("Auto keep is Off for this feed, so rules decide nothing until it is On.")
                    .accessibilityIdentifier("wilted-feed-rules-inactive")
            }
            if editor.hasProblems {
                Text("Fix the rules marked below to save changes.")
                    .accessibilityIdentifier("wilted-feed-rules-unsaved")
            }
        }
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Entry from the settings page

/// The row on the feed-settings page that opens the rules page.
struct WiltedMacFeedRulesEntry: View {
    let editor: WiltedMacFeedRulesEditor
    let subscription: WiltedMacSubscription
    let isEnabled: Bool
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: open) {
            HStack {
                Text("Match rules")
                Spacer()
                Text(editor.ruleCount == 0 ? "None" : "\(editor.ruleCount) rule\(editor.ruleCount == 1 ? "" : "s")")
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
        }
        .wiltedFont(.body)
        .padding(.vertical, WiltedTheme.Spacing.small)
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Edit match rules for \(subscription.title)")
        .accessibilityIdentifier("wilted-feed-policy-rules")
    }
}

// MARK: - One rule

private struct WiltedMacFeedRuleRow: View {
    let editor: WiltedMacFeedRulesEditor
    let draft: WiltedMacFeedRulesEditor.Draft
    let number: Int
    let count: Int
    let feedTitle: String
    @Environment(\.colorScheme) private var colorScheme

    private var problems: WiltedMacFeedRulesEditor.Problems { editor.problems(for: draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text("Rule \(number)").wiltedFont(.body)
                Toggle("On", isOn: binding(\.isEnabled))
                    .accessibilityLabel("Rule \(number) enabled for \(feedTitle)")
                    .accessibilityIdentifier("wilted-feed-rule-enabled-\(number)")
                Picker("Action", selection: binding(\.action)) {
                    Text("Keep").tag(EpisodeMatchAction.keep)
                    Text("Skip").tag(EpisodeMatchAction.skip)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Rule \(number) action for \(feedTitle)")
                .accessibilityIdentifier("wilted-feed-rule-action-\(number)")
                Picker("Match in", selection: binding(\.field)) {
                    Text("Title").tag(EpisodeMatchField.title)
                    Text("Notes").tag(EpisodeMatchField.notes)
                    Text("Title or notes").tag(EpisodeMatchField.both)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Rule \(number) searches in, for \(feedTitle)")
                .accessibilityIdentifier("wilted-feed-rule-field-\(number)")
                Spacer(minLength: 0)
                iconButton("chevron.up", "Move rule \(number) up", "up", enabled: number > 1) {
                    editor.move(draft.id, by: -1)
                }
                iconButton("chevron.down", "Move rule \(number) down", "down", enabled: number < count) {
                    editor.move(draft.id, by: 1)
                }
                iconButton("trash", "Delete rule \(number)", "delete", enabled: true) {
                    editor.delete(draft.id)
                }
            }
            patternField(
                "Matches (text or regular expression)", text: binding(\.include), error: problems.include,
                label: "Rule \(number) pattern to match for \(feedTitle)", identifier: "include"
            )
            patternField(
                "Unless it also matches (optional)", text: binding(\.exclude), error: problems.exclude,
                label: "Rule \(number) exception pattern for \(feedTitle)", identifier: "exclude"
            )
        }
        .padding(WiltedTheme.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(WiltedTheme.color(.secondaryText, scheme: colorScheme).opacity(0.3))
        )
        .opacity(draft.isEnabled ? 1 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-rule-\(number)")
    }

    private func iconButton(
        _ symbol: String, _ label: String, _ identifier: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel("\(label) for \(feedTitle)")
        .accessibilityIdentifier("wilted-feed-rule-\(identifier)-\(number)")
    }

    private func patternField(
        _ prompt: String, text: Binding<String>, error: String?, label: String, identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text(identifier == "include" ? "Matches" : "Unless it also matches")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .accessibilityIdentifier("wilted-feed-rule-\(identifier)-\(number)")
            if let error {
                Text(error)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-feed-rule-\(identifier)-error-\(number)")
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<WiltedMacFeedRulesEditor.Draft, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in editor.update(draft.id) { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Preview and Apply

private struct WiltedMacFeedRulesPreview: View {
    let editor: WiltedMacFeedRulesEditor
    let subscription: WiltedMacSubscription
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Rule results")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            HStack(spacing: WiltedTheme.Spacing.small) {
                Button("Preview") { editor.preview() }
                    .disabled(!editor.canRun)
                    .accessibilityLabel("Preview match rules for \(subscription.title)")
                    .accessibilityIdentifier("wilted-feed-rules-preview")
                Button("Apply to existing") { editor.apply() }
                    .disabled(!editor.canApply)
                    .accessibilityLabel("Apply match rules to existing episodes of \(subscription.title)")
                    .accessibilityIdentifier("wilted-feed-rules-apply")
                if editor.isBusy, editor.progress != nil {
                    Button("Cancel") { editor.cancel() }
                        .accessibilityLabel("Cancel checking rules for \(subscription.title)")
                        .accessibilityIdentifier("wilted-feed-rules-cancel")
                }
            }
            if let progress = editor.progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                    Text("Checked \(progress.done) of \(progress.total) episodes")
                        .wiltedFont(.utility)
                }
                .accessibilityLabel("Checked \(progress.done) of \(progress.total) episodes")
                .accessibilityIdentifier("wilted-feed-rules-progress")
            }
            if let message = editor.message {
                Text(message)
                    .wiltedFont(.utility)
                    .accessibilityIdentifier("wilted-feed-rules-message")
            }
            if editor.undo != nil {
                Button("Undo") { editor.undoLastApply() }
                    .disabled(editor.isBusy)
                    .accessibilityLabel("Undo applied match rules for \(subscription.title)")
                    .accessibilityIdentifier("wilted-feed-rules-undo")
            }
            if let plan = editor.plan {
                results(plan)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-rules-preview-section")
    }

    private func results(_ plan: FeedRulesPlan) -> some View {
        let counts = plan.counts
        return VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            if plan.rows.isEmpty {
                Text("This feed has no current episodes to check.")
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
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-rules-results")
    }

    @ViewBuilder
    private func group(_ title: String, _ summary: String, rows: [FeedRulesPreviewRow], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text("\(title): \(summary)")
                .fontWeight(.semibold)
                .accessibilityIdentifier("wilted-feed-rules-summary-\(identifier)")
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title).lineLimit(2)
                    Text("\(row.verdict) · \(row.outcome.explanation)")
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wilted-feed-rules-row-\(row.episodeID)")
            }
        }
    }
}

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
        }
    }
}
