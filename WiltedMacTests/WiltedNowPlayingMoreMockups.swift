import AppKit
import SwiftUI
import WiltedLibrary
@testable import WiltedMac

// Design artifacts only (B7c-2.9). Once Share and Mark completed left the Now Playing More popover, it
// holds playback speed, Restart and, during an audio route fault, Recover audio. These views place those
// three differently so the owner can choose; the shipping pane is unchanged and nothing here ships.

/// The shipping pane and the three alternatives compared against it.
enum NowPlayingMoreMockupOption: String, CaseIterable {
    case baseline, A, B, C

    var title: String {
        switch self {
        case .baseline: "Current · More popover"
        case .A: "A · Speed out front"
        case .B: "B · Control strip"
        case .C: "C · Native menu"
        }
    }

    var rationale: String {
        switch self {
        case .baseline:
            "The ellipsis button (More playback actions) opens a popover holding the speed pop-up, Restart and, "
                + "during a fault, Recover audio; changing speed takes three clicks."
        case .A:
            "Speed becomes a visible “Speed 1.25×” pull-down beside Share, worded like iPhone's and placed like the rail's, "
                + "and the ellipsis becomes a labelled More menu for the rarely used Restart and Recover audio."
        case .B:
            "One quiet row under the transport holds Speed, Restart and, during a fault, Recover audio, so nothing "
                + "is hidden; it costs one row of transcript height and puts Restart back in view."
        case .C:
            "The layout stays as it is, but the popover becomes a native pull-down menu with a Speed submenu, "
                + "Restart ⌘R and Recover audio, so every item is labelled and speed takes two clicks."
        }
    }
}

/// Which moment a render shows. `open` also puts the model in an audio route fault, so every control an
/// option offers, Recover audio included, is on screen or in its open menu.
enum NowPlayingMoreMockupState: String, CaseIterable {
    case rest, open, narrow

    /// The pane's real width band: widest for the two main states, narrowest to prove the controls fit.
    @MainActor var width: CGFloat {
        self == .narrow ? WiltedMacLarderLayout.paneWidth.lowerBound : WiltedMacLarderLayout.paneWidth.upperBound
    }
}

struct NowPlayingMoreMockupCapture {
    let name: String
    let image: NSImage
}

/// One render: the shipping pane for the baseline, a mockup pane for A, B and C.
@MainActor
struct NowPlayingMoreMockupView: View {
    let model: WiltedMacModel
    let option: NowPlayingMoreMockupOption
    let open: Bool

    var body: some View {
        if option == .baseline {
            NowPlayingMoreMockupBaseline(model: model, open: open)
        } else {
            NowPlayingMoreMockupPane(model: model, option: option, open: open)
        }
    }
}

/// The shipping pane, unchanged. Open, it shows the pane's own popover content where the popover
/// appears; an offscreen render cannot present a popover, so the frame around it is drawn and its
/// position is approximate.
@MainActor
private struct NowPlayingMoreMockupBaseline: View {
    let model: WiltedMacModel
    let open: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pane = WiltedMacNowPlayingPane(model: model, state: .constant(WiltedMacPaneState()))
        pane.overlay(alignment: .topTrailing) {
            if open {
                pane.playbackActions
                    .fixedSize()
                    .nowPlayingMoreMockupFloatingCard(scheme)
                    .padding(.top, 132)
                    .padding(.trailing, WiltedTheme.Spacing.small)
            }
        }
    }
}

/// A Now Playing pane built from the shipping pane's pieces, with speed, Restart and Recover audio placed
/// the way `option` proposes. Share stays beside the title and Mark completed stays in the transport row
/// in every option, as Phase 1 placed them.
@MainActor
private struct NowPlayingMoreMockupPane: View {
    let model: WiltedMacModel
    let option: NowPlayingMoreMockupOption
    let open: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var tab: WiltedMacPaneTab = .transcript
    @State private var followsPlayback = true

