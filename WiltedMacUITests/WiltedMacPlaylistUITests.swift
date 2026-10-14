import XCTest

@MainActor
extension WiltedMacEpisodeInfoUITests {
    /// Discovery of a manual playlist from a Larder row, the rename that
    /// updates beside the title while its write is pending, the established
    /// player path with the labelled Share options panel, and a confirmed
    /// delete that falls back to the Larder without touching the episode.
    func testManualPlaylistDiscoveryRenameDeleteAndShare() throws {
        let app = try launchFixture(extraArguments: ["--wilted-ui-fixture-playlist-write-delay"])
        let episodeID = keepFixtureEpisode(app)
        openLarderForEpisode(app, id: episodeID)
        let playlistID = try createManualPlaylistFromLarder(app, entryID: episodeID)

        // Creation is optimistic: the row, its entry and the selected page
        // appear before the delayed durable write has run.
        let creating = element(app, "wilted-sidebar-playlist-creating")
        XCTAssertTrue(creating.waitForExistence(timeout: 3), "New Playlist shows its pending create")
        let pageSaving = element(app, "wilted-playlist-saving")
        XCTAssertTrue(pageSaving.waitForExistence(timeout: 3))
        XCTAssertTrue(words(pageSaving).contains("Creating playlist"))
        XCTAssertTrue(element(app, "wilted-playlist-row-\(episodeID)").waitForExistence(timeout: 3),
                      "the new manual playlist shows the kept entry while the create is pending")
        XCTAssertTrue(creating.waitForNonExistence(timeout: 10), "the create's durable write settles")
        XCTAssertTrue(pageSaving.waitForNonExistence(timeout: 10))
        try waitForPlaylistWriteAcknowledgments(1)

        // Rename while a fresh delayed write is pending: the new name is on
        // the page immediately, and the pencil and trash stay with the title.
        let rename = app.buttons["wilted-playlist-rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.click()
        let name = try renamePlaylist(app, to: "Field Notes List")
        XCTAssertTrue(pageSaving.waitForExistence(timeout: 3), "the rename is pending before its durable write")
        XCTAssertTrue(words(pageSaving).contains("Saving playlist"))
        XCTAssertTrue(element(app, "wilted-sidebar-playlist-saving-\(playlistID)").waitForExistence(timeout: 3))
        let destination = element(app, "wilted-playlist-\(playlistID)")
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        let title = destination.staticTexts[name]
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
        XCTAssertTrue(pageSaving.waitForNonExistence(timeout: 10), "the rename's durable write settles")
        try waitForPlaylistWriteAcknowledgments(2)

        // The durable store keeps the playlist, its entry and its name across a
        // relaunch of the same owned fixture directory.
        try relaunchFixture(app)
        let sidebarRow = app.descendants(matching: .any)["wilted-navigation-playlist:\(playlistID)"]
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 10), "the created playlist survives a relaunch")
        XCTAssertEqual(sidebarRow.label, name)
        sidebarRow.click()
        XCTAssertTrue(element(app, "wilted-playlist-\(playlistID)").waitForExistence(timeout: 10))
        XCTAssertEqual(destination.staticTexts[name].label, name)
        XCTAssertTrue(element(app, "wilted-playlist-row-\(episodeID)").waitForExistence(timeout: 10),
                      "the durable playlist keeps the kept entry")

