import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The phone says in words when iCloud is rate limiting it, and every call it makes shares one gate.
@MainActor
final class LibraryThrottleTests: XCTestCase {
    /// The CloudKit adapter's error, as it prints (`TransportPressureClassifier` reads that text).
    private enum FakeCloudKitError: Error {
        case cloudKit(code: Int, message: String)
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 1_000_000
        var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    private let clock = TestClock()

    private func makeModel() -> LibraryAppModel {
        let clock = clock
        return LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: InMemoryLibraryServer(writerDeviceID: "mac")),
            deviceID: "phone", preferences: UserDefaults(suiteName: "library-throttle-tests")!,
            now: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    func testNothingIsSaidWhileICloudAnswers() async throws {
        let model = makeModel()
        await model.refresh()
        XCTAssertNil(model.throttleState)
        XCTAssertNil(model.throttleNotice)
    }

    func testARateLimitReplyPutsTheStatusLineInTheModelAndTheNextSuccessClearsIt() async throws {
        let model = makeModel()
        do {
            try await model.throttleGate.run {
                throw FakeCloudKitError.cloudKit(code: 7, message: "Request was rate limited. Retry after 45 seconds")
            } as Void
        } catch {}
        try await eventually("the notice appears") { model.throttleNotice != nil }
        let notice = try XCTUnwrap(model.throttleNotice)
        XCTAssertTrue(notice.hasPrefix("iCloud is rate limiting sync. Retrying at "), notice)
        XCTAssertEqual(model.throttleState?.kind, .rateLimited)

        // The next refresh is refused locally until the wait passes: nothing is sent, and the status says why.
        await model.refresh()
        XCTAssertTrue(model.errorMessage?.hasPrefix("iCloud sync is paused until ") == true, model.errorMessage ?? "nil")
        XCTAssertNotNil(model.throttleState, "a refused refresh does not clear the notice")

        // Once the server's 45 s wait has passed, the next refresh is the probe; its success clears it.
        clock.advance(46)
        await model.refresh()
        try await eventually("the notice clears") { model.throttleState == nil }
        XCTAssertNil(model.throttleNotice)
        XCTAssertNil(model.errorMessage)
    }

    func testTheWaitGrowsWhileICloudKeepsRefusing() async throws {
        let model = makeModel()
        for _ in 0..<2 {
            clock.advance(400)
            do {
                try await model.throttleGate.run {
                    throw FakeCloudKitError.cloudKit(code: 7, message: "Request was rate limited")
                } as Void
            } catch {}
        }
        try await eventually("second reply recorded") { model.throttleState?.consecutiveFailures == 2 }
        XCTAssertEqual(model.throttleState?.retryAt, clock.now.addingTimeInterval(2 * SyncCadence.backoffBase))
    }

    func testEveryModelCallGoesThroughTheOneGate() async throws {
        let model = makeModel()
        do {
            try await model.throttleGate.run {
                throw FakeCloudKitError.cloudKit(code: 6, message: "Service unavailable")
            } as Void
        } catch {}
        do {
            _ = try await model.transport.fetchDeviceRecords()
            XCTFail("a closed gate refuses the handoff fetch too")
        } catch {
            XCTAssertTrue(error is TransportThrottled)
        }
        do {
            _ = try await model.transport.mediaOffers()
            XCTFail("and the media offers")
        } catch {
            XCTAssertTrue(error is TransportThrottled)
        }
    }

    func testTheObserveCadenceIsThirtySeconds() {
        XCTAssertEqual(LibraryHandoffTiming().observeInterval, 30)
        XCTAssertEqual(LibraryHandoffTiming().observeInterval, SyncCadence.phoneObserveInterval)
    }
}
