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
