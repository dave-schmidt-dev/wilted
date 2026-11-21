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
        declarations["WiltedMacGlobalFeedDefaultsControls"] = source("WiltedMacFeedPolicyView").split("struct WiltedMacGlobalFeedDefaultsControls")[1]
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
        'wilted-ad-finding-controls',
        'wilted-ad-finding-key-saved',
        'wilted-ad-finding-key-remove',
        'wilted-ad-finding-key-field',
        'wilted-ad-finding-key-save',
        'wilted-ad-finding-key-message',
        'wilted-ad-finding-waiting',
        'wilted-ad-finding-review',
        'wilted-ad-finding-sheet-cancel',
        'wilted-ad-finding-sheet-confirm',
        'wilted-ad-finding-sheet',
        'wilted-ad-finding-sheet-show-\\(show.feedID)',
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
        'wilted-reports-route-status',
        'wilted-reports-interruptions-off-note',
        'wilted-reports-alerts',
        'wilted-reports-headlines',
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
