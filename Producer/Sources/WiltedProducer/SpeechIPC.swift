import Foundation

public enum FrameType: UInt8, Sendable {
    case request = 1
    case result = 2
    case error = 3
    case audioMeta = 4
    case audio = 5
    case end = 6
    case status = 7
}

public struct Frame: Equatable, Sendable {
    public let type: FrameType
    public let payload: Data

    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

public enum SpeechIPCError: Error, Equatable, CustomStringConvertible {
    case invalidSocketPath(String)
    case frameTooSmall(Int)
    case frameTooLarge(Int)
    case unknownFrameType(UInt8)
    case invalidControlJSON
    case connectionClosed(expected: Int, received: Int)
    case timeout(String)
    case systemCall(operation: String, code: Int32)
    case unexpectedFrame(FrameType)
    case invalidAudioByteCount(Int)
    case nonFiniteAudioSample(Int)
    case daemon(DaemonError)

    public var description: String {
        switch self {
        case .invalidSocketPath(let reason): return "invalid socket path: \(reason)"
        case .frameTooSmall(let length): return "frame length \(length) is below the 1-byte minimum"
        case .frameTooLarge(let length): return "frame length \(length) exceeds \(FrameCodec.maximumFrameBytes)"
        case .unknownFrameType(let type): return "unknown frame type \(type)"
        case .invalidControlJSON: return "control frame payload must be a UTF-8 JSON object"
        case .connectionClosed(let expected, let received): return "connection closed after \(received) of \(expected) bytes"
        case .timeout(let operation): return "\(operation) timed out"
        case .systemCall(let operation, let code): return "\(operation) failed with errno \(code)"
        case .unexpectedFrame(let type): return "unexpected frame \(type)"
        case .invalidAudioByteCount(let count): return "AUDIO payload byte count \(count) is not divisible by 4"
        case .nonFiniteAudioSample(let index): return "AUDIO payload sample \(index) is not finite"
        case .daemon(let error): return "\(error.errorClass): \(error.message)"
        }
    }
}

public struct Float32LEAudioSummary: Equatable, Sendable {
    public let sampleCount: Int
    public let peakAbsoluteAmplitude: Float

    public init(payload: Data) throws {
        guard payload.count % 4 == 0 else { throw SpeechIPCError.invalidAudioByteCount(payload.count) }
        var peak: Float = 0
        for offset in stride(from: 0, to: payload.count, by: 4) {
            let index = payload.index(payload.startIndex, offsetBy: offset)
            let bits = UInt32(payload[index])
                | (UInt32(payload[payload.index(index, offsetBy: 1)]) << 8)
                | (UInt32(payload[payload.index(index, offsetBy: 2)]) << 16)
                | (UInt32(payload[payload.index(index, offsetBy: 3)]) << 24)
            let sample = Float(bitPattern: bits)
            guard sample.isFinite else { throw SpeechIPCError.nonFiniteAudioSample(offset / 4) }
            peak = max(peak, abs(sample))
        }
        sampleCount = payload.count / 4
        peakAbsoluteAmplitude = peak
    }
}

public enum FrameCodec {
    public static let maximumFrameBytes = 64 * 1024 * 1024

    public static func encode(_ frame: Frame) throws -> Data {
        let bodyLength = 1 + frame.payload.count
        guard bodyLength <= maximumFrameBytes else { throw SpeechIPCError.frameTooLarge(bodyLength) }
        var output = Data(capacity: 4 + bodyLength)
        var length = UInt32(bodyLength).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(frame.type.rawValue)
        output.append(frame.payload)
        return output
    }

    public static func control(_ type: FrameType, object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw SpeechIPCError.invalidControlJSON }
        return try encode(Frame(type: type, payload: JSONSerialization.data(withJSONObject: object)))
    }

    public static func decodeControl(_ payload: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw SpeechIPCError.invalidControlJSON
        }
        return object
    }
}

