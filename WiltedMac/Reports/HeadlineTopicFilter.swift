import Foundation

/// The topics whose headlines are never read: sports (on by default) and the listener's own words.
///
/// Matching is kept conservative so a news story is not lost by accident. A post is about sports
/// when its feed files it under sports (a category such as "Sport" or "Football"), when its link
/// sits in a sports section (a path part "sport", "sports" or "football"), or when its title names
/// a sport, league or competition as whole words ("NFL", "Premier League", "tennis"). A listener
/// word or phrase matches whole words of the title or of a category, ignoring case and accents.
struct HeadlineTopicFilter: Equatable, Sendable {
    var skipSports: Bool
    /// Cleaned words and phrases, each already split into its folded words.
    private let customPhrases: [[String]]

    init(skipSports: Bool = false, words: [String] = []) {
        self.skipSports = skipSports
        customPhrases = words.map(Self.words(in:)).filter { !$0.isEmpty }
    }

    /// The sports names matched in titles and categories, as whole words or phrases.
    static let sportsPhrases: [[String]] = [
        "sport", "sports", "soccer", "football", "rugby", "cricket", "tennis", "golf", "baseball", "basketball",
        "hockey", "nfl", "nba", "wnba", "mlb", "nhl", "mls", "ufc", "nascar", "formula 1", "formula one", "f1",
        "premier league", "champions league", "europa league", "la liga", "serie a", "bundesliga", "ligue 1",
        "fa cup", "world cup", "super bowl", "stanley cup", "world series", "grand slam", "wimbledon",
        "ryder cup", "six nations", "playoffs", "playoff", "transfer window", "quarterback", "touchdown"
    ].map(words(in:))

    /// Link path parts that mark a sports section.
    static let sportsSections: Set<String> = ["sport", "sports", "football", "soccer"]

    var isEmpty: Bool { !skipSports && customPhrases.isEmpty }

    /// Whether a post with this title, link and categories is skipped.
    func skips(title: String, link: URL? = nil, categories: [String] = []) -> Bool {
        guard !isEmpty else { return false }
        let titleWords = Self.words(in: title)
        let categoryWords = categories.map(Self.words(in:))
        if skipSports {
            if categoryWords.contains(where: { words in Self.sportsPhrases.contains { Self.contains(words, $0) } }) {
                return true
            }
            if let link, link.pathComponents.contains(where: { Self.sportsSections.contains($0.lowercased()) }) {
                return true
            }
            if Self.sportsPhrases.contains(where: { Self.contains(titleWords, $0) }) { return true }
        }
        for phrase in customPhrases {
            if Self.contains(titleWords, phrase) || categoryWords.contains(where: { Self.contains($0, phrase) }) {
                return true
            }
        }
        return false
    }

    /// The text's words: lower case, without accents, split on anything that is not a letter or digit.
    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Whether `phrase` appears in `words` as consecutive whole words.
    private static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count) where words[start] == phrase[0] {
            if Array(words[start..<(start + phrase.count)]) == phrase { return true }
        }
        return false
    }
}
