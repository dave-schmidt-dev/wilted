import SwiftUI
import WiltedDomain
import WiltedLibrary

struct LibraryNotebookCaptureControl: View {
    @ObservedObject var model: LibraryAppModel
    @ObservedObject var player: LibraryPlayer
    @ObservedObject var state: LibraryNotebookPhoneState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if model.canCaptureNotebook(player.item) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                HStack(spacing: WiltedTheme.Spacing.medium) {
                    Button {
                        guard let item = player.item else { return }
                        let position = player.position
                        Task { await model.captureNotebookClip(for: item, at: position, capturedOn: .iphone) }
                    } label: {
                        Label(state.isCaptureInProgress ? "Saving moment…" : "Save last 30 seconds", systemImage: "bookmark")
                            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    }
                    .disabled(state.isCaptureInProgress)
                    .accessibilityIdentifier("wilted-notebook-capture")
                    if let id = state.lastCapturedEntryID {
                        Button("Undo") { Task { await model.undoNotebookCapture(id: id) } }
                            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                            .accessibilityIdentifier("wilted-notebook-capture-undo")
                    }
                    Spacer(minLength: 0)
                }
                if let id = state.lastCapturedEntryID {
                    Text(model.notebookStatus(for: id))
                        .wiltedFont(.utility)
                        .accessibilityIdentifier("wilted-notebook-capture-status")
                }
                if let notice = state.notice {
                    Text(notice)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-notebook-notice")
                }
            }
            .padding(.horizontal, WiltedTheme.Spacing.medium)
            .padding(.vertical, WiltedTheme.Spacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WiltedTheme.color(.card, scheme: colorScheme), in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.card))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-notebook-capture-control")
        }
    }
}

struct LibraryNotebookView: View {
    @ObservedObject var model: LibraryAppModel
    @ObservedObject var player: LibraryPlayer
    @ObservedObject private var notebook: LibraryNotebookPhoneState
    @ObservedObject private var headlines: LibraryHeadlinePhoneState
    @Environment(\.colorScheme) private var colorScheme

    init(model: LibraryAppModel, player: LibraryPlayer) {
        self.model = model
        self.player = player
        _notebook = ObservedObject(wrappedValue: model.notebookPhoneState)
        _headlines = ObservedObject(wrappedValue: model.headlinePhoneState)
    }

    private var orphanedCommands: [LibraryNotebookOutbox.Command] {
        let visibleIDs = Set(notebook.entries.map(\.id))
        return notebook.commands.filter {
            ( $0.delivery == .conflict || $0.delivery == .failed ) && !visibleIDs.contains($0.entry.id)
        }
    }

    private var savedHeadlineStories: [LibraryHeadlineStory] {
        model.notebookSavedHeadlineStories
    }

    private var headlineAvailabilityMessage: String? {
        if model.accountQuarantined {
            return "Saved headlines are hidden while this account is under review."
        }
        if headlines.refreshFailed {
            return model.headlineProjection == nil
                ? "Saved headlines are unavailable while offline."
                : "Offline. Showing the last saved stories from your Mac."
        }
        if headlines.writeFailed {
            return "Headline changes could not be saved on this iPhone."
        }
        if model.headlineProjection == nil && !headlines.isBoundToLocalOwner {
            return "Saved headlines appear after this library syncs."
        }
        return nil
    }

