import AppKit
import SwiftUI

/// The producer window.
///
/// One sidebar of permanent destinations, and exactly one of them filling the
/// detail region. The previous composition rendered the Library surface
/// unconditionally and merely *appended* a player pane, so selecting a
/// destination changed nothing, the sidebar repeated the article list the
/// detail already showed, and "Add an article" stayed in the middle of the
/// window no matter what was selected. Owner acceptance rejected that on
/// 2026-08-25. Playback no longer needs to sit beside the producer surface to
/// stay reachable — the sidebar keeps Now Playing one click away, which is the
/// same guarantee the listener's tab bar gives.
struct WiltedMacRootView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedNavigation) {
                ForEach(WiltedMacNavigation.allCases) { destination in
                    Button {
                        model.selectedNavigation = destination
                    } label: {
                        Label(destination.title, systemImage: destination.symbolName)
                            .foregroundStyle(
                                model.selectedNavigation == destination
                                    ? WiltedTheme.color(.primaryText, scheme: colorScheme)
                                    : WiltedTheme.color(.secondaryText, scheme: colorScheme)
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .listRowBackground(
                        model.selectedNavigation == destination
                            ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.24)
                            : Color.clear
                    )
                    .accessibilityIdentifier("wilted-navigation-\(destination.rawValue)")
                }
            }
            // The sidebar carries a page-token background rather than the
            // default AppKit material. It matches the rest of the palette, and
            // the material was additionally invisible to offscreen rendering,
            // which is why the navigation column recorded as a blank rectangle
            // in every Mac pixel baseline.
            .scrollContentBackground(.hidden)
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .navigationTitle("Wilted")
            .accessibilityIdentifier("wilted-mac-sidebar")
        } detail: {
            switch model.selectedNavigation {
            case .library:
                WiltedMacLibraryView(model: model)
            case .nowPlaying:
                WiltedMacNowPlayingView(model: model)
            case .processor:
                WiltedMacProcessorView(model: model)
            case .settings:
                WiltedMacSettingsView(model: model)
            }
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .toolbar { wordmark }
        // Three names for the same thing sat in one toolbar: the mark, the
        // window title beside it, and the destination heading below. macOS 26
        // draws the title as its own toolbar item, which `titleVisibility`
        // no longer suppresses, so remove the item where the API exists and
        // keep the AppKit fallback for macOS 14.
        .wiltedRemovingToolbarTitle()
        .background(WiltedWindowTitleHider())
        .accessibilityIdentifier("wilted-mac-root")
    }

    /// The wordmark states the brand at the top of the window. macOS 26 gives
    /// every toolbar item a glass capsule, which reads as a stray button
    /// behind letterforms that already have their own silhouette, so the
    /// shared background is opted out of where the API exists.
    @ToolbarContentBuilder
    private var wordmark: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                WiltedWordmark(height: 16)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                WiltedWordmark(height: 16)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func wiltedRemovingToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// Hides the window's title text while leaving the title itself set.
///
/// The wordmark already says "Wilted" in the toolbar, so drawing the word
/// again as text beside it reads as a duplicate. Clearing `navigationTitle`
/// does not work — an empty window title falls back to the bundle name — and
/// the declarative `toolbar(removing: .title)` is macOS 15+, while this target
/// ships to macOS 14. Hiding the title keeps it available to the Window menu,
/// Mission Control, and window-restoration, which an empty string would not.
private struct WiltedWindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // `window` is nil until the view joins the hierarchy, which happens
        // after this first runs, so defer the lookup by one turn of the loop.
        DispatchQueue.main.async {
            view.window?.titleVisibility = .hidden
        }
    }
}

/// Every destination opens with its own name, at one weight, in one place.
/// Three different title treatments across the two apps is what let a
/// composer heading pass for a destination heading.
private struct WiltedMacDestination<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xLarge) {
                Text(title)
                    .font(WiltedTheme.font(.display))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WiltedTheme.Spacing.section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Library

private struct WiltedMacLibraryView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.library, identifier: "wilted-mac-library-detail") {
            composer

            if let preparation = model.preparation {
                WiltedMacPreparationView(model: model, preparation: preparation)
            }

