import AppKit
import SwiftUI
import WiltedDomain

struct WiltedMacFeedsEpisodeRow: View {
    @Bindable var model: WiltedMacModel
    let episode: WiltedMacEpisode
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingNotes = false
    @State private var isHoveringTitle = false

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    isShowingNotes = true
                } label: {
                    Text(episode.title)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .lineLimit(1)
                        .underline(isHoveringTitle)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringTitle = $0 }
                .help("Show notes for \(episode.title)")
                .accessibilityLabel("Show notes for \(episode.title)")
                .accessibilityIdentifier("wilted-feeds-show-notes-\(episode.id)")
                .popover(isPresented: $isShowingNotes, arrowEdge: .bottom) {
                    notesPopover
                }
                Text("\(episode.feedTitle) · \(episode.lifecyclePresentation.primaryLabel)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(WiltedMacFeedsAction.allCases) { action in
                Button(action.rawValue) {
                    decide(action)
                }
                .accessibilityLabel("\(action.rawValue) \(episode.title)")
                .accessibilityIdentifier("wilted-feeds-\(action.rawValue.lowercased())-\(episode.id)")
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feeds-row-\(episode.id)")
    }

    private var notesPopover: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(episode.title)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(episode.feedTitle) · \(episode.releasedAt.formatted(date: .numeric, time: .omitted))")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            Divider()
            ScrollView {
                if let notes = episode.notes, !notes.isEmpty {
                    Text(WiltedShowNotes.linked(notes))
                        .wiltedFont(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("wilted-feeds-notes-text-\(episode.id)")
                } else {
                    Text("This episode's feed did not include show notes.")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-feeds-notes-unavailable-\(episode.id)")
                }
            }
            .frame(maxHeight: .infinity)
            // The popover repeats the row's two answers from the same enum, so
            // reading notes and deciding stays in one place. A popover, rather
            // than inline disclosure, keeps long notes from reflowing the list
            // and pushing the other rows' answers out of view.
            HStack {
                Spacer()
                ForEach(WiltedMacFeedsAction.allCases) { action in
                    Button(action.rawValue) {
                        decide(action)
                    }
                    .accessibilityLabel("\(action.rawValue) \(episode.title)")
                    .accessibilityIdentifier("wilted-feeds-decide-\(action.rawValue.lowercased())-\(episode.id)")
                    // Return keeps from inside the popover.
                    .keyboardShortcut(action == .keep ? .defaultAction : nil)
                }
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 420, height: 360)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-feeds-notes-popover-\(episode.id)")
    }

    private func decide(_ action: WiltedMacFeedsAction) {
        isShowingNotes = false
        switch action {
        case .keep: model.keepEpisode(episode)
        case .skip: model.skipFeedEpisode(episode)
        }
    }
}

/// Keeps the transient podcast status row at a two-line minimum without
/// truncating a longer diagnostic message.
enum WiltedMacPodcastOperationMessageLayout {
    static let utilityLineHeight: CGFloat = 16
    static let reservedLineCount = 2

    static func minimumRowHeight(for scale: WiltedTheme.TextScale) -> CGFloat {
        WiltedTheme.scaled(utilityLineHeight * CGFloat(reservedLineCount), scale: scale)
    }

    static func rowHeight(for measuredTextHeight: CGFloat, scale: WiltedTheme.TextScale) -> CGFloat {
        max(minimumRowHeight(for: scale), measuredTextHeight)
    }
}

