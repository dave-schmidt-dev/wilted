import SwiftUI

/// How the Larder's detail region divides between the list and a side Now
/// Playing pane. The pane is held to a narrow band and the list takes
/// everything else: extra window width goes to the list the reader is
/// scanning, not to a player that has nothing more to show. Pure, so the
/// split is a test rather than a screenshot.
enum WiltedMacLarderLayout {
    /// The pane's width range: 30% of the detail region, held to this band.
    static let paneWidth: ClosedRange<CGFloat> = 420...480
    static let paneShare: CGFloat = 0.30
    /// The least width the list keeps beside the pane.
    static let listMinimumWidth: CGFloat = 480
    static let dividerWidth: CGFloat = 1

    /// Not scaled with the text: the pane is artwork and centred controls
    /// rather than running text, and the owner asked for 420-480pt. Larger
    /// type is given room by the list, which takes whatever the pane leaves.
    static func paneColumnWidth(detailWidth: CGFloat) -> CGFloat {
        min(max(detailWidth * paneShare, paneWidth.lowerBound), paneWidth.upperBound)
    }

    static func listColumnWidth(detailWidth: CGFloat) -> CGFloat {
        max(0, detailWidth - paneColumnWidth(detailWidth: detailWidth) - dividerWidth)
    }
}

/// The navigation sidebar keeps its column: labelled when expanded and
/// wide enough, otherwise the same icon-only rail.
enum WiltedMacSidebarMode: Equatable { case full, rail }

/// Where the Now Playing pane sits: beside the list, or in the bar beneath
/// it. It is never hidden.
enum WiltedMacPaneMode: Equatable { case side, bottom }

/// Everything the window's width decides, in one place.
///
/// A narrowing window gives up space in a fixed order: the sidebar first
/// becomes a rail, then the pane drops from the side to the bottom bar. A
/// widening one reverses both. The pane's mode is decided here, from the
/// window, rather than from the detail region the sidebar leaves it:
/// otherwise the sidebar shrinking to a rail would hand the detail region
/// forty-odd points back and could flip the pane at the very threshold that
/// caused it. The widths are the ones the layout renders -- the sidebar and
/// the list scale with the text, the pane and the rail do not.
struct WiltedMacShellLayout: Equatable {
    let sidebar: WiltedMacSidebarMode
    let pane: WiltedMacPaneMode

    /// The rail holds one icon per destination.
    static let railWidth: CGFloat = 56
    /// The labelled sidebar's ideal width; the column may be dragged within
    /// `sidebarWidth`, which the thresholds do not chase.
    static let sidebarIdealWidth: CGFloat = 200
    static let sidebarWidth: ClosedRange<CGFloat> = 180...260
    /// Room left over beyond the columns themselves.
    static let slack: CGFloat = 40

    /// Below this window width the labelled sidebar gives way to the rail.
    static func fullSidebarMinimumWidth(scale: WiltedTheme.TextScale = .standard) -> CGFloat {
        WiltedTheme.scaled(sidebarIdealWidth, scale: scale) + sideContentWidth(scale: scale)
    }

    /// Below this window width the pane drops to the bottom bar.
    static func sidePaneMinimumWidth(scale: WiltedTheme.TextScale = .standard) -> CGFloat {
        railWidth + sideContentWidth(scale: scale)
    }

    /// The narrowest window: the rail and a list, with the bar beneath.
    static func windowMinimumWidth(scale: WiltedTheme.TextScale = .standard) -> CGFloat {
        railWidth + WiltedTheme.scaled(WiltedMacLarderLayout.listMinimumWidth, scale: scale) + slack
    }

    private static func sideContentWidth(scale: WiltedTheme.TextScale) -> CGFloat {
        WiltedTheme.scaled(WiltedMacLarderLayout.listMinimumWidth, scale: scale)
            + WiltedMacLarderLayout.paneWidth.lowerBound
            + WiltedMacLarderLayout.dividerWidth + slack
    }

    /// The saved preference controls labels, never whether navigation exists.
    /// False keeps the rail at every width; true expands labels when there is
    /// room. Both reserve the rail's width before the player can sit beside it.
    static func resolve(
        windowWidth: CGFloat, scale: WiltedTheme.TextScale = .standard, sidebarVisible: Bool = true
    ) -> WiltedMacShellLayout {
        if sidebarVisible && windowWidth >= fullSidebarMinimumWidth(scale: scale) {
            return WiltedMacShellLayout(sidebar: .full, pane: .side)
        }
        if windowWidth >= sidePaneMinimumWidth(scale: scale) {
            return WiltedMacShellLayout(sidebar: .rail, pane: .side)
        }
        return WiltedMacShellLayout(sidebar: .rail, pane: .bottom)
    }

    /// The one placement rule: every destination places the player and the
    /// sidebar identically at the same window width. The destination is a
    /// parameter so the rule is a tested contract the root view calls, not an
    /// assumption spread over three call sites.
    static func resolve(
        for destination: WiltedMacNavigation, windowWidth: CGFloat,
        scale: WiltedTheme.TextScale = .standard, sidebarVisible: Bool = true
    ) -> WiltedMacShellLayout {
        _ = destination
        return resolve(windowWidth: windowWidth, scale: scale, sidebarVisible: sidebarVisible)
    }
}

/// What a Larder row shows about listening progress: the bar and the
/// "time left" wording. The wording matches the CarPlay list rows
/// (`mm:ss left`), so the same episode reads the same on both surfaces.
struct WiltedMacEpisodeProgress: Equatable {
    /// 0...1 of the episode heard.
    let fraction: Double
    let timeLeftLabel: String

    /// Nil unless the episode is partway through: not started, finished, or
    /// of unknown length have nothing honest to draw.
    init?(positionSeconds: TimeInterval, durationSeconds: TimeInterval?, isPlayed: Bool) {
        guard !isPlayed,
              positionSeconds.isFinite, positionSeconds > 0,
              let duration = durationSeconds, duration.isFinite, duration > 0
        else { return nil }
        let heard = min(positionSeconds, duration)
        fraction = heard / duration
        timeLeftLabel = Self.clock(duration - heard) + " left"
    }

    /// `mm:ss`, or `h:mm:ss` from one hour up, as the CarPlay rows draw it.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
