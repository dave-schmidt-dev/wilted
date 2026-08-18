import Darwin
import Foundation
import XCTest
@testable import WiltedProducer

final class SpeechIPCTests: XCTestCase {
    func testFragmentedResultIsReassembled() throws {
        let server = try FakeServer { fd in
            let request = try TestWire.readFrame(fd)
            XCTAssertEqual(request.type, .request)
            let response = try FrameCodec.control(.result, object: ["result": ["value": SpeechIPCClient.selftestEchoValue]])
            try TestWire.write(fd, response, fragmentSize: 1)
        }
        let result = try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).selftest()
        XCTAssertEqual(result["value"] as? String, SpeechIPCClient.selftestEchoValue)
        try server.finish()
    }

    func testSelftestRejectsMissingEchoRoundTrip() throws {
        let server = try FakeServer { fd in
            _ = try TestWire.readFrame(fd)
            try TestWire.write(fd, FrameCodec.control(.result, object: ["result": [:]]))
        }
        XCTAssertThrowsError(try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).selftest()) {
            XCTAssertEqual($0 as? SpeechIPCError, .invalidControlJSON)
        }
        try server.finish()
    }

    func testOversizedFrameIsRejectedFromHeaderOnly() throws {
        let server = try FakeServer { fd in
            _ = try TestWire.readFrame(fd)
            var length = UInt32(FrameCodec.maximumFrameBytes + 1).bigEndian
            let header = withUnsafeBytes(of: &length) { Data($0) }
            try TestWire.write(fd, header)
        }
        XCTAssertThrowsError(try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).statusSnapshot()) {
            XCTAssertEqual($0 as? SpeechIPCError, .frameTooLarge(FrameCodec.maximumFrameBytes + 1))
        }
        try server.finish()
    }

    func testProtocolMismatchParsesTypedError() throws {
        let server = try FakeServer { fd in
            let request = try FrameCodec.decodeControl(TestWire.readFrame(fd).payload)
            XCTAssertEqual(request["protocol_version"] as? Int, 1)
            let error = try FrameCodec.control(.error, object: [
                "error_class": "ProtocolMismatch",
                "message": "client 1, daemon 2",
                "client_version": 1,
                "daemon_version": 2,
            ])
            try TestWire.write(fd, error)
        }
        let error = try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).protocolMismatch()
        XCTAssertEqual(error.errorClass, "ProtocolMismatch")
        XCTAssertEqual(error.clientVersion, 1)
        XCTAssertEqual(error.daemonVersion, 2)
        try server.finish()
    }

    func testSelftestRequestShape() throws {
        let server = try FakeServer { fd in
            let object = try FrameCodec.decodeControl(TestWire.readFrame(fd).payload)
            XCTAssertEqual(object["protocol_version"] as? Int, 2)
            XCTAssertNotNil(object["request_id"] as? String)
            XCTAssertEqual(object["kind"] as? String, "selftest")
            XCTAssertEqual((object["params"] as? [String: Any])?["action"] as? String, "echo")
            XCTAssertEqual((object["params"] as? [String: Any])?["value"] as? String, SpeechIPCClient.selftestEchoValue)
            XCTAssertEqual(object["lane"] as? String, "interactive")
            XCTAssertNotNil(object["timeout"] as? Double)
            try TestWire.write(fd, FrameCodec.control(.result, object: ["result": ["value": SpeechIPCClient.selftestEchoValue]]))
        }
        _ = try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).selftest()
        try server.finish()
    }

    func testStatusRequestShape() throws {
        let server = try FakeServer { fd in
            let object = try FrameCodec.decodeControl(TestWire.readFrame(fd).payload)
            XCTAssertEqual(object["kind"] as? String, "status")
            XCTAssertEqual((object["params"] as? [String: Any])?.count, 0)
            try TestWire.write(fd, FrameCodec.control(.result, object: ["result": ["ready": true]]))
        }
        let result = try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).statusSnapshot()
        XCTAssertEqual(result["ready"] as? Bool, true)
        try server.finish()
    }

    func testTTSCancelClosesAfterFirstNonemptyAudio() throws {
        let observedEOF = Locked(false)
        let server = try FakeServer { fd in
            let object = try FrameCodec.decodeControl(TestWire.readFrame(fd).payload)
            XCTAssertEqual(object["kind"] as? String, "tts_stream")
            XCTAssertEqual((object["params"] as? [String: Any])?["text"] as? String, "short text")
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: Data())))
            let samples = TestWire.float32LE([1.0, -0.5])
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: samples)), fragmentSize: 2)
            observedEOF.value = try TestWire.waitForEOF(fd)
        }
        let result = try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).cancelTTSAfterFirstAudio(text: "short text")
        XCTAssertEqual(result.receivedAudioBytes, 8)
        XCTAssertEqual(result.decodedSampleCount, 2)
        XCTAssertEqual(result.peakAbsoluteAmplitude, 1.0)
        XCTAssertTrue(result.socketClosed)
        try server.finish()
        XCTAssertTrue(observedEOF.value)
    }

    func testTTSCancelRejectsMisalignedFloat32Audio() throws {
        let server = try FakeServer { fd in
            _ = try TestWire.readFrame(fd)
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: Data([0, 1, 2]))))
        }
        XCTAssertThrowsError(try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).cancelTTSAfterFirstAudio(text: "short text")) {
            XCTAssertEqual($0 as? SpeechIPCError, .invalidAudioByteCount(3))
        }
        try server.finish()
    }

    func testTTSCancelRejectsNonFiniteFloat32Audio() throws {
        let server = try FakeServer { fd in
            _ = try TestWire.readFrame(fd)
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: TestWire.float32LE([.infinity]))))
        }
        XCTAssertThrowsError(try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).cancelTTSAfterFirstAudio(text: "short text")) {
            XCTAssertEqual($0 as? SpeechIPCError, .nonFiniteAudioSample(0))
        }
        try server.finish()
    }

    func testSocketPathLimit() throws {
        let maximum = SocketPath.maximumUTF8Bytes
        XCTAssertNoThrow(try SocketPath.validate(String(repeating: "a", count: maximum)))
        XCTAssertThrowsError(try SocketPath.validate(String(repeating: "a", count: maximum + 1)))
    }

    func testReadTimeoutIsBoundedAndEmitsWaitStatus() throws {
        let server = try FakeServer { fd in
            _ = try TestWire.readFrame(fd)
            usleep(250_000)
        }
        let statuses = Locked<[String]>([])
        let client = SpeechIPCClient(socketPath: server.path, operationTimeout: 0.05) { statuses.value.append($0) }
        let start = Date()
        XCTAssertThrowsError(try client.statusSnapshot()) {
            XCTAssertEqual($0 as? SpeechIPCError, .timeout("read"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(statuses.value.contains("read.wait"))
        try server.finish()
    }

    func testIncrementalDecoderRejectsOversizeBeforeBufferingBody() throws {
        var decoder = FrameDecoder()
        var length = UInt32(FrameCodec.maximumFrameBytes + 1).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        XCTAssertThrowsError(try decoder.feed(header))
        XCTAssertEqual(decoder.bufferedByteCount, 4)
    }

    func testCompleteTTSStreamAccumulatesValidatedAudioUntilEnd() throws {
        let server = try FakeServer { fd in
            let request = try FrameCodec.decodeControl(TestWire.readFrame(fd).payload)
            XCTAssertEqual(request["kind"] as? String, "tts_stream")
            try TestWire.write(fd, FrameCodec.control(.status, object: ["stage": "synthesizing"]))
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: TestWire.float32LE([0.25, -0.5]))), fragmentSize: 2)
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: TestWire.float32LE([1.0]))))
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .end, payload: Data())))
        }
        let result = try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).synthesize(text: "fixture article")
        XCTAssertEqual(result.samples, [0.25, -0.5, 1.0])
        try server.finish()
    }

    func testStreamWithoutAReportedRateUsesTheContractedDaemonRate() throws {
        let server = try FakeServer { fd in
            _ = try TestWire.readFrame(fd)
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: TestWire.float32LE([0.25]))))
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .end, payload: Data())))
        }
        // The broker's client-facing stream terminal is `{"cancelled": false}`, so the
        // wire reports no rate at all today and the contracted 24 kHz has to stand in.
        let result = try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).synthesize(text: "fixture")
        XCTAssertEqual(result.sampleRate, 24_000)
        XCTAssertEqual(SpeechIPCClient.streamSampleRate, 24_000)
        try server.finish()
    }

    func testStreamPrefersARateReportedOnTheWire() throws {
        let server = try FakeServer { fd in
            _ = try TestWire.readFrame(fd)
            try TestWire.write(fd, FrameCodec.control(.audioMeta, object: ["sample_rate": 16_000, "channels": 1]))
            try TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: TestWire.float32LE([0.25]))))
            try TestWire.write(fd, FrameCodec.control(.result, object: ["result": ["cancelled": false, "sample_rate": 22_050]]))
        }
        let result = try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).synthesize(text: "fixture")
        XCTAssertEqual(result.sampleRate, 22_050)
        try server.finish()
    }

    /// Regression: the read timeout is a per-frame gap budget, and the coordinator used
    /// to hardcode 4 s for it. A daemon that pauses longer than that between segments —
    /// Kokoro cold init, a contended GPU lock, one slow segment — failed the whole
    /// preparation with "read timed out" even though the stream was healthy.
    func testSlowFirstFrameFailsUnderATightBudgetAndSucceedsUnderAGenerousOne() throws {
        func serverWithDelayedFirstFrame() throws -> FakeServer {
            try FakeServer { fd in
                // The tight-budget client hangs up mid-delay. Without SO_NOSIGPIPE the
                // late write would take the whole test process down with SIGPIPE, and
                // the writes are `try?` so that hang-up is an expected outcome here.
                var enabled: Int32 = 1
                _ = Darwin.setsockopt(
                    fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)
                )
                _ = try TestWire.readFrame(fd)
                Thread.sleep(forTimeInterval: 0.6)
                try? TestWire.write(fd, FrameCodec.encode(Frame(type: .audio, payload: TestWire.float32LE([0.25]))))
                try? TestWire.write(fd, FrameCodec.encode(Frame(type: .end, payload: Data())))
            }
        }

        let tight = try serverWithDelayedFirstFrame()
        XCTAssertThrowsError(try SpeechIPCClient(socketPath: tight.path, operationTimeout: 0.2).synthesize(text: "fixture")) {
            XCTAssertEqual($0 as? SpeechIPCError, .timeout("read"))
        }
        try tight.finish()

        let generous = try serverWithDelayedFirstFrame()
        let result = try SpeechIPCClient(socketPath: generous.path, operationTimeout: 3).synthesize(text: "fixture")
        XCTAssertEqual(result.samples, [0.25])
        try generous.finish()
    }

    func testPreparationDoesNotShipTheHardcodedFourSecondSpeechBudget() {
        // Kokoro cold init alone is ~1.5 s before a contended GPU lock or a long segment.
        XCTAssertGreaterThanOrEqual(PreparationCoordinator.defaultSpeechOperationTimeout, 60)
    }

    func testCompleteTTSStreamCancellationClosesBeforeReading() throws {
        let observedEOF = Locked(false)
        let server = try FakeServer { fd in
            _ = try TestWire.readFrame(fd)
            observedEOF.value = try TestWire.waitForEOF(fd)
        }
        XCTAssertThrowsError(try SpeechIPCClient(socketPath: server.path, operationTimeout: 1).synthesize(text: "fixture", isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        try server.finish()
        XCTAssertTrue(observedEOF.value)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class FakeServer: @unchecked Sendable {
    let path: String
    private let listenFD: Int32
    private let done = DispatchSemaphore(value: 0)
    private let failure = Locked<Error?>(nil)

    init(handler: @escaping @Sendable (Int32) throws -> Void) throws {
        path = "/tmp/sipc-\(UUID().uuidString).sock"
        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        let length = offset + bytes.count + 1
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: bytes)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(length))
            }
        }
        guard bindResult == 0, Darwin.listen(listenFD, 1) == 0 else {
            Darwin.close(listenFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        DispatchQueue(label: "speech-ipc-fake-server").async { [self] in
            defer { done.signal() }
            do {
                try TestWire.wait(listenFD, events: Int16(POLLIN), milliseconds: 2_000)
                let fd = Darwin.accept(listenFD, nil, nil)
                guard fd >= 0 else { throw POSIXError(.ECONNABORTED) }
                defer { Darwin.close(fd) }
                try handler(fd)
            } catch {
                failure.value = error
            }
        }
    }

    deinit {
        Darwin.close(listenFD)
        Darwin.unlink(path)
    }

    func finish() throws {
        guard done.wait(timeout: .now() + 3) == .success else { throw SpeechIPCError.timeout("fake server") }
        if let failure = failure.value { throw failure }
    }
}

private enum TestWire {
    static func float32LE(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 4)
        for sample in samples {
            let bits = sample.bitPattern
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
            data.append(UInt8(truncatingIfNeeded: bits >> 16))
            data.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        return data
    }

    static func readFrame(_ fd: Int32) throws -> Frame {
        let header = try readExactly(fd, count: 4)
        let length = Int(header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length >= 1, length <= FrameCodec.maximumFrameBytes else { throw SpeechIPCError.frameTooLarge(length) }
        let body = try readExactly(fd, count: length)
        guard let type = FrameType(rawValue: body[body.startIndex]) else { throw SpeechIPCError.unknownFrameType(body[body.startIndex]) }
        return Frame(type: type, payload: body.dropFirst())
    }

    static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { raw in
            while received < count {
                try wait(fd, events: Int16(POLLIN), milliseconds: 2_000)
                let amount = Darwin.read(fd, raw.baseAddress!.advanced(by: received), count - received)
                guard amount > 0 else { throw SpeechIPCError.connectionClosed(expected: count, received: received) }
                received += amount
            }
        }
        return data
    }

    static func write(_ fd: Int32, _ data: Data, fragmentSize: Int = .max) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < raw.count {
                try wait(fd, events: Int16(POLLOUT), milliseconds: 2_000)
                let requested = min(fragmentSize, raw.count - offset)
                let amount = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), requested)
                guard amount > 0 else { throw POSIXError(.EIO) }
                offset += amount
            }
        }
    }

    static func waitForEOF(_ fd: Int32) throws -> Bool {
        try wait(fd, events: Int16(POLLIN), milliseconds: 2_000)
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) == 0
    }

    static func wait(_ fd: Int32, events: Int16, milliseconds: Int32) throws {
        var item = pollfd(fd: fd, events: events, revents: 0)
        guard Darwin.poll(&item, 1, milliseconds) > 0 else { throw SpeechIPCError.timeout("test wire") }
    }
}
