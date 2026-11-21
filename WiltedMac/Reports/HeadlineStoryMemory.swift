import Foundation

/// Remembers the stories already read as headlines, so the same story from several news feeds is
/// read once.
///
/// Two headlines are the same story when they share at least three key words and those shared
/// words make up at least 60% of the shorter headline's key words. Key words are the headline's
/// words in lower case, without accents or punctuation, minus common filler words, update markers
/// and words shorter than three letters (numbers always count).
///
/// A headline about a story already read is read again only as a major update, which is kept
/// conservative: either it is marked as breaking news or an update ("Breaking", "Update",
/// "Updated", "Developing", "Live", "Latest") and adds at least two new key words, or at least five
/// of its key words are new and they are at least half of its key words. After a major update is
/// read, its words join the story, so the next update must again bring something new.
struct HeadlineStoryMemory: Equatable, Sendable {
    /// What to do with a headline.
    enum Verdict: Equatable, Sendable {
        /// No story read recently matches: read it.
        case newStory
        /// A story already read, with nothing major added: skip it.
        case duplicate
        /// A story already read, with a major update: read it again.
        case majorUpdate
    }

    /// How long a read story is remembered.
    static let retention: TimeInterval = 24 * 3600
    /// The most stories remembered; the oldest are forgotten first.
    static let capacity = 200
    static let minimumSharedWords = 3
    static let minimumSharedFraction = 0.6
    static let markedUpdateNewWords = 2
    static let unmarkedUpdateNewWords = 5

    static let updateMarkers: Set<String> = ["breaking", "update", "updated", "updates", "developing", "live", "latest"]
    static let fillerWords: Set<String> = [
        "the", "and", "for", "but", "not", "nor", "yet", "with", "from", "into", "onto", "over", "under",
        "after", "before", "about", "against", "amid", "among", "as", "at", "by", "in", "of", "on", "to",
        "up", "out", "off", "its", "it's", "his", "her", "their", "they", "them", "this", "that", "these",
        "those", "who", "what", "when", "where", "why", "how", "which", "will", "would", "could", "should",
        "can", "may", "might", "has", "have", "had", "was", "were", "are", "been", "being", "is", "be",
        "says", "said", "say", "new", "news", "more", "than", "then", "now", "just", "also", "all", "any",
        "some", "you", "your", "our", "one", "two", "via", "per", "here", "there"
    ]

    private struct Story: Equatable, Sendable {
        var words: Set<String>
        var lastReadAt: Date
    }

    private var stories: [Story] = []

    /// Decides what to do with `title` at `time`, without remembering it.
    func verdict(for title: String, at time: Date) -> Verdict {
        let words = Self.keyWords(in: title)
        guard let story = match(words, at: time) else { return .newStory }
        let added = words.subtracting(story.words)
        let marked = Self.hasUpdateMarker(title)
        if marked && added.count >= Self.markedUpdateNewWords { return .majorUpdate }
        if added.count >= Self.unmarkedUpdateNewWords && Double(added.count) >= Double(words.count) / 2 {
            return .majorUpdate
        }
        return .duplicate
    }

    /// Records that `title` was read at `time`: it joins the story it matches, or starts a new one.
    mutating func remember(_ title: String, at time: Date) {
        let words = Self.keyWords(in: title)
        guard !words.isEmpty else { return }
        forget(before: time)
        if let index = matchIndex(words, at: time) {
            stories[index].words.formUnion(words)
            stories[index].lastReadAt = time
        } else {
            stories.append(Story(words: words, lastReadAt: time))
        }
        if stories.count > Self.capacity {
            stories.sort { $0.lastReadAt < $1.lastReadAt }
            stories.removeFirst(stories.count - Self.capacity)
        }
    }

    // MARK: - Matching

    private func match(_ words: Set<String>, at time: Date) -> Story? {
        matchIndex(words, at: time).map { stories[$0] }
    }

    private func matchIndex(_ words: Set<String>, at time: Date) -> Int? {
        guard !words.isEmpty else { return nil }
        var best: (index: Int, shared: Int)?
        for (index, story) in stories.enumerated() where time.timeIntervalSince(story.lastReadAt) <= Self.retention {
            let shared = words.intersection(story.words).count
            let smaller = min(words.count, story.words.count)
            guard shared >= Self.minimumSharedWords,
                  Double(shared) >= Self.minimumSharedFraction * Double(smaller) else { continue }
            if shared > (best?.shared ?? 0) { best = (index, shared) }
        }
        return best?.index
    }

    private mutating func forget(before time: Date) {
        stories.removeAll { time.timeIntervalSince($0.lastReadAt) > Self.retention }
    }

    // MARK: - Words

    static func tokens(in title: String) -> [String] {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'s", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func keyWords(in title: String) -> Set<String> {
        Set(tokens(in: title).filter { word in
            if word.allSatisfy(\.isNumber) { return true }
            return word.count >= 3 && !fillerWords.contains(word) && !updateMarkers.contains(word)
        })
    }

    static func hasUpdateMarker(_ title: String) -> Bool {
        tokens(in: title).contains { updateMarkers.contains($0) }
    }
}
