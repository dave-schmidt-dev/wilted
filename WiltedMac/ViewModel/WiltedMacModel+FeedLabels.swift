import Foundation

struct WiltedMacEpisodeLabel: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case trailer = "Likely trailer"
        case promo = "Likely promo"
        case bonus = "Bonus"
        case rerun = "Likely rerun"
    }

    let kind: Kind
    let reason: String
}

struct WiltedMacEpisodeLabelReviewRow: Equatable, Sendable {
    let showTitle: String
    let episodeTitle: String
    let labels: [WiltedMacEpisodeLabel]
}

enum WiltedMacEpisodeLabelPreference {
    static let key = "wilted.mac.feeds.episode-labels-enabled"
}

/// Informational title labels. Duration can support an ambiguous preview cue, but cannot identify a trailer alone.
enum WiltedMacEpisodeLabeler {
    private static let cueRules: [(WiltedMacEpisodeLabel.Kind, [String])] = [
        (.trailer, [
            "official trailer", "episode trailer", "series trailer", "show trailer", "season trailer",
            "new trailer", "final trailer", "trailer for", "teaser", "teaser for",
        ]),
        (.promo, ["preview of our upcoming show", "promo", "promotion", "promotional"]),
        (.bonus, ["bonus", "bonus episode", "bonus content", "extra episode"]),
        (.rerun, ["rerun", "re-run", "encore", "rebroadcast", "from the archives", "replay episode", "replay of"]),
    ]
    private static let clearPreviewCues = [
        "season preview", "preview season", "preview of the upcoming", "preview of our upcoming",
        "preview for the upcoming", "preview for our upcoming", "preview of the next season",
        "preview for the next season", "coming soon preview", "first look at the upcoming season",
    ]
    private static let minimumHistoryCount = 3
    private static let maximumHistoryCount = 100
    private static let likelyTrailerMaximumSeconds: TimeInterval = 15 * 60
    private static let likelyTrailerDurationRatio = 0.40

    static func labels(for candidate: WiltedMacEpisode, history: [WiltedMacEpisode]) -> [WiltedMacEpisodeLabel] {
        labelsByID(for: history + [candidate])[candidate.id] ?? []
    }

