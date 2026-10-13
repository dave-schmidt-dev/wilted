import SwiftUI

/// Both library surfaces open the exact row's notes without changing the queue.
struct WiltedMacEpisodeNotesTitle<Content: View>: View {
    let id: String
    let title: String
    let prefix: String
    let font: WiltedTheme.TypographyRole
    @Binding var isPresented: Bool
    var titleLineLimit = 1
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    /// A surface that knows only the identity and title a row carries, such as
    /// a History record or a playlist entry, without a whole `WiltedMacEpisode`.
    init(
        id: String,
        title: String,
        prefix: String,
        font: WiltedTheme.TypographyRole = .body,
        isPresented: Binding<Bool>,
        titleLineLimit: Int = 1,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.title = title
        self.prefix = prefix
        self.font = font
        self._isPresented = isPresented
        self.titleLineLimit = titleLineLimit
        self.content = content
    }

    /// The row's episode, when the surface has the whole row in hand.
    init(
        episode: WiltedMacEpisode,
        prefix: String,
        font: WiltedTheme.TypographyRole = .body,
        isPresented: Binding<Bool>,
        titleLineLimit: Int = 1,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            id: episode.id, title: episode.title, prefix: prefix, font: font,
            isPresented: isPresented, titleLineLimit: titleLineLimit, content: content)
    }

    var body: some View {
        Button { isPresented = true } label: {
            Text(title)
                .wiltedFont(font)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show notes for \(title)")
        .accessibilityLabel("Show notes for \(title)")
        .accessibilityIdentifier("\(prefix)-show-notes-\(id)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom, content: content)
    }
}

struct WiltedMacEpisodeNotes<Actions: View>: View {
    let info: WiltedMacEpisodeInfo
    let prefix: String
    /// The transcript source, when this popover offers the Transcript tab.
    /// Without one the popover is exactly the notes it always was.
    let source: WiltedMacEpisodeInfoSource?
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @State private var section: WiltedMacEpisodeNotesSection
    /// The transcript read is owned here, so it survives tab switches.
    @State private var transcriptLoad: WiltedMacEpisodeTranscriptLoad?
    @State private var transcriptAttempt = 0

    static func linkedNotes(for episode: WiltedMacEpisode) -> AttributedString? {
        linkedNotes(in: episode.notes)
    }

    private static func linkedNotes(in notes: String?) -> AttributedString? {
        guard let notes, !notes.isEmpty else { return nil }
        return WiltedShowNotes.linked(notes)
    }

    init(
        info: WiltedMacEpisodeInfo,
        prefix: String,
        source: WiltedMacEpisodeInfoSource? = nil,
        initialSection: WiltedMacEpisodeNotesSection = .notes,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.info = info
        self.prefix = prefix
        self.source = source
        self.actions = actions
        _section = State(initialValue: initialSection)
    }

    init(
        episode: WiltedMacEpisode,
        prefix: String,
        source: WiltedMacEpisodeInfoSource? = nil,
        initialSection: WiltedMacEpisodeNotesSection = .notes,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(
            info: WiltedMacEpisodeInfo(episode: episode), prefix: prefix, source: source,
            initialSection: initialSection, actions: actions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(info.title)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            WiltedMacEpisodeMetadata(
                presentation: info.presentation, identifier: "\(prefix)-notes-metadata-\(info.id)")
            if source != nil {
                Picker("Show notes or transcript", selection: $section) {
                    ForEach(WiltedMacEpisodeNotesSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Show notes or transcript")
                .accessibilityIdentifier("\(prefix)-notes-tabs-\(info.id)")
            }
            Divider()
            ScrollView {
                if section == .transcript, let source {
                    WiltedMacEpisodeTranscriptSection(
                        id: info.id, prefix: prefix, load: transcriptLoad, retry: retryTranscript
                    )
                    .task(id: transcriptAttempt) {
                        guard transcriptLoad == nil else { return }
                        transcriptLoad = await source.loadTranscript()
                    }
                } else if let notes = Self.linkedNotes(in: info.notes) {
                    Text(notes)
                        .wiltedFont(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("\(prefix)-notes-text-\(info.id)")
                } else {
                    Text("This episode's feed did not include show notes.")
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("\(prefix)-notes-unavailable-\(info.id)")
                }
            }
            .frame(maxHeight: .infinity)
            actions()
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 420, height: 360)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix)-notes-popover-\(info.id)")
    }

    private func retryTranscript() {
        transcriptLoad = nil
        transcriptAttempt += 1
    }
}

struct WiltedMacLarderEpisodeNotesTitle: View {
    let episode: WiltedMacEpisode
    @State private var isPresented = false

    var body: some View {
        WiltedMacEpisodeNotesTitle(episode: episode, prefix: "wilted-larder", isPresented: $isPresented, titleLineLimit: 2) {
            WiltedMacEpisodeNotes(episode: episode, prefix: "wilted-larder") { EmptyView() }
        }
    }
}
