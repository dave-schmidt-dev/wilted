import SwiftUI
import WiltedDomain
import WiltedLibrary

/// Splits published episode notes into paragraphs: plain text only, blank lines and line breaks
/// both separate paragraphs, and empty paragraphs are dropped.
enum LibraryNotes {
    static func paragraphs(_ notes: String) -> [String] {
        notes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// What Share offers for an episode: its own page when the feed published one, otherwise the
/// title and show, with the plain statement that there is no page. Never the feed address.
enum LibraryEpisodeShare: Equatable {
    case page(URL, message: String)
    case text(String, note: String)

    static let noEpisodePage = "No episode page"

    init(_ row: LibraryRow) {
        if let link = row.episodeLink {
            self = .page(link, message: row.title + " · " + row.showTitle)
        } else {
            self = .text(row.title + " — " + row.showTitle, note: Self.noEpisodePage)
        }
    }
}

/// The episode detail's transcript section: its `content` when given, else a placeholder.
struct LibraryTranscriptSlot<Content: View>: View {
    let entryID: ItemID
    private let content: Content?
    @Environment(\.colorScheme) private var colorScheme

    init(entryID: ItemID, @ViewBuilder content: () -> Content) {
        self.entryID = entryID
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Transcript").wiltedFont(.title)
            if let content {
                content
            } else {
                Label {
                    Text("Transcript not available yet").wiltedFont(.body)
                } icon: {
                    Image(systemName: "text.alignleft")
                }
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-library-detail-transcript-placeholder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-detail-transcript")
    }
}

extension LibraryTranscriptSlot where Content == EmptyView {
    /// The reserved, empty slot.
    init(entryID: ItemID) {
        self.entryID = entryID
        self.content = nil
    }
}

/// The episode detail's stacked content, top to bottom, as data. Download and Play are the two
/// controls of the shared action row; Share follows them, so the playback actions stay directly
/// under the heading. `drawn` is the order the screen builds from, and `index` pins the order in a test.
enum LibraryEpisodeDetailRow: Int, Comparable, Sendable {
    case artwork, header, download, play, share, notes, transcript

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The blocks the detail draws, in draw order. The shared action row draws Download and Play
    /// together, so it appears once, at `download`.
    static let drawn: [Self] = [.artwork, .header, .download, .share, .notes, .transcript]

    /// Where this element sits in the full top-to-bottom order.
    var index: Int { rawValue }
}

/// One episode in full: large artwork, title, show, date, duration, the notes the Mac published,
/// the same audio actions as its Larder row, and the transcript section. Reads the row
/// live from the model, so progress and state keep moving while it is open.
struct LibraryEpisodeDetailView: View {
    @ObservedObject var model: LibraryAppModel
    let entryID: ItemID
    var playingID: ItemID?
    var onPlay: ((LibraryRow) -> Void)?
    /// When given, the transcript follows this player while the episode is its loaded item.
    var player: LibraryPlayer?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let row = model.queued.first(where: { $0.id == entryID }) {
                content(row)
            } else {
                ContentUnavailableView {
                    Label("Episode not in the Larder", systemImage: "questionmark.circle")
                } description: {
                    Text("The Mac no longer lists this episode.")
                }
                .accessibilityIdentifier("wilted-library-detail-missing")
            }
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ row: LibraryRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                ForEach(LibraryEpisodeDetailRow.drawn, id: \.self) { element in
                    block(element, row: row)
                }
            }
            .padding(WiltedTheme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("wilted-library-detail")
    }

    /// One stacked block. Download and Play draw as the shared action row, so `.download` renders it
    /// and `.play` is an order marker that never appears in `drawn`.
    @ViewBuilder
    private func block(_ element: LibraryEpisodeDetailRow, row: LibraryRow) -> some View {
        switch element {
        case .artwork:
            LibraryArtwork(url: row.artworkURL, side: 240, isDecorative: false)
                .accessibilityLabel("Artwork for \(row.title)")
                .accessibilityIdentifier("wilted-library-detail-artwork")
                .frame(maxWidth: .infinity)
        case .header:
            header(row)
        case .download:
            LibraryEpisodeActions(
                row: row, media: model.mediaState(for: row.id),
                isPlaying: playingID == row.id,
                onMedia: { model.performMediaAction($0, entryID: row.id) },
                onPlay: onPlay.map { play in { play(row) } },
                decisionActions: model.decisionActions(for: row),
                decisionStatus: model.decisionStatus(for: row.id),
                onDecision: { model.performDecision($0, entryID: row.id) },
                onCancelDecision: { model.cancelDecision(entryID: row.id) })
        case .play:
            EmptyView()
        case .share:
            share(row)
        case .notes:
            notes(row)
        case .transcript:
            LibraryTranscriptSlot(entryID: row.id) {
                LibraryTranscriptSection(model: model, entryID: row.id, player: player, height: 360)
            }
        }
    }

    private func header(_ row: LibraryRow) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text(row.title)
                .wiltedFont(.title)
                .textSelection(.enabled)
                .accessibilityIdentifier("wilted-library-detail-title")
            Text(row.showTitle)
                .wiltedFont(.body)
                .foregroundStyle(secondary)
                .accessibilityIdentifier("wilted-library-detail-show")
            Text(meta(row))
                .wiltedFont(.utility)
                .foregroundStyle(secondary)
                .accessibilityIdentifier("wilted-library-detail-meta")
            if let removal = row.removalText {
                Text(removal)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
            }
            LibraryCheckpointLine(row: row, player: player, identifier: "wilted-library-detail-checkpoint")
        }
    }

    @ViewBuilder private func share(_ row: LibraryRow) -> some View {
        switch LibraryEpisodeShare(row) {
        case let .page(url, message):
            ShareLink(item: url, subject: Text(row.title), message: Text(message)) {
                Label("Share episode page", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("wilted-library-detail-share")
        case let .text(text, note):
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                ShareLink(item: text, subject: Text(row.title), message: Text(note)) {
                    Label("Share title and show", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("wilted-library-detail-share")
                Text(note)
                    .wiltedFont(.utility)
                    .foregroundStyle(secondary)
                    .accessibilityIdentifier("wilted-library-detail-no-page")
            }
        }
    }

    private func notes(_ row: LibraryRow) -> some View {
        let paragraphs = LibraryNotes.paragraphs(row.summary)
        return VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Notes").wiltedFont(.title)
            if paragraphs.isEmpty {
                Text("No notes for this episode.")
                    .wiltedFont(.body)
                    .foregroundStyle(secondary)
            } else {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).wiltedFont(.body).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-detail-notes")
    }

    private func meta(_ row: LibraryRow) -> String {
        [row.durationText, row.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var secondary: Color { WiltedTheme.color(.secondaryText, scheme: colorScheme) }
}
