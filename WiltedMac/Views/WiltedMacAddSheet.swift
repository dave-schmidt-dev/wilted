import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WiltedDomain

// MARK: - Add sheet

/// The one way to add anything: a single field, the results beneath it, and one
/// primary action on each result. Opened by the toolbar Add button and ⌘N.
struct WiltedMacAddSheet: View {
    @State private var session: WiltedMacAddSession

    init(model: WiltedMacModel) {
        _session = State(initialValue: model.makeAddSession())
    }

    var body: some View {
        WiltedMacAddSheetContent(session: session)
            .onAppear { session.start() }
            .onDisappear { session.teardown() }
    }
}

/// The sheet's content, separate from the presentation so snapshots render it directly.
struct WiltedMacAddSheetContent: View {
    let session: WiltedMacAddSession
    var focusedOverride: Bool?
    @Environment(\.colorScheme) private var colorScheme

    private var text: Binding<String> {
        Binding(get: { session.text }, set: { session.text = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text("Add")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                Button("Import book\u{2026}") { chooseBook() }
                    .disabled(session.isImporting)
                    .help("Import audio files, a folder, an EPUB or a PDF")
                    .accessibilityIdentifier("wilted-add-import")
            }
            HStack(spacing: WiltedTheme.Spacing.medium) {
                WiltedMacLinkField(
                    text: text, placeholder: "Search podcasts or paste a link",
                    identifier: "wilted-add-field", focusedOverride: focusedOverride
                )
                .onSubmit { session.submit() }
                if session.isWorking {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier("wilted-add-progress")
                    Button("Stop") { session.cancel() }
                        .accessibilityIdentifier("wilted-add-cancel")
                }
            }
            importStatus
            if session.importState == .idle, let status = session.statusMessage {
                note(status, identifier: "wilted-add-status")
            }
            if !session.rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        resultRow(row)
                    }
                }
                .wiltedCard(colorScheme)
            }
            if let intake = session.intakeMessage {
                note(intake, identifier: "wilted-add-intake-status")
            }
            HStack {
                Spacer()
                Button("Done") { session.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("wilted-add-done")
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 520)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .dropDestination(for: URL.self) { urls, _ in
            guard !session.isImporting else { return false }
            session.importBook(from: urls.filter(\.isFileURL))
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-add-sheet")
    }

    /// Progress with Cancel while a book imports; the reason when it was refused.
    @ViewBuilder private var importStatus: some View {
        switch session.importState {
        case .idle:
            EmptyView()
        case let .working(fraction, detail):
            HStack(spacing: WiltedTheme.Spacing.medium) {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Importing book")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                        .accessibilityIdentifier("wilted-add-import-progress")
                    note(detail, identifier: "wilted-add-import-detail")
                }
                Button("Cancel") { session.cancelImport() }
                    .accessibilityIdentifier("wilted-add-import-cancel")
            }
        case let .refused(reason):
            Label("Could not import: \(reason)", systemImage: "exclamationmark.triangle")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedStatusTone.failure.color(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-add-import-refusal")
        case .cancelled:
            note("Import cancelled.", identifier: "wilted-add-import-cancelled")
        case let .finished(message):
            note(message, identifier: "wilted-add-import-done")
        }
    }

    private func chooseBook() {
        let panel = NSOpenPanel()
        panel.message = "Choose audio files, a folder of audio files, an EPUB or a PDF."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .pdf, .epub, .folder]
        guard panel.runModal() == .OK else { return }
        session.importBook(from: panel.urls)
    }

    private func note(_ text: String, identifier: String) -> some View {
        Text(text)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private func resultRow(_ row: WiltedMacAddSession.Row) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(2)
                Text(row.detail)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch row.action {
            case .subscribe:
                Button("Subscribe") { session.subscribe(row) }
                    .disabled(session.isSubscribing)
                    .accessibilityLabel("Subscribe to \(row.title)")
                    .accessibilityIdentifier("wilted-add-subscribe-\(row.id)")
            case .followArticleFeed:
                Button("Follow as article feed") { session.subscribe(row) }
                    .disabled(session.isSubscribing)
                    .accessibilityLabel("Follow \(row.title) as an article feed")
                    .accessibilityIdentifier("wilted-add-follow-article-feed-\(row.id)")
            case .following:
                Label("Following", systemImage: "checkmark.circle")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityLabel("Already following \(row.title)")
                    .accessibilityIdentifier("wilted-add-following-\(row.id)")
            case .addArticle:
                Button("Add article") { session.addArticle(row) }
                    .accessibilityIdentifier("wilted-add-article-\(row.id)")
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-add-result-\(row.id)")
    }
}