/// The running report for the last podcast action.
///
/// Downloads and preparation are reported from Larder and refreshes from Feeds,
/// so both pages render it. Only one destination is on screen at a time, which
/// keeps the identifier unique.
struct WiltedMacPodcastOperationMessage: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.wiltedTextScale) private var textScale

    var body: some View {
        if let message = model.podcastOperationMessage {
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text(message)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        minHeight: WiltedMacPodcastOperationMessageLayout.minimumRowHeight(for: textScale),
                        alignment: .top
                    )
                    .accessibilityIdentifier("wilted-podcast-operation-message")
                if let undoable = model.undoableRemoval {
                    Button("Undo") {
                        model.restoreEpisode(undoable)
                    }
                    .accessibilityIdentifier("wilted-podcast-undo-removal")
                    .accessibilityLabel("Undo removing \(undoable.title)")
                }
                if let skipped = model.undoableSkip {
                    // Completion can be reversed locally without consulting
                    // the feed or deleting the episode's media.
                    Button("Undo completion") {
                        model.undoSkipEpisode(skipped)
                    }
                    .accessibilityIdentifier("wilted-podcast-undo-skip")
                    .accessibilityLabel("Undo completion of \(skipped.title)")
                }
            }
        }
    }
}

/// A tokenized field border replaces macOS's system-blue focus treatment.
struct WiltedMacLinkField: View {
    @Binding var text: String
    let placeholder: String
    /// Each composer names its own field: two fields sharing one identifier is
    /// an ambiguous query the moment both are reachable.
    let identifier: String
    let focusedOverride: Bool?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        text: Binding<String>,
        placeholder: String = "https://example.com/article",
        identifier: String = "wilted-link-url",
        focusedOverride: Bool? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.identifier = identifier
        self.focusedOverride = focusedOverride
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .wiltedFont(.body)
            .padding(.horizontal, WiltedTheme.Spacing.medium)
            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .background(
                WiltedTheme.color(.page, scheme: colorScheme),
                in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                    .stroke(
                        isFocused || focusedOverride == true
                            ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme)
                            : WiltedTheme.color(.steel, scheme: colorScheme),
                        lineWidth: isFocused || focusedOverride == true ? 2 : 1
                    )
            )
            .focused($isFocused)
            .accessibilityIdentifier(identifier)
    }
}

/// Show notes, wherever they are read.
///
/// The player and the Larder row render the same feed text, so the URL pass
/// lives apart from either rather than in whichever surface asked first.
enum WiltedShowNotes {
    /// Feed notes arrive as plain text with the URLs written out; make each
    /// one a link so a sponsor code or guest site is a click, not a copy.
    static func linked(_ notes: String) -> AttributedString {
        var text = AttributedString(notes)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        let whole = NSRange(notes.startIndex..., in: notes)
        for match in detector.matches(in: notes, range: whole) {
            guard let url = match.url, let range = Range(match.range, in: notes),
                  let attributedRange = Range(range, in: text) else { continue }
            text[attributedRange].link = url
        }
        return text
    }
}
struct WiltedMacArticleRow: View {
    let model: WiltedMacModel
    let article: WiltedMacArticle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            WiltedProduceTile(symbol: .lettuce, size: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Source and length on one line. Three stacked lines and a
                // card each meant four articles filled the window; a library
                // is a list to scan, not a page to read.
                Text(metaLine)
                    .wiltedFont(.utility)
                    .foregroundStyle(
                        article.isReady
                            ? WiltedTheme.color(.secondaryText, scheme: colorScheme)
                            : WiltedStatusTone.active.color(colorScheme)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if article.isReady {
                Button(WiltedScreenCopy.openPlayer) {
                    model.openNowPlaying(for: article)
                }
                .accessibilityIdentifier("wilted-open-now-playing")
            }

            Menu {
                Button("Remove", role: .destructive) { model.removeArticle(article) }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("More actions for \(article.title)")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("wilted-article-actions-\(article.id)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-article-row-\(article.id)")
    }

    /// `text.npr.org · 28:56`, plus **Preparing** while the row has no button.
    ///
    /// A ready row already carries **Open Now Playing**, so spelling out
    /// *Ready to play* beside it repeats the same fact. A preparing row has no
    /// control at all, so its word stays.
    private var metaLine: String {
        var parts = [article.source]
        if let seconds = article.durationSeconds, seconds > 0 {
            parts.append(WiltedDuration.clock(seconds))
        }
        if !article.isReady { parts.append("Preparing") }
        return parts.joined(separator: " · ")
    }
}
