import SwiftUI
import WiltedProducer

/// One editable rule row. Values stay strings, as the store keeps them; `makeRule` is the only
/// place that validates, so an invalid draft is explained instead of silently dropped.
struct WiltedMacPlaylistRuleDraft: Identifiable, Equatable {
    let id = UUID()
    var field: PlaylistRuleField = .played
    var comparator: PlaylistComparator = .is
    var value = PlaylistPlayedState.unplayed.rawValue

    init() {}
    init(_ rule: PlaylistRule) { field = rule.field; comparator = rule.comparator; value = rule.value }

    static func comparators(for field: PlaylistRuleField) -> [PlaylistComparator] {
        switch field {
        case .feed, .kind, .played: [.is, .isNot]
        case .length: [.shorterThan, .longerThan]
        case .published: [.withinDays, .before, .after]
        }
    }

    /// Switching field resets the comparator and value to ones the new field accepts.
    mutating func setField(_ new: PlaylistRuleField, firstFeedID: String?) {
        field = new
        comparator = Self.comparators(for: new)[0]
        switch new {
        case .feed: value = firstFeedID ?? ""
        case .kind: value = "podcast.episode"
        case .played: value = PlaylistPlayedState.unplayed.rawValue
        case .length: value = "30"
        case .published: value = "7"
        }
    }

    mutating func setComparator(_ new: PlaylistComparator) {
        comparator = new
        guard field == .published else { return }
        value = new == .withinDays ? "7" : PlaylistRule.dateValue(Date())
    }

    func makeRule() throws -> PlaylistRule {
        try PlaylistRule(field: field, comparator: comparator, value: value)
    }

    static func name(_ field: PlaylistRuleField) -> String {
        switch field {
        case .feed: "Feed"
        case .played: "Played"
        case .length: "Length"
        case .published: "Published"
        case .kind: "Kind"
        }
    }

    static func name(_ comparator: PlaylistComparator) -> String {
        switch comparator {
        case .is: "is"
        case .isNot: "is not"
        case .shorterThan: "is shorter than"
        case .longerThan: "is longer than"
        case .withinDays: "is within the last"
        case .before: "is before"
        case .after: "is after"
        }
    }
}

/// The rule editor for an automatic playlist: match all or any, then an ordered list of rules.
/// Save validates every row; on a failure nothing is written and the drafts stay as typed.
struct WiltedMacPlaylistRulesSheet: View {
    @Bindable var model: WiltedMacModel
    let playlist: Playlist
    @State private var drafts: [WiltedMacPlaylistRuleDraft]
    @State private var matchAll: Bool
    @State private var errorText: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    init(model: WiltedMacModel, playlist: Playlist) {
        self.model = model
        self.playlist = playlist
        _drafts = State(initialValue: (model.playlists.rules[playlist.id] ?? []).map(WiltedMacPlaylistRuleDraft.init))
        _matchAll = State(initialValue: playlist.matchAll)
    }

    static let width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Rules for \(playlist.name)")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityAddTraits(.isHeader)
            Picker("Include items that match", selection: $matchAll) {
                Text("All of the rules").tag(true)
                Text("Any of the rules").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("wilted-playlist-rules-match")
            if drafts.isEmpty {
                Text("No rules yet. A playlist without rules is empty.")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                ruleRow(index: index, draft: draft)
            }
            Button {
                drafts.append(WiltedMacPlaylistRuleDraft())
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .accessibilityIdentifier("wilted-playlist-rules-add")
            if let errorText {
                Text(errorText)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-playlist-rules-error")
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("wilted-playlist-rules-save")
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: Self.width)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-playlist-rules-sheet")
    }

    private func binding(_ id: UUID) -> Binding<WiltedMacPlaylistRuleDraft> {
        Binding(
            get: { drafts.first { $0.id == id } ?? WiltedMacPlaylistRuleDraft() },
            set: { new in if let i = drafts.firstIndex(where: { $0.id == id }) { drafts[i] = new } })
    }

    private func ruleRow(index: Int, draft: WiltedMacPlaylistRuleDraft) -> some View {
        let draftBinding = binding(draft.id)
        let number = index + 1
        return HStack(spacing: WiltedTheme.Spacing.small) {
            Picker("Field", selection: Binding(
                get: { draftBinding.wrappedValue.field },
                set: { draftBinding.wrappedValue.setField($0, firstFeedID: model.subscriptions.first?.id) })
            ) {
                ForEach(PlaylistRuleField.allCases, id: \.self) { Text(WiltedMacPlaylistRuleDraft.name($0)).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Rule \(number) field")
            Picker("Comparison", selection: Binding(
                get: { draftBinding.wrappedValue.comparator },
                set: { draftBinding.wrappedValue.setComparator($0) })
            ) {
                ForEach(WiltedMacPlaylistRuleDraft.comparators(for: draft.field), id: \.self) {
                    Text(WiltedMacPlaylistRuleDraft.name($0)).tag($0)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Rule \(number) comparison")
            valueControl(draftBinding, number: number)
            Button {
                drafts.removeAll { $0.id == draft.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove rule \(number)")
            .accessibilityLabel("Remove rule \(number)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-playlist-rule-\(number)")
    }

    @ViewBuilder
    private func valueControl(_ draft: Binding<WiltedMacPlaylistRuleDraft>, number: Int) -> some View {
        let label = "Rule \(number) value"
        switch draft.wrappedValue.field {
        case .feed:
            Picker("Feed", selection: draft.value) {
                ForEach(model.subscriptions) { Text($0.title).tag($0.id) }
            }
            .labelsHidden().accessibilityLabel(label)
        case .kind:
            Picker("Kind", selection: draft.value) {
                Text("Podcast episode").tag("podcast.episode")
                Text("Article").tag("article")
                Text("Audiobook").tag("audiobook")
            }
            .labelsHidden().accessibilityLabel(label)
        case .played:
            Picker("Played", selection: draft.value) {
                Text("Unplayed").tag(PlaylistPlayedState.unplayed.rawValue)
                Text("In progress").tag(PlaylistPlayedState.inProgress.rawValue)
                Text("Played").tag(PlaylistPlayedState.played.rawValue)
            }
            .labelsHidden().accessibilityLabel(label)
        case .length:
            HStack(spacing: 4) {
                TextField("Minutes", text: draft.value).frame(width: 64).accessibilityLabel(label)
                Text("min").foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
        case .published:
            if draft.wrappedValue.comparator == .withinDays {
                HStack(spacing: 4) {
                    TextField("Days", text: draft.value).frame(width: 64).accessibilityLabel(label)
                    Text("days").foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
            } else {
                DatePicker("Date", selection: Binding(
                    get: { ISO8601DateFormatter().date(from: draft.wrappedValue.value) ?? Date() },
                    set: { draft.wrappedValue.value = PlaylistRule.dateValue($0) }),
                    displayedComponents: .date)
                    .labelsHidden().accessibilityLabel(label)
            }
        }
    }

    private func save() {
        var rules: [PlaylistRule] = []
        for (index, draft) in drafts.enumerated() {
            do { rules.append(try draft.makeRule()) } catch {
                errorText = "Rule \(index + 1) is not valid: check its value."
                return
            }
        }
        Task {
            if await model.savePlaylistRules(playlist.id, rules: rules, matchAll: matchAll) {
                dismiss()
            } else {
                errorText = "The rules could not be saved."
            }
        }
    }
}
