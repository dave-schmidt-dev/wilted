import Foundation

/// An alphabetical comparison key; the original title remains the display value.
public enum LibrarySortKey {
    /// Ignores only a leading English article, preserving the rest for localized comparison.
    public static func title(_ value: String) -> String {
        guard let prefix = value.range(of: "The ", options: [.anchored, .caseInsensitive]) else { return value }
        return String(value[prefix.upperBound...])
    }
}
