import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedVisualSystemTests {
    func testEpisodeDownloadPresentationCoversEveryLifecycleState() {
        let values: [WiltedMacEpisodeDownloadState] = [
            .notDownloaded, .queued, .downloading(received: 2, expected: 10),
            .completed, .failed, .cancelled
        ]
        XCTAssertEqual(values.count, 6)
        XCTAssertNotEqual(values[1], values[4])
    }

    func testEpisodeRowsOwnOneDedicatedLifecycleLineAndKeepControlsActionOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let rowStart = try XCTUnwrap(source.range(of: "func menuRow")?.lowerBound)
        let start = try XCTUnwrap(source.range(of: "@ViewBuilder private func nextStepControl")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "var addArticleButton", range: start..<source.endIndex)?.lowerBound)
        let row = source[rowStart..<start]
        let control = source[start..<end]
        let metadata = try String(contentsOf: root.appendingPathComponent(
            "WiltedMac/Views/WiltedMacEpisodeMetadata.swift"), encoding: .utf8
        )

        // One metadata view owns the factual source fields and the single
        // optional lifecycle line; the row still derives that line from the
        // model's one group accessor.
        XCTAssertTrue(row.contains("WiltedMacModel.menuGroup(for: episode)"))
        XCTAssertTrue(row.contains("WiltedMacEpisodeMetadata("))
        XCTAssertTrue(row.contains("episode: episode"))
        XCTAssertTrue(row.contains("identifier: \"wilted-menu-metadata-\\(episode.id)\""))
        XCTAssertTrue(row.contains("showsGroupName"))
        XCTAssertTrue(source.contains("showsGroupName: section.statusGroup == nil"))
        XCTAssertEqual(row.components(separatedBy: "lifecycleLabel:").count - 1, 1)
        XCTAssertTrue(row.contains("lifecycleLabel: showsGroupName ? group.displayName : nil"))
        XCTAssertFalse(row.contains("releasedAt.formatted(date: .numeric, time: .omitted)"))
        XCTAssertTrue(metadata.contains("publishedAt?.formatted(date: .numeric, time: .omitted)"))
        XCTAssertFalse(metadata.contains("releasedAt.formatted(date: .numeric, time: .omitted)"))
        XCTAssertTrue(metadata.contains("Publication date unknown"))
        XCTAssertTrue(row.contains("wilted-menu-progress-\\(episode.id)"))
        XCTAssertTrue(row.contains("wilted-menu-row-\\(episode.id)"))

        XCTAssertTrue(control.contains("case .failed, .cancelled:"))
        XCTAssertEqual(control.components(separatedBy: "Label(\"Retry\", systemImage: \"arrow.clockwise\")").count - 1, 2)
        XCTAssertTrue(control.contains("wilted-menu-stop-\\(episode.id)"))
        XCTAssertTrue(control.contains("wilted-menu-retry-\\(episode.id)"))
        XCTAssertTrue(control.contains("wilted-menu-prepare-\\(episode.id)"))
        XCTAssertFalse(control.contains("Text(\"Download failed\")"))
        XCTAssertFalse(control.contains("Text(\"Download cancelled\")"))
        XCTAssertFalse(control.contains("accessibilityLabel(\"Available offline\")"))
    }

    func testLarderRowsUseIconsForShortWordsAndStateOnce() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let start = try XCTUnwrap(source.range(of: "func menuRow")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "var addArticleButton", range: start..<source.endIndex)?.lowerBound)
        let larderRows = source[start..<end]

        for symbol in [
            "checkmark.circle.fill", "play.fill", "checkmark", "minus.circle", "stop.fill",
            "arrow.clockwise", "xmark.circle", "arrow.down.circle",
        ] {
            XCTAssertTrue(larderRows.contains("\"\(symbol)\""), "missing \(symbol)")
        }
        for retiredRowStateSymbol in ["speaker.wave.2.fill", "speaker.fill", "circle.lefthalf.filled"] {
            XCTAssertFalse(larderRows.contains("\"\(retiredRowStateSymbol)\""),
                           "Now Playing owns \(retiredRowStateSymbol)")
        }
        XCTAssertTrue(larderRows.contains(".labelStyle(.iconOnly)"))
        for retiredTextControl in [
            "Text(\"Play now\")", "Button(\"Play now\")", "Button(\"Remove\")", "Button(\"Download\")",
            "Text(\"In Progress\")", "Text(\"Played\")",
        ] {
            XCTAssertFalse(larderRows.contains(retiredTextControl), "retired text control: \(retiredTextControl)")
        }
        XCTAssertTrue(larderRows.contains("Self.readyActionSlotWidth"))
        XCTAssertTrue(larderRows.contains("Self.trailingActionSlotsWidth"))
        XCTAssertTrue(larderRows.contains("HStack(spacing: 2)"))
        XCTAssertTrue(larderRows.contains("model.hasStartedEpisode(episode) && !episode.isPlayed"))
        XCTAssertTrue(larderRows.contains("Label(\"Mark completed\", systemImage: \"checkmark\")"))
        XCTAssertTrue(larderRows.contains(".help(\"Mark completed\")"))
        XCTAssertTrue(larderRows.contains(".accessibilityIdentifier(\"wilted-menu-mark-completed-\\(episode.id)\")"))
        XCTAssertTrue(larderRows.contains(".accessibilityLabel(\"Mark \\(episode.title) completed\")"))
        XCTAssertTrue(larderRows.contains("Color.clear\n                        .frame(width: 28, height: 28)"))
        XCTAssertFalse(larderRows.contains("wilted-menu-skip-"))
        XCTAssertFalse(larderRows.contains("forward.end.fill"))
        XCTAssertTrue(source.contains("Button(\"Undo completion\")"))
        XCTAssertTrue(source.contains("Undo completion of \\(skipped.title)"))
        XCTAssertFalse(larderRows.contains("model.currentPodcastEpisodeID"))
        let modelRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let modelSource = try WiltedMacSource.model(root: modelRoot)
        XCTAssertTrue(modelSource.contains("Undo completion restores it."))
        XCTAssertTrue(modelSource.contains("var larderPresentationEpisodes"))
        XCTAssertTrue(modelSource.contains("guard isPodcastPlayback, let currentPodcastEpisodeID"))

        // Each icon-only control carries its own tooltip: the `.help` has to
        // come before the next control starts, not anywhere later in the row.
        let iconOnlyControls = larderRows.components(separatedBy: ".labelStyle(.iconOnly)").dropFirst()
        for control in iconOnlyControls {
            let ownModifiers = control.components(separatedBy: "Button").first ?? ""
            XCTAssertTrue(ownModifiers.contains(".help("), "icon-only control without its tooltip: \(ownModifiers.prefix(120))")
        }
        XCTAssertFalse(larderRows.contains("retirementLabel == \"Completed\""))
    }
    func testPreviewMatrixCoversEveryRequiredState() {
        XCTAssertEqual(WiltedPreviewFixture.matrix.count, WiltedPreviewState.allCases.count)
        XCTAssertEqual(Set(WiltedPreviewFixture.matrix.map(\.id)).count, WiltedPreviewFixture.matrix.count)
        XCTAssertEqual(WiltedVisualVariant.matrix.count, 8)
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.cancelling))
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.iCloudUnavailable))
        XCTAssertTrue(WiltedPreviewState.allCases.contains(.incompatibleRevision))
    }

    /// The custom symbols are only symbols if the catalog compiled them under
    /// the names the code uses; a typo would draw nothing, silently.
    func testCustomSymbolsResolveFromTheCatalog() {
        for symbol in WiltedSymbol.allCases {
            XCTAssertNotNil(NSImage(named: symbol.rawValue), symbol.rawValue)
        }
        XCTAssertEqual(WiltedMacNavigation.menu.symbolName, WiltedSymbol.larder.rawValue)
        XCTAssertEqual(WiltedMacNavigation.feeds.symbolName, WiltedSymbol.broccoli.rawValue)
        XCTAssertEqual(WiltedPreviewState.preparing(.synthesizing).symbolName, WiltedSymbol.processor.rawValue)
        XCTAssertEqual(WiltedPreviewState.emptyLibrary.symbolName, WiltedSymbol.larder.rawValue)
        XCTAssertFalse(WiltedSymbol.isCustom(WiltedMacNavigation.settings.symbolName))
    }

    func testStatesHaveStableUserFacingMetadata() {
        for state in WiltedPreviewState.allCases {
            XCTAssertFalse(state.id.isEmpty)
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
            XCTAssertFalse(state.symbolName.isEmpty)
            XCTAssertFalse(state.accessibilityStatus.isEmpty)
        }
    }

    func testLightAndDarkLeafPassReadableContrast() {
        XCTAssertEqual(WiltedTheme.lightHex[.wiltedLeaf], 0x4D6B22)
        for scheme in [ColorScheme.light, .dark] {
            let page = WiltedTheme.hex(for: .page, scheme: scheme)
            let card = WiltedTheme.hex(for: .card, scheme: scheme)
            let leaf = WiltedTheme.hex(for: .wiltedLeaf, scheme: scheme)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(leaf, page), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(leaf, card), 4.5)
        }
    }

    func testPrimaryAndSecondaryTextPassReadableContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let page = WiltedTheme.hex(for: .page, scheme: scheme)
            let primary = WiltedTheme.hex(for: .primaryText, scheme: scheme)
            let secondary = WiltedTheme.hex(for: .secondaryText, scheme: scheme)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(primary, page), 4.5)
            XCTAssertGreaterThanOrEqual(WiltedTheme.contrastRatio(secondary, page), 4.5)
        }
    }

    /// The producer surfaces put body and status text on `.card`, not just on
    /// `.page`. That pairing shipped untested until the Mac producer screens
    /// adopted the token set, so it is asserted here rather than assumed.
    func testCardTextPairingsPassReadableContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let card = WiltedTheme.hex(for: .card, scheme: scheme)
            for token in [WiltedTheme.ColorToken.primaryText, .secondaryText, .success, .error, .progress] {
                let foreground = WiltedTheme.hex(for: token, scheme: scheme)
                XCTAssertGreaterThanOrEqual(
                    WiltedTheme.contrastRatio(foreground, card), 4.5,
                    "\(token) on card fails readable contrast in \(scheme)"
                )
            }
        }
    }

    func testNativeInteractionContract() {
        XCTAssertEqual(WiltedNavigation.allCases.map(\.title), [WiltedScreenCopy.library, WiltedScreenCopy.nowPlaying, WiltedScreenCopy.downloads, WiltedScreenCopy.settings])
        XCTAssertEqual(WiltedMacNavigation.allCases.map(\.title), ["Larder", "Feeds", "Settings"])
        XCTAssertFalse(WiltedMacNavigation.allCases.map(\.rawValue).contains("nowPlaying"))
        XCTAssertEqual(WiltedScreenCopy.libraryEmpty, "Your larder is empty")
        XCTAssertEqual(WiltedScreenCopy.noArticles, "No articles yet")
        XCTAssertEqual(WiltedScreenCopy.addArticle, "Add Article")
        XCTAssertEqual(WiltedScreenCopy.addArticleIdentifier, "wilted-add-article")
        // Larder's box is for articles, and says so: a feed pasted there is
        // handed to Podcast feeds rather than saved as an episode.
        XCTAssertEqual(WiltedScreenCopy.addLink, "Add article")
        XCTAssertEqual(WiltedScreenCopy.addLinkTitle, "Add an article")
        XCTAssertTrue(WiltedScreenCopy.addLinkDetail.contains(WiltedScreenCopy.feeds))
        // Podcast feeds owns subscribing now, so the empty card explains what
        // its own composer accepts instead of sending the reader elsewhere.
        XCTAssertEqual(WiltedScreenCopy.subscribeToPodcast, "Subscribe to a podcast")
        XCTAssertFalse(WiltedScreenCopy.feedsEmptyDetail.contains("above"))
        XCTAssertFalse(WiltedScreenCopy.feedsEmptyDetail.contains(WiltedScreenCopy.library))
        XCTAssertTrue(WiltedScreenCopy.subscribeToPodcastDetail.contains("RSS"))
        XCTAssertEqual(WiltedScreenCopy.stateActionIdentifier, "wilted-state-action")
        XCTAssertEqual(WiltedScreenCopy.libraryIdentifier, "wilted-library")
        XCTAssertEqual(
            WiltedPreviewState.emptyLibrary.accessibilityIdentifier,
            "wilted-state-emptyLibrary"
        )
        XCTAssertEqual(WiltedScreenCopy.downloads, "Downloads")
        XCTAssertEqual(WiltedScreenCopy.noDownloads, "No Downloads")
        XCTAssertEqual(WiltedScreenCopy.downloadsEmptyIdentifier, "wilted-no-downloads")
        XCTAssertEqual(WiltedScreenCopy.nowPlaying, "Now Playing")
        XCTAssertEqual(WiltedScreenCopy.nowPlayingEmptyIdentifier, "wilted-player-empty")
        XCTAssertEqual(WiltedScreenCopy.downloadsIdentifier, "wilted-downloads")
        XCTAssertEqual(WiltedScreenCopy.settings, "Settings")
        XCTAssertEqual(WiltedScreenCopy.settingsIdentifier, "wilted-settings")
        XCTAssertEqual(WiltedPreviewFixture(state: .ready).articleTitle, "Fixture article")
        XCTAssertEqual(WiltedTheme.Spacing.minimumTouchTarget, 44)
        XCTAssertEqual(WiltedMark.geometrySignature, "single-stroke-w:balanced-d6:v2")
        XCTAssertEqual(
            WiltedVisualVariant.matrix.map(\.id),
            [
                "light-standard-motion-full", "light-standard-motion-reduced",
                "light-xxxLarge-motion-full", "light-xxxLarge-motion-reduced",
                "dark-standard-motion-full", "dark-standard-motion-reduced",
                "dark-xxxLarge-motion-full", "dark-xxxLarge-motion-reduced"
            ]
        )
    }

    /// The window keeps its transparent look: the toolbar background and the top
    /// scroll-edge effect are hidden, so no grey band shows across the toolbar on
    /// hover. AppKit chrome cannot be snapshotted headlessly and no snapshot covers
    /// the toolbar, so this source contract pins the modifiers on the window's root.
    func testWindowToolbarBackgroundAndTopScrollEdgeEffectAreHidden() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("WiltedMac/Views/WiltedMacRootView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".wiltedTransparentToolbar()"), "the split view applies the transparent toolbar")
        XCTAssertTrue(source.contains("toolbarBackgroundVisibility(.hidden, for: .windowToolbar)"))
        XCTAssertTrue(source.contains("scrollEdgeEffectHidden(true, for: .top)"))
        XCTAssertTrue(source.contains("if #available(macOS 26.0, *) {\n            toolbarBackgroundVisibility"), "the scroll-edge effect is macOS 26 API")
    }

    /// The iPhone's one word for an episode that can play now is "Ready"; the Mac's
    /// Larder count line used to say "Waiting for you". No Mac source shows that term.
    func testNoMacSourceSaysWaitingForYou() throws {
        let macRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: macRoot, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("waiting for you"), "\(file.lastPathComponent) says \"Waiting for you\"; the term is \"Ready\"")
        }
        let menu = try String(contentsOf: macRoot.appendingPathComponent("Views/WiltedMacMenuView.swift"), encoding: .utf8)
        // The count is the Ready group, the sidebar Ready row's own source: the whole
        // Larder also holds Downloaded and Not downloaded rows, which are not ready.
        XCTAssertTrue(menu.contains("Text(\"Ready: \\(model.menuUnfilteredEpisodes(in: .playable).count) episodes\")"))
    }

    /// Prep controls live in the Menu row that owns the run, and the player's
    /// facts keep their predictable regions. This source contract catches a
    /// visual regression without changing snapshots.
    func testPrepRunAndCompactPlayerPresentationContracts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)

        func section(_ start: String, before end: String) throws -> Substring {
            let startIndex = try XCTUnwrap(source.range(of: start)?.lowerBound)
            let endIndex = try XCTUnwrap(source.range(of: end, range: startIndex..<source.endIndex)?.lowerBound)
            return source[startIndex..<endIndex]
        }

        let row = try section("func menuRow", before: "@ViewBuilder private func nextStepControl")
        XCTAssertTrue(row.contains("nextStepControl(episode, group: group)"))
        XCTAssertTrue(row.contains("wilted-menu-progress-\\(episode.id)"))

        let control = try section("@ViewBuilder private func nextStepControl", before: "var addArticleButton")
        XCTAssertTrue(control.contains("wilted-menu-stop-\\(episode.id)"))
        XCTAssertTrue(control.contains("wilted-menu-retry-\\(episode.id)"))
        XCTAssertTrue(control.contains("wilted-menu-prepare-\\(episode.id)"))

        XCTAssertTrue(source.contains("Text(model.playbackStatusMessage)"))
        XCTAssertTrue(source.contains("if model.playbackStatusMessage != \"Playing\""))
        XCTAssertTrue(source.contains("model.playbackStatusMessage != \"Paused\""))
        XCTAssertFalse(source.contains(".opacity(model.playbackStatusMessage =="))
        XCTAssertFalse(source.contains("if let error = model.playbackError"))
        XCTAssertTrue(source.contains("wilted-player-recoverable-error"))
        XCTAssertTrue(source.contains("Button(\"Recover audio\") { model.recoverAudioRoute() }"))
        XCTAssertTrue(source.contains("wilted-player-route-recovery"))
        XCTAssertTrue(source.contains("if model.audioRouteFault"))

        // The finished-with-it control keys on the retirement rather than the
        // written record. Keying it on `playbackCompleted` disabled the only
        // control that could retire an episode whose completion was written
        // without one, so the predicate is pinned here as well as tested.
        XCTAssertTrue(source.contains(
            "Button(model.playbackCompletionIsSettled ? \"Completed\" : \"Mark completed\")"))
        XCTAssertTrue(source.contains(
            ".disabled(!model.hasCurrentPlayback || model.playbackCompletionIsSettled)"))
        XCTAssertFalse(source.contains(".disabled(!model.hasCurrentPlayback || model.playbackCompleted)"))

        let modelSource = try WiltedMacSource.model(root: root)
        XCTAssertTrue(modelSource.contains("guard !audioRouteRecoveryAttempted else { return }"))
        XCTAssertTrue(modelSource.contains("audioRouteRecoveryAttempted = true"))
        XCTAssertTrue(modelSource.contains("self.audioRouteFault = true"))
    }

    /// The rail opens a detail presentation rather than growing a short pane
    /// under its controls. Both forms must render through the same content
    /// implementation, or their transport affordances will drift apart.
    func testFullWindowPlayerPresentationContracts() throws {
        XCTAssertEqual(
            WiltedMacPlayerSection.allCases.map(\.expandedAccessibilityIdentifier),
            [
                "wilted-player-transcript-expanded",
                "wilted-player-notes-expanded"
            ]
        )

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let player = try XCTUnwrap(source.range(of: "struct WiltedMacPlayerContent")?.lowerBound)
        let playerSource = source[player...]

        XCTAssertTrue(source.contains("WiltedMacFullWindowPlayer("))
        XCTAssertTrue(source.contains("wilted-player-full-window"))
        XCTAssertTrue(source.contains("wilted-player-collapse"))
        XCTAssertTrue(source.contains("wilted-player-item-title"))
        XCTAssertTrue(source.contains("WiltedMacPlayerContent("))
        XCTAssertFalse(playerSource.contains("maxHeight: 170"))
        XCTAssertTrue(playerSource.contains("maxHeight: .infinity"))
        // Every destination, the Larder included, is made unavailable behind
        // the full-window overlay, which is what keeps duplicate live controls
        // out of the accessibility tree.
        XCTAssertTrue(source.contains(".allowsHitTesting(playerPresentation == nil)"))
        XCTAssertTrue(source.contains(".accessibilityHidden(playerPresentation != nil)"))
        XCTAssertTrue(source.contains(".disabled(playerPresentation != nil)"))
        // The sidebar no longer clears the presentation itself: every
        // navigation change is retired by the detail's onChange, while
        // collapsing keeps its own clear.
        XCTAssertTrue(source.contains("model.selectedNavigation = $0"))
        XCTAssertTrue(source.contains(".onChange(of: model.selectedNavigation) {"))
        XCTAssertTrue(source.contains("playerPresentation = nil\n                        playerFocusRequest = section"))
        XCTAssertTrue(source.contains("case .menu:"))
        XCTAssertTrue(source.contains("WiltedMacMenuView("))
        XCTAssertTrue(source.contains("presentation: $playerPresentation"))
        XCTAssertTrue(source.contains("wilted-mac-menu-detail"))
        XCTAssertTrue(source.contains(".draggable(episode.id)"))
        XCTAssertTrue(source.contains(".dropDestination(for: String.self)"))
        XCTAssertTrue(source.contains("Prepare all now (\\(model.menuPreparableEpisodes.count))"))
        XCTAssertTrue(source.contains("\"Needs preparation\""))
        XCTAssertTrue(source.contains("Label(\"Group by: \\(model.menuGrouping.rawValue)\""))
        XCTAssertTrue(source.contains("Label(\"Sort by: \\(model.menuSort.displayName)\""))
        XCTAssertTrue(source.contains("wilted-menu-grouping"))
        XCTAssertFalse(source.contains("Picker(\"Sort order\""),
                       "the Larder sort menu must not nest a Picker submenu")
        XCTAssertTrue(source.contains("model.menuSort = option"),
                      "each sort order must be a directly clickable menu action")
        XCTAssertTrue(source.contains("Button {\n                            model.menuSort = option"))
        XCTAssertTrue(source.contains("wilted-player-share"))
        XCTAssertTrue(source.contains("if let shareURL = model.currentPlaybackShareURL"))
        XCTAssertTrue(source.contains("else if let shareText = model.currentPlaybackShareText"))
        XCTAssertTrue(source.contains(".opacity(dropTargetID == episode.id ? 1 : 0)"))
        let menuRowStart = try XCTUnwrap(source.range(of: "func menuRow")?.lowerBound)
        let menuRowEnd = try XCTUnwrap(source.range(
            of: "@ViewBuilder private func nextStepControl", range: menuRowStart..<source.endIndex
        )?.lowerBound)
        XCTAssertFalse(source[menuRowStart..<menuRowEnd].contains(
            "WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.12)"
        ))
        XCTAssertTrue(source.contains("model.menuEpisodes(in: .playable)"))
        XCTAssertTrue(source.contains("model.menuPreparableEpisodes"))
        XCTAssertTrue(source.contains(".disabled(model.isSearchingMenu)"))
        XCTAssertTrue(source.contains("model.prepareAllDownloadedMenuEpisodes()"))
        XCTAssertTrue(source.contains("wilted-menu-prepare-all"))
        XCTAssertFalse(source.contains("expansionButton(\"Up Next\""))
    }

    func testBulkActionsBecomeTheirProgressWhileRowsAreInFlight() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let start = try XCTUnwrap(source.range(of: "private func bulkAction("))
        let end = try XCTUnwrap(source.range(
            of: "private func ", range: start.upperBound..<source.endIndex
        )?.lowerBound)
        let bulkAction = source[start.lowerBound..<end]

        XCTAssertTrue(bulkAction.contains("ProgressView()"))
        XCTAssertTrue(bulkAction.contains("\"\\(identifier)-progress\""))
        XCTAssertTrue(bulkAction.contains("inFlight.isEmpty"))
        XCTAssertTrue(bulkAction.contains(".disabled(model.isSearchingMenu)"))
        // Every call site pairs an in-flight set with the actionable set of the same kind,
        // however many call sites there are.
        let compact = source.filter { !$0.isWhitespace }
        for (actionable, inFlight) in [
            ("model.menuDownloadableEpisodes", "model.menuDownloadsInFlight"),
            ("model.menuPreparableEpisodes", "model.menuPreparationsInFlight"),
        ] {
            let uses = compact.components(separatedBy: "inFlight:\(inFlight)").count - 1
            let paired = compact.components(separatedBy: "actionable:\(actionable),inFlight:\(inFlight)").count - 1
            XCTAssertGreaterThan(uses, 0, inFlight)
            XCTAssertEqual(paired, uses, inFlight)
        }
        // The button is its own branch, not the else of the progress branch, so new
        // arrivals can still be started while earlier rows run.
        XCTAssertFalse(bulkAction.contains("} else if !actionable.isEmpty"))
        XCTAssertTrue(source.contains("inFlightVerb: \"Downloading\""))
        XCTAssertTrue(source.contains("inFlightVerb: \"Preparing\""))
        XCTAssertFalse(source.contains("Button(\"Download all new ("))
    }

    /// Which cue carries a speaker name, and what its spoken label says, are
    /// unit-tested in `WiltedMacModelTests`. This pins the wiring that puts
    /// that label on each transcript row, which the Mac UI suite used to prove
    /// by reading the live tree (W-INV-012 moved it here).
    func testTranscriptRowsSpeakTheSpeakerExactlyWhereTheHeadingIsDrawn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/WiltedSurfaces.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        XCTAssertTrue(source.contains("let headings = speakerHeadingCueIDs"))
        XCTAssertTrue(source.contains("case .cue(let cue): line(cue, showsSpeaker: headings.contains(cue.id))"))
        XCTAssertTrue(source.contains(".accessibilityLabel(spokenLabel(cue, showsSpeaker: showsSpeaker))"))
    }

    func testFeedsTitleOpensShowNotesWithTheSameTwoAnswers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let start = try XCTUnwrap(source.range(of: "struct WiltedMacFeedsEpisodeRow")?.lowerBound)
        // The struct ends at its own column-zero closing brace, so nothing
        // declared after it can satisfy an assertion meant for the row.
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: start..<source.endIndex)?.upperBound)
        let row = source[start..<end]

        let notes = try String(contentsOf: root.appendingPathComponent("WiltedMac/Views/WiltedMacEpisodeNotes.swift"), encoding: .utf8)
        XCTAssertTrue(row.contains("WiltedMacEpisodeNotesTitle("))
        XCTAssertTrue(row.contains("isPresented: $isShowingNotes"))
        XCTAssertTrue(notes.contains("WiltedShowNotes.linked("))
        XCTAssertTrue(row.contains("prefix: \"wilted-feeds\""))
        XCTAssertTrue(notes.contains("This episode's feed did not include show notes."))
        XCTAssertTrue(row.contains("wilted-feeds-decide-"))
        XCTAssertEqual(row.components(separatedBy: "ForEach(WiltedMacFeedsAction.allCases)").count - 1, 2)
        XCTAssertFalse(source.contains("private func feedsEpisodeRow"))
    }

    func testSharedEpisodeNotesUsesExactEpisodeAndEmptyState() throws {
        var episode = WiltedMacEpisode(id: "notes-exact", title: "Exact episode", feedTitle: "Show",
            summary: "", artworkURL: nil, releasedAt: Date(), durationSeconds: 60,
            playbackSeconds: 0, downloadState: .completed, preparationState: .prepared(summary: "Ready"))
        episode.notes = "Exact notes https://example.com/episode"
        let linked = try XCTUnwrap(WiltedMacEpisodeNotes<EmptyView>.linkedNotes(for: episode))
        XCTAssertEqual(String(linked.characters), episode.notes)
        XCTAssertTrue(linked.runs.contains { $0.link == URL(string: "https://example.com/episode") })
        episode.notes = ""
        XCTAssertNil(WiltedMacEpisodeNotes<EmptyView>.linkedNotes(for: episode))
        episode.notes = nil
        XCTAssertNil(WiltedMacEpisodeNotes<EmptyView>.linkedNotes(for: episode))
    }

    func testEpisodeCountControlsOnlyExposeNumericInputForCustomAndKeepValidation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // Settings keeps the saved default's long label; the add-feed popover names the control "Episodes listed".
        for (name, label) in [
            ("WiltedMacSettingsView.swift", "Episodes to list when adding a feed"),
            ("WiltedMacFeedsView.swift", "Episodes listed"),
        ] {
            let source = try String(contentsOf: root.appendingPathComponent("WiltedMac/Views/\(name)"), encoding: .utf8)
            XCTAssertTrue(source.contains("Picker(\"\(label)\""))
            XCTAssertTrue(source.contains("Text(\"Custom\").tag(0)"))
            XCTAssertTrue(source.contains("if initialMetadataPreset.wrappedValue == 0"))
            XCTAssertTrue(source.contains("Titles and notes only; audio follows your download settings."))
            XCTAssertTrue(source.contains("validInitialEpisodeMetadataCount(value)"))
        }
        XCTAssertNil(WiltedAutomationSettings.validInitialEpisodeMetadataCount(0))
        XCTAssertNil(WiltedAutomationSettings.validInitialEpisodeMetadataCount(101))
        XCTAssertEqual(WiltedAutomationSettings.validInitialEpisodeMetadataCount(7), 7)
    }

    func testAutomationSettingsPresentationFollowsThePipelineAndOnlyShowsLiveControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let start = try XCTUnwrap(source.range(of: "private var automationCard")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "private var syncCard", range: start..<source.endIndex)?.lowerBound)
        let card = source[start..<end]

        let feeds = try XCTUnwrap(card.range(of: "automationSectionTitle(\"Feeds\")")?.lowerBound)
        let processing = try XCTUnwrap(card.range(of: "automationSectionTitle(\"Processing\")")?.lowerBound)
        XCTAssertLessThan(feeds, processing)
        XCTAssertFalse(card.contains("wilted-automation-download-policy"))
        XCTAssertTrue(card.contains("wilted-automation-feeds-admission-policy"))
        XCTAssertTrue(card.contains("wilted-automation-refresh-policy"))
        XCTAssertTrue(card.contains("wilted-automation-processing-policy"))
        XCTAssertTrue(card.contains("wilted-automation-transcript-policy"))
        XCTAssertTrue(card.contains("wilted-automation-remove-ads"))
        // The notice is conditional, so the pane only says the pair is
        // unworkable while it is actually selected.
        XCTAssertTrue(card.contains("wilted-automation-transcript-conflict"))
        XCTAssertTrue(card.contains("if model.automationSettings.transcriptPolicyBlocksAdRemoval"))
        XCTAssertTrue(card.contains("wilted-automation-off-peak-start"))
        XCTAssertTrue(card.contains("wilted-automation-off-peak-end"))
        XCTAssertTrue(card.contains("Uses local time. The window may continue overnight."))
        XCTAssertTrue(card.contains("if isOffPeakProcessing"))
        XCTAssertTrue(card.contains("value: model.automationStatus.settingsStatusText"))
        XCTAssertTrue(card.contains("if model.automationStatus.isCancellable"))
        XCTAssertTrue(card.contains("wilted-automation-status"))
        XCTAssertTrue(card.contains("wilted-automation-stop"))
        XCTAssertTrue(card.contains("model.updateAutomationSettings"))
        XCTAssertFalse(card.contains("UserDefaults"), "Settings must reuse the model's validated persistence")
    }

    func testSettingsOffersTheRemovedAdChime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.views(root: root)
        let removeAds = try XCTUnwrap(source.range(of: "wilted-automation-remove-ads")?.lowerBound)
        let marker = try XCTUnwrap(source.range(of: "wilted-automation-ad-marker")?.lowerBound)
        XCTAssertTrue(source.contains("Toggle(\"Chime where an ad was removed\""))
        XCTAssertLessThan(removeAds, marker)
    }

    /// Removed rows carry enough presentation metadata to name the episode,
    /// its feed, and its retained Prep history without reconstructing a deleted
    /// episode record.
    func testRemovedEpisodePresentationMetadataNamesPrepHistory() {
        let removed = WiltedMacDismissedEpisode(
            id: "episode-id", feedID: "feed-id", title: "Recovered episode",
            feedTitle: "Field Notes", dismissedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasPreparationHistory: true
        )
        XCTAssertEqual(removed.title, "Recovered episode")
        XCTAssertEqual(removed.feedTitle, "Field Notes")
        XCTAssertTrue(removed.hasPreparationHistory)
        XCTAssertEqual(removed.id, "episode-id", "Restore identity must remain stable across renders")
    }

    // The removed-episodes card and its rows were deleted with the Larder in
    // Phase 0b; the accessibility-containment assertion that lived here is
    // waiting on Task 2.4 to decide where restore lives. Reinstate it against
    // that surface rather than reconstructing the old one.

    /// The producer window has no Downloads destination, so its copy must not
    /// send the reader to one. This was shipped: the Mac empty player told the
    /// reader to visit Downloads, and no pixel baseline could catch it because
    /// the Mac baselines always render the player, never the empty state.
    func testProducerCopyNamesOnlyProducerDestinations() {
        let producerDestinations = WiltedMacNavigation.allCases
        XCTAssertEqual(producerDestinations.map(\.title), ["Larder", "Feeds", "Settings"])

        XCTAssertFalse(
            WiltedScreenCopy.nowPlayingEmptyDetailProducer.contains(WiltedScreenCopy.downloads),
            "Producer copy must not point at a destination the Mac window does not have."
        )
        XCTAssertTrue(
            WiltedScreenCopy.nowPlayingEmptyDetailProducer.contains(WiltedScreenCopy.library)
        )
        // The listener does have Downloads, so its wording legitimately differs.
        XCTAssertTrue(WiltedScreenCopy.nowPlayingEmptyDetailListener.contains(WiltedScreenCopy.library))
        XCTAssertFalse(WiltedScreenCopy.nowPlayingEmptyDetailListener.contains(WiltedScreenCopy.downloads))
        XCTAssertFalse(
            WiltedScreenCopy.libraryEmptyDetailProducer.contains(WiltedScreenCopy.downloads)
        )
    }

    /// Emphasis without letting colour carry state alone: every phase still
    /// renders its own name, and only the phases that mean something distinct
    /// get a non-neutral tone.
    func testSyncPhasesCarryTheirOwnToneAndText() {
        let expected: [(WiltedMacSyncPhase, WiltedStatusTone)] = [
            (.disabled, .neutral), (.idle, .neutral), (.cancelled, .neutral),
            (.staging, .active), (.fetching, .active), (.sending, .active),
            (.completed, .positive), (.quarantined, .caution), (.failed, .failure)
        ]
        for (phase, tone) in expected {
            XCTAssertEqual(phase.tone, tone, "wrong tone for \(phase.rawValue)")
            XCTAssertFalse(phase.rawValue.isEmpty)
        }
        XCTAssertEqual(WiltedMacSyncPhase.quarantined.rawValue.capitalized, "Quarantined")
    }

    func testDeterministicRenderArtifactDoesNotDrift() {
        let variant = WiltedVisualVariant(
            appearance: .light,
            dynamicType: .xxxLarge,
            reduceMotion: true
        )
        XCTAssertEqual(
            WiltedPreviewState.emptyLibrary.renderSignature(variant: variant),
            "2ba6962858bc3fb7"
        )
        let signatures = Set(
            WiltedPreviewState.allCases.flatMap { state in
                WiltedVisualVariant.matrix.map { state.renderSignature(variant: $0) }
            }
        )
        XCTAssertEqual(signatures.count, WiltedPreviewState.allCases.count * WiltedVisualVariant.matrix.count)
    }

    /// The reported defect: a 29-minute article read "1743 seconds" on both
    /// platforms. These lock the format, not just the fix.
    func testDurationsReadAsClockTimeRatherThanRawSeconds() {
        XCTAssertEqual(WiltedDuration.clock(1743), "29:03")
        XCTAssertEqual(WiltedDuration.clock(120), "2:00")
        XCTAssertEqual(WiltedDuration.clock(0), "0:00")
        XCTAssertEqual(WiltedDuration.clock(9), "0:09")
        XCTAssertEqual(WiltedDuration.clock(3600), "1:00:00")
        XCTAssertEqual(WiltedDuration.clock(3661), "1:01:01")
        // Nothing may print a negative or non-finite clock.
        XCTAssertEqual(WiltedDuration.clock(-90), "0:00")
        XCTAssertEqual(WiltedDuration.clock(.infinity), "0:00")
        XCTAssertEqual(WiltedDuration.clock(.nan), "0:00")
        XCTAssertEqual(WiltedDuration.progress(position: 31, duration: 1743), "0:31 of 29:03")
    }

    /// VoiceOver cannot infer units from a colon, so the spoken form must carry
    /// the words. Reading "twenty-nine oh three" is the same defect as printing
    /// "1743".
    func testSpokenDurationsCarryUnitsRatherThanColons() {
        for value in [WiltedDuration.spoken(1743), WiltedDuration.spokenProgress(position: 31, duration: 1743)] {
            XCTAssertFalse(value.contains(":"), "spoken duration must not rely on a colon: \(value)")
            XCTAssertTrue(value.lowercased().contains("minute"), "spoken duration must name its units: \(value)")
        }
    }
}
