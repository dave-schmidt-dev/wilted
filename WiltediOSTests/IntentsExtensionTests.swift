@preconcurrency import Intents
import XCTest
@testable import WiltediOS

/// The Siri Intents extension that ordinary Siri requests (in the car too) go through: its Info.plist, that it is embedded in
/// the app, and that it hands every play request to the app instead of playing.
final class IntentsExtensionTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func extensionPlist() throws -> [String: Any] {
        try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("WiltediOSIntents/Info.plist")) as? [String: Any])
    }

    func testExtensionInfoPlistDeclaresTheIntentsServiceForPlayMedia() throws {
        let plist = try extensionPlist()
        let ext = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.intents-service")
        XCTAssertEqual(ext["NSExtensionPrincipalClass"] as? String, "$(PRODUCT_MODULE_NAME).IntentHandler")
        let attributes = try XCTUnwrap(ext["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(attributes["IntentsSupported"] as? [String], ["INPlayMediaIntent"])
        XCTAssertEqual(attributes["SupportedMediaCategories"] as? [String], ["INMediaCategoryPodcasts"])
        XCTAssertNil(attributes["IntentsRestrictedWhileLocked"], "CarPlay requests arrive with the phone locked")
    }

    func testTheExtensionIsEmbeddedInTheAppWithTheRightIdentifier() throws {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let appex = plugIns.appendingPathComponent("WiltediOSIntents.appex", isDirectory: true)
        let bundle = try XCTUnwrap(Bundle(url: appex), "the app embeds WiltediOSIntents.appex")
        XCTAssertEqual(bundle.bundleIdentifier, "com.zerodelta.wilted.ios.intents")
    }

    func testTheExtensionPlaysNothingAndHandsTheRequestToTheApp() async {
        let handler = PlayMediaExtensionHandler()
        let intent = INPlayMediaIntent(
            mediaItems: nil, mediaContainer: nil, playShuffled: nil, playbackRepeatMode: .unknown, resumePlayback: nil,
            playbackQueueLocation: .unknown, playbackSpeed: nil, mediaSearch: nil)
        let handled = await handler.handle(intent: intent)
        XCTAssertEqual(handled.code, .handleInApp)
        let confirmed = await handler.confirm(intent: intent)
        XCTAssertEqual(confirmed.code, .ready)
    }

    func testResolveKeepsWhatSiriChoseAndOtherwiseLeavesMatchingToTheApp() async {
        let handler = PlayMediaExtensionHandler()
        let item = INMediaItem(identifier: "ep-1", title: "Chips", type: .podcastEpisode, artwork: nil, artist: "Show")
        let chosen = INPlayMediaIntent(
            mediaItems: [item], mediaContainer: nil, playShuffled: nil, playbackRepeatMode: .unknown, resumePlayback: nil,
            playbackQueueLocation: .unknown, playbackSpeed: nil, mediaSearch: nil)
        XCTAssertEqual(PlayMediaExtensionHandler.chosenItems(for: chosen)?.map(\.identifier), ["ep-1"])
        let kept = await handler.resolveMediaItems(for: chosen)
        XCTAssertEqual(kept.count, 1)
        let bare = INPlayMediaIntent(
            mediaItems: nil, mediaContainer: nil, playShuffled: nil, playbackRepeatMode: .unknown, resumePlayback: nil,
            playbackQueueLocation: .unknown, playbackSpeed: nil,
            mediaSearch: INMediaSearch(mediaType: .podcastEpisode, sortOrder: .unknown, mediaName: "Chips", artistName: nil,
                                       albumName: nil, genreNames: nil, moodNames: nil, releaseDate: nil, reference: .unknown, mediaIdentifier: nil))
        XCTAssertNil(PlayMediaExtensionHandler.chosenItems(for: bare), "nothing is invented; the app matches the search")
        let passedThrough = await handler.resolveMediaItems(for: bare)
        XCTAssertEqual(passedThrough.count, 1)
    }
}