        // A fixture relaunch rebuilds the Larder queue from Keep, so the
        // established fixture path re-keeps the same episode before playing.
        XCTAssertEqual(keepFixtureEpisode(app), episodeID)
        // The established fixture path plays the prepared episode, and the
        // labelled Share options control opens its panel without sharing.
        openLarderForEpisode(app, id: episodeID)
        let play = app.buttons["wilted-larder-play-\(episodeID)"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        clickVerified(play, in: app, name: "Play \(episodeID)", label: "Play Quiet Machines now")
        let share = element(app, "wilted-player-share-options")
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        XCTAssertEqual(share.label, "Share options")
        clickVerified(share, in: app, name: "Share options")
        let includeSummary = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Include transcript summary'")
        ).firstMatch
        XCTAssertTrue(includeSummary.waitForExistence(timeout: 5), "Share options opens its panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(includeSummary.waitForNonExistence(timeout: 5), "the panel closes without sharing")

        // Delete confirms, falls back to the Larder, and the episode remains.
        sidebarRow.click()
        XCTAssertTrue(element(app, "wilted-playlist-\(playlistID)").waitForExistence(timeout: 10))
        let delete = app.buttons["wilted-playlist-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        let confirm = app.buttons["Delete Playlist"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(element(app, "wilted-mac-larder-detail").waitForExistence(timeout: 10),
                      "deleting the selected playlist falls back to the Larder")
        XCTAssertTrue(element(app, "wilted-player-show-notes-\(episodeID)").waitForExistence(timeout: 10),
                      "the episode is not deleted with the playlist")
        XCTAssertTrue(element(app, "wilted-larder-row-\(episodeID)").waitForExistence(timeout: 10),
                      "the retained episode is still in the Larder after deleting its playlist")
        try waitForPlaylistWriteAcknowledgments(3)
        XCTAssertTrue(sidebarRow.waitForNonExistence(timeout: 5), "the deleted playlist's row stays gone")
        XCTAssertFalse(element(app, "wilted-sidebar-playlist-error-\(playlistID)").exists,
                       "the durable delete did not fail")
        attachWindow(app, name: "Manual playlist deleted, episode kept")
    }

    /// The automatic editor: copied rules, a grouped formula with its live
    /// preview, an unknown reference that clears both, a preview title's exact
    /// notes, and a save whose pending and completion states are visible.
    func testAutomaticPlaylistFormulaPreviewAndSave() throws {
        let app = try launchFixture(extraArguments: ["--wilted-ui-fixture-playlist-write-delay"])
        let playlistID = try createAutomaticPlaylist(app)
        XCTAssertTrue(element(app, "wilted-playlist-saving").waitForExistence(timeout: 3),
                      "the automatic playlist appears before its delayed write completes")
        XCTAssertTrue(element(app, "wilted-playlist-saving").waitForNonExistence(timeout: 10),
                      "the new automatic playlist's create write settles")
        try waitForPlaylistWriteAcknowledgments(1)
        let editRules = app.buttons["wilted-playlist-edit-rules"]
        XCTAssertTrue(editRules.waitForExistence(timeout: 10))
        editRules.click()
        let sheet = element(app, "wilted-playlist-rules-sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))

        let add = app.buttons["wilted-playlist-rules-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        choose(app, picker: "Rule 1 field", option: "Feed")
        XCTAssertTrue(pickerValue(app, "Rule 1 value").contains("Field Notes"))
        add.click()
        XCTAssertTrue(pickerValue(app, "Rule 2 field").contains("Feed"), "Add copies the last field")
        XCTAssertTrue(pickerValue(app, "Rule 2 comparison").contains("is"), "Add copies the last comparison")
        choose(app, picker: "Rule 2 comparison", option: "is not")
        add.click()
        XCTAssertTrue(pickerValue(app, "Rule 3 comparison").contains("is not"), "Add copies the last comparison")
        choose(app, picker: "Rule 3 field", option: "Played")
        XCTAssertTrue(pickerValue(app, "Rule 3 value").contains("Unplayed"))
        add.click()
        XCTAssertTrue(pickerValue(app, "Rule 4 field").contains("Played"), "Add copies the last field")
        choose(app, picker: "Rule 4 field", option: "Ready")
        XCTAssertTrue(pickerValue(app, "Rule 4 value").contains("Yes"))

        let expression = element(app, "wilted-playlist-rule-expression")
        XCTAssertTrue(expression.waitForExistence(timeout: 5))
        replaceText(expression, with: "(1 OR 2) AND 3 AND 4")
        let count = element(app, "wilted-playlist-rule-preview-count")
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the grouped formula previews live")
        XCTAssertEqual(count.label, "2 matching", "the live count reflects the matching episodes")
        let previewTitle = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-playlist-preview-show-notes-'")
        ).firstMatch
        XCTAssertTrue(previewTitle.waitForExistence(timeout: 5))
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

        save.click()
        let saving = element(app, "wilted-playlist-rules-saving")
        XCTAssertTrue(saving.waitForExistence(timeout: 3), "Save shows its spinner while the write is pending")
        XCTAssertFalse(save.isEnabled, "Save is disabled while the write is pending")
        XCTAssertFalse(expression.isEnabled, "the expression field is locked while the save is pending")
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the sheet dismisses when the save completes")
        XCTAssertTrue(element(app, "wilted-playlist-edit-rules").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "wilted-playlist-row-\(previewID)").waitForExistence(timeout: 10),
                      "the saved automatic playlist holds its matching entry")
        try waitForPlaylistWriteAcknowledgments(2)
        attachWindow(app, name: "Automatic playlist saved")
    }

