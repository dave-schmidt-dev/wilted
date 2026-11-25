import AppKit
import SwiftUI
import WiltedLibrary

struct WiltedMacNotebookView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var entries: [LibraryNotebookEntry] = []
    @State private var noteDrafts: [String: String] = [:]
    @State private var deletedEntry: LibraryNotebookEntry?
    @State private var status: String?
    @State private var isBusy = false

    init(model: WiltedMacModel) { _model = Bindable(model) }

    private var canCapture: Bool {
        model.isPodcastPlayback && model.playback?.itemID != nil && model.playback?.revisionID != nil
    }

    private var savedStories: [LibraryHeadlineStory] {
        model.headlineCatalogState.projection?.saved ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("Notebook")
                    .font(.system(size: WiltedTheme.scaled(NSFont.preferredFont(forTextStyle: .title1).pointSize, scale: model.textScale), weight: .semibold))
                Spacer()
                Button {
                    Task { await capture() }
                } label: {
                    Label("Clip last 30 seconds", systemImage: "bookmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCapture || isBusy)
                .accessibilityIdentifier("wilted-notebook-capture-clip")
            }

            if let status {
                Text(status)
                    .wiltedFont(.caption)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-notebook-status")
            }
            if model.headlineCatalogState.projectionMessage != nil {
                Text("Saved stories could not be loaded. Try again later.")
                    .wiltedFont(.caption)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-notebook-headline-availability")
            }
            if model.playbackError == "Original audio unavailable." {
                Text("Original audio unavailable.")
                    .wiltedFont(.caption)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-notebook-audio-unavailable")
            }
            if let deletedEntry {
                HStack(spacing: WiltedTheme.Spacing.small) {
                    Text("Clip deleted.")
                    Button("Undo") { Task { await undoDelete(deletedEntry) } }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("wilted-notebook-undo-delete")
                }
                .wiltedFont(.caption)
            }

            if entries.isEmpty && savedStories.isEmpty && model.headlineCatalogState.projectionMessage == nil {
                ContentUnavailableView {
                    Label("Notebook is empty", systemImage: "book.closed")
                } description: {
                    Text(canCapture ? "Save a moment from the episode you’re listening to, or save a headline." : "Save a podcast moment or headline to keep it here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                        if !savedStories.isEmpty {
                            sectionTitle("Saved stories")
                            ForEach(savedStories) { story in
                                WiltedMacPlayerHeadlineCard(
                                    model: model, story: story, isSpeakingHeadline: false,
                                    stopReading: {})
                            }
                        }
                        let savedEntries = entries.filter { !$0.isDeleted }
                        if !savedEntries.isEmpty {
                            sectionTitle("Saved moments")
                        }
                        ForEach(savedEntries) { entry in
                            clipCard(entry)
                        }
                    }
                    .padding(.vertical, WiltedTheme.Spacing.small)
                }
                .accessibilityIdentifier("wilted-notebook-entries")
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .task {
            model.headlineCatalogState.refresh()
            await reload()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .wiltedFont(.body)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clipCard(_ entry: LibraryNotebookEntry) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.sourceTitle)
                        .wiltedFont(.body)
                        .fontWeight(.semibold)
                    Text([entry.sourceName, timeRange(entry)].compactMap { $0 }.joined(separator: " · "))
                        .wiltedFont(.caption)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                Spacer()
                Link(destination: entry.sourceURL) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open source")
                .accessibilityLabel("Open source for \(entry.sourceTitle)")
            }

            if let excerpt = entry.textExcerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .wiltedFont(.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wilted-notebook-excerpt-\(entry.id.rawValue)")
            } else {
                Text("Transcript excerpt unavailable for this revision.")
                    .wiltedFont(.caption)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }

            TextField("Add a note", text: draft(for: entry), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityIdentifier("wilted-notebook-note-\(entry.id.rawValue)")

            HStack {
                Button {
                    model.playNotebookClip(entry)
                } label: {
                    Label("Play clip", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("wilted-notebook-play-\(entry.id.rawValue)")
                Spacer()
                Button("Save note") { Task { await saveNote(for: entry) } }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                    .accessibilityIdentifier("wilted-notebook-save-note-\(entry.id.rawValue)")
                Button(role: .destructive) {
                    Task { await delete(entry) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .accessibilityIdentifier("wilted-notebook-delete-\(entry.id.rawValue)")
            }
        }
        .padding(WiltedTheme.Spacing.medium)
        .background(WiltedTheme.color(.card, scheme: colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(WiltedTheme.color(.steel, scheme: colorScheme), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func draft(for entry: LibraryNotebookEntry) -> Binding<String> {
        Binding(
            get: { noteDrafts[entry.id.rawValue] ?? entry.note ?? "" },
            set: { noteDrafts[entry.id.rawValue] = $0 }
        )
    }

    private func timeRange(_ entry: LibraryNotebookEntry) -> String? {
        guard let start = entry.startSeconds, let end = entry.endSeconds else { return nil }
        return "\(Self.time(start))–\(Self.time(end))"
    }

    private static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @MainActor
    private func reload() async {
        do {
            entries = try await model.loadNotebookEntries()
            for entry in entries where noteDrafts[entry.id.rawValue] == nil {
                noteDrafts[entry.id.rawValue] = entry.note ?? ""
            }
            if status == "Notebook is unavailable right now." { status = nil }
        } catch {
            status = "Notebook is unavailable right now."
        }
    }

    @MainActor
    private func capture() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let entry = try await model.captureNotebookClip()
            entries.insert(entry, at: 0)
            noteDrafts[entry.id.rawValue] = ""
            status = "Clip saved."
        } catch let error as WiltedMacNotebookError {
            status = error.message
        } catch {
            status = "Clip could not be saved. Your episode is unchanged."
        }
    }

    @MainActor
    private func saveNote(for entry: LibraryNotebookEntry) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await model.saveNotebookNote(entry, note: noteDrafts[entry.id.rawValue])
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = updated }
            status = "Note saved."
        } catch {
            status = "Note could not be saved. Your text is still here."
        }
    }

    @MainActor
    private func delete(_ entry: LibraryNotebookEntry) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let tombstone = try await model.deleteNotebookEntry(entry) else { return }
            deletedEntry = tombstone
            entries.removeAll { $0.id == entry.id }
            status = nil
        } catch {
            status = "Clip could not be deleted."
        }
    }

    @MainActor
    private func undoDelete(_ entry: LibraryNotebookEntry) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if let restored = try await model.undoNotebookDelete(entry) {
                entries.insert(restored, at: 0)
                noteDrafts[restored.id.rawValue] = restored.note ?? ""
                deletedEntry = nil
                status = "Clip restored."
            }
        } catch {
            status = "Clip could not be restored."
        }
    }
}