public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private var requiredBodyBytes: Int?

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func feed(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while true {
            if requiredBodyBytes == nil {
                guard buffer.count >= 4 else { return frames }
                let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let bodyLength = Int(length)
                guard bodyLength >= 1 else { throw SpeechIPCError.frameTooSmall(bodyLength) }
                guard bodyLength <= FrameCodec.maximumFrameBytes else { throw SpeechIPCError.frameTooLarge(bodyLength) }
                buffer.removeFirst(4)
                requiredBodyBytes = bodyLength
            }
            guard let needed = requiredBodyBytes, buffer.count >= needed else { return frames }
            let rawType = buffer[buffer.startIndex]
            guard let type = FrameType(rawValue: rawType) else { throw SpeechIPCError.unknownFrameType(rawType) }
            let payloadStart = buffer.index(after: buffer.startIndex)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: needed)
            frames.append(Frame(type: type, payload: Data(buffer[payloadStart..<payloadEnd])))
            buffer.removeFirst(needed)
            requiredBodyBytes = nil
        }
    }
}

public struct DaemonError: Error, Equatable, Sendable {
    public let errorClass: String
    public let message: String
    public let errorType: String?
    public let clientVersion: Int?
    public let daemonVersion: Int?

    public init(control: [String: Any]) throws {
        guard let errorClass = control["error_class"] as? String,
              let message = control["message"] as? String else {
            throw SpeechIPCError.invalidControlJSON
        }
        self.errorClass = errorClass
        self.message = message
        self.errorType = control["error_type"] as? String
        self.clientVersion = control["client_version"] as? Int
        self.daemonVersion = control["daemon_version"] as? Int
    }

    public init(errorClass: String, message: String, errorType: String? = nil, clientVersion: Int? = nil, daemonVersion: Int? = nil) {
        self.errorClass = errorClass
        self.message = message
        self.errorType = errorType
        self.clientVersion = clientVersion
        self.daemonVersion = daemonVersion
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["error_class": errorClass, "message": message]
        if let errorType { object["error_type"] = errorType }
        if let clientVersion { object["client_version"] = clientVersion }
        if let daemonVersion { object["daemon_version"] = daemonVersion }
        return object
    }
}

import Darwin
import Foundation

public typealias StatusSink = @Sendable (String) -> Void

public enum SocketPath {
    public static let maximumUTF8Bytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public static func validate(_ path: String) throws -> [UInt8] {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty else { throw SpeechIPCError.invalidSocketPath("path is empty") }
        guard !bytes.contains(0) else { throw SpeechIPCError.invalidSocketPath("path contains NUL") }
        guard bytes.count <= maximumUTF8Bytes else {
            throw SpeechIPCError.invalidSocketPath("UTF-8 length \(bytes.count) exceeds \(maximumUTF8Bytes)")
        }
        return bytes
    }
}

public final class UnixConnection: @unchecked Sendable {
    private var descriptor: Int32

