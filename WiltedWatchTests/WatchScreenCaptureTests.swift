import CoreGraphics
import ImageIO
import SwiftUI
import WatchKit
import XCTest
@testable import WiltedWatch

/// Fixture-only captures of the shipping Watch views, without a phone session.
@MainActor
final class WatchScreenCaptureTests: XCTestCase {
    func testNowPlayingCapture() async throws {
        try await withPendingFixture(.toggle) { model in
            try capture("now-playing", NowPlayingView(model: model).captureContent)
        }
    }
    func testUpNextCapture() async throws {
        try await withPendingFixture(.playRow(episodeID: "fixture-next")) { model in
            XCTAssertTrue(model.canSend(.playRow(episodeID: "fixture-later")))
            try capture("up-next", UpNextView(model: model).captureContent)
        }
    }
    func testSpeedCapture() async throws {
        try await withPendingFixture(.setRate(1.5)) { model in
            XCTAssertTrue(model.canSend(.setRate(1.75)))
            try capture("speed", SpeedListView(model: model).captureContent, fullContent: true)
        }
    }
    func testSleepCapture() async throws {
        try await withPendingFixture(.startSleep(minutes: 20)) { model in
            XCTAssertTrue(model.canSend(.cancelSleep))
            try capture("sleep", SleepListView(model: model).captureContent, fullContent: true)
        }
    }

    private func withPendingFixture(_ action: WatchCommand.Action, render: (WatchViewModel) throws -> Void) async throws {
        let reference = Date(), deadline = reference.addingTimeInterval(600)
        var sent: [WatchCommand] = []
        let model = WatchViewModel(now: { Date() }, commandSender: { sent.append($0) },
            pendingSleep: { seconds in
                XCTAssertEqual(seconds, 3)
                // Hold feedback through rendering; this injected sleep is cancelled below.
                try await Task.sleep(for: .seconds(3600))
            })
        let snapshot = WatchSnapshot(
            nowPlaying: NowPlaying(episodeID: "fixture-current", title: "A quieter morning",
                                   showTitle: "Garden Radio", positionSeconds: 245,
                                   durationSeconds: 1_800, isPlaying: true),
            upNext: [UpNextRow(episodeID: "fixture-next", title: "The autumn garden", showTitle: "Garden Radio"),
                     UpNextRow(episodeID: "fixture-later", title: "A walk by the river", showTitle: "Outside")],
            rate: 1.25, sleep: .untilDate(deadline), skipBackSeconds: 10, skipForwardSeconds: 45, publishedAt: reference
        )
        let context = try WatchLinkCodec.encode(snapshot)
        model.receive(context: context)
        model.isPhoneReachable = true
        XCTAssertTrue(model.send(action))
        XCTAssertTrue(model.isPending(action))
        XCTAssertFalse(model.canSend(action))
        XCTAssertEqual(sent.map(\.action), [action])
        print("watch.fixture reference=\(reference.timeIntervalSince1970) sleep_deadline=\(deadline.timeIntervalSince1970) pending=\(action)")
        var failure: Error?
        do { try render(model) } catch { failure = error }
        let expiries = Array(model.pendingExpiryTasks.values)
        model.receive(context: context)
        model.commandSender = nil
        for expiry in expiries { await expiry.value }
        XCTAssertTrue(model.pendingControls.isEmpty)
        if let failure { throw failure }
    }

    private func capture<Content: View>(_ name: String, _ view: Content, fullContent: Bool = false) throws {
        let device = WKInterfaceDevice.current()
        let bounds = device.screenBounds
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        let height: CGFloat? = fullContent ? nil : bounds.height
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, .dark)
            .fixedSize(horizontal: false, vertical: fullContent)
            .frame(width: bounds.width, height: height, alignment: .top)
            .clipped()
            .background(.black))
        renderer.proposedSize = ProposedViewSize(width: bounds.width, height: height)
        renderer.scale = device.screenScale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer must render the actual Watch screen")
        XCTAssertEqual(image.width, Int(bounds.width * device.screenScale))
        if fullContent {
            XCTAssertGreaterThan(image.height, Int(bounds.height * device.screenScale), "All option rows must fit at intrinsic height")
        } else {
            XCTAssertEqual(image.height, Int(bounds.height * device.screenScale))
        }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let textPixels = try pixels.withUnsafeMutableBytes { buffer -> Int in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 0, to: buffer.count, by: 4).filter { offset in
                let red = Int(buffer[offset]), green = Int(buffer[offset + 1]), blue = Int(buffer[offset + 2])
                return red > 100 && abs(red - green) < 12 && abs(red - blue) < 12
            }.count
        }
        XCTAssertGreaterThan(textPixels, 0, "Shipping labels must render; black/unsupported-container images must fail")
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertGreaterThan(data.length, 1_000, "A blank capture must fail")
        let attachment = XCTAttachment(data: data as Data, uniformTypeIdentifier: "public.png")
        attachment.name = "watch-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("watch.capture name=\(name) viewport_points=\(bounds.width)x\(bounds.height) scale=\(device.screenScale) pixels=\(image.width)x\(image.height) full_content=\(fullContent)")
    }
}