    var body: some View {
        List {
            if let headlineAvailabilityMessage {
                Section {
                    Text(headlineAvailabilityMessage)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-notebook-headline-availability")
                }
            }
            if let actionNotice = headlines.actionNotice {
                Section {
                    Text(actionNotice)
                        .wiltedFont(.utility)
                        .accessibilityIdentifier("wilted-notebook-headline-notice")
                }
            }
            if let notice = notebook.notice {
                Section {
                    Text(notice)
                        .wiltedFont(.utility)
                        .accessibilityIdentifier("wilted-notebook-notice")
                }
            }
            if let capturedID = notebook.lastCapturedEntryID,
               let captured = notebook.entries.first(where: { $0.id == capturedID }) {
                Section {
                    HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
                        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                            Text("Moment saved")
                                .wiltedFont(.body)
                            Text(captured.sourceTitle)
                                .wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            Text(model.notebookStatus(for: capturedID))
                                .wiltedFont(.utility)
                        }
                        Spacer(minLength: 0)
                        Button("Undo") { Task { await model.undoNotebookCapture(id: capturedID) } }
                            .accessibilityIdentifier("wilted-notebook-capture-undo")
                    }
                }
            }
            if let deletedID = notebook.lastDeletedEntryID {
                Section {
                    HStack {
                        Text("Entry deleted")
                            .wiltedFont(.body)
                        Spacer()
                        Button("Undo") {
                            Task { _ = await model.restoreNotebookEntryAsNewID(id: deletedID) }
                        }
                        .accessibilityIdentifier("wilted-notebook-delete-undo")
                    }
                }
            }
            if !orphanedCommands.isEmpty {
                Section("Needs attention") {
                    ForEach(orphanedCommands) { command in
                        LibraryNotebookConflictCard(command: command, model: model)
                    }
                }
            }
            if !savedHeadlineStories.isEmpty {
                Section("Saved stories") {
                    ForEach(savedHeadlineStories) { story in
                        LibraryHeadlineStoryCard(state: headlines, model: model, story: story)
                            .listRowInsets(EdgeInsets(
                                top: WiltedTheme.Spacing.small, leading: WiltedTheme.Spacing.medium,
                                bottom: WiltedTheme.Spacing.small, trailing: WiltedTheme.Spacing.medium))
                            .listRowBackground(Color.clear)
                    }
                }
            }
            if notebook.entries.isEmpty && savedHeadlineStories.isEmpty && headlineAvailabilityMessage == nil {
                Section {
                    ContentUnavailableView(
                        "Notebook is empty",
                        systemImage: "bookmark",
                        description: Text("Save a podcast moment or headline to keep it here.")
                    )
                    .accessibilityIdentifier("wilted-notebook-empty")
                }
            }
            if !notebook.entries.isEmpty {
                Section("Saved moments") {
                    ForEach(notebook.entries) { entry in
                        LibraryNotebookEntryCard(entry: entry, model: model, player: player, notebook: notebook)
                            .listRowInsets(EdgeInsets(
                                top: WiltedTheme.Spacing.small, leading: WiltedTheme.Spacing.medium,
                                bottom: WiltedTheme.Spacing.small, trailing: WiltedTheme.Spacing.medium))
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .overlay { LibraryWatermark() }
        .navigationTitle("Notebook")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("wilted-notebook-view")
        .task { await model.refreshNotebookReplayAvailability() }
    }
}

private struct LibraryNotebookEntryCard: View {
    let entry: LibraryNotebookEntry
    @ObservedObject var model: LibraryAppModel
    @ObservedObject var player: LibraryPlayer
    @ObservedObject var notebook: LibraryNotebookPhoneState
    @Environment(\.colorScheme) private var colorScheme
    @State private var noteDraft: String
    @State private var confirmingDelete = false

    init(
        entry: LibraryNotebookEntry, model: LibraryAppModel, player: LibraryPlayer,
        notebook: LibraryNotebookPhoneState
    ) {
        self.entry = entry
        self.model = model
        self.player = player
        self.notebook = notebook
        _noteDraft = State(initialValue: entry.note ?? "")
    }

    private var command: LibraryNotebookOutbox.Command? {
        notebook.commands.last(where: { $0.entry.id == entry.id })
    }

    private var hasChangedNote: Bool {
        noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != entry.note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack(alignment: .top, spacing: WiltedTheme.Spacing.small) {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    Text(entry.sourceTitle)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let sourceName = entry.sourceName, !sourceName.isEmpty {
                        Text(sourceName)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    }
                }
                Spacer(minLength: 0)
                Text(entry.kind == .clip ? "Clip" : String(describing: entry.kind).capitalized)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }

            if let start = entry.startSeconds, let end = entry.endSeconds {
                Text("\(LibraryClockFormat.duration(start))–\(LibraryClockFormat.duration(end))")
                    .wiltedFont(.utility)
                    .monospacedDigit()
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityLabel("Clip from \(LibraryClockFormat.duration(start)) to \(LibraryClockFormat.duration(end))")
            }
            if let excerpt = entry.textExcerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-notebook-excerpt-\(entry.id.rawValue)")
            } else if notebook.excerptPendingIDs.contains(entry.id) {
                Label("Checking for transcript text", systemImage: "text.alignleft")
                    .wiltedFont(.utility)
            }

            Link(destination: entry.sourceURL) {
                Label("Open original source", systemImage: "arrow.up.right.square")
                    .wiltedFont(.utility)
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            }
            .accessibilityIdentifier("wilted-notebook-source-\(entry.id.rawValue)")

            TextField("Add a note", text: $noteDraft, axis: .vertical)
                .wiltedFont(.body)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("wilted-notebook-note-\(entry.id.rawValue)")
                .onChange(of: entry.note) { _, value in noteDraft = value ?? "" }

            HStack(spacing: WiltedTheme.Spacing.medium) {
                if entry.kind == .clip, entry.sourceKind == .podcast {
                    Button {
                        Task { _ = await model.replayNotebookEntry(id: entry.id) }
                    } label: {
                        Label("Play clip", systemImage: "play.fill")
                            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    }
                    .disabled(!notebook.replayableIDs.contains(entry.id))
                    .accessibilityIdentifier("wilted-notebook-replay-\(entry.id.rawValue)")
                }
                Button("Save note") { Task { _ = await model.updateNotebookNote(id: entry.id, note: noteDraft) } }
                    .disabled(!hasChangedNote)
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-notebook-save-note-\(entry.id.rawValue)")
                Spacer(minLength: 0)
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                        .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                }
                .accessibilityLabel("Delete Notebook entry")
                .accessibilityIdentifier("wilted-notebook-delete-\(entry.id.rawValue)")
            }

