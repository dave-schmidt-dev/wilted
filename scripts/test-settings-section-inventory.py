"""Check each section's rendered view composition against the pre-regroup control inventory."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1] / "WiltedMac"


def source(name):
    return next(ROOT.rglob(name + ".swift")).read_text()


def controls(text):
    return re.findall(r'"(wilted-[^"\n]+)', text)


class SettingsInventory(unittest.TestCase):
    def test_every_device_row_offers_a_menu_instead_of_the_stop_link(self):
        card = source("WiltedMacLibrarySyncCard")
        self.assertNotIn("Stop direct downloads for this iPhone", card)
        rows = card.split("ForEach(WiltedMacLibrarySyncStatus.deviceRows(activity.devices)) { row in")[1].split("// The counters")[0]
        self.assertNotIn("if ", rows)
        self.assertIn("WiltedMacDeviceDownloadsRow(row: row, macEnabled: model.isDirectDownloadsEnabled,", rows)
        self.assertIn("onStop: { model.stopDirectDownloads(for: row.id) }", rows)
        self.assertIn("onRename: { try await model.renameDevice(row.id, to: $0) }", rows)
        self.assertIn("onRemove: { try await model.removeDevice(row.id) }", rows)
        self.assertIn(".disabled(!canStop)", card)
        self.assertIn('Button("Rename…", action: onRename)', card)
        self.assertIn('Button("Remove device…", role: .destructive, action: onRemove)', card)

    def test_phone_sections_render_in_declared_order(self):
        view = (ROOT.parent / "WiltediOS/Library/LibrarySettingsView.swift").read_text()
        self.assertIn("ForEach(LibrarySettingsSection.allCases", view)
        for name in ("general", "playback", "storage", "devices", "about"):
            self.assertRegex(view, rf"case \.{name}:\s+{name}Card")
            body = view.split(f"private var {name}Card:", 1)[1].split("\n    }", 1)[0]
            self.assertIn(f"WiltedSettingsCard(title: LibrarySettingsSection.{name}.title)", body)
            self.assertIn(f"scopeNote(.{name})", body)
        self.assertEqual(view.count("WiltedSettingsCard(title:"), 5)
        about = view.split("private var aboutCard:", 1)[1].split("private var", 1)[0]
        for content in ("StatisticsRows(", "aboutRows(", "diagnosticsDisclosure"):
            self.assertIn(content, about)

    def test_sections(self):
        settings = source("WiltedMacSettingsView")
        self.assertIn("sectionContent", settings, "Settings must render the selected section")
        layout = source("WiltedMacSettingsSections").split("var sectionContent:")[1]
        # Expand the view declarations reached by each arm of the section switch.
        parts = dict(re.findall(r'case \.(\w+):\n(.*?)(?=\n        (?:case |\}))', layout, re.S))
        declarations = dict(re.findall(r'var (\w+): some View \{\n(.*?)(?=\n    \})', settings, re.S))
        declarations = {name: body for name, body in declarations.items() if name.endswith("Card")}
        declarations["WiltedMacLibrarySyncCard"] = source("WiltedMacLibrarySyncCard").split("struct WiltedMacLibrarySyncCard: View {", 1)[1]
        for name in ("WiltedMacAdFindingSettingsView", "WiltedMacReportsCard", "WiltedMacAdFeedbackCard",
                     "WiltedMacLifetimeStatisticsCard"):
            declarations[name] = source(name)
        declarations["WiltedMacGlobalFeedDefaultsControls"] = source("WiltedMacGlobalFeedDefaultsControls").split("struct WiltedMacGlobalFeedDefaultsControls")[1]
        declarations["WiltedMacInheritedFeedDefaults"] = source("WiltedMacFeedsComponents").split("struct WiltedMacInheritedFeedDefaults")[1].split("\nstruct ")[0]

        inherited = declarations["WiltedMacInheritedFeedDefaults"]
        # These two rows use the same Swift interpolation, with different labels.
        template = next(line for line in inherited.splitlines() if ".accessibilityIdentifier(" in line)
        inherited_ids = [
            '"wilted-automation-feed-default-' + label.lower().replace(" ", "-") + '"'
            for label in re.findall(r'\$0.label == "([^"]+)"', inherited)
        ]
        self.assertIn('row.label.lowercased().replacingOccurrences(of: " ", with: "-")', template)
        declarations["WiltedMacInheritedFeedDefaults"] = inherited.replace(template, " ".join(inherited_ids))

        shared = ROOT.parent / "Shared"
        publication = (shared / "WiltedAccountRecoveryNotice.swift").read_text()
        declarations["WiltedPublicationNotice"] = publication.split("public struct WiltedPublicationNotice")[1]
        statistics = declarations["WiltedMacLifetimeStatisticsCard"]
        for owner, definitions in [
            ("WiltedScreenCopy", (shared / "WiltedRootView.swift").read_text()),
            ("WiltedMacStatisticsCopy", source("WiltedMacStatisticsState")),
        ]:
            for name, identifier in re.findall(r'static let (\w+Identifier) = "(wilted-[^"]+)"', definitions):
                statistics = statistics.replace(owner + "." + name, '"' + identifier + '"')
        declarations["WiltedMacLifetimeStatisticsCard"] = statistics

        def expand(body):
            result = controls(body)
            for name, declaration in declarations.items():
                for _ in re.finditer(r'\b' + name + (r'\(' if name.startswith('Wilted') else r'\b'), body):
                    result.extend(expand(declaration))
            return result

        self.assertEqual(set(parts), set(INVENTORY))
        for section, expected in INVENTORY.items():
            with self.subTest(section=section):
                self.assertCountEqual(expand(parts[section]), expected)


class ShowSettingsInventory(unittest.TestCase):
    def setUp(self):
        self.page_files = sorted(ROOT.glob("Views/*ShowSettings*.swift"))
        self.page_files.extend(
            path for path in ROOT.glob("Views/*.swift")
            if "struct WiltedMacFeedDetailsSection" in path.read_text() and path not in self.page_files
        )
        self.page_source = "\n".join(path.read_text() for path in self.page_files)
        self.all_view_source = "\n".join(path.read_text() for path in ROOT.glob("Views/*.swift"))

    def assert_page_controls_once(self, identifiers):
        self.assertTrue(self.page_files, "Show settings page source must be present")
        self.assertEqual(self.page_source.count('"wilted-show-settings-page-\\(feedID)"'), 1)
        for identifier in identifiers:
            with self.subTest(identifier=identifier):
                self.assertEqual(self.page_source.count(identifier), 1)

    def test_podcast_settings_page_has_each_applicable_control_once(self):
        self.assert_page_controls_once([
            '"wilted-feed-policy-auto-keep"',
            '"wilted-feed-policy-auto-download"',
            '"wilted-feed-policy-auto-prepare"',
            '"wilted-feed-policy-kept-limit-mode"',
            '"wilted-feed-policy-kept-limit"',
            '"wilted-feed-policy-kept-limit-stepper"',
            '"wilted-feed-policy-ad-free"',
            '"wilted-feed-policy-restore-cuts"',
            '"wilted-feed-policy-remove-self-promotion"',
            '"wilted-feed-policy-send-for-ad-finding"',
            '"wilted-show-settings-rename"',
            '"wilted-feed-details-source-\\(subscription.id)"',
        ])
        self.assertEqual(self.all_view_source.count('"wilted-podcast-feed-rename-\\(subscription.id)"'), 1,
                         "rename remains a single inline Feeds action")
        self.assertIn("if !isArticle {", self.page_source)
        type_section = self.page_source.split("private var typeSection:", 1)[1].split("private var newsRow:", 1)[0]
        self.assertIn("if isArticle && board.isLoaded(feedID) { newsRow }", type_section)

    def test_article_settings_page_has_article_controls_once(self):
        self.assert_page_controls_once([
            '"wilted-feed-policy-auto-keep"',
            '"wilted-feed-policy-auto-prepare"',
            '"wilted-feed-policy-kept-limit-mode"',
            '"wilted-feed-policy-kept-limit"',
            '"wilted-feed-policy-kept-limit-stepper"',
            '"wilted-feed-policy-news"',
            '"wilted-show-settings-rename"',
            '"wilted-feed-details-source-\\(subscription.id)"',
        ])
        ads = self.page_source.split("private var adsSection:", 1)[1].split("private var typeSection:", 1)[0]
        self.assertIn("if board.isLoaded(feedID), !isArticle {", ads)
        for row in ("removeAdsRow", "restoreCutEpisodesRow", "selfPromotionRow", "sendForAdFindingRow"):
            self.assertIn(row, ads)

    def test_retired_show_editors_and_accessibility_identifiers_are_gone(self):
        for retired in (
            "struct WiltedMacFeedPolicyContent", "struct WiltedMacFeedPolicyButton",
            "struct WiltedMacFeedDetailsView", '"wilted-mac-feed-details-',
            '"wilted-feed-policy-button-', '"wilted-feed-policy-done"',
            '"wilted-ad-finding-sheet-show-', '"wilted-ad-finding-review"',
        ):
            with self.subTest(retired=retired):
                self.assertNotIn(retired, self.all_view_source)

    def test_show_row_reset_uses_its_own_setting_and_feed(self):
        self.assertIn("reset: { board.reset(setting, for: feedID) }", self.page_source)
        self.assertIn("private var feedID: String { subscription.id }", self.page_source)

    def test_show_reset_can_only_revoke_consent(self):
        resets = source("WiltedMacShowSettingsBoard")
        self.assertNotIn("setSendForAdFinding(", resets)
        self.assertNotIn("setConfirmed(", resets)
        board = source("WiltedMacFeedPolicyBoard")
        revoke = board.split("func resetAdFinding(", 1)[1].split("\n    }", 1)[0]
        self.assertEqual(re.findall(r"setConfirmed\(feedID: feedID, (\w+)\)", revoke), ["false"])
        self.assertNotIn("keepBack(", revoke)

    def test_page_orders_sections_like_global_defaults(self):
        self.assertTrue(self.page_files, "Show settings page source must be present")
        body = self.page_source.split("var body: some View", 1)[1].split("@ViewBuilder private var renameTitleAccessory", 1)[0]
        self.assertNotIn("playbackSection", body)
        positions = [body.index(section) for section in
                     ("newEpisodesSection", "adsSection", "typeSection",
                      "WiltedMacFeedDetailsSection(")]
        self.assertEqual(positions, sorted(positions))


INVENTORY = {
    "general": [
        'wilted-text-scale',
        'wilted-sidebar-counts',
        'wilted-appearance-controls',
        'wilted-appearance-help',
    ],
    "newEpisodes": [
        'wilted-automation-status',
        'wilted-automation-stop',
        'wilted-automation-refresh-policy',
        'wilted-automation-initial-metadata-count',
        'wilted-automation-initial-metadata-custom',
        'wilted-automation-larder-overrides-explanation',
        'wilted-automation-auto-add-to-larder',
        'wilted-automation-download-everything',
        'wilted-automation-prepare-everything',
        'wilted-automation-feed-defaults-explanation',
        'wilted-automation-controls',
        'wilted-automation-feed-default-auto-keep',
        'wilted-automation-feed-default-kept-limit-mode',
        'wilted-automation-feed-default-kept-limit',
        'wilted-automation-feed-default-kept-limit-stepper',
        "wilted-automation-feed-default-auto-download",
        "wilted-automation-feed-default-auto-prepare",
    ],
    "preparing": [
        'wilted-automation-processing-policy',
        'wilted-automation-off-peak-start',
        'wilted-automation-off-peak-end',
        'wilted-automation-off-peak-explanation',
        'wilted-automation-transcript-policy',
        'wilted-automation-transcript-conflict',
    ],
    "ads": [
        'wilted-automation-remove-ads',
        'wilted-automation-ad-marker',
        'wilted-ad-finding-switch',
        'wilted-ad-finding-switch-message',
        'wilted-ad-finding-provider-paused',
        'wilted-ad-finding-requests',
        'wilted-ad-finding-help',
        'wilted-ad-finding-consent-summary',
        'wilted-ad-finding-controls',
        'wilted-ad-finding-key-saved',
        'wilted-ad-finding-key-remove',
        'wilted-ad-finding-key-field',
        'wilted-ad-finding-key-save',
        'wilted-ad-finding-key-message',
        'wilted-settings-all-show-\\(subscription.id)',
        'wilted-settings-all-shows-page',
        'wilted-settings-all-shows-done',
        'wilted-settings-all-shows-back',
        'wilted-feed-sheet-done',
        'wilted-ad-finding-sheet-cancel',
        'wilted-ad-finding-sheet-confirm',
        'wilted-ad-finding-sheet',
        'wilted-ad-finding-confirm-show-\\(show.feedID)',
        'wilted-ad-feedback-summary',
        'wilted-ad-feedback-failure',
        'wilted-ad-feedback-removed',
        'wilted-ad-feedback-card',
        'wilted-ad-feedback-row-\\(entry.id)',
        'wilted-ad-feedback-label',
        'wilted-ad-feedback-remove',
        'wilted-ad-feedback-restore',
    ],
    "reports": [
        'wilted-reports-interruptions',
        'wilted-reports-readiness',
        'wilted-reports-add-news-feed',
        'wilted-reports-refresh-news-readiness',
        'wilted-reports-set-location',
        'wilted-reports-retry-sound-check',
        'wilted-reports-test-bulletin',
        'wilted-reports-interruptions-off-note',
        'wilted-reports-alerts',
        'wilted-reports-headlines',
        'wilted-reports-skip-sports',
        'wilted-reports-skip-words',
        'wilted-reports-skipped-count',
        'wilted-reports-wait-limit',
        'wilted-reports-headline-gap',
        'wilted-reports-bulletin-status',
        'wilted-reports-daily',
        'wilted-reports-time',
        'wilted-reports-nws-contact',
        'wilted-reports-details',
        'wilted-reports-controls',
        'wilted-reports-help',
        'wilted-reports-location-status',
        'wilted-reports-location-detail',
        'wilted-reports-latitude',
        'wilted-reports-longitude',
        'wilted-reports-coordinate-problem',
        'wilted-reports-location-allow',
        'wilted-reports-location-open-settings',
        'wilted-reports-location-refresh',
        'wilted-reports-daily-status',
        'wilted-reports-build-now',
    ],
    "devices": [
        "wilted-author-publication",
        'wilted-sync-status',
        'wilted-sync-throttle',
        'wilted-sync-last-send',
        'wilted-sync-last-check',
        'wilted-sync-direct-downloads-toggle',
        'wilted-sync-device',
        'wilted-sync-device-menu-\\(row.id)',
        'wilted-sync-device-toggle-\\(row.id)',
        'wilted-sync-stop-direct-\\(row.id)',
        'wilted-sync-device-rename-\\(row.id)',
        'wilted-sync-device-remove-\\(row.id)',
        'wilted-sync-device-last-announced-\\(row.id)',
        'wilted-sync-device-name-field',
        'wilted-sync-device-confirm-remove',
        'wilted-sync-diagnostics',
        'wilted-sync-scope-note',
        'wilted-sync-now',
        'wilted-sync-review-account',
        'wilted-sync-review-approve',
        'wilted-sync-review-keep-held',
        'wilted-sync-controls',
    ],
    "about": [
        "wilted-lifetime-statistics-scope",
        "wilted-lifetime-audio-processed",
        "wilted-lifetime-speech-generated",
        "wilted-lifetime-ad-time-removed",
        "wilted-lifetime-speed-time-saved",
        "wilted-lifetime-played-time",
        "wilted-lifetime-downloaded",
        "wilted-lifetime-skipped-time",
        "wilted-lifetime-tracking-start",
        "wilted-lifetime-statistics-retry",
        "wilted-lifetime-statistics-status",
        "wilted-lifetime-statistics-status",

        'wilted-lifetime-statistics',
        'wilted-statistics-help',
    ],
}

if __name__ == "__main__":
    unittest.main()
