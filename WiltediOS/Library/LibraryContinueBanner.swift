import SwiftUI
import WiltedLibrary

/// "Continue listening": shown above the mini-player when another device outranks this phone.
/// Says what it will do in words, including the resumed position, and spells out a refusal.
struct LibraryContinueBanner: View {
    @ObservedObject var model: LibraryAppModel

    var body: some View {
        LibraryContinueBannerContent(continuation: model.continuation,
            title: model.continuation.map { model.continuationTitle($0.entryID) } ?? "",
            media: model.continuation.map { model.mediaState(for: $0.entryID) } ?? .available,
            message: model.handoffMessage, now: model.now(), clockOffset: model.handoffState.clockOffset,
            onContinue: { Task { await model.continueFromMac() } }, canRequestAudio: model.deviceLinked)
    }

    /// True when there is anything to show.
    static func isVisible(_ model: LibraryAppModel) -> Bool { model.continuation != nil || model.handoffMessage != nil }

    static func detail(_ continuation: LibraryContinuation, media: LibraryMediaState, canRequest: Bool = true) -> String {
        LibraryContinueBannerContent.detail(continuation, media: media, canRequest: canRequest)
    }

    static func actionTitle(_ continuation: LibraryContinuation, media: LibraryMediaState, canRequest: Bool = true) -> String? {
        LibraryContinueBannerContent.actionTitle(continuation, media: media, canRequest: canRequest)
    }
}

/// The shipping banner contents; hosted rendering uses this same view with a fixed clock.
struct LibraryContinueBannerContent: View {
    let continuation: LibraryContinuation?
    let title: String
    let media: LibraryMediaState
    let message: String?
    let now: Date
    let clockOffset: TimeInterval
    let onContinue: () -> Void
    /// False until the Mac has linked this device; the banner then offers no request for audio.
    var canRequestAudio = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            if let message = message {
                Text(message)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                    .accessibilityIdentifier("wilted-handoff-message")
            }
            if let continuation = continuation {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                        Text(title).wiltedFont(.body).fixedSize(horizontal: false, vertical: true)
                        Text(Self.detail(continuation, media: media, canRequest: canRequestAudio))
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let age = LibraryContinuationAge(source: continuation.source, now: now, clockOffset: clockOffset)
                    Text(age.text).wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if age.isStale {
                        Text(LibraryContinuationAge.staleText).wiltedFont(.utility)
                            .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let title = Self.actionTitle(continuation, media: media, canRequest: canRequestAudio) {
                        Button(action: onContinue) {
                            Text(title)
                                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier("wilted-handoff-continue")
                    }
                }
            }
        }
        .padding(.horizontal, WiltedTheme.Spacing.large)
        .padding(.vertical, WiltedTheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-handoff-banner")
    }

    static func detail(_ continuation: LibraryContinuation, media: LibraryMediaState, canRequest: Bool = true) -> String {
        switch continuation {
        case let .ready(_, position, _, wasPlaying, _, _):
            "\(wasPlaying ? "Playing" : "Paused") on another device at \(LibraryClockFormat.duration(position))"
        case .needsAudio:
            media.isInFlight ? media.statusText()
                : canRequest ? "On another device. Get the audio from your Mac, then continue."
                : "On another device. Connecting to your Mac first."
        case let .refused(_, reason, _): reason
        }
    }

    /// Nil when nothing can be done: refused, a transfer is already running, or the Mac has not linked
    /// this device yet, so a request for audio could not be answered.
    static func actionTitle(_ continuation: LibraryContinuation, media: LibraryMediaState, canRequest: Bool = true) -> String? {
        switch continuation {
        case .ready: "Continue listening"
        case .needsAudio: media.isInFlight || !canRequest ? nil : "Get audio and continue"
        case .refused: nil
        }
    }
}

