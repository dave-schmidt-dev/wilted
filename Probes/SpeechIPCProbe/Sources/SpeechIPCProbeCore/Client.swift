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

public final class SpeechIPCClient: Sendable {
    public static let selftestEchoValue = "wilted-swift"

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