    public init(socketPath: String, timeout: TimeInterval, status: @escaping StatusSink = { _ in }) throws {
        let pathBytes = try SocketPath.validate(socketPath)
        guard timeout > 0 else { throw SpeechIPCError.timeout("connect") }
        status("connect.wait")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpeechIPCError.systemCall(operation: "socket", code: errno) }
        descriptor = fd
        do {
            try Self.setNonBlocking(fd)
            var address = sockaddr_un()
            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
            let addressLength = pathOffset + pathBytes.count + 1
            address.sun_len = UInt8(addressLength)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.initializeMemory(as: UInt8.self, repeating: 0)
                raw.copyBytes(from: pathBytes)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(addressLength))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw SpeechIPCError.systemCall(operation: "connect", code: errno) }
                try Self.wait(fd: fd, events: Int16(POLLOUT), deadline: Deadline(timeout), operation: "connect")
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                    throw SpeechIPCError.systemCall(operation: "getsockopt", code: errno)
                }
                guard socketError == 0 else { throw SpeechIPCError.systemCall(operation: "connect", code: socketError) }
            }
            status("connect.ready")
        } catch {
            Darwin.close(fd)
            descriptor = -1
            throw error
        }
    }

    deinit { close() }

    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }

    public func write(_ data: Data, timeout: TimeInterval, status: @escaping StatusSink = { _ in }) throws {
        let deadline = Deadline(timeout)
        var written = 0
        try data.withUnsafeBytes { raw in
            while written < raw.count {
                status("write.wait")
                try Self.wait(fd: descriptor, events: Int16(POLLOUT), deadline: deadline, operation: "write")
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                if count > 0 { written += count; continue }
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                throw SpeechIPCError.systemCall(operation: "write", code: errno)
            }
        }
        status("write.complete")
    }

    public func readFrame(timeout: TimeInterval, status: @escaping StatusSink = { _ in }) throws -> Frame {
        let deadline = Deadline(timeout)
        let header = try readExactly(4, deadline: deadline, status: status)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let bodyLength = Int(length)
        guard bodyLength >= 1 else { throw SpeechIPCError.frameTooSmall(bodyLength) }
        guard bodyLength <= FrameCodec.maximumFrameBytes else { throw SpeechIPCError.frameTooLarge(bodyLength) }
        let body = try readExactly(bodyLength, deadline: deadline, status: status)
        let rawType = body[body.startIndex]
        guard let type = FrameType(rawValue: rawType) else { throw SpeechIPCError.unknownFrameType(rawType) }
        return Frame(type: type, payload: body.dropFirst())
    }

    private func readExactly(_ count: Int, deadline: Deadline, status: @escaping StatusSink) throws -> Data {
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { raw in
            while received < count {
                status("read.wait")
                try Self.wait(fd: descriptor, events: Int16(POLLIN), deadline: deadline, operation: "read")
                let amount = Darwin.read(descriptor, raw.baseAddress!.advanced(by: received), count - received)
                if amount > 0 { received += amount; continue }
                if amount == 0 { throw SpeechIPCError.connectionClosed(expected: count, received: received) }
                if errno == EAGAIN || errno == EINTR { continue }
                throw SpeechIPCError.systemCall(operation: "read", code: errno)
            }
        }
        return data
    }

    private static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SpeechIPCError.systemCall(operation: "fcntl", code: errno)
        }
    }

    private static func wait(fd: Int32, events: Int16, deadline: Deadline, operation: String) throws {
        while true {
            let milliseconds = deadline.remainingMilliseconds
            guard milliseconds > 0 else { throw SpeechIPCError.timeout(operation) }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, milliseconds)
            if result > 0 {
                if item.revents & Int16(POLLNVAL) != 0 { throw SpeechIPCError.systemCall(operation: operation, code: EBADF) }
                if item.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
                continue
            }
            if result == 0 { throw SpeechIPCError.timeout(operation) }
            if errno == EINTR { continue }
            throw SpeechIPCError.systemCall(operation: "poll(\(operation))", code: errno)
        }
    }
}

private struct Deadline {
    private let end: UInt64

    init(_ timeout: TimeInterval) {
        let bounded = max(0, timeout)
        let nanoseconds = UInt64(min(bounded * 1_000_000_000, Double(UInt64.max / 2)))
        end = DispatchTime.now().uptimeNanoseconds &+ nanoseconds
    }

    var remainingMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { return 0 }
        let roundedUp = (end - now + 999_999) / 1_000_000
        return Int32(min(roundedUp, UInt64(Int32.max)))
    }
}

import Foundation

public struct SpeechRequest: Sendable {
    public static let protocolVersion = 2

    public let protocolVersion: Int
    public let requestID: String
    public let kind: String
    public let params: [String: Sendable]
    public let lane: String
    public let timeout: TimeInterval

    public init(protocolVersion: Int = Self.protocolVersion, requestID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), kind: String, params: [String: Sendable], lane: String = "interactive", timeout: TimeInterval) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.kind = kind
        self.params = params
        self.lane = lane
        self.timeout = timeout
    }

    public var jsonObject: [String: Any] {
        [
            "protocol_version": protocolVersion,
            "request_id": requestID,
            "kind": kind,
            "params": params,
            "lane": lane,
            "timeout": timeout,
        ]
    }
}

public struct TTSCancellationResult: Sendable {
    public let requestID: String
    public let receivedAudioBytes: Int
    public let decodedSampleCount: Int
    public let peakAbsoluteAmplitude: Float
    public let socketClosed: Bool

