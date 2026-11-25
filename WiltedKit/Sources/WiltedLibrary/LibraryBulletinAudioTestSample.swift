import Foundation

/// A deterministic, non-personal bulletin used to verify the approved voice path.
public enum LibraryBulletinAudioTestSample {
    private static let idPrefix = "wilted-test-bulletin:"
    private static let bucketDuration: TimeInterval = 60 * 60
    private static let lifetime: TimeInterval = 6 * 60 * 60

    public static let text = "This is a test bulletin."

    /// Creates the same test bulletin on the phone and Mac for the current hour.
    public static func make(at now: Date) -> Bulletin? {
        let bucket = Int64(floor(now.timeIntervalSince1970 / bucketDuration))
        return make(id: idPrefix + String(bucket), at: now)
    }

    /// Resolves only a current ID created by `make(at:)`.
    public static func make(id: String, at now: Date) -> Bulletin? {
        guard id.hasPrefix(idPrefix),
              let bucket = Int64(id.dropFirst(idPrefix.count)),
              String(bucket) == id.dropFirst(idPrefix.count) else { return nil }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(bucket) * bucketDuration)
        let expiresAt = issuedAt.addingTimeInterval(lifetime)
        guard issuedAt <= now, expiresAt > now else { return nil }
        return try? Bulletin(
            id: id, kind: .headline, text: text, issuedAt: issuedAt, expiresAt: expiresAt)
    }
}
