import Foundation

/// Local, transient search state for the open episode's transcript.
struct WiltedMacTranscriptSearch: Equatable, Sendable {
    var query = ""
    private(set) var selectedMatchIndex = 0

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        selectedMatchIndex = 0
    }

    /// One result per line, even when a line contains the term more than once.
    func matchingLineIndices(in lines: [String]) -> [Int] {
        let term = trimmedQuery
        guard !term.isEmpty else { return [] }
        return lines.indices.filter { lines[$0].range(of: term, options: [.caseInsensitive]) != nil }
    }

    func lines(in transcript: WiltedMacTranscript) -> [String] {
        if transcript.isSynchronized { return transcript.cues.map(\.text) }
        return (transcript.text ?? "").components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    mutating func selectNext(matchCount: Int) {
        guard matchCount > 0 else {
            selectedMatchIndex = 0
            return
        }
        selectedMatchIndex = (selectedMatchIndex + 1) % matchCount
    }

    mutating func selectPrevious(matchCount: Int) {
        guard matchCount > 0 else {
            selectedMatchIndex = 0
            return
        }
        selectedMatchIndex = (selectedMatchIndex + matchCount - 1) % matchCount
    }

    mutating func select(_ index: Int, matchCount: Int) {
        guard matchCount > 0 else {
            selectedMatchIndex = 0
            return
        }
        selectedMatchIndex = min(max(index, 0), matchCount - 1)
    }

    func selectionIndex(matchCount: Int) -> Int {
        guard matchCount > 0 else {
            return 0
        }
        return selectedMatchIndex % matchCount
    }
}