    /// Labels a full catalog in one per-feed chronological pass, avoiding a catalog scan per row on every render.
    static func labelsByID(for episodes: [WiltedMacEpisode]) -> [String: [WiltedMacEpisodeLabel]] {
        let uniqueByID = Dictionary(episodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let uniqueEpisodes = Array(uniqueByID.values)
        var labelsByID = Dictionary(uniqueEpisodes.map { ($0.id, titleCueLabels(for: $0)) },
                                    uniquingKeysWith: { _, latest in latest })
        var byFeed: [String: [WiltedMacEpisode]] = [:]
        for episode in uniqueEpisodes {
            guard let feedID = episode.feedID, episode.publishedAt != nil else { continue }
            byFeed[feedID, default: []].append(episode)
        }

        for feedEpisodes in byFeed.values {
            let ordered = feedEpisodes.sorted {
                let leftDate = $0.publishedAt ?? .distantPast
                let rightDate = $1.publishedAt ?? .distantPast
                return leftDate == rightDate ? $0.id < $1.id : leftDate < rightDate
            }
            var previousByTitle: [String: WiltedMacEpisode] = [:]
            var priorWindow: [WiltedMacEpisode] = []
            var index = 0

            while index < ordered.count {
                let date = ordered[index].publishedAt ?? .distantPast
                var end = index + 1
                while end < ordered.count, (ordered[end].publishedAt ?? .distantPast) == date { end += 1 }

                for episode in ordered[index..<end] {
                    var labels = labelsByID[episode.id] ?? []
                    let title = normalized(episode.title)
                    if !labels.contains(where: { $0.kind == .rerun }), !title.isEmpty,
                       let previous = previousByTitle[title] {
                        labels.append(WiltedMacEpisodeLabel(
                            kind: .rerun, reason: "Title matches an earlier episode (\(previous.title))."))
                    }
                    if labels.isEmpty, let reason = corroboratedPreviewReason(episode, history: priorWindow) {
                        labels.append(WiltedMacEpisodeLabel(kind: .trailer, reason: reason))
                    }
                    labelsByID[episode.id] = labels
                }

                // Episodes with the same publication time are peers, not evidence of an earlier replay.
                for episode in ordered[index..<end] {
                    let title = normalized(episode.title)
                    if !title.isEmpty { previousByTitle[title] = episode }
                    priorWindow.append(episode)
                }
                if priorWindow.count > maximumHistoryCount {
                    priorWindow.removeFirst(priorWindow.count - maximumHistoryCount)
                }
                index = end
            }
        }
        return labelsByID
    }

    static func reviewRows(
        candidates: [WiltedMacEpisode], history: [WiltedMacEpisode]
    ) -> [WiltedMacEpisodeLabelReviewRow] {
        let labels = labelsByID(for: history + candidates)
        return candidates.compactMap { episode in
            guard let episodeLabels = labels[episode.id], !episodeLabels.isEmpty else { return nil }
            return WiltedMacEpisodeLabelReviewRow(
                showTitle: episode.feedTitle, episodeTitle: episode.title, labels: episodeLabels
            )
        }
    }

    private static func titleCueLabels(for episode: WiltedMacEpisode) -> [WiltedMacEpisodeLabel] {
        let title = normalized(episode.title)
        var labels: [WiltedMacEpisodeLabel] = []
        for (kind, cues) in cueRules {
            let matchedCue = cues.filter { hasPhrase($0, in: title) }.max { $0.count < $1.count }
            if let matchedCue {
                labels.append(WiltedMacEpisodeLabel(kind: kind, reason: "Title contains the explicit “\(matchedCue)” cue."))
            } else if kind == .trailer, hasMeaningfulTrailerToken(in: title) {
                labels.append(WiltedMacEpisodeLabel(kind: kind, reason: "Title uses “trailer” as a standalone title cue."))
            }
        }
        if labels.isEmpty,
           let matchedCue = clearPreviewCues.filter({ hasPhrase($0, in: title) }).max(by: { $0.count < $1.count }) {
            labels.append(WiltedMacEpisodeLabel(
                kind: .trailer, reason: "Title contains “\(matchedCue)”, identifying a season or upcoming-show preview."
            ))
        }
        return labels
    }

    private static func hasMeaningfulTrailerToken(in normalizedTitle: String) -> Bool {
        let words = normalizedTitle.split(separator: " ")
        guard let index = words.firstIndex(of: "trailer") else { return false }
        if words.count == 1 || index == words.startIndex || index == words.index(before: words.endIndex) {
            // Do not classify show names such as "Trailer Park Boys" as trailers.
            return words.count == 1 || index == words.index(before: words.endIndex)
                || words.dropFirst().first != "park"
        }
        return false
    }

    private static func corroboratedPreviewReason(
        _ candidate: WiltedMacEpisode, history: [WiltedMacEpisode]
    ) -> String? {
        let title = normalized(candidate.title)
        guard hasPhrase("preview", in: title),
              let feedID = candidate.feedID,
              let duration = candidate.sourceDurationSeconds, duration.isFinite,
              duration > 0, duration <= likelyTrailerMaximumSeconds else { return nil }
        let priorDurations = history.compactMap { episode -> TimeInterval? in
            guard episode.feedID == feedID,
                  let seconds = episode.sourceDurationSeconds, seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        }.sorted()
        guard priorDurations.count >= minimumHistoryCount else { return nil }
        let median = priorDurations[priorDurations.count / 2]
        guard median > 0, duration < median * likelyTrailerDurationRatio else { return nil }
        return "Title includes the ambiguous “preview” cue, and duration is under 40% of the median for \(priorDurations.count) earlier episodes."
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func hasPhrase(_ phrase: String, in normalizedTitle: String) -> Bool {
        let normalizedPhrase = normalized(phrase)
        return (" " + normalizedTitle + " ").contains(" " + normalizedPhrase + " ")
    }
}

extension WiltedMacModel {
    var feedEpisodeLabelsByID: [String: [WiltedMacEpisodeLabel]] {
        WiltedMacEpisodeLabeler.labelsByID(for: episodes)
    }

    var flaggedFeedEpisodeReviewRows: [WiltedMacEpisodeLabelReviewRow] {
        WiltedMacEpisodeLabeler.reviewRows(candidates: feedsEpisodeCandidates, history: episodes)
    }
}
