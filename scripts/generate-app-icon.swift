// Renders the Wilted app icon from the shipping `WiltedMarkShape`.
//
// This is compiled against `Shared/WiltedMark.swift` and `Shared/WiltedTheme.swift`
// rather than re-transcribing the master SVG, so the icon and the in-app mark are
// the same geometry by construction. Run via `make app-icon`.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Icon canvases differ by platform: iOS supplies a square bleed and the system
/// applies the mask, while macOS ships its own rounded rectangle.
enum IconStyle {
    case squareBleed
    case roundedRect
}

func renderIcon(pixels: Int, style: IconStyle, background: UInt32, mark: UInt32) -> CGImage? {
    let size = CGFloat(pixels)
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    func cgColor(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    // SwiftUI paths use a top-left origin; CoreGraphics uses bottom-left.
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    context.setFillColor(cgColor(background))
    switch style {
    case .squareBleed:
        context.fill(canvas)
    case .roundedRect:
        // 224/1024 is the master icon's corner radius.
        let radius = size * 224 / WiltedMarkShape.designSize
        context.addPath(CGPath(roundedRect: canvas, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    context.addPath(WiltedMarkShape().path(in: canvas).cgPath)
    context.setStrokeColor(cgColor(mark))
    context.setLineWidth(size * WiltedMarkShape.strokeRatio)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "wilted.icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "wilted.icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot finalize \(url.path)"])
    }
}

struct Target {
    let path: String
    let style: IconStyle
    let sizes: [Int]
}

@main
struct IconGenerator {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            FileHandle.standardError.write("usage: generate-app-icon <repo-root>\n".data(using: .utf8)!)
            exit(2)
        }
        let root = URL(fileURLWithPath: arguments[1])

        // The icon is always the dark treatment: a light-mode icon on a light home
        // screen loses the mark entirely, and the dock example in the brand sheet uses
        // the dark lockup.
        let background = WiltedTheme.darkHex[.page]!
        let mark = WiltedTheme.darkHex[.wiltedLeaf]!

        let targets = [
            Target(path: "WiltediOS/Assets.xcassets/AppIcon.appiconset", style: .squareBleed, sizes: [1024]),
            Target(
                path: "WiltedMac/Assets.xcassets/AppIcon.appiconset",
                style: .roundedRect,
                sizes: [16, 32, 64, 128, 256, 512, 1024]
            )
        ]

        var written = 0
        for target in targets {
            let directory = root.appendingPathComponent(target.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for pixels in target.sizes {
                guard let image = renderIcon(pixels: pixels, style: target.style, background: background, mark: mark) else {
                    FileHandle.standardError.write("failed to render \(pixels)px\n".data(using: .utf8)!)
                    exit(1)
                }
                try write(image, to: directory.appendingPathComponent("icon-\(pixels).png"))
                written += 1
            }
        }
        print("wilted.icon.written count=\(written)")
    }
}
