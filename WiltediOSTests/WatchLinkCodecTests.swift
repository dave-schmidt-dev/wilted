import XCTest
@testable import WiltediOS

/// Round-trip and rejection coverage for the watch link payloads: the phone
/// publishes `WatchSnapshot` in its application context and answers `WatchCommand`s.
final class WatchLinkCodecTests: XCTestCase {
    private let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeNowPlaying() -> NowPlaying {
        NowPlaying(
            episodeID: "ep-1",
            title: "Episode One",
            showTitle: "Wilted Weekly",
            positionSeconds: 12.5,
            durationSeconds: 1_800,
            isPlaying: true
        )
    }

    private func makeSnapshot(
        version: Int = WatchSnapshot.currentVersion,
        nowPlaying: NowPlaying? = nil,
        upNext: [UpNextRow] = [],
        sleep: SleepState = .untilDate(Date(timeIntervalSince1970: 1_700_000_500))
    ) -> WatchSnapshot {
        WatchSnapshot(
            version: version,
            nowPlaying: nowPlaying,
            upNext: upNext,
            rate: 1.5,
            sleep: sleep,
            publishedAt: publishedAt
        )
    }

    private func makeRows(_ count: Int) -> [UpNextRow] {
        (0..<count).map {
            UpNextRow(episodeID: "ep-\($0)", title: "Episode \($0)", showTitle: "Show", durationSeconds: Double($0))
        }
    }

    func testSnapshotRoundTripPreservesEveryField() throws {
        let snapshot = makeSnapshot(nowPlaying: makeNowPlaying(), upNext: makeRows(3))
        let context = try WatchLinkCodec.encode(snapshot)
        XCTAssertEqual(Set(context.keys), Set([WatchLinkCodec.snapshotKey]))
        XCTAssertTrue(context[WatchLinkCodec.snapshotKey] is Data)
        XCTAssertEqual(try WatchLinkCodec.decodeSnapshot(context), snapshot)
    }

    func testCommandRoundTripForEveryAction() throws {
        let actions: [WatchCommand.Action] = [
            .playRow(episodeID: "ep-1"),
            .toggle,
            .skipForward,
            .skipBack,
            .setRate(1.25),
            .startSleep(minutes: 15),
            .startSleepEndOfEpisode,
            .cancelSleep,
        ]
        for action in actions {
            let command = WatchCommand(action: action)
            let message = try WatchLinkCodec.encode(command)
            XCTAssertEqual(Set(message.keys), Set([WatchLinkCodec.commandKey]))
            XCTAssertEqual(try WatchLinkCodec.decodeCommand(message), command, "\(action)")
        }
    }

    func testSleepStateRoundTripForEveryCase() throws {
        let cases: [SleepState] = [.off, .endOfEpisode, .untilDate(Date(timeIntervalSince1970: 1_700_000_900))]
        for sleep in cases {
            let snapshot = makeSnapshot(sleep: sleep)
            let context = try WatchLinkCodec.encode(snapshot)
            XCTAssertEqual(try WatchLinkCodec.decodeSnapshot(context).sleep, sleep)
        }
    }

    func testUnknownSnapshotVersionIsRejected() throws {
        let future = makeSnapshot(version: WatchSnapshot.currentVersion + 1, nowPlaying: makeNowPlaying())
        let context = try WatchLinkCodec.encode(future)
        XCTAssertThrowsError(try WatchLinkCodec.decodeSnapshot(context)) {
            XCTAssertEqual($0 as? WatchLinkError, .unsupportedVersion(WatchSnapshot.currentVersion + 1))
        }
    }

    func testUnknownCommandVersionIsRejected() throws {
        let future = WatchCommand(version: WatchCommand.currentVersion + 1, action: .toggle)
        let message = try WatchLinkCodec.encode(future)
        XCTAssertThrowsError(try WatchLinkCodec.decodeCommand(message)) {
            XCTAssertEqual($0 as? WatchLinkError, .unsupportedVersion(WatchCommand.currentVersion + 1))
        }
    }

