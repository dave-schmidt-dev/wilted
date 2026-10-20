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
        XCTAssertTrue(source.contains("if !model.larderReady"), "the saved rows show while the audio is checked (W-INV-040)")
        XCTAssertTrue(source.contains("WiltedLoadingMotif()"))
        XCTAssertEqual(source.components(separatedBy: "Text(\"Opening your larder…\")").count - 1, 1)
        XCTAssertTrue(source.contains(".task { await runtime.start() }"))
        XCTAssertTrue(source.contains("if let banner = model.syncBanner"))
        XCTAssertTrue(source.contains("model.recoverFromAccountChange()"), "existing recovery action stays available")
        let motif = try String(contentsOf: url.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Shared/WiltedLoadingMotif.swift"), encoding: .utf8)
        XCTAssertTrue(motif.contains(".accessibilityHidden(true)"), "the adjacent status is the one accessible wait")
        XCTAssertFalse(motif.contains(".accessibilityValue("), "indeterminate art never announces a percentage")
    }

    func testBothNativeSizesHonorLightDarkSampledMotionAndSettledReducedMotion() throws {
        // Independently transcribed motion samples from the dated approved package.
        // Exact same-renderer PNG equality is stronger than its two-channel limit;
        // this does not compare native pixels with browser contact-strip pixels.
        let times = [0.0, 0.2, 0.4, 0.8, 1.2, 1.55, 1.599, 1.6]
        for size in WiltedLoadingMotifSize.allCases {
            for scheme in [ColorScheme.light, .dark] {
                func image(elapsed: Double, reduced: Bool, retainEvidence: Bool = false) throws -> Data {
                    let renderer = ImageRenderer(content:
                        WiltedLoadingMotifMark(size: size, elapsed: elapsed, reduceMotion: reduced, scheme: scheme)
                            .background(WiltedLoadingMotifGeometry.surface(scheme)))
                    renderer.scale = size == .compact ? 8 : 3
                    let image = try XCTUnwrap(renderer.uiImage)
                    XCTAssertEqual(image.size, CGSize(width: size.rawValue, height: size.rawValue))
                    let pixels = try XCTUnwrap(image.cgImage)
                    XCTAssertEqual(pixels.width, Int(size.rawValue * renderer.scale))
                    XCTAssertEqual(pixels.height, Int(size.rawValue * renderer.scale))
                    if retainEvidence {
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "phone-serpentine-\(Int(size.rawValue))-\(scheme)-\(elapsed)-reduced-\(reduced)"
                        attachment.lifetime = .keepAlways; add(attachment)
                    }
                    return try XCTUnwrap(image.pngData())
                }
                let zero = try image(elapsed: 0, reduced: false, retainEvidence: true)
                for time in times {
                    let moving = try image(elapsed: time, reduced: false, retainEvidence: time == 0.8)
                    if time == 0 || time == 1.6 {
                        XCTAssertEqual(moving, zero)
                    } else {
                        XCTAssertNotEqual(moving, zero, "the dash travels at \(time)")
                    }
                    XCTAssertEqual(try image(elapsed: time, reduced: true, retainEvidence: time == 0), zero,
                                   "reduced motion is the settled phase-zero dash, not a full outline")
                }
            }
        }
    }
}
