import SwiftUI

public enum WiltedScreenCopy {
    public static let rootIdentifier = "wilted-root"
    public static let library = "Library"
    public static let libraryIdentifier = "wilted-library"
    public static let libraryEmpty = "Your library is empty"
    /// Both apps say the same thing about an empty library and then differ
    /// only on what the reader can do about it, because only Mac produces.
    public static let libraryEmptyDetailProducer = "Add an article to start listening."
    public static let libraryEmptyDetailListener = "Articles you prepare on your Mac appear here."
    public static let noArticles = "No articles yet"
    public static let addArticle = "Add Article"
    public static let addArticleTitle = "Add an article"
    public static let addArticleDetail = "Paste an HTTPS article URL. Wilted keeps the saved article and audio on this Mac."
    public static let savedArticles = "Saved articles"
    public static let addArticleIdentifier = "wilted-add-article"
    public static let openPlayer = "Open Now Playing"
    public static let openPlayerIdentifier = "wilted-open-player"
    public static let stateActionIdentifier = "wilted-state-action"
    public static let libraryStateIdentifierPrefix = "wilted-state-"
    public static let downloads = "Downloads"
    public static let downloadsIdentifier = "wilted-downloads"
    public static let noDownloads = "No Downloads"
    public static let downloadsEmptyIdentifier = "wilted-no-downloads"
    public static let nowPlaying = "Now Playing"
    public static let nowPlayingEmpty = "Nothing is playing"
    /// The two apps have different destination sets, so copy that names a
    /// destination cannot be one string. The Mac has no Downloads: audio is
    /// local the moment it is produced. Telling a producer to visit a place
    /// its window does not have is the same defect as listing it in the
    /// sidebar.
    public static let nowPlayingEmptyDetailProducer = "Choose a ready article in Library, then return here for playback controls."
    public static let nowPlayingEmptyDetailListener = "Choose a downloaded article from Library or Downloads, then return here for playback controls."
    public static let nowPlayingEmptyIdentifier = "wilted-player-empty"
    public static let settings = "Settings"
    public static let settingsIdentifier = "wilted-settings"
    public static let audio = "Audio"
    public static let audioValue = "Local speech"
    public static let audioMode = "Speech mode"
    public static let audioRowIdentifier = "wilted-audio-setting"
    public static let sync = "Sync"
    /// Account recovery is worded identically on both platforms. Before this
    /// was shared, only the Mac had the control at all; the listener showed a
    /// non-retryable red line and no way out of quarantine.
    public static let useCurrentAccount = "Use Current iCloud Account"
    public static let useCurrentAccountIdentifier = "wilted-use-current-account"
    public static let useCurrentAccountDetail = "Wilted paused sync and kept your local work. Review before continuing with the account now signed in."
    public static let sendPlaybackProgress = "Send Playback Progress"
    public static let playerIdentifier = "wilted-player"
    public static let playerRewindIdentifier = "wilted-player-rewind"
    public static let playerPlayPauseIdentifier = "wilted-player-play-pause"
    public static let playerForwardIdentifier = "wilted-player-forward"
}