            if model.articles.isEmpty {
                ContentUnavailableView(
                    WiltedScreenCopy.libraryEmpty,
                    systemImage: "tray",
                    description: Text(WiltedScreenCopy.libraryEmptyDetailProducer)
                )
                .accessibilityIdentifier("wilted-mac-empty-state")
            } else {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                    Text(WiltedScreenCopy.savedArticles)
                        .font(WiltedTheme.font(.title))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.articles.enumerated()), id: \.element.id) { index, article in
                            if index > 0 { Divider() }
                            WiltedMacArticleRow(model: model, article: article)
                        }
                    }
                    .wiltedCard(colorScheme)
                }
            }
        }
    }

    /// The composer is a card inside Library, not the page itself. As the
    /// page's own heading it read as an unrelated form sitting where the
    /// library was supposed to be.
    private var composer: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(WiltedScreenCopy.addArticleTitle)
                .font(WiltedTheme.font(.title))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(WiltedScreenCopy.addArticleDetail)
                .font(WiltedTheme.font(.body))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: WiltedTheme.Spacing.medium) {
                WiltedMacArticleURLField(text: $model.urlDraft)
                Button(WiltedScreenCopy.addArticle) {
                    model.addArticle()
                }
                .keyboardShortcut(.return)
                .accessibilityIdentifier("wilted-add-article-url")
            }
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-mac-composer")
    }
}

/// A tokenized field border replaces macOS's system-blue focus treatment.
struct WiltedMacArticleURLField: View {
    @Binding var text: String
    let focusedOverride: Bool?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(text: Binding<String>, focusedOverride: Bool? = nil) {
        _text = text
        self.focusedOverride = focusedOverride
    }

    var body: some View {
        TextField("https://example.com/article", text: $text)
            .textFieldStyle(.plain)
            .font(WiltedTheme.font(.body))
            .padding(.horizontal, WiltedTheme.Spacing.medium)
            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .background(
                WiltedTheme.color(.page, scheme: colorScheme),
                in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                    .stroke(
                        isFocused || focusedOverride == true
                            ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme)
                            : WiltedTheme.color(.steel, scheme: colorScheme),
                        lineWidth: isFocused || focusedOverride == true ? 2 : 1
                    )
            )
            .focused($isFocused)
            .accessibilityIdentifier("wilted-article-url")
    }
}

private struct WiltedMacPreparationView: View {
    let model: WiltedMacModel
    let preparation: WiltedMacPreparation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text(preparation.phase.title)
                    .font(WiltedTheme.font(.title))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                if preparation.cancellable {
                    Button("Cancel") { model.cancelPreparation() }
                        .accessibilityIdentifier("wilted-cancel-preparation")
                }
            }
            if let fraction = preparation.fraction {
                ProgressView(value: fraction)
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-preparation-progress")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                ProgressView()
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-preparation-progress")
            }
            Text(preparation.detail)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-preparation-detail")
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-preparation")
    }
}

