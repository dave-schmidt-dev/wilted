import AppKit
import SwiftUI
import WiltedDomain

/// Native tri-state selection exposes a real `.mixed` checkbox state.
struct WiltedMacFeedsSelectionControl: NSViewRepresentable {
    let state: NSControl.StateValue
    let identifier: String
    let toggle: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(toggle: toggle) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "Select all", target: context.coordinator, action: #selector(Coordinator.changed))
        button.allowsMixedState = true
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.toggle = toggle
        button.state = state
    }

    final class Coordinator: NSObject {
        var toggle: () -> Void
        init(toggle: @escaping () -> Void) { self.toggle = toggle }
        @objc func changed() { toggle() }
    }
}

struct WiltedMacFeedsEpisodeRow: View {
    @Bindable var model: WiltedMacModel
    let episode: WiltedMacEpisode
    let isSelected: Bool
    var isWaitingForSpace = false
    var position: Int? = nil
    var count: Int? = nil
    let setSelected: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingNotes = false

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            if let position {
                Text(String(format: "%02d", position))
                    .wiltedFont(.utility)
                    .monospacedDigit()
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityHidden(true)
            }
            Toggle("Select \(episode.title)", isOn: Binding(get: { isSelected }, set: setSelected))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.pendingFeedDecisionIDs.contains(episode.id))
                .accessibilityIdentifier("wilted-feeds-select-\(episode.id)")
            WiltedMacEpisodeArtwork(episode: episode, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                WiltedMacEpisodeNotesTitle(
                    episode: episode, prefix: "wilted-feeds", isPresented: $isShowingNotes
                ) {
                    notesPopover
                }
                WiltedMacEpisodeMetadata(
                    episode: episode,
                    lifecycleLabel: episode.lifecyclePresentation.primaryLabel,
                    identifier: "wilted-feeds-metadata-\(episode.id)"
                )
                if isWaitingForSpace {
                    Text("Waiting for space")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-feeds-waiting-\(episode.id)")
                }
                if model.pendingFeedDecisionIDs.contains(episode.id) {
                    HStack(spacing: WiltedTheme.Spacing.xSmall) {
                        ProgressView().controlSize(.small)
                        Text("Saving decision…")
                    }
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-feeds-decision-pending-\(episode.id)")
                }
                if model.failedFeedDecisionIDs.contains(episode.id) {
                    Text("Could not save this decision. Try again.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-feeds-decision-failed-\(episode.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(WiltedMacFeedsAction.allCases) { action in
                decisionButton(
                    action,
                    identifier: "wilted-feeds-\(action.rawValue.lowercased())-\(episode.id)"
                )
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(position.map { "\(episode.title), number \($0) in Feeds" } ?? episode.title)
        .accessibilityValue(position.flatMap { value in count.map { "\(value) of \($0)" } } ?? "")
        .accessibilityIdentifier("wilted-feeds-row-\(episode.id)")
    }

    private var notesPopover: some View {
        WiltedMacEpisodeNotes(
            episode: episode,
            prefix: "wilted-feeds",
            source: model.episodeInfoSource(id: episode.id, showTitle: episode.feedTitle)
        ) {
            // The popover repeats the row's two answers from the same enum, so
            // reading notes and deciding stays in one place. A popover, rather
            // than inline disclosure, keeps long notes from reflowing the list
            // and pushing the other rows' answers out of view.
            HStack {
                Spacer()
                ForEach(WiltedMacFeedsAction.allCases) { action in
                    decisionButton(
                        action,
                        identifier: "wilted-feeds-decide-\(action.rawValue.lowercased())-\(episode.id)"
                    )
                    // Return keeps from inside the popover.
                    .keyboardShortcut(action == .keep ? .defaultAction : nil)
                }
            }
        }

    }

    private func decide(_ action: WiltedMacFeedsAction) {
        isShowingNotes = false
        switch action {
        case .keep: model.keepEpisode(episode)
        case .skip: model.skipFeedEpisode(episode)
        }
    }

    @ViewBuilder private func decisionButton(
        _ action: WiltedMacFeedsAction, identifier: String
    ) -> some View {
        if action == .keep {
            Button(action.rawValue) { decide(action) }
                .buttonStyle(.borderedProminent)
                .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .accessibilityLabel("\(action.rawValue) \(episode.title)")
                .accessibilityIdentifier(identifier)
                .disabled(model.pendingFeedDecisionIDs.contains(episode.id))
        } else {
            Button(action.rawValue) { decide(action) }
                .buttonStyle(WiltedMacOutlinedButtonStyle())
                .accessibilityLabel("\(action.rawValue) \(episode.title)")
                .accessibilityIdentifier(identifier)
                .disabled(model.pendingFeedDecisionIDs.contains(episode.id))
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

/// The running report for the last Larder or Feeds action.
///
/// Downloads, preparation, completion, reordering and Undo report from Larder;
/// feed refreshes report from Feeds and Feed History. Each destination renders
/// it once near the top of its list, and only one destination is on screen at a
/// time, which keeps the identifier unique.
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
    @State private var removal: WiltedMacRemovalFlow
    @State private var showsActions = false

    init(model: WiltedMacModel, article: WiltedMacArticle, removal: WiltedMacRemovalFlow = WiltedMacRemovalFlow()) {
        self.model = model
        self.article = article
        _removal = State(initialValue: removal)
    }

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            WiltedProduceTile(symbol: .lettuce, size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(article.title)
                    .accessibilityLabel(article.title)
                HStack(spacing: 0) {
                    Text(article.source).lineLimit(1)
                    Text(" - \(WiltedMacEpisodePresentation.durationLabel(article.durationSeconds))")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Text(article.createdAt == .distantPast ? "Date unknown" : article.createdAt.formatted(date: .numeric, time: .omitted))
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WiltedMacLarderArticleAction(model: model, article: article)

            WiltedMacAddToPlaylistMenu(model: model, entryID: article.id, style: .rowAction)

            Button { showsActions.toggle() } label: {
                Image(systemName: removal.phase == .failed ? "exclamationmark.triangle" : "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: WiltedMacLarderView.trailingActionSlotsWidth, alignment: .trailing)
            .help(removal.statusText ?? "More actions for \(article.title)")
            .accessibilityLabel("More actions for \(article.title)")
            .accessibilityIdentifier("wilted-article-actions-\(article.id)")
            .popover(isPresented: $showsActions, arrowEdge: .bottom) {
                articleActions
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .contentShape(Rectangle())
        .wiltedRemovalConfirmation(removal, model: model)
        .accessibilityElement(children: .contain)
        .accessibilityValue(removal.statusText ?? "")
        .accessibilityIdentifier("wilted-article-row-\(article.id)")
    }

    /// The native popover content can also be hosted without opening a window.
    var articleActions: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            if removal.phase == .failed {
                Button("Retry removal", action: retryRemoval)
                    .accessibilityIdentifier("wilted-removal-retry-\(article.id)")
            }
            Button("Delete…", role: .destructive, action: requestRemoval)
                .disabled(removal.isSaving)
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(minWidth: 160, alignment: .leading)
        .controlSize(.regular)
    }

    func requestRemoval() {
        showsActions = false
        removal.request(.article(article))
    }

    func retryRemoval() {
        showsActions = false
        removal.retry(model: model)
    }

}

/// The article's real Larder control shares the episode action slot without changing the Feeds row.
struct WiltedMacLarderArticleAction: View {
    let model: WiltedMacModel
    let article: WiltedMacArticle

    /// Ready means the audio can start; the visible Play action must request autoplay on load.
    func play() {
        model.openNowPlaying(for: article, autoplay: true)
    }

    var body: some View {
        Group {
            if article.isReady {
                Button(action: play) {
                    Label("Play", systemImage: "play.fill")
                }
                .labelStyle(.iconOnly)
                .help("Play")
                .accessibilityLabel("Play \(article.title)")
                .accessibilityIdentifier("wilted-open-now-playing")
            } else {
                ProgressView().controlSize(.small)
                    .help("Preparing article")
                    .accessibilityLabel("Preparing \(article.title)")
            }
        }
        .controlSize(.small)
        .buttonStyle(WiltedMacLarderActionStyle())
        .frame(width: WiltedMacLarderView.readyActionSlotWidth, height: 32)
    }
}

/// The quieter of a pair of answers: the label and a thin outline, with no fill, so the filled
/// answer beside it reads as the primary one.
struct WiltedMacOutlinedButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let leaf = WiltedTheme.color(.wiltedLeaf, scheme: colorScheme)
        configuration.label
            .padding(.horizontal, WiltedTheme.Spacing.small)
            .padding(.vertical, 3)
            .foregroundStyle(leaf)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(leaf, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// The one "Last refreshed" value, shared by Feeds and the Larder: relative on screen, with the exact
/// date as its accessibility label and hover help. It re-reads the clock each minute.
struct WiltedMacLastRefreshedLabel: View {
    let model: WiltedMacModel
    let identifier: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text("Last refreshed: \(model.lastPodcastRefreshRelativeText(now: context.date))")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .help(model.lastPodcastRefreshExactText)
                .accessibilityLabel(model.lastPodcastRefreshExactText)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// The same resolved capacity and waiting set used by admission, shown beside the feed.
struct WiltedMacFeedCapacityLabel: View {
    let board: WiltedMacFeedPolicyBoard
    let subscription: WiltedMacSubscription
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label).wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("wilted-podcast-feed-count-\(subscription.id)")
    }

    private var label: String {
        if board.loadFailureMessage != nil { return "Settings unavailable" }
        guard board.isLoaded(subscription.id) else { return "Loading settings" }
        let kept = board.keptCount(forFeed: subscription.id)
        let limit = board.resolved(for: subscription.id).keptLimit
        let capacity = limit.map { "\(kept) of \($0) kept" } ?? "\(kept) kept · No limit"
        let waiting = board.waitingEpisodes(forFeed: subscription.id).count
        return "\(capacity) · \(waiting) waiting for space" + (subscription.enabled ? "" : " · Hidden")
    }
}

/// Read-only feed defaults name the controls that own their inherited values.
struct WiltedMacInheritedFeedDefaults: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ForEach(WiltedFeedAutomationSummary.globalRows(model.automationSettings).filter {
            $0.label == "Auto download" || $0.label == "Auto prepare"
        }, id: \.label) { row in
            HStack {
                Text(row.label).wiltedFont(.body)
                Spacer()
                Text("\(row.value) · Set in \(row.label == "Auto download" ? "Larder" : "Processing")")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            .accessibilityIdentifier("wilted-automation-feed-default-\(row.label.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
    }
}
