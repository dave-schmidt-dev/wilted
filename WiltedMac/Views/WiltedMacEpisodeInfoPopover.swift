import SwiftUI

/// One episode-name surface: the title a reader clicks, and the info popover
/// that click opens.
///
/// A surface that already holds the episode seeds the popover and it draws at
/// once. History and the rules preview hold only the identity the stored row
/// carried, so their popover resolves it through the source as it opens and
/// shows a spinner until an answer arrives.
struct WiltedMacEpisodeInfoPopover<Actions: View>: View {
    private let id: String
    private let title: String
    private let prefix: String
    private let font: WiltedTheme.TypographyRole
    private let source: WiltedMacEpisodeInfoSource?
    /// Non-nil for a seeded popover; a by-ID open resolves its own info.
    private let seed: WiltedMacEpisodeInfo?
    private let initialSection: WiltedMacEpisodeNotesSection
    private let actions: () -> Actions
    @State private var isPresented = false

    init(
        info: WiltedMacEpisodeInfo,
        prefix: String,
        font: WiltedTheme.TypographyRole = .body,
        source: WiltedMacEpisodeInfoSource? = nil,
        initialSection: WiltedMacEpisodeNotesSection = .notes,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.id = info.id
        self.title = info.title
        self.prefix = prefix
        self.font = font
        self.source = source
        self.seed = info
        self.initialSection = initialSection
        self.actions = actions
    }

    init(
        episode: WiltedMacEpisode,
        prefix: String,
        font: WiltedTheme.TypographyRole = .body,
        source: WiltedMacEpisodeInfoSource? = nil,
        initialSection: WiltedMacEpisodeNotesSection = .notes,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(
            info: WiltedMacEpisodeInfo(episode: episode), prefix: prefix, font: font,
            source: source, initialSection: initialSection, actions: actions)
    }

    /// The caller knows the row's title from its own record and passes it;
    /// nothing is read until the popover opens.
    init(
        id: String,
        title: String,
        prefix: String,
        font: WiltedTheme.TypographyRole = .body,
        source: WiltedMacEpisodeInfoSource,
        initialSection: WiltedMacEpisodeNotesSection = .notes,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.id = id
        self.title = title
        self.prefix = prefix
        self.font = font
        self.source = source
        self.seed = nil
        self.initialSection = initialSection
        self.actions = actions
    }

    var body: some View {
        WiltedMacEpisodeNotesTitle(
            id: id, title: title, prefix: prefix, font: font, isPresented: $isPresented
        ) {
            WiltedMacEpisodeInfoPopoverContent(
                id: id, seed: seed, prefix: prefix, source: source,
                initialSection: initialSection, actions: actions)
        }
    }
}

/// What a title's popover draws. The by-ID branch owns the one read that has
/// no answer yet, so the spinner, the neutral not-found state, and the error
/// with Retry all live here; the loaded answer is the ordinary notes body.
struct WiltedMacEpisodeInfoPopoverContent<Actions: View>: View {
    let id: String
    let seed: WiltedMacEpisodeInfo?
    let prefix: String
    let source: WiltedMacEpisodeInfoSource?
    let initialSection: WiltedMacEpisodeNotesSection
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @State private var load: WiltedMacEpisodeInfoLoad?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let seed {
                WiltedMacEpisodeNotes(
                    info: seed, prefix: prefix, source: source,
                    initialSection: initialSection, actions: actions)
            } else {
                switch load {
                case nil:
                    loading
                case .loaded(let info):
                    WiltedMacEpisodeNotes(
                        info: info, prefix: prefix, source: source,
                        initialSection: initialSection, actions: actions)
                case .notFound:
                    notFound
                case .failed:
                    failure
                }
            }
        }
        .task(id: attempt) {
            guard seed == nil, load == nil, let source else { return }
            load = await source.loadInfo()
        }
    }

    private var loading: some View {
        VStack(spacing: WiltedTheme.Spacing.small) {
            ProgressView().controlSize(.small)
            Text("Loading episode…")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 420, height: 360)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(prefix)-notes-loading-\(id)")
    }

    private var notFound: some View {
        Text("No saved details for this episode.")
            .wiltedFont(.body)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(WiltedTheme.Spacing.large)
            .frame(width: 420, height: 360)
            .background(WiltedTheme.color(.card, scheme: colorScheme))
            .accessibilityIdentifier("\(prefix)-notes-unavailable-\(id)")
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Could not load this episode's details.")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { retry() }
                .accessibilityIdentifier("\(prefix)-notes-retry-\(id)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 420, height: 360)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix)-notes-popover-\(id)")
    }

    private func retry() {
        load = nil
        attempt += 1
    }
}