    public var jsonObject: [String: Any] {
        [
            "request_id": requestID,
            "received_audio_bytes": receivedAudioBytes,
            "decoded_sample_count": decodedSampleCount,
            "peak_absolute_amplitude": Double(peakAbsoluteAmplitude),
            "socket_closed": socketClosed,
            "daemon_cancellation_acknowledged": false,
        ]
    }
}

public struct SpeechSynthesisResult: Equatable, Sendable {
    public let requestID: String
    public let samples: [Float]
    /// The rate the samples were produced at. This is not the transfer container's
    /// rate: the daemon streams Kokoro audio at 24 kHz and callers must resample.
    public let sampleRate: Int

    public init(requestID: String, samples: [Float], sampleRate: Int) {
        self.requestID = requestID
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public final class SpeechIPCClient: Sendable {
    public static let selftestEchoValue = "wilted-swift"

    /// The rate `tts_stream` PCM arrives at, per the daemon's Kokoro contract
    /// (`speech_stack.tts.KOKORO_SAMPLE_RATE`). The broker's client-facing terminal
    /// frame relays only `{"cancelled": false}`, so nothing on this wire reports the
    /// rate today. `synthesize` still prefers any rate a frame does report and falls
    /// back to this contracted value, so a later broker that relays it wins.
    public static let streamSampleRate = 24_000

    public let socketPath: String
    public let connectTimeout: TimeInterval
    public let operationTimeout: TimeInterval
    private let status: StatusSink

    public init(socketPath: String, connectTimeout: TimeInterval = 2, operationTimeout: TimeInterval = 15, status: @escaping StatusSink = { _ in }) {
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
        self.operationTimeout = operationTimeout
        self.status = status
    }

    /// Reads `sample_rate` from a control payload, tolerating the daemon's nested
    /// `result` envelope, so either frame shape can report the stream's real rate.
    static func reportedSampleRate(in control: [String: Any]) -> Int? {
        if let rate = control["sample_rate"] as? Int, rate > 0 { return rate }
        if let result = control["result"] as? [String: Any],
           let rate = result["sample_rate"] as? Int, rate > 0 { return rate }
        return nil
    }

    public func selftest() throws -> [String: Any] {
        let result = try unary(SpeechRequest(
            kind: "selftest",
            params: ["action": "echo", "value": Self.selftestEchoValue],
            timeout: operationTimeout
        ))
        guard result["value"] as? String == Self.selftestEchoValue else {
            throw SpeechIPCError.invalidControlJSON
        }
        return result
    }

    public func statusSnapshot() throws -> [String: Any] {
        try unary(SpeechRequest(kind: "status", params: [:], timeout: operationTimeout))
    }

    public func protocolMismatch(clientVersion: Int = 1) throws -> DaemonError {
        let request = SpeechRequest(protocolVersion: clientVersion, kind: "status", params: [:], timeout: operationTimeout)
        let connection = try UnixConnection(socketPath: socketPath, timeout: connectTimeout, status: status)
        defer { connection.close() }
        try send(request, on: connection)
        let frame = try connection.readFrame(timeout: operationTimeout, status: status)
        guard frame.type == .error else { throw SpeechIPCError.unexpectedFrame(frame.type) }
        return try DaemonError(control: FrameCodec.decodeControl(frame.payload))
    }

    public func cancelTTSAfterFirstAudio(text: String) throws -> TTSCancellationResult {
        let request = SpeechRequest(kind: "tts_stream", params: ["text": text], timeout: operationTimeout)
        let connection = try UnixConnection(socketPath: socketPath, timeout: connectTimeout, status: status)
        defer { connection.close() }
        try send(request, on: connection)
        while true {
            status("stream.wait")
            let frame = try connection.readFrame(timeout: operationTimeout, status: status)
            switch frame.type {
            case .audio where !frame.payload.isEmpty:
                let summary = try Float32LEAudioSummary(payload: frame.payload)
                let count = frame.payload.count
                connection.close()
                status("stream.closed_after_audio")
                return TTSCancellationResult(
                    requestID: request.requestID,
                    receivedAudioBytes: count,
                    decodedSampleCount: summary.sampleCount,
                    peakAbsoluteAmplitude: summary.peakAbsoluteAmplitude,
                    socketClosed: true
                )
            case .audio:
                continue
            case .error:
                connection.close()
                throw SpeechIPCError.daemon(try DaemonError(control: FrameCodec.decodeControl(frame.payload)))
            case .result:
                connection.close()
                throw SpeechIPCError.connectionClosed(expected: 1, received: 0)
            default:
                connection.close()
                throw SpeechIPCError.unexpectedFrame(frame.type)
            }
        }
    }

    /// Receives one complete protocol-v2 Float32 stream. Cancellation closes
    /// the connection at the next frame boundary; the socket timeout remains
    /// the hard bound when the daemon stalls between frames.
    public func synthesize(
        text: String,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> SpeechSynthesisResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechIPCError.invalidControlJSON
        }
        let request = SpeechRequest(kind: "tts_stream", params: ["text": text], timeout: operationTimeout)
        let connection = try UnixConnection(socketPath: socketPath, timeout: connectTimeout, status: status)
        defer { connection.close() }
        try send(request, on: connection)
        var samples: [Float] = []
        var reportedRate: Int?
        while true {
            if isCancelled() { connection.close(); throw CancellationError() }
            status("stream.wait")
            let frame = try connection.readFrame(timeout: operationTimeout, status: status)
            switch frame.type {
            case .audio where !frame.payload.isEmpty:
                samples.append(contentsOf: try decodeFloat32LE(frame.payload))
                status("stream.audio samples=\(samples.count)")
            case .audio, .audioMeta, .status:
                if frame.type != .audio, !frame.payload.isEmpty {
                    reportedRate = Self.reportedSampleRate(in: try FrameCodec.decodeControl(frame.payload)) ?? reportedRate
                }
            case .end, .result:
                guard !samples.isEmpty else { throw SpeechIPCError.connectionClosed(expected: 1, received: 0) }
                if !frame.payload.isEmpty {
                    reportedRate = Self.reportedSampleRate(in: try FrameCodec.decodeControl(frame.payload)) ?? reportedRate
                }
                let rate = reportedRate ?? Self.streamSampleRate
                status("stream.complete samples=\(samples.count) rate=\(rate)")
                return SpeechSynthesisResult(requestID: request.requestID, samples: samples, sampleRate: rate)
            case .error:
                throw SpeechIPCError.daemon(try DaemonError(control: FrameCodec.decodeControl(frame.payload)))
            case .request:
                throw SpeechIPCError.unexpectedFrame(frame.type)
            }
        }
    }

    public func unary(_ request: SpeechRequest) throws -> [String: Any] {
        let connection = try UnixConnection(socketPath: socketPath, timeout: connectTimeout, status: status)
        defer { connection.close() }
        try send(request, on: connection)
        let frame = try connection.readFrame(timeout: operationTimeout, status: status)
        switch frame.type {
        case .result, .status:
            let control = try FrameCodec.decodeControl(frame.payload)
            return control["result"] as? [String: Any] ?? [:]
        case .error:
            throw SpeechIPCError.daemon(try DaemonError(control: FrameCodec.decodeControl(frame.payload)))
        default:
            throw SpeechIPCError.unexpectedFrame(frame.type)
        }
    }

    private func send(_ request: SpeechRequest, on connection: UnixConnection) throws {
        status("request.encode")
        let frame = try FrameCodec.control(.request, object: request.jsonObject)
        try connection.write(frame, timeout: operationTimeout, status: status)
    }
}

private func decodeFloat32LE(_ payload: Data) throws -> [Float] {
    _ = try Float32LEAudioSummary(payload: payload)
    return stride(from: 0, to: payload.count, by: 4).map { offset in
        let index = payload.index(payload.startIndex, offsetBy: offset)
        let bits = UInt32(payload[index])
            | (UInt32(payload[payload.index(index, offsetBy: 1)]) << 8)
            | (UInt32(payload[payload.index(index, offsetBy: 2)]) << 16)
            | (UInt32(payload[payload.index(index, offsetBy: 3)]) << 24)
        return Float(bitPattern: bits)
    }
}
