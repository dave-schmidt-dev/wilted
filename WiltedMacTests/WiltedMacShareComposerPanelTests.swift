import AppKit
import SwiftUI
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacShareComposerPanelTests: XCTestCase {
    func testLoadingPreviewAndErrorRenderThroughTheShippingPanel() throws {
        let states: [(String, String?, String?, (String, String, URL?)?)] = [
            ("loading", "Loading local transcript…", nil, nil),
            ("progress", "Summarizing locally…", nil, nil),
            ("preview", nil, nil, ("Full locally generated summary for review.", "Episode", URL(string: "https://example.test/episode"))),
            ("error", nil, "The local model is unavailable.", nil)
        ]
        for (name, progress, failure, preview) in states {
            let view = WiltedMacShareComposerPanel(progress: progress, failure: failure,
                preview: preview.map { (text: $0.0, title: $0.1, url: $0.2) }, onRetry: {}, onCancel: {},
                payload: { value in value.url.map { "\(value.text)\n\n\($0.absoluteString)" } ?? value.text })
            let text = try WiltedMacHeadless.recognizedText(view.padding(), size: CGSize(width: 430, height: 360)).joined(separator: " ")
            if let progress {
                XCTAssertTrue(text.contains(progress.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))), "\(name): \(text)")
                XCTAssertTrue(text.contains("close this panel"), "\(name): \(text)")
            }
            if let failure { XCTAssertTrue(text.contains(failure), "\(name): \(text)") }
            if preview != nil { XCTAssertTrue(text.contains("Preview"), "\(name): \(text)") }
        }
    }

    func testFourShippingPanelPNGsAreRetained() throws {
        let states: [(String, String?, String?, (String, String, URL?)?)] = [
            ("loading", "Loading local transcript…", nil, nil), ("progress", "Summarizing locally…", nil, nil),
            ("preview", nil, nil, ("Full locally generated summary for review.", "Episode", nil)),
            ("error", nil, "The local model is unavailable.", nil)
        ]
        let size = CGSize(width: 430, height: 360)
        let page = WiltedTheme.color(.page, scheme: .light)
        for (name, progress, failure, preview) in states {
            let panel = WiltedMacShareComposerPanel(progress: progress, failure: failure,
                preview: preview.map { (text: $0.0, title: $0.1, url: $0.2) }, onRetry: {}, onCancel: {}, payload: { $0.text })
            let capture = ZStack(alignment: .topLeading) { page; panel.padding() }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(page)
                .environment(\.colorScheme, .light)
            let bitmap = try WiltedMacHeadless.render(capture, size: size)
            XCTAssertEqual(bitmap.pixelsWide, Int(size.width), "\(name): capture uses the full canvas width")
            XCTAssertEqual(bitmap.pixelsHigh, Int(size.height), "\(name): capture uses the full canvas height")
            let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThanOrEqual(corner.alphaComponent, 0.99, "\(name): page background covers the full capture")
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                           uniformTypeIdentifier: "public.png")
            attachment.name = "share-summary-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