    func testOversizePayloadIsRejectedBeforeDecoding() {
        let oversize = Data(repeating: 0x7B, count: WatchLinkCodec.maximumPayloadBytes + 1)
        XCTAssertThrowsError(try WatchLinkCodec.decodeSnapshot([WatchLinkCodec.snapshotKey: oversize])) {
            XCTAssertEqual($0 as? WatchLinkError, .payloadTooLarge(oversize.count))
        }
        XCTAssertThrowsError(try WatchLinkCodec.decodeCommand([WatchLinkCodec.commandKey: oversize])) {
            XCTAssertEqual($0 as? WatchLinkError, .payloadTooLarge(oversize.count))
        }
    }

    func testOversizeEncodingIsRejected() {
        let snapshot = makeSnapshot(
            nowPlaying: NowPlaying(
                episodeID: "ep-1",
                title: String(repeating: "t", count: WatchLinkCodec.maximumPayloadBytes),
                showTitle: "Show",
                positionSeconds: 0,
                durationSeconds: nil,
                isPlaying: false
            )
        )
        XCTAssertThrowsError(try WatchLinkCodec.encode(snapshot)) {
            guard case .payloadTooLarge = $0 as? WatchLinkError else { return XCTFail("\($0)") }
        }
    }

    func testMissingKeyAndWrongTypeAreRejected() {
        XCTAssertThrowsError(try WatchLinkCodec.decodeSnapshot([:])) {
            XCTAssertEqual($0 as? WatchLinkError, .missingKey(WatchLinkCodec.snapshotKey))
        }
        XCTAssertThrowsError(try WatchLinkCodec.decodeCommand([:])) {
            XCTAssertEqual($0 as? WatchLinkError, .missingKey(WatchLinkCodec.commandKey))
        }
        XCTAssertThrowsError(try WatchLinkCodec.decodeSnapshot([WatchLinkCodec.snapshotKey: "not data"])) {
            XCTAssertEqual($0 as? WatchLinkError, .wrongType(WatchLinkCodec.snapshotKey))
        }
        XCTAssertThrowsError(try WatchLinkCodec.decodeCommand([WatchLinkCodec.commandKey: 1])) {
            XCTAssertEqual($0 as? WatchLinkError, .wrongType(WatchLinkCodec.commandKey))
        }
    }

    func testMalformedJSONIsRejected() {
        let garbage = Data("{not json".utf8)
        XCTAssertThrowsError(try WatchLinkCodec.decodeSnapshot([WatchLinkCodec.snapshotKey: garbage])) {
            XCTAssertEqual($0 as? WatchLinkError, .malformedPayload)
        }
        let wrongShape = Data(#"{"version":1}"#.utf8)
        XCTAssertThrowsError(try WatchLinkCodec.decodeCommand([WatchLinkCodec.commandKey: wrongShape])) {
            XCTAssertEqual($0 as? WatchLinkError, .malformedPayload)
        }
    }

    func testUpNextIsTruncatedToLimit() throws {
        let rows = makeRows(WatchSnapshot.upNextLimit + 10)
        let snapshot = makeSnapshot(nowPlaying: makeNowPlaying(), upNext: rows)
        XCTAssertEqual(snapshot.upNext.count, WatchSnapshot.upNextLimit)
        let context = try WatchLinkCodec.encode(snapshot)
        let decoded = try WatchLinkCodec.decodeSnapshot(context)
        XCTAssertEqual(decoded.upNext.count, WatchSnapshot.upNextLimit)
    }

    func testWireFormatUsesTheDocumentedKeys() throws {
        let context = try WatchLinkCodec.encode(makeSnapshot(nowPlaying: makeNowPlaying()))
        XCTAssertNotNil(context["wiltedWatchSnapshot"])
        let message = try WatchLinkCodec.encode(WatchCommand(action: .toggle))
        XCTAssertNotNil(message["wiltedWatchCommand"])
    }
}