    /// Keeps the prepared fixture episode from Feeds and returns its ID.
    private func keepFixtureEpisode(_ app: XCUIApplication) -> String {
        let feeds = element(app, "wilted-navigation-feeds")
        XCTAssertTrue(feeds.waitForExistence(timeout: 10))
        feeds.click()
        XCTAssertTrue(element(app, "wilted-mac-feeds-detail").waitForExistence(timeout: 10))
        let keep = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        let id = String(keep.identifier.dropFirst("wilted-feeds-keep-".count))
        XCTAssertFalse(id.isEmpty)
        keep.click()
        return id
    }

    private func openLarderForEpisode(_ app: XCUIApplication, id: String) {
        element(app, "wilted-navigation-larder").click()
        XCTAssertTrue(element(app, "wilted-mac-larder-detail").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "wilted-larder-row-\(id)").waitForExistence(timeout: 10))
    }

    /// Requires the visible Larder action and returns the new playlist's ID.
    private func createManualPlaylistFromLarder(_ app: XCUIApplication, entryID: String) throws -> String {
        let rowAction = element(app, "wilted-add-to-playlist-\(entryID)")
        XCTAssertTrue(rowAction.waitForExistence(timeout: 5), "Add to Playlist is visible in the Larder row")
        clickVerified(rowAction, in: app, name: "Add to Playlist")
        let newPlaylist = app.menuItems["New Playlist…"]
        XCTAssertTrue(newPlaylist.waitForExistence(timeout: 5), "New Playlist is offered")
        newPlaylist.click()
        return try XCTUnwrap(newPlaylistID(app))
    }

    private func createAutomaticPlaylist(_ app: XCUIApplication) throws -> String {
        let menu = element(app, "wilted-sidebar-new-playlist")
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.click()
        let item = app.menuItems["New Automatic Playlist"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
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
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the rename prompt exposes its name field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        let confirm = app.buttons["Rename"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
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
        let popUp = app.popUpButtons[label]
        if popUp.exists { return popUp }
        let labelled = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", label)
        ).firstMatch
        return labelled.exists ? labelled : element(app, label)
    }

    private func pickerValue(_ app: XCUIApplication, _ label: String) -> String {
        let control = pickerControl(app, label)
        XCTAssertTrue(control.waitForExistence(timeout: 5), label)
        if let value = control.value as? String, !value.isEmpty { return value }
        return words(control)
    }

    private func choose(_ app: XCUIApplication, picker label: String, option: String) {
        let control = pickerControl(app, label)
        XCTAssertTrue(control.waitForExistence(timeout: 5), label)
        clickVerified(control, in: app, name: label)
        let menuItem = app.menuItems[option]
        let buttonItem = app.buttons[option]
        let choice = menuItem.waitForExistence(timeout: 5) ? menuItem : buttonItem
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(label) offers \(option)")
        choice.click()
    }

    /// Clicks through the control's own AX action, or through its verified
    /// on-window center when XCTest rejects that action.
    private func clickVerified(
        _ control: XCUIElement, in app: XCUIApplication, name: String, label: String? = nil
    ) {
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
            return XCTFail("\(name) must be a visible control inside its fixture window")
        }
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
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
