import SwiftUI
import UIKit
import Vision
import XCTest
@testable import WiltediOS

/// Native rendering and text bounds of synthetic shipping content, not a copied UI.
@MainActor
struct PhoneLayoutCapture {
    let image: UIImage
    private let lines: [VNRecognizedTextObservation]
    var text: [String] { lines.compactMap { $0.topCandidates(1).first?.string } }

    init<Content: View>(_ content: Content, width: CGFloat, scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: content.padding(16).frame(width: width).clipped()
            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: scheme))
            .background(WiltedTheme.color(.page, scheme: scheme))
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en_US")))
        renderer.scale = 2
        image = try XCTUnwrap(renderer.uiImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
        lines = request.results ?? []
        XCTAssertEqual(image.size.width, width, accuracy: 0.1)
    }

    /// The recognized tokens regrouped into painted lines, top to bottom. Vision may split one painted line,
    /// such as a date standing alone, into several observations, so tokens whose vertical centres agree
    /// are joined left to right.
    var paintedLines: [(text: String, box: CGRect)] {
        let tokens = lines.compactMap { observation in
            observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox) }
        }.sorted { $0.box.midY > $1.box.midY }
        var groups: [[(text: String, box: CGRect)]] = []
        for token in tokens {
            if let first = groups.last?.first, abs(first.box.midY - token.box.midY) < token.box.height / 2 {
                groups[groups.count - 1].append(token)
            } else {
                groups.append([token])
            }
        }
        return groups.map { group in
            let ordered = group.sorted { $0.box.minX < $1.box.minX }
            return (ordered.map(\.text).joined(separator: " "), ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) })
        }
    }

    /// The painted line holding `value` whole (ignoring case, spaces and punctuation), if any.
    func paintedLine(containing value: String) -> (text: String, box: CGRect)? {
        func compact(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return paintedLines.first { compact($0.text).contains(compact(value)) }
    }

    func line(containing value: String) -> CGRect? {
        func compact(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return lines.first { observation in
            observation.topCandidates(1).first.map { compact($0.string).contains(compact(value)) } ?? false
        }?.boundingBox
    }
}