    var body: some View {
        VStack(spacing: WiltedTheme.Spacing.medium) {
            header
            // Above the rows that follow, so an open menu drawn below it is not covered.
            transportRow.zIndex(1)
            if option == .B { controlStrip }
            WiltedMacSpeedSaveLine(model: model)
            scrubber
            if showsStatus { status }
            tabs
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedTheme.color(.page, scheme: scheme))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            WiltedProduceTile(symbol: .cabbage, size: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(model.currentEpisode?.title ?? "Quiet Machines")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: scheme))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(model.currentEpisode?.presentation.playerSubtitleLabel ?? "Field Notes")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: scheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if option == .A { speedMenu }
            WiltedMacPlaybackShareLink(model: model).buttonStyle(.borderless)
        }
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: WiltedTheme.Spacing.xSmall) {
            transport("backward.end.fill", label: "Previous episode", action: model.previousPlayback)
                .disabled(!model.canSelectPreviousEpisode)
            transport("gobackward.15", label: "Rewind 15 seconds", action: model.rewind)
            transport(model.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                      label: model.isPlaying ? "Pause" : "Play", size: 48, action: model.togglePlayback)
                .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: scheme))
            transport("goforward.30", label: "Skip forward 30 seconds", action: model.forward)
            transport("forward.end.fill", label: "Next episode", action: model.nextPlayback)
                .disabled(!model.canSelectNextEpisode)
            completion
            switch option {
            case .A: labelledMoreMenu
            case .C: nativeMoreMenu
            case .baseline, .B: EmptyView()
            }
        }
        .controlSize(.regular)
    }

    private var completion: some View {
        Button(model.playbackCompletionIsSettled ? "Completed" : "Mark completed") {
            model.markCurrentPlaybackCompleted()
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(model.playbackCompletionIsSettled)
    }

    private func transport(
        _ symbol: String, label: String, size: CGFloat = 24, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .wiltedSquare(size)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Speed, Restart and Recover audio

    private var rateText: String { String(format: "%g×", model.playbackRate) }

    private var speedPicker: some View {
        Picker("Speed", selection: Binding(
            get: { model.playbackRate }, set: { model.setPlaybackRate($0) }
        )) {
            ForEach(PlaybackSpeeds.all, id: \.self) {
                Text("\($0, specifier: "%g")×").tag($0)
            }
        }
    }

    /// A: a "Speed" pull-down worded like the iPhone player's, beside Share where the rail player keeps its picker.
    private var speedMenu: some View {
        Menu {
            speedPicker.pickerStyle(.inline).labelsHidden()
        } label: {
            Text("Speed \(rateText)")
        }
        .fixedSize()
        .help("Playback speed")
        .accessibilityLabel("Speed")
    }

    /// A: the rare actions keep a menu, but it says what it is.
    private var labelledMoreMenu: some View {
        Menu("More") {
            restartItem
            recoverItem
        }
        .fixedSize()
        .help("More playback actions")
        .overlay(alignment: .topTrailing) {
            if open { NowPlayingMoreMockupMenuCard(items: actionItems).offset(y: 30) }
        }
    }

    /// C: the same single control as today, as a native pull-down menu instead of a popover.
    private var nativeMoreMenu: some View {
        Menu {
            Menu("Speed: \(rateText)") {
                speedPicker.pickerStyle(.inline).labelsHidden()
            }
            Divider()
            restartItem
            recoverItem
        } label: {
            Image(systemName: "ellipsis.circle")
                .wiltedSquare(24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More playback actions")
        .accessibilityLabel("More playback actions")
        .overlay(alignment: .topTrailing) {
            if open {
                NowPlayingMoreMockupMenuCard(items: [
                    .init(title: "Speed: \(rateText)", trailingSymbol: "chevron.right"), .divider
                ] + actionItems)
                .offset(y: 30)
            }
        }
    }

    /// B: one row for how the episode plays, directly under the transport and above the speed's save line.
    private var controlStrip: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            speedPicker
                .fixedSize()
                .help("Playback speed")
            Button("Restart", systemImage: "arrow.counterclockwise") { model.restartPlayback() }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
                .help("Play from the beginning")
            Spacer(minLength: 0)
            if model.audioRouteFault {
                Button("Recover audio", systemImage: "speaker.wave.2") { model.recoverAudioRoute() }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private var restartItem: some View {
        Button("Restart", systemImage: "arrow.counterclockwise") { model.restartPlayback() }
            .keyboardShortcut("r", modifiers: .command)
    }

    @ViewBuilder private var recoverItem: some View {
        if model.audioRouteFault {
            Button("Recover audio", systemImage: "speaker.wave.2") { model.recoverAudioRoute() }
        }
    }

    private var actionItems: [NowPlayingMoreMockupMenuCard.Item] {
        var items: [NowPlayingMoreMockupMenuCard.Item] = [
            .init(title: "Restart", symbol: "arrow.counterclockwise", shortcut: "⌘R")
        ]
        if model.audioRouteFault { items.append(.init(title: "Recover audio", symbol: "speaker.wave.2")) }
        return items
    }

    // MARK: Scrubber and status

    private var scrubber: some View {
        VStack(spacing: WiltedTheme.Spacing.xSmall) {
            Slider(value: Binding(
                get: { model.playbackPositionSeconds }, set: { model.scrub(to: $0) }
            ), in: 0...max(1, model.playbackDurationSeconds))
            .tint(WiltedTheme.color(.wiltedLeaf, scheme: scheme))
            .accessibilityLabel("Playback position")
            HStack {
                Text(WiltedMacScrubberLabels.elapsed(model.playbackPositionSeconds))
                Spacer()
                Text(WiltedMacScrubberLabels.remaining(
                    position: model.playbackPositionSeconds, duration: model.playbackDurationSeconds))
            }
            .wiltedFont(.utility)
            .monospacedDigit()
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: scheme))
            .accessibilityHidden(true)
        }
    }

    private var showsStatus: Bool {
        model.playbackStatusMessage != "Playing" && model.playbackStatusMessage != "Paused"
            && model.playbackCommands.pending?.usesPlayPauseButtonFeedback != true
    }

    private var status: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Text(model.playbackStatusMessage)
                .wiltedFont(.utility)
                .foregroundStyle(model.playbackStatusTone.color(scheme))
            WiltedMacPlaybackRetryButton(model: model)
        }
    }

    // MARK: Tabs

    private var tabs: some View {
        VStack(spacing: WiltedTheme.Spacing.small) {
            Picker("Section", selection: $tab) {
                ForEach(WiltedMacPaneTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch tab {
                case .transcript:
                    WiltedMacTranscriptPanel(model: model, viewportHeight: nil, following: $followsPlayback)
                case .notes:
                    WiltedMacNotesPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A drawn stand-in for an open native menu: an offscreen render cannot open an `NSMenu`, so the open
/// state is illustrated with the same items, symbols and shortcuts the native menu would list.
@MainActor
private struct NowPlayingMoreMockupMenuCard: View {
    struct Item {
        var title: String
        var symbol: String?
        var shortcut: String?
        var trailingSymbol: String?

        init(title: String, symbol: String? = nil, shortcut: String? = nil, trailingSymbol: String? = nil) {
            self.title = title
            self.symbol = symbol
            self.shortcut = shortcut
            self.trailingSymbol = trailingSymbol
        }

        static let divider = Item(title: "")
    }

    let items: [Item]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.title.isEmpty {
                    Divider().padding(.vertical, WiltedTheme.Spacing.xSmall)
                } else {
                    row(item)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(minWidth: 180, alignment: .leading)
        .fixedSize()
        .nowPlayingMoreMockupFloatingCard(scheme)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Image(systemName: item.symbol ?? "circle")
                .opacity(item.symbol == nil ? 0 : 1)
                .frame(width: 16)
            Text(item.title)
            Spacer(minLength: WiltedTheme.Spacing.xLarge)
            if let shortcut = item.shortcut {
                Text(shortcut).foregroundStyle(WiltedTheme.color(.secondaryText, scheme: scheme))
            }
            if let trailing = item.trailingSymbol {
                Image(systemName: trailing).foregroundStyle(WiltedTheme.color(.secondaryText, scheme: scheme))
            }
        }
        .wiltedFont(.body)
        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: scheme))
        .padding(.horizontal, WiltedTheme.Spacing.medium)
        .frame(height: 22)
    }
}

private extension View {
    /// The drawn frame of an open popover or menu: card surface, steel edge, soft shadow.
    func nowPlayingMoreMockupFloatingCard(_ scheme: ColorScheme) -> some View {
        background(WiltedTheme.color(.card, scheme: scheme),
                   in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: WiltedTheme.Radius.card)
                    .stroke(WiltedTheme.color(.steel, scheme: scheme), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// One light sheet: each column is an option at rest above the same option open during a fault.
@MainActor
struct NowPlayingMoreMockupComparison: View {
    let captures: [NowPlayingMoreMockupCapture]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Now Playing · where speed, Restart and Recover audio live").wiltedFont(.title)
            Text("Top: at rest. Bottom: the menu or popover open during an audio route fault. "
                 + "Open menus and the popover frame are drawn illustrations; positions are approximate. "
                 + "Light appearance, widest pane (480 pt).")
                .wiltedFont(.utility)
            HStack(alignment: .top, spacing: 20) {
                ForEach(NowPlayingMoreMockupOption.allCases, id: \.self) { option in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(option.title).wiltedFont(.body).fontWeight(.semibold)
                        Text(option.rationale)
                            .wiltedFont(.utility)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 72, alignment: .topLeading)
                        ForEach(["rest", "open"], id: \.self) { state in
                            if let capture = captures.first(where: { $0.name == "\(option.rawValue)-\(state)-light" }) {
                                Image(nsImage: capture.image).resizable().scaledToFit().frame(height: 470)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WiltedTheme.color(.page, scheme: .light))
        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: .light))
    }

    /// The owner-facing note written beside the renders.
    static let notes = """
    # Now Playing: where speed, Restart and Recover audio live (B7c-2.9)

    The control David asked about is the ellipsis button labelled "More playback actions". Today it opens a
    popover (a floating panel), not a menu, and the speed control inside it is a second pop-up, which is why it
    feels like a menu inside a drop-down. Phase 1 already moved Share beside the title and made Mark completed a
    bordered button; every option below keeps both where Phase 1 put them.

    | | Current | A · Speed out front | B · Control strip | C · Native menu |
    |---|---|---|---|---|
    | Speed | In the popover; 3 clicks | "Speed 1.25×" pull-down beside Share; 2 clicks, value always visible | Speed pop-up in a row under the transport; 2 clicks, always visible | Submenu of a native menu; 2 clicks plus a hover |
    | Restart | In the popover; ⌘R | Labelled More menu; ⌘R shown | Visible small button; ⌘R | Native menu item; ⌘R shown |
    | Recover audio (faults only) | In the popover | More menu | Visible in the row | Native menu item |
    | Extra height | None | None | One small row | None |
    | Tradeoff | Awkward two-level control | The More menu holds one item until a fault | Restart is visible again, which an earlier owner note said competes with the transport | Speed stays hidden |

    Recommendation: A. Speed is the frequent control, so it becomes visible and reads like iPhone's "Speed" menu
    and the rail player (speed beside Share); the rare Restart stays out of the way in a menu that says what it
    is. B is the choice if nothing should be hidden; C is the smallest change.

    Renders: `<option>-<rest|open|narrow>-<light|dark>.png`. `open` is the same pane during an audio route
    fault with the menu or popover open; `narrow` is the narrowest pane (420 pt). Open native menus and the
    popover frame are drawn illustrations, because an offscreen render cannot open them, and their positions
    are approximate. Synthetic episode and transcript; native SwiftUI offscreen renders; no shipping UI change.
    Owner choice pending.

    ![Comparison](comparison.png)
    """
}
