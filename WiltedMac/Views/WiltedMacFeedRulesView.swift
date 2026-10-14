import SwiftUI
import WiltedDomain
import WiltedProducer

// MARK: - Sheet

/// One feed's match rules in a resizable sheet: the ordered editor beside a
/// live preview of what the rules decide for the feed's episodes, with Apply
/// to existing and Undo. The feed-settings popover opens it.
struct WiltedMacFeedRulesView: View {
    /// The sheet's smallest size. It opens a little larger and can grow.
    static let width: CGFloat = 720
    static let height: CGFloat = 560
    /// The editor column's widest; the results take the rest.
    static let editorMaxWidth: CGFloat = 440

    let editor: WiltedMacFeedRulesEditor
    let subscription: WiltedMacSubscription
    let resolved: EffectiveFeedAutomationPolicy
    var dismiss: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView { editorColumn.padding(WiltedTheme.Spacing.large) }
                    .frame(minWidth: 340, maxWidth: Self.editorMaxWidth, maxHeight: .infinity)
                Divider()
                WiltedMacFeedRulesPreview(editor: editor, subscription: subscription)
                    .padding(WiltedTheme.Spacing.large)
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(
            minWidth: Self.width, idealWidth: 820, maxWidth: .infinity,
            minHeight: Self.height, idealHeight: 640, maxHeight: .infinity
        )
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feed-rules-\(subscription.id)")
        // Opening previews at once; each edit previews again once editing pauses.
        .task {
            editor.loadIfNeeded()
            editor.preview()
        }
    }

    private var header: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Text("Match rules for \(subscription.title)")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("wilted-feed-rules-title")
            Spacer(minLength: WiltedTheme.Spacing.medium)
            Button("Done", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close match rules for \(subscription.title)")
                .accessibilityIdentifier("wilted-feed-rules-done")
        }
        .padding(.horizontal, WiltedTheme.Spacing.large)
        .padding(.vertical, WiltedTheme.Spacing.medium)
    }

    private var editorColumn: some View {
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
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text("The first rule that matches decides. Matching ignores case.")
            regexGuidance
            if !resolved.autoKeep {
                Text("Auto keep is Off for this feed, so only Skip rules decide until it is On.")
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

    /// What the pattern boxes accept. The examples stay behind a disclosure so
    /// the editor column still fits the sheet's minimum height.
    private var regexGuidance: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text("Patterns are case insensitive regular expressions.")
                Text("Plain text matches a substring: MMA")
                Text("Alternatives: MMA|boxing")
                Text("Whole word: \\bMMA\\b")
                Text("Literal metacharacters need a backslash to escape: \\. \\( \\[")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, WiltedTheme.Spacing.xSmall)
            .accessibilityIdentifier("wilted-feed-rules-regex-help-detail")
        } label: {
            Text("Regex help")
        }
        .accessibilityIdentifier("wilted-feed-rules-regex-help")
    }
}

// MARK: - Entry from the settings popover

/// The row in the feed-settings popover that opens the rules sheet.
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
            HStack(spacing: WiltedTheme.Spacing.small) {
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
        .wiltedCard(colorScheme, padding: WiltedTheme.Spacing.medium)
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
        .help(label)
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
