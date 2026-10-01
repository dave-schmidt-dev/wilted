import Foundation
import XCTest
@testable import WiltediOS

/// Headless conformance checks for the CarPlay scene (W-INV-015, docs/carplay-requirements.md).
/// The CarPlay Simulator and a real car are attended evidence; these catch the rules that can be
/// read from source and from the Info.plist without a screen.
final class CarPlaySourceTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func carPlaySources() throws -> [(name: String, text: String)] {
        let directory = root.appendingPathComponent("WiltediOS/CarPlay", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no CarPlay sources found")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testOnlyListAndNowPlayingTemplatesAreUsed() throws {
        let allowed: Set<String> = [
            "CPListTemplate", "CPNowPlayingTemplate", "CPTabBarTemplate", "CPTemplateApplicationSceneDelegate",
            "CPTemplate"]  // the base class, as a variable type
        let regex = try NSRegularExpression(pattern: "CP[A-Za-z]*Template[A-Za-z]*")
        for (name, text) in try carPlaySources() {
            let range = NSRange(text.startIndex..., in: text)
            let used = Set(regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
            let extra = used.subtracting(allowed).filter { !$0.hasPrefix("CPTemplateApplicationScene") }
            XCTAssertTrue(extra.isEmpty, "\(name) uses templates an audio app may not: \(extra.sorted())")
        }
    }

    /// Depth is tab bar, then one show's list, then Now Playing: three of the five CarPlay allows.
    func testOnlyAShowListAndNowPlayingArePushedSoDepthStaysAtThree() throws {
        var pushes = 0
        for (name, text) in try carPlaySources() {
            XCTAssertFalse(text.contains("presentTemplate("), "\(name) presents a template")
            for line in text.split(separator: "\n") where line.contains("pushTemplate(") {
                pushes += 1
                XCTAssertTrue(
                    line.contains("CPNowPlayingTemplate.shared") || line.contains("pushTemplate(template,"),
                    "\(name) pushes something other than Now Playing or a show's list: \(line)")
            }
        }
        XCTAssertEqual(pushes, 2, "one push for a show's list, one for Now Playing")
    }

    /// A show's list is filled before it is pushed, so filling it must not depend on it being on the
    /// stack yet; the driver going back is noticed through the interface delegate instead.
    func testAShowListIsFilledBeforeItsPushAndForgottenThroughTheDelegate() throws {
        let delegate = try XCTUnwrap(carPlaySources().first { $0.name == "CarPlaySceneDelegate.swift" }).text
        let body = try XCTUnwrap(delegate.components(separatedBy: "private func renderOpenShow").last?
            .components(separatedBy: "private func showItem").first)
        XCTAssertFalse(body.contains("templates.contains"), "filling an open show must not require it to be on the stack")
        XCTAssertTrue(delegate.contains("func templateDidDisappear"), "the delegate notices the driver going back")
    }

    func testTabCountComesFromTheCarAndTheTabBarStaysSmall() throws {
        let delegate = try XCTUnwrap(carPlaySources().first { $0.name == "CarPlaySceneDelegate.swift" }).text
        XCTAssertTrue(delegate.contains("CPTabBarTemplate.maximumTabCount"), "the tab limit is read from the car")
        XCTAssertTrue(delegate.contains("CPTabBarTemplate(templates: [list, shows])"), "two tabs: Downloaded and Shows")
        XCTAssertTrue(delegate.contains("CPListTemplate.maximumItemCount"), "list length comes from the car")
    }

    func testCarPlayCodeNeverTouchesTheAudioSession() throws {
        for (name, text) in try carPlaySources() {
            for forbidden in ["AVAudioSession", "import AVFoundation", "setActive", "setCategory"] {
                XCTAssertFalse(
                    text.contains(forbidden),
                    "\(name) touches the audio session (\(forbidden)); only the player activates it, on play")
            }
        }
    }

    func testListCapComesFromTheCarAtRuntimeNotAHardcodedNumber() throws {
        let delegate = try XCTUnwrap(carPlaySources().first { $0.name == "CarPlaySceneDelegate.swift" }).text
        XCTAssertTrue(delegate.contains("CPListTemplate.maximumItemCount"), "the car's own item limit sizes the list")
        XCTAssertFalse(
            delegate.contains("limit: 12") || delegate.contains("prefix(12)"),
            "the scene must not hardcode the cap; 12 is only the model's default for tests")
    }

    /// David does not want a Siri button on the car screen ("Hey Siri" and the car's Siri button cover it),
    /// and a misconfigured cell crashed the scene on a device. No source configures one.
    func testNoAssistantCellIsConfiguredAnywhereInTheApp() throws {
        let sources = root.appendingPathComponent("WiltediOS", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["CPAssistantCellConfiguration", "assistantCellConfiguration"] {
                XCTAssertFalse(text.contains(forbidden), "\(file.lastPathComponent) configures a Siri assistant cell (\(forbidden))")
            }
        }
    }

    func testAppInfoPlistDeclaresThePlayMediaIntentItHandlesInApp() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("WiltediOS/Info.plist")) as? [String: Any])
        XCTAssertEqual(plist["INIntentsSupported"] as? [String], ["INPlayMediaIntent"])
        XCTAssertEqual(plist["INSupportedMediaCategories"] as? [String], ["INMediaCategoryPodcasts"])
        XCTAssertNotNil(plist["NSSiriUsageDescription"])
        let entitlements = try XCTUnwrap(
            NSDictionary(contentsOf: root.appendingPathComponent("WiltediOS/WiltediOS.entitlements")) as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.developer.siri"] as? Bool, true)
    }

    func testEveryListItemHandlerCompletes() throws {
        for (name, text) in try carPlaySources() where text.contains(".handler") {
            XCTAssertTrue(text.contains("completion()"), "\(name) has a list item handler that never calls completion()")
        }
    }

    func testCarTextNeverAsksTheDriverToHandleThePhone() throws {
        let banned = ["pick up", "unlock your", "open the app", "on your phone", "use your iphone", "tap the"]
        for (name, text) in try carPlaySources() {
            let lowered = text.lowercased()
            for phrase in banned {
                XCTAssertFalse(lowered.contains(phrase), "\(name) contains driver-handling wording: \(phrase)")
            }
        }
    }

    func testInfoPlistDeclaresTheCarPlaySceneAndItsDelegateExists() throws {
        let url = root.appendingPathComponent("WiltediOS/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        let manifest = try XCTUnwrap(plist["UIApplicationSceneManifest"] as? [String: Any])
        let configurations = try XCTUnwrap(manifest["UISceneConfigurations"] as? [String: [[String: Any]]])
        let carPlay = try XCTUnwrap(configurations["CPTemplateApplicationSceneSessionRoleApplication"]?.first)
        XCTAssertEqual(carPlay["UISceneClassName"] as? String, "CPTemplateApplicationScene")
        let delegate = try XCTUnwrap(carPlay["UISceneDelegateClassName"] as? String)
        XCTAssertEqual(delegate, "$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate")
        XCTAssertNotNil(NSClassFromString("WiltediOS.CarPlaySceneDelegate"), "the manifest names a delegate class that does not exist")
        XCTAssertTrue(
            (plist["UIBackgroundModes"] as? [String] ?? []).contains("audio"),
            "CarPlay playback needs the audio background mode")
    }

    func testEntitlementIsInDevelopmentOnlyUntilCarPlayIsReadyForEveryone() throws {
        func entitlements(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("WiltediOS/\(name)")) as? [String: Any])
        }
        XCTAssertEqual(try entitlements("WiltediOS.entitlements")["com.apple.developer.carplay-audio"] as? Bool, true)
        XCTAssertNil(
            try entitlements("WiltediOSProduction.entitlements")["com.apple.developer.carplay-audio"],
            "Production must not carry the CarPlay entitlement until CarPlay is ready for all users")
    }
}
