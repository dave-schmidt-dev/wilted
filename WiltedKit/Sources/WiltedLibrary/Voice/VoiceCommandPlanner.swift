import Foundation
import WiltedDomain

/// Turns a command and a snapshot into an action and a short spoken line. Pure: no player, no
/// model, no clock. Semantics are in `docs/siri-voice-commands.md`.
public enum VoiceCommandPlanner {
    /// How many titles `listDownloaded` speaks after the count.
    public static let spokenTitleLimit = 3

    public static func plan(_ command: VoiceCommand, snapshot: VoiceSnapshot) -> VoicePlan {
        switch command {
        case .playNext(let show):
            if let show = show {
                switch VoiceShowMatcher.match(show, among: snapshot.knownShowTitles) {
                case .none:
                    return VoicePlan(action: .none, dialog: "I can't find a show called \(show).")
                case .ambiguous(let titles):
                    let first = titles.count > 0 ? titles[0] : ""
                    let second = titles.count > 1 ? titles[1] : ""
                    return VoicePlan(action: .none, dialog: "Did you mean \(first) or \(second)?")
                case .match(let matchedShowTitle):
                    let showEpisodes = snapshot.downloaded.filter { sameShow($0.showTitle, matchedShowTitle) }
                    if showEpisodes.isEmpty {
                        return VoicePlan(action: .none, dialog: "No \(matchedShowTitle) episodes are on your phone.")
                    }
                    if let playingEpisode = snapshot.nowPlaying?.episode,
                       sameShow(playingEpisode.showTitle, matchedShowTitle),
                       let currentIndex = showEpisodes.firstIndex(where: { $0.id == playingEpisode.id }) {
                        if currentIndex + 1 < showEpisodes.count {
                            let nextEpisode = showEpisodes[currentIndex + 1]
                            return VoicePlan(action: .play(nextEpisode.id), dialog: "Playing \(nextEpisode.title).")
                        } else {
                            return VoicePlan(action: .none, dialog: "That was the last \(matchedShowTitle) episode on your phone.")
                        }
                    } else {
                        let firstEpisode = showEpisodes[0]
                        return VoicePlan(action: .play(firstEpisode.id), dialog: "Playing \(firstEpisode.title).")
                    }
                }
            } else {
                if snapshot.downloaded.isEmpty {
                    return VoicePlan(action: .none, dialog: "No episodes are on your phone.")
                }
                if let playingEpisode = snapshot.nowPlaying?.episode,
                   let currentIndex = snapshot.downloaded.firstIndex(where: { $0.id == playingEpisode.id }) {
                    if currentIndex + 1 < snapshot.downloaded.count {
                        let nextEpisode = snapshot.downloaded[currentIndex + 1]
                        return VoicePlan(action: .play(nextEpisode.id), dialog: "Playing \(nextEpisode.title).")
                    } else {
                        return VoicePlan(action: .none, dialog: "That was the last episode on your phone.")
                    }
                } else {
                    let firstEpisode = snapshot.downloaded[0]
                    return VoicePlan(action: .play(firstEpisode.id), dialog: "Playing \(firstEpisode.title).")
                }
            }

        case .playEpisode(let title, let show):
            return planPlayEpisode(title: title, show: show, snapshot: snapshot)

        case .playEpisodeByID(let id):
            guard let episode = snapshot.downloaded.first(where: { $0.id == id }) else {
                return VoicePlan(action: .none, dialog: "That episode isn't on your phone.")
            }
            return VoicePlan(action: .play(episode.id), dialog: "Playing \(episode.title).")

        case .playLatest(let show):
            return planPlayLatest(show: show, snapshot: snapshot)

        case .pause:
            if let nowPlaying = snapshot.nowPlaying, nowPlaying.isPlaying {
                return VoicePlan(action: .pause, dialog: "Paused.")
            } else {
                return VoicePlan(action: .none, dialog: "Nothing is playing.")
            }

        case .resume:
            guard let nowPlaying = snapshot.nowPlaying else {
                return VoicePlan(action: .none, dialog: "Nothing to resume.")
            }
            if nowPlaying.isPlaying {
                return VoicePlan(action: .none, dialog: "Already playing.")
            } else {
                return VoicePlan(action: .resume, dialog: "Resuming \(nowPlaying.episode.title).")
            }

        case .skipForward:
            if snapshot.nowPlaying != nil {
                return VoicePlan(action: .skipForward, dialog: "Skipped forward.")
            } else {
                return VoicePlan(action: .none, dialog: "Nothing is playing.")
            }

        case .skipBack:
            if snapshot.nowPlaying != nil {
                return VoicePlan(action: .skipBack, dialog: "Skipped back.")
            } else {
                return VoicePlan(action: .none, dialog: "Nothing is playing.")
            }

        case .restart:
            if snapshot.nowPlaying != nil {
                return VoicePlan(action: .restart, dialog: "Starting over.")
            } else {
                return VoicePlan(action: .none, dialog: "Nothing is playing.")
            }

        case .markCompleted:
            guard let nowPlaying = snapshot.nowPlaying else {
                return VoicePlan(action: .none, dialog: "Nothing is playing.")
            }
            if nowPlaying.canMarkCompleted {
                return VoicePlan(
                    action: .markCompleted(nowPlaying.episode.id),
                    dialog: "Mark \(nowPlaying.episode.title) completed?",
                    needsConfirmation: true
                )
            } else {
                return VoicePlan(action: .none, dialog: "I can't mark that completed yet.")
            }

        case .whatsPlaying:
            guard let nowPlaying = snapshot.nowPlaying else {
                return VoicePlan(action: .none, dialog: "Nothing is playing.")
            }
            if nowPlaying.episode.showTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return VoicePlan(action: .none, dialog: "\(nowPlaying.episode.title).")
            } else {
                return VoicePlan(action: .none, dialog: "\(nowPlaying.episode.title), from \(nowPlaying.episode.showTitle).")
            }

        case .listDownloaded:
            let count = snapshot.downloaded.count
            if count == 0 {
                return VoicePlan(action: .none, dialog: "No episodes are on your phone.")
            }
            let prefixCount = min(count, spokenTitleLimit)
            var titles = snapshot.downloaded.prefix(prefixCount).map(\.title)
            if count > spokenTitleLimit {
                let remaining = count - spokenTitleLimit
                titles.append("and \(remaining) more")
            }
            let listString = titles.joined(separator: ", ")
            let countString = count == 1 ? "1 episode" : "\(count) episodes"
            return VoicePlan(action: .none, dialog: "\(countString) on your phone: \(listString).")

        case .timeLeft:
            return planTimeLeft(snapshot: snapshot)

        case .setSpeed(let rate):
            return planSetSpeed(rate, snapshot: snapshot)

        case .sleepTimer(let request):
            return planSleepTimer(request, snapshot: snapshot)
        }
    }

    /// The downloaded episodes a command may pick from, or the plan that explains why none can be.
    private enum Candidates {
        case episodes([VoiceEpisode])
        case stop(VoicePlan)
    }

    private static func candidates(show: String?, snapshot: VoiceSnapshot) -> Candidates {
        guard let show else {
            if snapshot.downloaded.isEmpty {
                return .stop(VoicePlan(action: .none, dialog: "No episodes are on your phone."))
            }
            return .episodes(snapshot.downloaded)
        }
        switch VoiceShowMatcher.match(show, among: snapshot.knownShowTitles) {
        case .none:
            return .stop(VoicePlan(action: .none, dialog: "I can't find a show called \(show)."))
        case .ambiguous(let titles):
            return .stop(VoicePlan(action: .none, dialog: "Did you mean \(titles[0]) or \(titles[1])?"))
        case .match(let matched):
            let episodes = snapshot.downloaded.filter { sameShow($0.showTitle, matched) }
            if episodes.isEmpty {
                return .stop(VoicePlan(action: .none, dialog: "No \(matched) episodes are on your phone."))
            }
            return .episodes(episodes)
        }
    }

    private static func planPlayEpisode(title: String, show: String?, snapshot: VoiceSnapshot) -> VoicePlan {
        let episodes: [VoiceEpisode]
        switch candidates(show: show, snapshot: snapshot) {
        case .stop(let plan): return plan
        case .episodes(let found): episodes = found
        }
        switch VoiceShowMatcher.match(title, among: episodes.map(\.title)) {
        case .none:
            return VoicePlan(action: .none, dialog: "I can't find an episode called \(title) on your phone.")
        case .ambiguous(let titles):
            return VoicePlan(action: .none, dialog: "Did you mean \(titles[0]) or \(titles[1])?")
        case .match(let matched):
            guard let episode = episodes.first(where: { $0.title == matched }) else {
                return VoicePlan(action: .none, dialog: "I can't find an episode called \(title) on your phone.")
            }
            return VoicePlan(action: .play(episode.id), dialog: "Playing \(episode.title).")
        }
    }

    private static func planPlayLatest(show: String?, snapshot: VoiceSnapshot) -> VoicePlan {
        let episodes: [VoiceEpisode]
        switch candidates(show: show, snapshot: snapshot) {
        case .stop(let plan): return plan
        case .episodes(let found): episodes = found
        }
        // A scan, not `max(by:)`, which returns the last maximum: a tie keeps the earlier Larder row.
        var latest = episodes[0]
        for episode in episodes.dropFirst() where episode.publishedAt > latest.publishedAt {
            latest = episode
        }
        return VoicePlan(action: .play(latest.id), dialog: "Playing \(latest.title).")
    }

    private static func sameShow(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
