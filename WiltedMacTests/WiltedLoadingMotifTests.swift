import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedLoadingMotifTests: XCTestCase {
    // Independent transcription of the immutable owner-approved 2026-10-12
    // docs/motifs/2026-10-12/assets/loading-larder-serpentine-{20,64}-template.svg.
    // The integration gate intentionally does not stage docs/. These constants
    // are reference input, not snapshots generated from the implementation.
    private let approvedOutline: [[CGFloat]] = [
        [0,17,8], [1,47,8], [2,50,8,50,11], [1,50,24], [2,50,27,47,27],
        [1,17,27], [2,14,27,14,30], [1,14,38], [2,14,41,17,41],
        [1,47,41], [2,50,41,50,44], [1,50,53], [2,50,56,47,56],
        [1,17,56], [2,14,56,14,53], [1,14,11], [2,14,8,17,8], [3]
    ]
    private let approvedShelves: [[CGFloat]] = [
        [0,14,27], [1,50,27], [0,14,41], [1,50,41], [0,32,8], [1,32,56],
        [0,27,17], [1,27,22], [0,37,17], [1,37,22], [0,21,33], [1,28,33],
        [0,36,33], [1,44,33], [0,21,47], [1,28,47], [0,36,47], [1,44,47]
    ]
    private let sampleTimes = [0.0, 0.2, 0.4, 0.8, 1.2, 1.55, 1.599, 1.6]

    func testExactApprovedNativeGeometryAndStrokesForBothSizes() {
        for size in WiltedLoadingMotifSize.allCases {
            let geometry = WiltedLoadingMotifGeometry(size: size)
            let scale = size.rawValue / 64
            XCTAssertEqual(elements(geometry.outline, dividedBy: scale), approvedOutline)
            XCTAssertEqual(elements(geometry.shelves, dividedBy: scale), approvedShelves)
            let referenceFrame = Path(roundedRect: CGRect(x: 14 * scale, y: 8 * scale,
                                                         width: 36 * scale, height: 48 * scale),
                                      cornerSize: CGSize(width: 3 * scale, height: 3 * scale))
            XCTAssertEqual(elements(geometry.frame), elements(referenceFrame))
            XCTAssertEqual(geometry.shelfStrokeWidth / scale, size == .compact ? 3 : 2.3, accuracy: 0.000001)
            XCTAssertEqual(geometry.traceStrokeWidth / scale, 2.8, accuracy: 0.000001)
            // Independently integrate the approved quadratic reference at higher
            // resolution to catch a missing straight segment or corner.
            XCTAssertEqual(geometry.length / scale, approvedLength(), accuracy: 0.0001)
        }
        XCTAssertEqual(WiltedLoadingMotifSize.compact.rawValue, 20)
        XCTAssertEqual(WiltedLoadingMotifSize.regular.rawValue, 64)
    }

    func testExactApprovedLinearMotionOpacityAndLeafColors() throws {
        XCTAssertEqual(WiltedLoadingMotifGeometry.cycle, 1.6)
        XCTAssertEqual(WiltedLoadingMotifGeometry.dashFraction, 0.18)
        XCTAssertEqual(WiltedLoadingMotifGeometry.shelfOpacity, 0.58)
        XCTAssertEqual(WiltedLoadingMotifGeometry.traceOpacity, 0.98)
        for time in sampleTimes {
            XCTAssertEqual(WiltedLoadingMotifGeometry.phase(at: time),
                           CGFloat(time == 1.6 ? 0 : time / 1.6), accuracy: 0.000001)
        }
        XCTAssertEqual(WiltedLoadingMotifGeometry.phase(at: -1), 0)
        XCTAssertEqual(WiltedLoadingMotifGeometry.phase(at: .nan), 0)
        for (scheme, expected) in [(ColorScheme.light, [77.0,107,34]), (.dark, [127.0,212,140])] {
            let color = try XCTUnwrap(NSColor(WiltedLoadingMotifGeometry.ink(scheme)).usingColorSpace(.sRGB))
            for (actual, channel) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
                XCTAssertEqual(actual * 255, CGFloat(channel), accuracy: 0.001)
            }
        }
    }

    func testNativeSampledFramesAndStrictReducedMotionSettledEquality() throws {
        for size in WiltedLoadingMotifSize.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let zero = try render(size: size, scheme: scheme, elapsed: 0, reduced: false, retainEvidence: true)
                for time in sampleTimes {
                    let frame = try render(size: size, scheme: scheme, elapsed: time, reduced: false,
                                           retainEvidence: time == 0.8)
                    if time == 0 || time == 1.6 {
                        assertChannels(frame, equalTo: zero, tolerance: 2)
                    } else {
                        XCTAssertNotEqual(rgba(frame), rgba(zero), "dash travels at \(time), \(size), \(scheme)")
                    }
                    let reduced = try render(size: size, scheme: scheme, elapsed: time, reduced: true,
                                             retainEvidence: time == 0)
                    assertChannels(reduced, equalTo: zero, tolerance: 2)
                }
            }
        }
    }

    func testShelfIntersectionsUseGroupOpacityBeforeTrace() throws {
        // Away from the phase-zero trace, the center shelf intersection must
        // carry one .58 layer, rather than two independently translucent strokes.
        for scheme in [ColorScheme.light, .dark] {
            let bitmap = try render(size: .regular, scheme: scheme, elapsed: 0, reduced: true)
            let intersection = try XCTUnwrap(bitmap.colorAt(x: 32 * 3, y: 27 * 3)?.usingColorSpace(.sRGB))
            let shelf = try XCTUnwrap(bitmap.colorAt(x: 32 * 3, y: 35 * 3)?.usingColorSpace(.sRGB))
            for (first, second) in zip([intersection.redComponent, intersection.greenComponent, intersection.blueComponent],
                                       [shelf.redComponent, shelf.greenComponent, shelf.blueComponent]) {
                XCTAssertEqual(first * 255, second * 255, accuracy: 2)
            }
        }
    }

    func testExistingCompactCallersUseNative20AndNoProgressArtwork() throws {
        let compactPlayer = try WiltedMacHeadless.viewSource("WiltedMacPlayerContent+Sections.swift")
        let review = try WiltedMacHeadless.viewSource("WiltedMacEpisodeIdentityReview.swift")
        XCTAssertTrue(compactPlayer.contains("WiltedLoadingMotif(size: .compact)"))
        XCTAssertFalse(compactPlayer.contains(".scaleEffect(0.24)"))
        XCTAssertTrue(review.contains("WiltedLoadingMotif(size: .compact)"))
        XCTAssertFalse(review.contains(".scaleEffect(0.28)"))
    }

    private func elements(_ path: Path, dividedBy scale: CGFloat = 1) -> [[CGFloat]] {
        var result: [[CGFloat]] = []
        path.forEach { element in
            switch element {
            case let .move(to: p): result.append([0,p.x / scale,p.y / scale])
            case let .line(to: p): result.append([1,p.x / scale,p.y / scale])
            case let .quadCurve(to: p, control: c): result.append([2,c.x / scale,c.y / scale,p.x / scale,p.y / scale])
            case .closeSubpath: result.append([3])
            case let .curve(to: p, control1: c1, control2: c2):
                result.append([4,c1.x / scale,c1.y / scale,c2.x / scale,c2.y / scale,p.x / scale,p.y / scale])
            }
        }
        return result
    }

    private func approvedLength() -> CGFloat {
        var length: CGFloat = 0
        var current = CGPoint.zero
        var first = CGPoint.zero
        for command in approvedOutline {
            switch command[0] {
            case 0:
                current = CGPoint(x: command[1], y: command[2]); first = current
            case 1:
                let end = CGPoint(x: command[1], y: command[2])
                length += hypot(end.x - current.x, end.y - current.y); current = end
            case 2:
                let control = CGPoint(x: command[1], y: command[2])
                let end = CGPoint(x: command[3], y: command[4])
                let start = current
                for sample in 1...4096 {
                    let t = CGFloat(sample) / 4096, u = 1 - t
                    let next = CGPoint(x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
                                       y: u*u*start.y + 2*u*t*control.y + t*t*end.y)
                    length += hypot(next.x - current.x, next.y - current.y); current = next
                }
            default:
                length += hypot(first.x - current.x, first.y - current.y); current = first
            }
        }
        return length
    }

    /// Native RGBA comparison domain: exactly20×20 at8× or64×64 at3×,
    /// opaque app surface, sRGB. Package contact strips are visual references;
    /// these tests do not claim native-vs-browser whole-image PNG equality.
    private func render(size: WiltedLoadingMotifSize, scheme: ColorScheme,
                        elapsed: Double, reduced: Bool, retainEvidence: Bool = false) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: WiltedLoadingMotifMark(
            size: size, elapsed: elapsed, reduceMotion: reduced, scheme: scheme)
            .background(WiltedLoadingMotifGeometry.surface(scheme)))
        renderer.scale = size == .compact ? 8 : 3
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(bitmap.pixelsWide, Int(size.rawValue * renderer.scale))
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.rawValue * renderer.scale))
        if retainEvidence {
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                           uniformTypeIdentifier: "public.png")
            attachment.name = "serpentine-\(Int(size.rawValue))-\(scheme)-\(elapsed)-reduced-\(reduced)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        return bitmap
    }

    private func rgba(_ bitmap: NSBitmapImageRep) -> [UInt8] {
        var channels: [UInt8] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                channels += [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                    .map { UInt8(clamping: Int(($0 * 255).rounded())) }
            }
        }
        return channels
    }

    private func assertChannels(_ actual: NSBitmapImageRep, equalTo expected: NSBitmapImageRep, tolerance: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.pixelsWide, expected.pixelsWide, file: file, line: line)
        XCTAssertEqual(actual.pixelsHigh, expected.pixelsHigh, file: file, line: line)
        let first = rgba(actual), second = rgba(expected)
        XCTAssertEqual(first.count, actual.pixelsWide * actual.pixelsHigh * 4, file: file, line: line)
        XCTAssertEqual(first.count, second.count, file: file, line: line)
        let maximum = zip(first, second).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximum, tolerance, "native settled/frame0 RGBA maximum channel delta", file: file, line: line)
    }
}