private struct WiltedMacArticleRow: View {
    let model: WiltedMacModel
    let article: WiltedMacArticle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Source and length on one line. Three stacked lines and a
                // card each meant four articles filled the window; a library
                // is a list to scan, not a page to read.
                Text(metaLine)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(
                        article.isReady
                            ? WiltedTheme.color(.secondaryText, scheme: colorScheme)
                            : WiltedStatusTone.active.color(colorScheme)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if article.isReady {
                Button(WiltedScreenCopy.openPlayer) {
                    model.openNowPlaying(for: article)
                }
                .accessibilityIdentifier("wilted-open-now-playing")
            }

            Menu {
                Button("Remove", role: .destructive) { model.removeArticle(article) }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("More actions for \(article.title)")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("wilted-article-actions-\(article.id)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-article-row-\(article.id)")
    }

    /// `text.npr.org · 28:56`, plus **Preparing** while the row has no button.
    ///
    /// A ready row already carries **Open Now Playing**, so spelling out
    /// *Ready to play* beside it repeats the same fact. A preparing row has no
    /// control at all, so its word stays.
    private var metaLine: String {
        var parts = [article.source]
        if let seconds = article.durationSeconds, seconds > 0 {
            parts.append(WiltedDuration.clock(seconds))
        }
        if !article.isReady { parts.append("Preparing") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Processor

/// Visibility into the preparation pipeline.
///
/// The producer runs one preparation at a time and journals every status it
/// emits, but nothing read that journal back: a run that failed while the
/// window was closed left no trace a reader could find, and the only evidence
/// preparation had ever happened was whether an article appeared in Library.
/// This lists what is running now and every attempt that came before it.
private struct WiltedMacProcessorView: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.processor, identifier: "wilted-mac-processor-detail") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                Text("Active")
                    .font(WiltedTheme.font(.title))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                if let preparation = model.preparation, !preparation.phase.isTerminal {
                    WiltedMacPreparationView(model: model, preparation: preparation)
                } else {
                    Text("Nothing is preparing. Add an article in Larder to start a run.")
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-processor-idle")
                }
            }

            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                HStack {
                    Text("Recent runs")
                        .font(WiltedTheme.font(.title))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    Spacer()
                    Text(runCountLabel)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                if model.processorRuns.isEmpty {
                    Text("No preparation has been recorded on this Mac yet.")
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-processor-empty")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.processorRuns.enumerated()), id: \.element.id) { index, run in
                            if index > 0 { Divider() }
                            runRow(run)
                        }
                    }
                    .wiltedCard(colorScheme)
                }
            }
        }
        .task {
            // Polled rather than pushed: the journal is written by the
            // coordinator's own actor and this destination has no hook into
            // it. One second matches the player's readout cadence.
            while !Task.isCancelled {
                model.refreshProcessorRuns()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var runCountLabel: String {
        let count = model.processorRuns.count
        return "\(count) recorded"
    }

    private func runRow(_ run: WiltedMacProcessorRun) -> some View {
        HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title)
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(run.detail)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                // The word always carries the outcome; the tone only
                // emphasises it (W-INV-010).
                Text(run.outcomeLabel)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(run.tone.color(colorScheme))
                Text(Self.stamp.string(from: run.updatedAt))
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wilted-processor-run-\(run.id)")
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Now Playing

/// The producer's player, carrying the same components as the listener's:
/// mark, title, source, progress, elapsed/total, status, transports, restart,
/// and transcript. It previously had transports and nothing else, so the Mac
/// could not answer how far into an article it was.
private struct WiltedMacNowPlayingView: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let article = model.currentArticle {
                    player(article)
                } else {
                    WiltedNowPlayingEmptyView(detail: WiltedScreenCopy.nowPlayingEmptyDetailProducer)
                        .accessibilityIdentifier("wilted-now-playing")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(WiltedTheme.color(.page, scheme: colorScheme))
        }
    }

    private func player(_ article: WiltedMacArticle) -> some View {
        ScrollView {
            VStack(spacing: WiltedTheme.Spacing.large) {
                WiltedMark(size: 64, color: WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))

                VStack(spacing: WiltedTheme.Spacing.xSmall) {
                    Text(article.title)
                        .font(WiltedTheme.font(.title))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .multilineTextAlignment(.center)
                    Text(article.source)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }

                ProgressView(
                    value: model.playbackPositionSeconds,
                    total: max(1, model.playbackDurationSeconds)
                )
                .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                .accessibilityLabel("Playback progress")
                .accessibilityValue(model.playbackProgressSpokenLabel)
                .accessibilityIdentifier("wilted-now-playing-progress")

                Text(model.playbackProgressLabel)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))

                Text(model.playbackStatusMessage)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(model.playbackStatusTone.color(colorScheme))
                    .accessibilityIdentifier("wilted-now-playing-status")

                HStack(spacing: WiltedTheme.Spacing.medium) {
                    transport("gobackward.15", label: "Rewind 15 seconds",
                              identifier: WiltedScreenCopy.playerRewindIdentifier) { model.rewind() }
                    transport(model.isPlaying ? "pause.fill" : "play.fill",
                              label: model.isPlaying ? "Pause" : "Play",
                              identifier: WiltedScreenCopy.playerPlayPauseIdentifier,
                              prominent: true) { model.togglePlayback() }
                    transport("goforward.30", label: "Skip forward 30 seconds",
                              identifier: WiltedScreenCopy.playerForwardIdentifier) { model.forward() }
                }

                Button("Restart") { model.restartPlayback() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("wilted-player-restart")

                // Always rendered, like the listener's. A missing transcript
                // resolves to a row that says so; it does not disappear.
                let transcript = model.currentTranscript ?? .unavailable
                WiltedTranscriptSection(
                    isReadable: transcript.isReadable,
                    title: transcript.disclosureTitle,
                    text: transcript.text,
                    unavailableLabel: transcript.unavailableLabel,
                    identifier: "wilted-now-playing-transcript"
                )

                // Offered only when there is genuinely no text to show, on the
                // same principle as the audio-route and account-review
                // controls. Articles prepared before transcripts shipped have
                // audio and no text, and re-preparing cannot fix it because
                // the revision is immutable, so this is their only route.
                if !transcript.isReadable {
                    Button(model.isBackfillingTranscript ? "Fetching transcript…" : "Fetch transcript") {
                        model.backfillCurrentTranscript()
                    }
                    .disabled(model.isBackfillingTranscript)
                    .accessibilityIdentifier("wilted-now-playing-fetch-transcript")
                }
                if let status = model.transcriptBackfillStatus {
                    Text(status)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-now-playing-transcript-status")
                }

                if let error = model.playbackError {
                    Text(error)
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-error")
                }

                // Offered only against a fault it can actually clear, the way
                // account review is offered only while sync is quarantined.
                if model.audioRouteFault {
                    Button("Recover audio route") { model.recoverAudioRoute() }
                        .buttonStyle(.bordered)
                        .font(WiltedTheme.font(.caption))
                        .accessibilityIdentifier("wilted-player-route-recovery")
                }
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(WiltedTheme.Spacing.section)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing. \(article.title)")
        .accessibilityIdentifier("wilted-now-playing")
        .task(id: article.id) {
            while !Task.isCancelled {
                model.refreshPlaybackReadout()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func transport(
        _ symbol: String,
        label: String,
        identifier: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let icon = Image(systemName: symbol)
            .font(.title3)
            .frame(
                width: WiltedTheme.Spacing.minimumTouchTarget,
                height: WiltedTheme.Spacing.minimumTouchTarget
            )
        if prominent {
            Button(action: action) { icon }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        } else {
            Button(action: action) { icon }
                .buttonStyle(.bordered)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Settings

/// Sync used to sit inside Library, above the article composer, which is both
/// the wrong altitude and out of step with the listener, where the same facts
/// live in Settings.
private struct WiltedMacSettingsView: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.settings, identifier: "wilted-mac-settings") {
            syncCard
            WiltedSettingsCard(title: WiltedScreenCopy.audio) {
                WiltedSettingsRow(
                    WiltedScreenCopy.audioMode,
                    value: WiltedScreenCopy.audioValue,
                    identifier: WiltedScreenCopy.audioRowIdentifier
                )
            }
        }
    }

    private var syncCard: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.sync) {
            WiltedSettingsRow(
                "Status",
                value: model.syncStatus.phase.rawValue.capitalized,
                identifier: "wilted-sync-status",
                tone: model.syncStatus.phase.tone
            )
            Divider()
            WiltedSettingsRow(
                "Detail",
                value: model.syncStatus.detail,
                identifier: "wilted-sync-detail"
            )
            Divider()
            WiltedSettingsRow(
                "Producer identity",
                value: model.syncObservability.producerIdentity.label,
                identifier: "wilted-sync-producer-identity"
            )
            Divider()
            WiltedSettingsRow("Last fetch", value: lastFetchLabel, identifier: "wilted-sync-last-fetch")
            Divider()
            WiltedSettingsRow("Last send", value: lastSendLabel, identifier: "wilted-sync-last-send")

            HStack(spacing: WiltedTheme.Spacing.small) {
                Button("Refresh") { model.refreshSync() }
                    .disabled(syncActionsDisabled)
                    .accessibilityIdentifier("wilted-sync-refresh")
                Button("Upload") { model.uploadPendingSync() }
                    .disabled(syncActionsDisabled)
                    .accessibilityIdentifier("wilted-sync-upload")
                if model.syncStatus.phase == .fetching
                    || model.syncStatus.phase == .sending
                    || model.syncStatus.phase == .staging {
                    Button("Cancel") { model.cancelSync() }
                        .accessibilityIdentifier("wilted-sync-cancel")
                }
            }
            .padding(.top, WiltedTheme.Spacing.xSmall)

            if model.syncStatus.phase == .quarantined {
                WiltedAccountRecoveryNotice(identifier: "wilted-sync-use-current-account") {
                    model.resetSyncAccount()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sync-controls")
    }

    private var syncActionsDisabled: Bool {
        model.syncStatus.phase == .disabled || model.syncStatus.phase == .quarantined
    }

    private var lastFetchLabel: String {
        model.syncObservability.lastSuccessfulFetchAt
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet"
    }

    private var lastSendLabel: String {
        model.syncObservability.lastSuccessfulSendAt
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet"
    }
}
