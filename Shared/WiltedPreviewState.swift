import Foundation

/// Stable state vocabulary for previews, UI tests, and empty/loading/error
/// rendering. These are presentation states, not persistence records.
public enum WiltedPreviewState: CaseIterable, Hashable, Identifiable, Sendable {
    public enum PreparationStage: String, CaseIterable, Hashable, Sendable {
        case fetching
        case extracting
        case synthesizing
        case assembling
        case saving

        public var title: String {
            switch self {
            case .fetching: "Fetching article"
            case .extracting: "Extracting text"
            case .synthesizing: "Making speech"
            case .assembling: "Assembling audio"
            case .saving: "Saving revision"
            }
        }
    }

    case emptyLibrary
    case preparing(PreparationStage)
    case cancelling
    case extractionFailure
    case speechUnavailable
    case ready
    case playing
    case paused
    case completed
    case syncPending
    case iCloudUnavailable
    case offlineCached
    case downloadFailure
    case deletedRemotely
    case incompatibleRevision

    public static var allCases: [WiltedPreviewState] {
        [.emptyLibrary]
            + PreparationStage.allCases.map(Self.preparing)
            + [
                .cancelling, .extractionFailure, .speechUnavailable, .ready,
                .playing, .paused, .completed, .syncPending, .iCloudUnavailable,
                .offlineCached, .downloadFailure, .deletedRemotely, .incompatibleRevision
            ]
    }

    public var id: String {
        switch self {
        case .preparing(let stage): "preparing-\(stage.rawValue)"
        default: String(describing: self)
        }
    }

    public var title: String {
        switch self {
        case .emptyLibrary: "Your larder is empty"
        case .preparing(let stage): stage.title
        case .cancelling: "Cancelling preparation"
        case .extractionFailure: "Article text is unavailable"
        case .speechUnavailable: "Speech service is unavailable"
        case .ready: "Ready to play"
        case .playing: "Playing"
        case .paused: "Paused"
        case .completed: "Completed"
        case .syncPending: "Sync pending"
        case .iCloudUnavailable: "iCloud is unavailable"
        case .offlineCached: "Offline audio available"
        case .downloadFailure: "Download failed"
        case .deletedRemotely: "Removed from the larder"
        case .incompatibleRevision: "Revision is incompatible"
        }
    }

    public var detail: String {
        switch self {
        case .emptyLibrary: "Add an article on your Mac to start listening."
        case .preparing: "Wilted is working. You can cancel at any stage."
        case .cancelling: "The current work will stop without replacing saved audio."
        case .extractionFailure: "The page did not provide readable article text."
        case .speechUnavailable: "Check the local speech service, then try again."
        case .ready: "This revision is ready for playback."
        case .playing: "Playback is active."
        case .paused: "Playback is paused."
        case .completed: "You reached the end of this revision."
        case .syncPending: "Changes will send when the connection is available."
        case .iCloudUnavailable: "The local larder remains available while iCloud is offline."
        case .offlineCached: "This download can play without a connection."
        case .downloadFailure: "The audio was not saved. Try the download again."
        case .deletedRemotely: "The source item was removed on another device."
        case .incompatibleRevision: "Update Wilted before selecting this revision."
        }
    }

    public var symbolName: String {
        switch self {
        case .emptyLibrary: "tray"
        case .preparing: "waveform"
        case .cancelling: "xmark.circle"
        case .extractionFailure, .downloadFailure: "exclamationmark.triangle"
        case .speechUnavailable: "speaker.slash"
        case .ready: "play.circle"
        case .playing: "play.fill"
        case .paused: "pause.fill"
        case .completed: "checkmark.circle"
        case .syncPending: "arrow.triangle.2.circlepath"
        case .iCloudUnavailable, .offlineCached: "icloud.slash"
        case .deletedRemotely: "trash"
        case .incompatibleRevision: "questionmark.folder"
        }
    }

    public var isCancellable: Bool {
        if case .preparing = self { return true }
        return false
    }

    public var accessibilityStatus: String {
        "\(title). \(detail)"
    }

    /// Stable identifier for the state container used by native UI tests.
    public var accessibilityIdentifier: String {
        "\(WiltedScreenCopy.libraryStateIdentifierPrefix)\(id)"
    }

    /// Canonical presentation metadata used by snapshot-equivalent tests. It
    /// is deliberately text, not a platform screenshot, so both targets can
    /// verify the same state contract in a headless runner.
    public func renderSignature(variant: WiltedVisualVariant) -> String {
        let input = [
            "wilted-render-v1",
            id,
            variant.id,
            symbolName,
            title,
            detail,
            isCancellable ? "cancellable" : "terminal",
            WiltedMark.geometrySignature
        ].joined(separator: "|")
        return WiltedVisualVariant.fnv1a(input)
    }
}

public enum WiltedAppearance: String, CaseIterable, Hashable, Sendable {
    case light
    case dark
}

public enum WiltedDynamicType: String, CaseIterable, Hashable, Sendable {
    case standard
    case xxxLarge
}

public struct WiltedVisualVariant: Hashable, Sendable {
    public let appearance: WiltedAppearance
    public let dynamicType: WiltedDynamicType
    public let reduceMotion: Bool

    public init(
        appearance: WiltedAppearance,
        dynamicType: WiltedDynamicType,
        reduceMotion: Bool
    ) {
        self.appearance = appearance
        self.dynamicType = dynamicType
        self.reduceMotion = reduceMotion
    }

    public var id: String {
        "\(appearance.rawValue)-\(dynamicType.rawValue)-motion-\(reduceMotion ? "reduced" : "full")"
    }

    /// The deterministic visual matrix is the minimum review surface for each
    /// state: light/dark, default/XXXL text, and Reduce Motion on/off.
    public static let matrix: [WiltedVisualVariant] = WiltedAppearance.allCases.flatMap { appearance in
        WiltedDynamicType.allCases.flatMap { dynamicType in
            [
                WiltedVisualVariant(appearance: appearance, dynamicType: dynamicType, reduceMotion: false),
                WiltedVisualVariant(appearance: appearance, dynamicType: dynamicType, reduceMotion: true)
            ]
        }
    }

    fileprivate static func fnv1a(_ input: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

public struct WiltedPreviewFixture: Identifiable, Hashable, Sendable {
    public let id: String
    public let state: WiltedPreviewState
    public let articleTitle: String
    public let sourceLabel: String

    public init(
        state: WiltedPreviewState,
        articleTitle: String = "Fixture article",
        sourceLabel: String = "Example source"
    ) {
        self.id = state.id
        self.state = state
        self.articleTitle = articleTitle
        self.sourceLabel = sourceLabel
    }

    public static let matrix: [WiltedPreviewFixture] = WiltedPreviewState.allCases.map { state in
        WiltedPreviewFixture(state: state)
    }

    /// UI-test launch arguments select static content without introducing a
    /// persistence or playback dependency into the native shell.
    public static func fromLaunchArguments(_ arguments: [String]) -> Self {
        if arguments.contains("--wilted-ui-fixture-playing") {
            return Self(state: .playing)
        }
        if arguments.contains("--wilted-ui-fixture-ready") {
            return Self(state: .ready)
        }
        return Self(state: .emptyLibrary)
    }
}
