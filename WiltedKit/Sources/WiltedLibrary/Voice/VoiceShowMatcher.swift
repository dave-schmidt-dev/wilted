import Foundation

/// Matches a spoken show name to a feed title, tolerating how people say titles:
/// "tech crunch daily" for "TechCrunch Daily", a dropped "The", punctuation, accents, a feed
/// title with a subtitle, and small speech-recognition slips.
public enum VoiceShowMatcher {
    /// Lowercased, accent- and punctuation-free, leading "the" removed, single spaces.
    public static func normalize(_ text: String) -> String {
        let accentFree = text.folding(options: .diacriticInsensitive, locale: nil)
        let lowercased = accentFree.lowercased()
        let noPunctuation = lowercased.filter { !$0.isPunctuation }
        var words = noPunctuation.split(whereSeparator: \.isWhitespace)
        if words.first == "the" {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    /// The best-matching title among `titles`. Tiers, best first: the title as written, ignoring
    /// case; equal after normalizing with spaces removed; one side equals a run of whole words of
    /// the other (spaces removed, shorter side at least 4 letters, so "science" never matches
    /// "Conscience"); every word of the spoken name appears among the title's words; Levenshtein
    /// similarity of the space-free forms at least 0.8 (both at least 5 letters). Identical
    /// titles count once; two distinct titles tied at the best tier are `.ambiguous`, so "The
    /// Daily" and "Daily" stay separate feeds.
    public static func match(_ spoken: String, among titles: [String]) -> VoiceShowMatch {
        let spokenNorm = normalize(spoken)
        guard !spokenNorm.isEmpty else { return .none }

        let spokenSpaceFree = spokenNorm.filter { !$0.isWhitespace }
        let spokenWords = Set(spokenNorm.split(whereSeparator: \.isWhitespace))

        struct TitleCandidate {
            let original: String
            let spaceFree: String
            let wordList: [String]
            let words: Set<Substring>
        }

        var seenTitles = Set<String>()
        var candidates: [TitleCandidate] = []
        for title in titles {
            let norm = normalize(title)
            if seenTitles.insert(title.trimmingCharacters(in: .whitespaces).lowercased()).inserted {
                let spaceFree = norm.filter { !$0.isWhitespace }
                let words = Set(norm.split(whereSeparator: \.isWhitespace))
                candidates.append(TitleCandidate(
                    original: title,
                    spaceFree: spaceFree,
                    wordList: norm.split(whereSeparator: \.isWhitespace).map(String.init),
                    words: words
                ))
            }
        }

        // Tier 0: the title as written, ignoring case
        let written = spoken.trimmingCharacters(in: .whitespaces).lowercased()
        let tier0 = candidates.filter { $0.original.trimmingCharacters(in: .whitespaces).lowercased() == written }
        if !tier0.isEmpty {
            return tier0.count == 1 ? .match(tier0[0].original) : .ambiguous(tier0.map(\.original))
        }

        // Tier 1: equal after normalizing with spaces removed
        let tier1 = candidates.filter { $0.spaceFree == spokenSpaceFree }
        if !tier1.isEmpty {
            return tier1.count == 1 ? .match(tier1[0].original) : .ambiguous(tier1.map(\.original))
        }

        // Tier 2: one side equals a run of whole words of the other (shorter side at least 4 letters)
        let spokenWordList = spokenNorm.split(whereSeparator: \.isWhitespace).map(String.init)
        let tier2 = candidates.filter { c in
            min(spokenSpaceFree.count, c.spaceFree.count) >= 4 &&
            (wordRun(c.wordList, equals: spokenSpaceFree) || wordRun(spokenWordList, equals: c.spaceFree))
        }
        if !tier2.isEmpty {
            return tier2.count == 1 ? .match(tier2[0].original) : .ambiguous(tier2.map(\.original))
        }

        // Tier 3: every word of the spoken name appears among the title's words
        let tier3 = candidates.filter { c in
            spokenWords.isSubset(of: c.words)
        }
        if !tier3.isEmpty {
            return tier3.count == 1 ? .match(tier3[0].original) : .ambiguous(tier3.map(\.original))
        }

        // Tier 4: Levenshtein similarity of the space-free forms at least 0.8 (both at least 5 letters)
        let spokenChars = Array(spokenSpaceFree)
        let tier4 = candidates.filter { c in
            guard spokenSpaceFree.count >= 5 && c.spaceFree.count >= 5 else { return false }
            let maxLen = max(spokenSpaceFree.count, c.spaceFree.count)
            let dist = levenshteinDistance(spokenChars, Array(c.spaceFree))
            let similarity = Double(maxLen - dist) / Double(maxLen)
            return similarity >= 0.8 - 1e-9
        }
        if !tier4.isEmpty {
            return tier4.count == 1 ? .match(tier4[0].original) : .ambiguous(tier4.map(\.original))
        }

        return .none
    }

    /// Whether some run of consecutive `words`, joined with no spaces, is exactly `target`.
    private static func wordRun(_ words: [String], equals target: String) -> Bool {
        for start in words.indices {
            var joined = ""
            for word in words[start...] {
                joined += word
                if joined == target { return true }
                if joined.count >= target.count { break }
            }
        }
        return false
    }

    private static func levenshteinDistance(_ s1: [Character], _ s2: [Character]) -> Int {
        let m = s1.count
        let n = s2.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                if s1[i - 1] == s2[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j], min(curr[j - 1], prev[j - 1]))
                }
            }
            prev = curr
        }

        return prev[n]
    }
}
