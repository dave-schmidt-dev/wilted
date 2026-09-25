import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Persistent Player
/// A fixed footer outside every destination's scroll view. It keeps playback
/// visible while the Larder moves and owns the complete local podcast surface.
enum WiltedMacPlayerSection: String, Hashable, CaseIterable {
    case transcript
    case notes

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .notes: "Notes"
        }
    }

    var expandedAccessibilityIdentifier: String {
        switch self {
        case .transcript: "wilted-player-transcript-expanded"
        case .notes: "wilted-player-notes-expanded"
        }
    }
}

enum WiltedMacPlayerLayout: Equatable {
    case rail
    case fullWindow

    /// Larder owns the outer destination scroll view. The inline transcript
    /// needs its own viewport so it can reveal an off-screen active cue.
    var synchronizedTranscriptViewportHeight: CGFloat? {
        switch self {
        case .rail: 280
        case .fullWindow: nil
        }
    }
}

struct WiltedMacCompactPlayer: View {
    @Bindable var model: WiltedMacModel
    @Binding var presentation: WiltedMacPlayerSection?
    private let focusRequest: WiltedMacPlayerSection?

    init(model: WiltedMacModel) {
        self.model = model
        _presentation = .constant(nil)
        focusRequest = nil
    }

    init(
        model: WiltedMacModel,
        presentation: Binding<WiltedMacPlayerSection?>,
        focusRequest: WiltedMacPlayerSection?
    ) {
        self.model = model
        _presentation = presentation
        self.focusRequest = focusRequest
    }

    var body: some View {
        WiltedMacPlayerContent(
            model: model,
            presentation: $presentation,
            layout: .rail,
            focusRequest: focusRequest,
            onCollapse: { _ in }
        )
        .padding(.horizontal, WiltedTheme.Spacing.medium)
        .padding(.vertical, WiltedTheme.Spacing.small)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback rail")
        .accessibilityValue(presentation == nil ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("wilted-compact-player")
    }

    @Environment(\.colorScheme) private var colorScheme

}

/// A presentation layer over the selected work destination, not a destination
/// itself. The root retains its selected navigation and model while this fills
/// the detail column, so collapsing returns to precisely the prior work view.
struct WiltedMacFullWindowPlayer: View {
    @Bindable var model: WiltedMacModel
    @Binding var presentation: WiltedMacPlayerSection?
    let onSelect: (WiltedMacPlayerSection) -> Void
    let onCollapse: (WiltedMacPlayerSection) -> Void

    init(
        model: WiltedMacModel,
        presentation: Binding<WiltedMacPlayerSection?>,
        onSelect: @escaping (WiltedMacPlayerSection) -> Void,
        onCollapse: @escaping (WiltedMacPlayerSection) -> Void
    ) {
        self.model = model
        _presentation = presentation
        self.onSelect = onSelect
        self.onCollapse = onCollapse
    }

    var body: some View {
        WiltedMacPlayerContent(
            model: model,
            presentation: $presentation,
            layout: .fullWindow,
            focusRequest: nil,
            onCollapse: onCollapse,
            onSelect: onSelect
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(WiltedTheme.Spacing.section)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-full-window")
    }

    @Environment(\.colorScheme) private var colorScheme
}

/// The rail and full-window presentation deliberately delegate here. It owns
/// every transport, label, identifier, enabled state, and selected pane, so a
/// visual change cannot give either form of Now Playing a different player.
