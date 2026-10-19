import XCTest

@MainActor
extension WiltedMacEpisodeInfoUITests {
    /// Discovery of a manual playlist from a Larder row, the rename that
    /// updates beside the title while its write is pending, the established
    /// player path with the labelled Share options panel, and a confirmed
    /// delete that falls back to the Larder without touching the episode.
    func testManualPlaylistDiscoveryRenameDeleteAndShare() throws {
        let app = try launchFixture(extraArguments: ["--wilted-ui-fixture-playlist-write-delay"])
        let episodeID = try keepFixtureEpisode(app)
        try openLarderForEpisode(app, id: episodeID)
        let playlistID = try createManualPlaylistFromLarder(app, entryID: episodeID)

        // Creation is optimistic: the row, its entry and the selected page
        // appear before the delayed durable write has run.
        let creating = element(app, "wilted-sidebar-playlist-saving-\(playlistID)")
        XCTAssertTrue(creating.waitForExistence(timeout: 3), "the new playlist row shows its pending create")
        let pageSaving = element(app, "wilted-playlist-saving")
        XCTAssertTrue(pageSaving.waitForExistence(timeout: 3))
        XCTAssertTrue(words(pageSaving).contains("Creating playlist"))
        XCTAssertTrue(app.buttons["wilted-playlist-show-notes-\(episodeID)"].waitForExistence(timeout: 3),
                      "the new manual playlist shows the kept entry while the create is pending")
        try releasePlaylistWrite(1)
        XCTAssertTrue(creating.waitForNonExistence(timeout: 10), "the create's durable write settles")
        XCTAssertTrue(pageSaving.waitForNonExistence(timeout: 10))
        try waitForPlaylistWriteAcknowledgments(1)

        // Rename while a fresh delayed write is pending: the new name is on
        // the page immediately, and the pencil and trash stay with the title.
        let rename = app.buttons["wilted-playlist-rename"]
        try requireControl(rename, name: "Rename playlist")
        rename.click()
        let name = try renamePlaylist(app, to: "Field Notes List")
        XCTAssertTrue(pageSaving.waitForExistence(timeout: 3), "the rename is pending before its durable write")
        XCTAssertTrue(words(pageSaving).contains("Saving playlist"))
        XCTAssertTrue(element(app, "wilted-sidebar-playlist-saving-\(playlistID)").waitForExistence(timeout: 3))
        let title = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", name, name)
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3), "the new name shows while the write is pending")
        let deleteButton = app.buttons["wilted-playlist-delete"]
        XCTAssertTrue(deleteButton.exists)
        let actionRow = element(app, "wilted-playlist-play")
        XCTAssertTrue(actionRow.exists)
        XCTAssertEqual(rename.frame.midY, title.frame.midY, accuracy: 12,
                       "Rename sits beside the title, not in the item action row")
        XCTAssertEqual(deleteButton.frame.midY, title.frame.midY, accuracy: 12,
                       "Delete sits beside the title, not in the item action row")
        XCTAssertGreaterThanOrEqual(rename.frame.minX, title.frame.maxX - 8)
        XCTAssertGreaterThan(actionRow.frame.minY, title.frame.maxY,
                             "the item action row sits below the title row")
        attachWindow(app, name: "Manual playlist rename pending")
        try releasePlaylistWrite(2)
        XCTAssertTrue(pageSaving.waitForNonExistence(timeout: 10), "the rename's durable write settles")
        try waitForPlaylistWriteAcknowledgments(2)

        // The durable store keeps the playlist, its entry and its name across a
        // relaunch of the same owned fixture directory.
        try relaunchFixture(app)
        let sidebarRow = app.descendants(matching: .any)["wilted-navigation-playlist:\(playlistID)"]
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 10), "the created playlist survives a relaunch")
        // The row names its kind for VoiceOver, as `WiltedMacSidebarRow` describes it.
        XCTAssertEqual(sidebarRow.label, "\(name), Manual playlist")
        sidebarRow.click()
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the renamed playlist heading survives relaunch")
        XCTAssertTrue(words(title).contains(name))
        XCTAssertTrue(app.buttons["wilted-playlist-show-notes-\(episodeID)"].waitForExistence(timeout: 10),
                      "the durable playlist keeps the kept entry")

        // A fixture relaunch rebuilds the Larder queue from Keep, so the
        // established fixture path re-keeps the same episode before playing.
        XCTAssertEqual(try keepFixtureEpisode(app), episodeID)
        // Delete before playback: the active episode moves to Now Playing, so
        // the waiting-row retention check belongs before that transition.
        sidebarRow.click()
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the selected playlist shows its heading")
        let delete = app.buttons["wilted-playlist-delete"]
        try requireControl(delete, name: "Delete playlist")
        delete.click()
        let confirm = app.sheets.firstMatch.buttons["Delete Playlist"]
        try requireControl(confirm, name: "Confirm Delete Playlist")
        confirm.click()
        XCTAssertTrue(element(app, "wilted-navigation-larder").isSelected,
                      "deleting the selected playlist falls back to the Larder")
        XCTAssertTrue(app.buttons["wilted-larder-show-notes-\(episodeID)"].waitForExistence(timeout: 10),
                      "the retained episode is still in the Larder after deleting its playlist")
        try releasePlaylistWrite(3)
        try waitForPlaylistWriteAcknowledgments(3)
        XCTAssertTrue(sidebarRow.waitForNonExistence(timeout: 5), "the deleted playlist's row stays gone")
        XCTAssertFalse(element(app, "wilted-sidebar-playlist-error-\(playlistID)").exists,
                       "the durable delete did not fail")
        attachWindow(app, name: "Manual playlist deleted, episode kept")

        // The retained episode still plays after deleting its playlist, and the
        // labelled Share options control opens its panel without sharing.
        try openLarderForEpisode(app, id: episodeID)
        let play = app.buttons["wilted-larder-play-\(episodeID)"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        try clickVerified(play, in: app, name: "Play \(episodeID)", label: "Play Quiet Machines now")
        let share = element(app, "wilted-player-share-options")
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        XCTAssertEqual(share.label, "Share options")
        try clickVerified(share, in: app, name: "Share options")
        let includeSummary = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Include transcript summary'")
        ).firstMatch
        XCTAssertTrue(includeSummary.waitForExistence(timeout: 5), "Share options opens its panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(includeSummary.waitForNonExistence(timeout: 5), "the panel closes without sharing")
    }

    /// The automatic editor: copied rules, a grouped formula with its live
    /// preview, an unknown reference that clears both, a preview title's exact
    /// notes, and a save whose pending and completion states are visible.
    func testAutomaticPlaylistFormulaPreviewAndSave() throws {
        let app = try launchFixture(extraArguments: ["--wilted-ui-fixture-playlist-write-delay"])
        let episodeID = try keepFixtureEpisode(app)
        let playlistID = try createAutomaticPlaylist(app)
        XCTAssertTrue(element(app, "wilted-playlist-saving").waitForExistence(timeout: 3),
                      "the automatic playlist appears before its delayed write completes")
        try releasePlaylistWrite(1)
        XCTAssertTrue(element(app, "wilted-playlist-saving").waitForNonExistence(timeout: 10),
                      "the new automatic playlist's create write settles")
        try waitForPlaylistWriteAcknowledgments(1)
        let editRules = app.buttons["wilted-playlist-edit-rules"]
        try requireControl(editRules, name: "Edit Rules", timeout: 10)
        editRules.click()
        let sheet = element(app, "wilted-playlist-rules-sheet")
        try requireElement(sheet, name: "Rules sheet", timeout: 10)

        let add = app.buttons["wilted-playlist-rules-add"]
        try requireControl(add, name: "Add rule")
        add.click()
        try choose(app, picker: "Rule 1 field", option: "Feed")
        XCTAssertTrue(try pickerValue(app, "Rule 1 value").contains("Field Notes"))
        add.click()
        XCTAssertTrue(try pickerValue(app, "Rule 2 field").contains("Feed"), "Add copies the last field")
        XCTAssertTrue(try pickerValue(app, "Rule 2 comparison").contains("is"), "Add copies the last comparison")
        try choose(app, picker: "Rule 2 comparison", option: "is not")
        add.click()
        XCTAssertTrue(try pickerValue(app, "Rule 3 comparison").contains("is not"), "Add copies the last comparison")
        try choose(app, picker: "Rule 3 field", option: "Played")
        XCTAssertTrue(try pickerValue(app, "Rule 3 value").contains("Unplayed"))
        add.click()
        XCTAssertTrue(try pickerValue(app, "Rule 4 field").contains("Played"), "Add copies the last field")
        try choose(app, picker: "Rule 4 field", option: "Ready")
        XCTAssertTrue(try pickerValue(app, "Rule 4 value").contains("Yes"))

        let expression = element(app, "wilted-playlist-rule-expression")
        try requireControl(expression, name: "Match expression")
        replaceText(expression, with: "(1 OR 2) AND 3 AND 4")
        let count = element(app, "wilted-playlist-rule-preview-count")
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the grouped formula previews live")
        let countText = (count.value as? String ?? count.label).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(countText, "2 matching", "the live count reflects the matching episodes")
        let previewTitle = app.buttons["wilted-playlist-preview-show-notes-\(episodeID)"]
        try requireControl(previewTitle, name: "Quiet Machines preview")
        XCTAssertTrue(words(previewTitle).contains("Quiet Machines"))
        attachWindow(app, name: "Automatic playlist valid preview")

        replaceText(expression, with: "99")
        let error = element(app, "wilted-playlist-rules-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5), "an unknown rule must be named immediately")
        let save = app.buttons["wilted-playlist-rules-save"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "Save is disabled while the formula is invalid")
        XCTAssertTrue(element(app, "wilted-playlist-rule-preview-count").waitForNonExistence(timeout: 5),
                      "no stale count survives an invalid formula")
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-playlist-preview-show-notes-'")
        ).count, 0, "no stale preview titles survive an invalid formula")
        attachWindow(app, name: "Automatic playlist invalid formula")

        replaceText(expression, with: "(1 OR 2) AND 3 AND 4")
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the valid formula previews again")
        XCTAssertTrue(previewTitle.waitForExistence(timeout: 5))
        let previewID = String(previewTitle.identifier.dropFirst("wilted-playlist-preview-show-notes-".count))
        XCTAssertFalse(previewID.isEmpty)
        previewTitle.click()
        let notes = element(app, "wilted-playlist-preview-notes-text-\(previewID)")
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "a preview title opens the exact episode's notes")
        XCTAssertTrue(words(notes).contains(savedNotes))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element(app, "wilted-playlist-preview-notes-popover-\(previewID)")
            .waitForNonExistence(timeout: 5), "Escape closes the preview's notes")

        try requireControl(save, name: "Save valid rules")
        save.click()
        let saving = element(app, "wilted-playlist-rules-saving")
        XCTAssertTrue(saving.waitForExistence(timeout: 3), "Save shows its spinner while the write is pending")
        XCTAssertFalse(save.isEnabled, "Save is disabled while the write is pending")
        XCTAssertFalse(expression.isEnabled, "the expression field is locked while the save is pending")
        try releasePlaylistWrite(2)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the sheet dismisses when the save completes")
        XCTAssertTrue(element(app, "wilted-playlist-edit-rules").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["wilted-playlist-show-notes-\(previewID)"].waitForExistence(timeout: 10),
                      "the saved automatic playlist holds its matching entry")
        XCTAssertTrue(element(app, "wilted-navigation-playlist:\(playlistID)").exists,
                      "the saved automatic playlist remains in the sidebar")
        try waitForPlaylistWriteAcknowledgments(2)
        attachWindow(app, name: "Automatic playlist saved")
    }

    /// Keeps the prepared fixture episode from Feeds and returns its ID.
    private func keepFixtureEpisode(_ app: XCUIApplication) throws -> String {
        let feeds = element(app, "wilted-navigation-feeds")
        try requireControl(feeds, name: "Feeds", timeout: 10)
        feeds.click()
        XCTAssertTrue(feeds.isSelected)
        let episodeTitle = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-show-notes-' AND label == 'Show notes for Quiet Machines'")
        ).firstMatch
        try requireControl(episodeTitle, name: "Quiet Machines in Feeds", timeout: 10)
        let id = String(episodeTitle.identifier.dropFirst("wilted-feeds-show-notes-".count))
        XCTAssertFalse(id.isEmpty)
        let keep = app.buttons["wilted-feeds-keep-\(id)"]
        try requireControl(keep, name: "Keep Quiet Machines", timeout: 10)
        keep.click()
        return id
    }

    private func openLarderForEpisode(_ app: XCUIApplication, id: String) throws {
        let larder = element(app, "wilted-navigation-larder")
        try requireControl(larder, name: "Larder")
        larder.click()
        XCTAssertTrue(larder.isSelected)
        XCTAssertTrue(app.buttons["wilted-larder-show-notes-\(id)"].waitForExistence(timeout: 10),
                      "the kept episode's visible title is in the Larder")
    }

    /// Requires the visible Larder action and returns the new playlist's ID.
    private func createManualPlaylistFromLarder(_ app: XCUIApplication, entryID: String) throws -> String {
        let rowAction = element(app, "wilted-add-to-playlist-\(entryID)")
        try requireControl(rowAction, name: "Visible Add to Playlist in Larder")
        try clickVerified(rowAction, in: app, name: "Add to Playlist")
        let newPlaylist = app.menuItems["New Playlist…"]
        try requireControl(newPlaylist, name: "New Playlist menu item")
        newPlaylist.click()
        return try XCTUnwrap(newPlaylistID(app))
    }

    private func createAutomaticPlaylist(_ app: XCUIApplication) throws -> String {
        // macOS exports the Section header identifier on this MenuButton.
        let menu = app.descendants(matching: .menuButton).matching(
            identifier: "wilted-sidebar-playlists-header"
        ).firstMatch
        try requireControl(menu, name: "Sidebar New Playlist", timeout: 10)
        XCTAssertEqual(menu.label, "add", "the captured sidebar New Playlist menu is the visible plus")
        try clickVerified(menu, in: app, name: "New Playlist", label: "add")
        let item = app.menuItems["New Automatic Playlist"]
        try requireControl(item, name: "New Automatic Playlist menu item")
        item.click()
        return try XCTUnwrap(newPlaylistID(app))
    }

    private func newPlaylistID(_ app: XCUIApplication) -> String? {
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-navigation-playlist:'")
        ).firstMatch
        guard row.waitForExistence(timeout: 10) else { return nil }
        let prefix = "wilted-navigation-playlist:"
        let id = String(row.identifier.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    private func renamePlaylist(_ app: XCUIApplication, to name: String) throws -> String {
        let field = app.textFields.matching(
            NSPredicate(format: "placeholderValue == 'Name' OR label == 'Name'")
        ).firstMatch
        try requireControl(field, name: "Rename name field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        let confirm = app.sheets.firstMatch.buttons["Rename"]
        try requireControl(confirm, name: "Confirm rename")
        confirm.click()
        return name
    }

    /// Replaces a text field's contents through the focused control.
    private func replaceText(_ field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func pickerControl(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.popUpButtons.matching(
            NSPredicate(format: "label == %@ OR label ENDSWITH %@", label, ", " + label)
        ).firstMatch
    }

    private func pickerValue(_ app: XCUIApplication, _ label: String) throws -> String {
        let control = pickerControl(app, label)
        try requireControl(control, name: label)
        if let value = control.value as? String, !value.isEmpty { return value }
        return words(control)
    }

    private func choose(_ app: XCUIApplication, picker label: String, option: String) throws {
        let control = pickerControl(app, label)
        try requireControl(control, name: label)
        try clickVerified(control, in: app, name: label)
        let menuItem = app.menuItems[option]
        let buttonItem = app.buttons[option]
        let choice = menuItem.waitForExistence(timeout: 5) ? menuItem : buttonItem
        try requireControl(choice, name: "\(label) option \(option)")
        choice.click()
    }

    /// Clicks through the control's own AX action, or through its verified
    /// on-window center when XCTest rejects that action.
    private func clickVerified(
        _ control: XCUIElement, in app: XCUIApplication, name: String, label: String? = nil
    ) throws {
        try requireControl(control, name: name)
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: control)
        if XCTWaiter().wait(for: [hittable], timeout: 3) == .completed {
            control.click()
            return
        }
        let window = app.windows.firstMatch
        guard control.exists, control.isEnabled, label == nil || control.label == label,
              control.frame.width > 0, control.frame.height > 0,
              window.exists, window.frame.contains(control.frame) else {
            throw PlaylistUIPrerequisiteError(message: "\(name) must be a visible control inside its fixture window")
        }
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private struct PlaylistUIPrerequisiteError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func requireElement(_ control: XCUIElement, name: String, timeout: TimeInterval = 5) throws {
        guard control.waitForExistence(timeout: timeout) else {
            throw PlaylistUIPrerequisiteError(message: "\(name) must exist before the journey continues")
        }
    }

    private func requireControl(_ control: XCUIElement, name: String, timeout: TimeInterval = 5) throws {
        try requireElement(control, name: name, timeout: timeout)
        guard control.isEnabled else {
            throw PlaylistUIPrerequisiteError(message: "\(name) must be enabled before interaction")
        }
    }

    /// Releases only one numbered write in this test's already-owned synthetic root.
    private func releasePlaylistWrite(_ number: Int) throws {
        let root = try XCTUnwrap(latestFixtureRoot)
        try Data().write(to: root.appendingPathComponent("playlist-ui-write-release-\(number)"), options: .atomic)
    }

    /// Relaunches the same fixture over its own state directory.
    private func relaunchFixture(_ app: XCUIApplication) throws {
        app.terminate()
        app.launch()
        try WiltedMacUITestApplicationLaunch.reopenFixture(app)
        app.activate()
        if !app.wait(for: .runningForeground, timeout: 10) {
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    /// The delayed fixture hook counts each playlist write it held open; this
    /// waits until the expected write has been acknowledged before its real
    /// store write, so a pending window can be bounded without polling the UI.
    private func waitForPlaylistWriteAcknowledgments(_ expected: Int) throws {
        let root = try XCTUnwrap(latestFixtureRoot)
        let url = root.appendingPathComponent("playlist-ui-write-acknowledgments.json")
        let acknowledged = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: url),
                      let counts = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                return (counts["writes"] as? Int ?? 0) >= expected
            }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [acknowledged], timeout: 10), .completed,
                       "playlist write \(expected) must be acknowledged")
    }
}