public enum WiltedNavigation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case library
    case nowPlaying
    case downloads
    case settings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .library: WiltedScreenCopy.library
        case .nowPlaying: WiltedScreenCopy.nowPlaying
        case .downloads: WiltedScreenCopy.downloads
        case .settings: WiltedScreenCopy.settings
        }
    }

    public var symbolName: String {
        switch self {
        case .library: "books.vertical"
        case .nowPlaying: "waveform"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}

/// Shared native root shell. The shipping Mac app owns its producer-specific
/// split view; iPhone exposes every listener feature as a permanent tab.
public struct WiltedRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: WiltedNavigation
    private let fixture: WiltedPreviewFixture
    private let iOSLibrary: AnyView?
    private let iOSNowPlaying: AnyView?
    private let iOSDownloads: AnyView?
    private let iOSSettings: AnyView?
    private let iOSOverlay: AnyView?

    public init(
        initialSelection: WiltedNavigation = .library,
        fixture: WiltedPreviewFixture = WiltedPreviewFixture(state: .emptyLibrary),
        iOSLibrary: AnyView? = nil,
        iOSNowPlaying: AnyView? = nil,
        iOSDownloads: AnyView? = nil,
        iOSSettings: AnyView? = nil,
        iOSOverlay: AnyView? = nil
    ) {
        _selection = State(initialValue: initialSelection)
        self.fixture = fixture
        self.iOSLibrary = iOSLibrary
        self.iOSNowPlaying = iOSNowPlaying
        self.iOSDownloads = iOSDownloads
        self.iOSSettings = iOSSettings
        self.iOSOverlay = iOSOverlay
    }

    public var body: some View {
        Group {
#if os(macOS)
            NavigationSplitView {
                List {
                    // This shared shell is preview-only on Mac, but it must
                    // still name the destinations the shipping producer has, or
                    // the previews and pixel baselines document a window that
                    // does not exist. Downloads is the one listener-only
                    // destination: Mac audio is local the moment it is
                    // produced, so there is nothing for it to download.
                    ForEach(WiltedNavigation.allCases.filter { $0 != .downloads }) { item in
                        Button {
                            selection = item
                        } label: {
                            Label(item.title, systemImage: item.symbolName)
                                .foregroundStyle(
                                    item == selection
                                        ? WiltedTheme.color(.primaryText, scheme: colorScheme)
                                        : WiltedTheme.color(.secondaryText, scheme: colorScheme)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .listRowBackground(
                            item == selection
                                ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.24)
                                : Color.clear
                        )
                        .accessibilityIdentifier("wilted-navigation-\(item.rawValue)")
                    }
                }
                .navigationTitle("Wilted")
            } detail: {
                NavigationStack {
                    destination(for: selection)
                }
            }
#else
            TabView(selection: $selection) {
                NavigationStack {
                    destination(for: .library)
                }
                    .tabItem { Label(WiltedScreenCopy.library, systemImage: WiltedNavigation.library.symbolName) }
                    .tag(WiltedNavigation.library)

                NavigationStack {
                    destination(for: .nowPlaying)
                }
                    .tabItem { Label(WiltedScreenCopy.nowPlaying, systemImage: WiltedNavigation.nowPlaying.symbolName) }
                    .tag(WiltedNavigation.nowPlaying)

                NavigationStack {
                    destination(for: .downloads)
                }
                    .tabItem { Label(WiltedScreenCopy.downloads, systemImage: WiltedNavigation.downloads.symbolName) }
                    .tag(WiltedNavigation.downloads)

                NavigationStack {
                    destination(for: .settings)
                }
                    .tabItem { Label(WiltedScreenCopy.settings, systemImage: WiltedNavigation.settings.symbolName) }
                    .tag(WiltedNavigation.settings)
            }
            // Fixture-only recovery controls are injected above the selected
            // navigation stack. A bottom inset occupies the tab bar's hit
            // region and can intercept Now Playing and Downloads taps.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let iOSOverlay { iOSOverlay }
            }
#endif
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        // Expose the root as a containing element so its identifier does not
        // replace identifiers owned by injected fixture controls.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedScreenCopy.rootIdentifier)
    }

    @ViewBuilder
    private func destination(for item: WiltedNavigation) -> some View {
        switch item {
        case .library:
            #if os(iOS)
            if let iOSLibrary { iOSLibrary } else { WiltedLibraryShell(fixture: fixture) }
            #else
            WiltedLibraryShell(fixture: fixture)
            #endif
        case .nowPlaying:
            #if os(iOS)
            if let iOSNowPlaying {
                iOSNowPlaying
            } else if fixture.state == .ready || fixture.state == .playing || fixture.state == .paused {
                WiltedPlayerShell(fixture: fixture)
            } else {
                WiltedNowPlayingEmptyView(detail: WiltedScreenCopy.nowPlayingEmptyDetailListener)
            }
            #else
            WiltedPlayerShell(fixture: fixture)
            #endif
        case .downloads:
            #if os(iOS)
            if let iOSDownloads { iOSDownloads } else { WiltedDownloadsShell() }
            #else
            WiltedDownloadsShell()
            #endif
        case .settings:
            #if os(iOS)
            if let iOSSettings { iOSSettings } else { WiltedSettingsShell() }
            #else
            WiltedSettingsShell()
            #endif
        }
    }
}

#Preview("Library / dark") {
    WiltedRootView()
        .preferredColorScheme(.dark)
}

#Preview("State matrix / light") {
    ScrollView {
        LazyVStack(spacing: WiltedTheme.Spacing.medium) {
            ForEach(WiltedPreviewFixture.matrix) { fixture in
                WiltedStateCard(fixture: fixture)
            }
        }
        .padding()
    }
}

#Preview("State matrix / dark / XXXL / reduced motion") {
    ScrollView {
        LazyVStack(spacing: WiltedTheme.Spacing.medium) {
            ForEach(WiltedPreviewFixture.matrix) { fixture in
                WiltedStateCard(fixture: fixture)
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.xxxLarge)
    .transaction { transaction in
        transaction.animation = nil
    }
}
