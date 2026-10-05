import Foundation

/// A failure while encoding or decoding a watch link payload.
public enum WatchLinkError: Error, Equatable, Sendable {
    /// The envelope does not carry the expected key.
    case missingKey(String)
    /// The envelope carries a value of the wrong type under the key.
    case wrongType(String)
    /// The encoded payload exceeds `WatchLinkCodec.maximumPayloadBytes`.
    case payloadTooLarge(Int)
    /// The payload declares a version this build does not understand.
    case unsupportedVersion(Int)
    /// The payload is not the JSON shape the key promises.
    case malformedPayload
}

/// The codec for `WatchSnapshot`s and `WatchCommand`s carried in
/// `WCSession` application-context and message dictionaries.
public enum WatchLinkCodec {
    /// Largest payload accepted in either direction.
    public static let maximumPayloadBytes = 64 * 1024
    /// Application-context key holding the encoded snapshot.
    public static let snapshotKey = "wiltedWatchSnapshot"
    /// Message key holding the encoded command.
    public static let commandKey = "wiltedWatchCommand"

    /// Encodes a snapshot into a single-key application-context dictionary.
    public static func encode(_ snapshot: WatchSnapshot) throws -> [String: Any] {
        let data = try payload(for: snapshot)
        return [snapshotKey: data]
    }

    /// Decodes and version-checks the snapshot in an application context.
    public static func decodeSnapshot(_ context: [String: Any]) throws -> WatchSnapshot {
        let data = try payloadData(in: context, key: snapshotKey)
        let snapshot = try decode(WatchSnapshot.self, from: data)
        guard snapshot.version == WatchSnapshot.currentVersion else {
            throw WatchLinkError.unsupportedVersion(snapshot.version)
        }
        return snapshot
    }

    /// Encodes a command into a single-key message dictionary.
    public static func encode(_ command: WatchCommand) throws -> [String: Any] {
        let data = try payload(for: command)
        return [commandKey: data]
    }

    /// Decodes and version-checks the command in a message dictionary.
    public static func decodeCommand(_ message: [String: Any]) throws -> WatchCommand {
        let data = try payloadData(in: message, key: commandKey)
        let command = try decode(WatchCommand.self, from: data)
        guard command.version == WatchCommand.currentVersion else {
            throw WatchLinkError.unsupportedVersion(command.version)
        }
        return command
    }

    private static func payload<Value: Encodable>(for value: Value) throws -> Data {
        let data = try encoder.encode(value)
        guard data.count <= maximumPayloadBytes else { throw WatchLinkError.payloadTooLarge(data.count) }
        return data
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw WatchLinkError.malformedPayload
        }
    }

    private static func payloadData(in envelope: [String: Any], key: String) throws -> Data {
        guard let value = envelope[key] else { throw WatchLinkError.missingKey(key) }
        guard let data = value as? Data else { throw WatchLinkError.wrongType(key) }
        guard data.count <= maximumPayloadBytes else { throw WatchLinkError.payloadTooLarge(data.count) }
        return data
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
