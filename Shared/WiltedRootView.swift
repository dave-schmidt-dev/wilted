import SwiftUI

/// Elapsed and total playback time, in a form a person can read.
///
/// Both apps previously printed a raw second count, so a half-hour article
/// read "1743 seconds". Seconds are the right storage unit and the wrong
/// display unit. Kept beside the screen copy because that is what this is:
/// the words the player says about time.
public enum WiltedDuration {
    /// `h:mm:ss` at an hour or more, `m:ss` below it. Negative and
    /// non-finite inputs collapse to zero rather than printing `-1:-30`.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(bounded(seconds).rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The spoken form. VoiceOver reading "1743" is the same defect as
    /// printing it, and it cannot infer units from a colon.
    public static func spoken(_ seconds: TimeInterval) -> String {
        let total = Int(bounded(seconds).rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    /// The player's one-line readout: elapsed against total.
    public static func progress(position: TimeInterval, duration: TimeInterval) -> String {
        "\(clock(position)) of \(clock(duration))"
    }

    /// The spoken readout, for accessibility values.
    public static func spokenProgress(position: TimeInterval, duration: TimeInterval) -> String {
        "\(spoken(position)) of \(spoken(duration))"
    }

    private static func bounded(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? max(0, seconds) : 0
    }
}

public enum WiltedScreenCopy {
    public static let rootIdentifier = "wilted-root"
    public static let processor = "Prep"
    public static let processorIdentifier = "wilted-processor"
    public static let library = "Larder"
    public static let libraryIdentifier = "wilted-library"
    public static let libraryEmpty = "Your larder is empty"
    /// Both apps say the same thing about an empty library and then differ
    /// only on what the reader can do about it, because only Mac produces.
    public static let libraryEmptyDetailProducer = "Add an article to start listening."
    public static let libraryEmptyDetailListener = "Articles you prepare on your Mac appear here."
    public static let noArticles = "No articles yet"
    public static let addArticle = "Add Article"
    /// One box, both kinds. Two boxes asked the reader to classify the address
    /// before pasting it, which is work Wilted can do from the document itself.
    public static let addLink = "Add"
    public static let addLinkTitle = "Add an article or podcast"
    public static let addLinkDetail = "Paste an HTTPS address. Wilted works out whether it is an article or a podcast feed. "
        + "Saved articles, episodes, and audio stay on this Mac."
    public static let savedArticles = "Saved articles"
    public static let feeds = "Podcast feeds"
    public static let feedsIdentifier = "wilted-podcast-feeds"
    public static let feedsEmpty = "No podcast feeds yet"
    public static let feedsEmptyDetail = "Paste a podcast address into Larder's add box and the feed appears here with its own controls."
    /// Wilted refreshes only when asked and downloads only what the listener
    /// picks, so the Feeds card says so rather than letting an absent schedule
    /// read as a hidden one.
    public static let feedsPolicy = "Feeds refresh when you choose Refresh. No feed downloads audio on its own; "
        + "use Download on an episode to keep it offline."
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
    /// The two apps use different readiness language: Mac audio is ready after
    /// preparation, while listener audio is ready after download. Both route
    /// the reader through Larder because Downloads is no longer a destination.
    public static let nowPlayingEmptyDetailProducer = "Choose a ready article in Larder, then return here for playback controls."
    public static let nowPlayingEmptyDetailListener = "Choose a downloaded article in Larder, then return here for playback controls."
    public static let nowPlayingEmptyIdentifier = "wilted-player-empty"
    public static let settings = "Settings"
    public static let settingsIdentifier = "wilted-settings"
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
                    destination(for: .settings)
                }
                    .tabItem { Label(WiltedScreenCopy.settings, systemImage: WiltedNavigation.settings.symbolName) }
                    .tag(WiltedNavigation.settings)
            }
            // Fixture-only recovery controls are injected above the selected
            // navigation stack. A bottom inset occupies the tab bar's hit
            // region and can intercept Now Playing taps.
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
