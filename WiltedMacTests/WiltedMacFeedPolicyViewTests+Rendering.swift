import SwiftUI
import Vision
import XCTest
@testable import WiltedMac

@MainActor
extension WiltedMacFeedPolicyViewTests {
    /// OCR uses the exact canvas: the shared 24pt margin clips a fixed-width popover's Done control.
    func capture<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) throws -> String {
        let size = CGSize(width: width, height: height)
        var text = ""
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let content = view.environment(\.colorScheme, scheme)
                .frame(width: width, height: height, alignment: .topLeading)
                .background(WiltedTheme.color(.card, scheme: scheme))
            let bitmap = try WiltedMacHeadless.render(content, size: size)
            if !dark {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true; request.recognitionLanguages = ["en-US"]
                request.customWords = ["Larder", "Processing"]; request.minimumTextHeight = 0.001
                try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
                text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                if name.hasPrefix("defaults-") {
                    let image = try XCTUnwrap(bitmap.cgImage)
                    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                    for observation in request.results ?? [] {
                        guard observation.topCandidates(1).first?.string.contains("Set in") == true else { continue }
                        let box = observation.boundingBox
                        let pixels = CGRect(x: box.minX * bounds.width,
                            y: (1 - box.maxY) * bounds.height, width: box.width * bounds.width,
                            height: box.height * bounds.height).insetBy(dx: -4, dy: -4).intersection(bounds).integral
                        let crop = try XCTUnwrap(image.cropping(to: pixels))
                        let line = VNRecognizeTextRequest(); line.recognitionLevel = .accurate
                        line.usesLanguageCorrection = true; line.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: crop).perform([line])
                        text += " " + (line.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    }
                }
            }
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "feed-policy-\(name)-\(dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
        }
        return text
    }

}
