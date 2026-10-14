import SwiftUI
import WiltedProducer

/// The rule editor for an automatic playlist: stable numbered rules, the match expression built
/// from those numbers with AND, OR, NOT and parentheses, and a live preview of the episodes the
/// exact compiled rule matches. Save validates the same editor the preview evaluated; on a failure
/// nothing is written and the drafts stay as typed.
struct WiltedMacPlaylistRulesSheet: View {
    @Bindable var model: WiltedMacModel
    let playlist: Playlist
    @State private var editor: WiltedMacPlaylistRulesEditor
    @State private var preview: WiltedMacPlaylistRulePreview?
    @State private var previewGeneration: UInt64 = 0
    @State private var isSaving = false
    @State private var errorText: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    init(model: WiltedMacModel, playlist: Playlist) {
        self.model = model
        self.playlist = playlist
        _editor = State(initialValue: WiltedMacPlaylistRulesEditor(
            playlist: playlist, storedRules: model.playlists.rules[playlist.id] ?? []))
    }

    static let width: CGFloat = 520
    /// The pause after the last edit before a live preview runs.
    static let livePreviewDelay: Duration = .milliseconds(150)

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Rules for \(playlist.name)")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityAddTraits(.isHeader)
            HStack {
                Text("Expression presets")
                    .wiltedFont(.utility)
                Button("All (AND)") {
                    editor.applyPreset(matchAll: true)
                    preview = nil
                }
                Button("Any (OR)") {
                    editor.applyPreset(matchAll: false)
                    preview = nil
                }
            }
            .help("Replace the expression with all or any of the numbered rules")
            .disabled(isSaving)
            .accessibilityIdentifier("wilted-playlist-rules-match")
            rulesList
                .disabled(isSaving)
            Button {
                editor.addRule()
                preview = nil
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .accessibilityIdentifier("wilted-playlist-rules-add")
            .disabled(isSaving)
            expressionField
                .disabled(isSaving)
            previewArea
            if let text = model.playlists.ruleReadErrors[playlist.id] ?? editor.validationProblem ?? errorText {
                Text(text)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-playlist-rules-error")
            }
            Divider()
            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving rules")
                        .accessibilityIdentifier("wilted-playlist-rules-saving")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.playlists.ruleReadErrors[playlist.id] != nil || editor.validationProblem != nil || isSaving
                        || model.playlists.pending[playlist.id] != nil)
                    .accessibilityIdentifier("wilted-playlist-rules-save")
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: Self.width)
        .frame(minHeight: 420, idealHeight: 540, maxHeight: 680)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-playlist-rules-sheet")
        .task(id: previewKey) { await refreshPreview() }
        .onDisappear {
            isSaving = false
            previewGeneration &+= 1
        }
    }

    /// The debounced preview depends on the editor's text and on the library the preview reads.
    private var previewKey: String {
        editor.previewSignature + "\u{1F}" + model.playlistPreviewFingerprint
    }

    private var rulesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                if editor.leaves.isEmpty {
                    Text("No rules yet. A playlist without rules is empty.")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                ForEach(editor.leaves) { draft in
                    ruleRow(draft)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 88, maxHeight: 220)
        .accessibilityIdentifier("wilted-playlist-rules-list")
    }

    private var expressionField: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text("Match expression")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            TextField("e.g. (1 OR 2) AND NOT 3", text: Binding(
                get: { editor.expression },
                set: { editor.editExpression($0); preview = nil }))
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Match expression")
                .accessibilityIdentifier("wilted-playlist-rule-expression")
            Text("Rules are numbered above; combine them with AND, OR, NOT and parentheses.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            if !editor.formulaIsGenerated, !editor.unusedRuleNumbers.isEmpty {
                Text("Not used by the expression: rule "
                    + editor.unusedRuleNumbers.map(String.init).joined(separator: ", ") + ".")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-playlist-rule-unused")
            }
        }
    }

    private var previewArea: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            HStack {
                Text("Live preview")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Spacer()
                if let preview {
                    Text("\(preview.matchCount) matching")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-playlist-rule-preview-count")
                }
            }
            if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                        if preview.entries.isEmpty {
                            Text("Nothing matches these rules.")
                                .wiltedFont(.body)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                .accessibilityIdentifier("wilted-playlist-rule-preview-empty")
                        }
                        ForEach(preview.entries) { entry in
                            WiltedMacPlaylistPreviewRow(model: model, entryID: entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 40, maxHeight: 160)
            } else if editor.validationProblem == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Previewing matches")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-playlist-rule-preview")
    }

    private func draftBinding(_ id: UUID) -> Binding<WiltedMacPlaylistRuleDraft> {
        Binding(
            get: { editor.leaves.first { $0.id == id } ?? WiltedMacPlaylistRuleDraft() },
            set: { new in
                editor.updateLeaf(id) { $0 = new }
                preview = nil
            })
    }

    private func ruleRow(_ draft: WiltedMacPlaylistRuleDraft) -> some View {
        let binding = draftBinding(draft.id)
        let number = draft.number
        return HStack(spacing: WiltedTheme.Spacing.small) {
            Text("\(number)")
                .wiltedFont(.utility)
                .monospacedDigit()
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .frame(minWidth: 20, alignment: .trailing)
                .accessibilityHidden(true)
            Picker("Field", selection: Binding(
                get: { binding.wrappedValue.field },
                set: { binding.wrappedValue.setField($0, firstFeedID: model.subscriptions.first?.id) })
            ) {
                ForEach(editor.fieldChoices, id: \.self) { Text(WiltedMacPlaylistRuleDraft.name($0)).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Rule \(number) field")
            Picker("Comparison", selection: Binding(
                get: { binding.wrappedValue.comparator },
                set: { binding.wrappedValue.setComparator($0) })
            ) {
                ForEach(WiltedMacPlaylistRuleDraft.comparators(for: binding.wrappedValue.field), id: \.self) {
                    Text(WiltedMacPlaylistRuleDraft.name($0)).tag($0)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Rule \(number) comparison")
            valueControl(binding, number: number)
            Button {
                editor.removeRule(number: number)
                preview = nil
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
        case .ready:
            Picker("Ready", selection: draft.value) {
                Text("Yes").tag("true")
                Text("No").tag("false")
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
        case .expression:
            EmptyView()
        }
    }

    /// Waits out the debounce, then evaluates the compiled editor over the Larder. A newer edit
    /// cancels this one; a failing validation clears the preview so no last-good rows stand.
    private func refreshPreview() async {
        previewGeneration &+= 1
        let generation = previewGeneration
        preview = nil
        errorText = nil
        do { try await Task.sleep(for: Self.livePreviewDelay) } catch { return }
        guard generation == previewGeneration, !Task.isCancelled else { return }
        guard let validated = try? editor.validated() else { return }
        let rules: [PlaylistRule]
        switch validated {
        case .empty: rules = []
        case .expression(let rule): rules = [rule]
        }
        let result = await model.playlistRulePreview(for: rules, matchAll: true)
        guard generation == previewGeneration, !Task.isCancelled else { return }
        preview = result
    }

    /// Captures the compiled rule, playlist ID and match mode synchronously, marks the save state
    /// synchronously (so a second Save cannot slip in before the task is scheduled), and only then
    /// starts the write.
    private func save() {
        guard !isSaving, model.playlists.ruleReadErrors[playlist.id] == nil else { return }
        let snapshot = editor
        let validated: WiltedMacPlaylistRulesEditor.Validated
        do {
            validated = try snapshot.validated()
        } catch let error as PlaylistRuleError {
            errorText = error.reason
            preview = nil
            return
        } catch {
            errorText = "The expression is not valid."
            preview = nil
            return
        }
        let rules: [PlaylistRule]
        switch validated {
        case .empty:
            rules = []
        case .expression(let rule):
            rules = [rule]
        }
        let matchAll = snapshot.matchAll
        let playlistID = playlist.id
        isSaving = true
        errorText = nil
        Task {
            let saved = await model.savePlaylistRules(playlistID, rules: rules, matchAll: matchAll)
            isSaving = false
            if saved {
                dismiss()
            } else {
                errorText = "The rules could not be saved."
            }
        }
    }
}

/// One preview row: the same title and popover the playlist page uses, under the preview prefix so
/// a hosted test can tell preview surfaces apart. Opening it reads notes only; playback and the
/// current transcript are untouched.
private struct WiltedMacPlaylistPreviewRow: View {
    let model: WiltedMacModel
    let entryID: String
    @State private var isPresented = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let item = model.playlistLibraryItem(entryID) {
            switch item {
            case .article(let article):
                Text(article.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
            case .episode(let episode), .audiobook(let episode):
                WiltedMacEpisodeNotesTitle(
                    episode: episode, prefix: "wilted-playlist-preview", isPresented: $isPresented,
                    titleLineLimit: 1
                ) {
                    WiltedMacEpisodeNotes(
                        episode: episode, prefix: "wilted-playlist-preview",
                        source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle)
                    ) { EmptyView() }
                }
                .id(episode.id)
            }
        }
    }
}
