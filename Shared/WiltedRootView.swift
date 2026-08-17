import SwiftUI

public enum WiltedScreenCopy {
    public static let rootIdentifier = "wilted-root"
    public static let library = "Library"
    public static let libraryIdentifier = "wilted-library"
    public static let libraryEmpty = "Your library is empty"
    public static let noArticles = "No articles yet"
    public static let addArticle = "Add Article"
    public static let addArticleIdentifier = "wilted-add-article"
    public static let openPlayer = "Open Now Playing"
    public static let openPlayerIdentifier = "wilted-open-player"
    public static let stateActionIdentifier = "wilted-state-action"
    public static let libraryStateIdentifierPrefix = "wilted-state-"
    public static let downloads = "Downloads"
    public static let downloadsIdentifier = "wilted-downloads"
    public static let noDownloads = "No Downloads"
    public static let downloadsEmptyIdentifier = "wilted-no-downloads"
    public static let settings = "Settings"
    public static let settingsIdentifier = "wilted-settings"
    public static let audio = "Audio"
    public static let audioValue = "Local speech"
    public static let audioRowIdentifier = "wilted-audio-setting"
    public static let playerIdentifier = "wilted-player"
    public static let playerRewindIdentifier = "wilted-player-rewind"
    public static let playerPlayPauseIdentifier = "wilted-player-play-pause"
    public static let playerForwardIdentifier = "wilted-player-forward"
}

public enum WiltedNavigation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case library
    case downloads
    case settings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .library: WiltedScreenCopy.library
        case .downloads: WiltedScreenCopy.downloads
        case .settings: WiltedScreenCopy.settings
        }
    }

    public var symbolName: String {
        switch self {
        case .library: "books.vertical"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}

/// Shared native root shell. Mac uses a split navigation surface; iPhone uses
/// the same literal labels as tabs. Now Playing is a destination from content,
/// not a fourth permanent tab.
public struct WiltedRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: WiltedNavigation
    private let fixture: WiltedPreviewFixture
    private let iOSLibrary: AnyView?
    private let iOSDownloads: AnyView?

    public init(
        initialSelection: WiltedNavigation = .library,
        fixture: WiltedPreviewFixture = WiltedPreviewFixture(state: .emptyLibrary),
        iOSLibrary: AnyView? = nil,
        iOSDownloads: AnyView? = nil
    ) {
        _selection = State(initialValue: initialSelection)
        self.fixture = fixture
        self.iOSLibrary = iOSLibrary
        self.iOSDownloads = iOSDownloads
    }

    public var body: some View {
        Group {
#if os(macOS)
            NavigationSplitView {
                List(WiltedNavigation.allCases, selection: $selection) { item in
                    Label(item.title, systemImage: item.symbolName)
                        .tag(item)
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
                destination(for: .downloads)
                    .tabItem { Label(WiltedScreenCopy.downloads, systemImage: WiltedNavigation.downloads.symbolName) }
                    .tag(WiltedNavigation.downloads)
                destination(for: .settings)
                    .tabItem { Label(WiltedScreenCopy.settings, systemImage: WiltedNavigation.settings.symbolName) }
                    .tag(WiltedNavigation.settings)
            }
#endif
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        // Keep the root identifiable without turning it into an accessibility
        // container. The navigation labels and controls must remain visible
        // as independent elements to VoiceOver and XCUITest.
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
        case .downloads:
            #if os(iOS)
            if let iOSDownloads { iOSDownloads } else { WiltedDownloadsShell() }
            #else
            WiltedDownloadsShell()
            #endif
        case .settings:
            WiltedSettingsShell()
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
