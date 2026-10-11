import SwiftUI
import Combine
import UIKit
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryLoadingMotifTests: XCTestCase {
    func testLocalReadinessCompletesWithoutNetworkAndIsObservable() async throws {
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        let model = LibraryAppModel(transport: UnavailableLibraryTransport(reason: "Offline fixture"),
                                    store: InMemoryLibraryStore(), deviceID: "motif-phone",
                                    mediaCache: fixture.cache, preferences: fixture.defaults,
                                    ownPositionsURL: fixture.scratch.appendingPathComponent("positions.json"))
        XCTAssertFalse(model.localStateLoaded)
        var readiness: [Bool] = []
        let observation = model.$localStateLoaded.sink { readiness.append($0) }
        await model.loadLocalState()
        XCTAssertTrue(model.localStateLoaded)
        XCTAssertEqual(readiness, [false, true])
        XCTAssertNil(model.errorMessage, "local readiness does not require cloud transport")
        withExtendedLifetime(observation) {}
    }

    func testRootGatesOnlyLocalReadinessAndRetainsExistingSyncErrors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltediOS/Library/LibraryListView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("if !model.localStateLoaded"))
        XCTAssertTrue(source.contains("WiltedLoadingMotif()"))
        XCTAssertTrue(source.contains(".task { await runtime.start() }"))
        XCTAssertTrue(source.contains("if let banner = model.syncBanner"))
        XCTAssertTrue(source.contains("model.recoverFromAccountChange()"), "existing recovery action stays available")
    }

    func testSmallNativeMotifHonorsLightDarkAndReducedMotion() throws {
        for scheme in [ColorScheme.light, .dark] {
            func image(progress: Double?, elapsed: Double, reduced: Bool) throws -> Data {
                let renderer = ImageRenderer(content:
                    WiltedLoadingMotifMark(progress: progress, elapsed: elapsed, reduceMotion: reduced, scheme: scheme)
                        .background(WiltedLoadingMotifGeometry.surface(scheme)))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size, CGSize(width: 100, height: 100))
                let data = try XCTUnwrap(image.pngData())
                let attachment = XCTAttachment(image: image)
                attachment.name = "phone-motif-\(scheme)-\(String(describing: progress))-\(elapsed)-\(reduced)"
                attachment.lifetime = .keepAlways; add(attachment)
                return data
            }
            XCTAssertNotEqual(try image(progress: nil, elapsed: 0, reduced: false),
                              try image(progress: nil, elapsed: 0.725, reduced: false))
            let full = try image(progress: 1, elapsed: 0, reduced: false)
            XCTAssertEqual(try image(progress: nil, elapsed: 0.725, reduced: true), full)
            XCTAssertNotEqual(try image(progress: 0, elapsed: 0, reduced: false), full)
        }
    }
}
