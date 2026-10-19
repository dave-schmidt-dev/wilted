import Foundation

/// The one way a preparation or playback log line names its episode (LG-6).
///
/// An `item-<sha>` alone cannot answer "what happened to episode X" without
/// the store; the feed and the title can, and both are public feed metadata.
/// Only identifiers, the title and counters go in, never notes, summaries or
/// transcript text, so every call site may interpolate the result as public.
struct WiltedMacEpisodeLogContext: Equatable, Sendable {
    static let titleLimit = 80

    let episodeID: String
    var feedID: String?
    var title: String?
    var requestSequence: Int?
    var attempt: Int?

    /// `episode=<id> feed=<id> title="<title>" seq=<n> attempt=<n>`, always in
    /// that order. A field nobody knows is left out rather than guessed.
    var rendered: String {
        var fields = ["episode=\(Self.token(episodeID))"]
        if let feedID { fields.append("feed=\(Self.token(feedID))") }
        if let title { fields.append("title=\"\(Self.sanitizedTitle(title))\"") }
        if let requestSequence { fields.append("seq=\(requestSequence)") }
        if let attempt { fields.append("attempt=\(attempt)") }
        return fields.joined(separator: " ")
    }

    /// One line of at most `titleLimit` characters, with no double quote or
    /// backslash, so a title cannot end its own field or forge another.
    static func sanitizedTitle(_ title: String) -> String {
        let flattened = String(String.UnicodeScalarView(title.unicodeScalars.map { scalar -> Unicode.Scalar in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            if scalar == "\"" { return "'" }
            if scalar == "\\" { return "/" }
            return scalar
        }))
        let collapsed = flattened.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > titleLimit else { return collapsed }
        return String(collapsed.prefix(titleLimit - 1)) + "…"
    }

    /// Identifiers are single tokens; whitespace or a quote would split the line's fields.
    static func token(_ value: String) -> String {
        value.isEmpty ? "-" : String(value.map { $0.isWhitespace || $0 == "\"" ? "_" : $0 })
    }
}

extension WiltedMacModel {
    /// The log context for `episodeID`, with the feed and title of the row the
    /// model holds for it. An id with no row (an article, a removed episode)
    /// logs its id and counters only.
    func episodeLogContext(_ episodeID: String, requestSequence: Int? = nil, attempt: Int? = nil) -> String {
        let episode = episodes.first { $0.id == episodeID }
        return WiltedMacEpisodeLogContext(
            episodeID: episodeID, feedID: episode?.feedID, title: episode?.title,
            requestSequence: requestSequence, attempt: attempt
        ).rendered
    }
}
