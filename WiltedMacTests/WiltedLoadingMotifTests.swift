import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedLoadingMotifTests: XCTestCase {
    func testExactAcceptedCubicGeometryAndNormalizedDashTiming() {
        let geometry = WiltedLoadingMotifGeometry.self
        XCTAssertEqual(geometry.start, CGPoint(x: 13, y: 26))
        let expected: [[CGFloat]] = [
            [13,19,21,19,21,27], [23,40,28,63,34,63], [39,63,44,34,50,34],
            [56,34,61,63,66,63], [72,63,77,40,79,27], [79,19,87,19,87,26]
        ]
        XCTAssertEqual(geometry.curves.map { [$0.0.x,$0.0.y,$0.1.x,$0.1.y,$0.2.x,$0.2.y] }, expected)
        XCTAssertEqual(geometry.strokeWidth, 10)
        XCTAssertEqual(geometry.dashFraction, 0.24)
        XCTAssertEqual(geometry.cycle, 1.45)
        XCTAssertEqual(geometry.phase(at: 0), 0)
        XCTAssertEqual(geometry.phase(at: 0.725), 0.5, accuracy: 0.000001)
        XCTAssertEqual(geometry.phase(at: 1.45), 0, accuracy: 0.000001)
        XCTAssertGreaterThan(geometry.length, 100)
        XCTAssertLessThan(geometry.length, 200)
    }

    func testActualProgressClampsWithoutInventingCompletion() {
        XCTAssertEqual(WiltedLoadingMotifGeometry.fraction(0), 0)
        XCTAssertEqual(WiltedLoadingMotifGeometry.fraction(0.37), 0.37, accuracy: 0.000001)
        XCTAssertEqual(WiltedLoadingMotifGeometry.fraction(1), 1)
        XCTAssertEqual(WiltedLoadingMotifGeometry.fraction(-1), 0)
        XCTAssertEqual(WiltedLoadingMotifGeometry.fraction(2), 1)
        XCTAssertEqual(WiltedLoadingMotifGeometry.fraction(.nan), 0)
    }

    func testSmallNativeLightAndDarkWaitingProgressAndSettledMotion() throws {
        for scheme in [ColorScheme.light, .dark] {
            func pixels(_ progress: Double?, _ elapsed: Double, _ reduced: Bool) throws -> Data {
                let bitmap = try WiltedMacHeadless.render(
                    WiltedLoadingMotifMark(progress: progress, elapsed: elapsed, reduceMotion: reduced, scheme: scheme)
                        .background(WiltedLoadingMotifGeometry.surface(scheme)), size: CGSize(width: 100, height: 100))
                XCTAssertEqual(bitmap.pixelsWide, 100); XCTAssertEqual(bitmap.pixelsHigh, 100)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "motif-\(scheme)-\(String(describing: progress))-\(elapsed)-\(reduced)"
                attachment.lifetime = .keepAlways; add(attachment)
                return png
            }
            XCTAssertNotEqual(try pixels(nil, 0, false), try pixels(nil, 0.725, false), "waiting dash travels")
            let empty = try pixels(0, 0, false), half = try pixels(0.5, 0, false), full = try pixels(1, 0, false)
            XCTAssertNotEqual(empty, half); XCTAssertNotEqual(half, full)
            XCTAssertEqual(try pixels(nil, 0, true), full, "reduced motion settles the full W")
            XCTAssertEqual(try pixels(0.2, 0.725, true), full)
        }
    }
}