            Text(model.notebookStatus(for: entry.id))
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-notebook-status-\(entry.id.rawValue)")

            if let command, command.delivery == .conflict {
                if let remote = command.serverEntry {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                        Text("Latest version on Mac")
                            .wiltedFont(.utility)
                            .accessibilityAddTraits(.isHeader)
                        if let note = remote.note, !note.isEmpty { Text(note).wiltedFont(.body) }
                        if let excerpt = remote.textExcerpt, !excerpt.isEmpty { Text(excerpt).wiltedFont(.body) }
                    }
                }
                Button("Reapply my version") { Task { await model.reapplyNotebookCommand(command.id) } }
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-notebook-reapply-\(command.id)")
            } else if let command, command.delivery == .failed {
                Button("Try again") { Task { await model.retryNotebookCommand(command.id) } }
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-notebook-retry-\(command.id)")
            }

            if entry.kind == .clip, entry.sourceKind == .podcast,
               !notebook.replayableIDs.contains(entry.id) {
                Text("Audio for this saved version is not on this phone.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-notebook-audio-unavailable-\(entry.id.rawValue)")
            }
        }
        .padding(WiltedTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiltedTheme.color(.card, scheme: colorScheme), in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-notebook-entry-\(entry.id.rawValue)")
        .confirmationDialog(
            "Delete this Notebook entry?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete entry", role: .destructive) { Task { await model.deleteNotebookEntry(id: entry.id) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You can undo this by restoring it as a new entry.")
        }
    }
}

private struct LibraryNotebookConflictCard: View {
    let command: LibraryNotebookOutbox.Command
    @ObservedObject var model: LibraryAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text(command.entry.sourceTitle).wiltedFont(.body)
            Text(command.detail ?? "This entry needs attention.")
                .wiltedFont(.utility)
            if command.delivery == .conflict {
                Button("Reapply as a new entry") { Task { await model.reapplyNotebookCommand(command.id) } }
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-notebook-reapply-\(command.id)")
            } else if command.delivery == .failed {
                Button("Try again") { Task { await model.retryNotebookCommand(command.id) } }
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-notebook-retry-\(command.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-notebook-attention-\(command.id)")
    }
}
