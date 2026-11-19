import OSLog
@preconcurrency import Intents

/// The text of one SiriKit voice routing line. Pure, and compiled into both the app and the Intents
/// extension, so both write the same format.
enum VoiceRoutingLine {
    /// Sends one line to the system log. Lines hold spoken search terms and show names, so they are
    /// readable there only in Development device builds (the ones used for routing drives); every
    /// other build redacts them.
    static func emit(_ line: String, to logger: Logger) {
        #if WILTED_SIRI
        logger.info("\(line, privacy: .public)")
        #else
        logger.info("\(line, privacy: .private)")
        #endif
    }

    static func siriKit(path: String, outcome: String, search: INMediaSearch?, prechosen: Bool) -> String {
        let typeName: String
        if let type = search?.mediaType {
            switch type {
            case .podcastShow: typeName = "podcastShow"
            case .podcastEpisode: typeName = "podcastEpisode"
            case .podcastPlaylist: typeName = "podcastPlaylist"
            case .song: typeName = "song"
            case .album: typeName = "album"
            case .artist: typeName = "artist"
            case .playlist: typeName = "playlist"
            case .unknown: typeName = "unknown"
            default: typeName = "\(type.rawValue)"
            }
        } else {
            typeName = "none"
        }

        let sortName: String
        if let sort = search?.sortOrder {
            switch sort {
            case .newest: sortName = "newest"
            case .recommended: sortName = "recommended"
            case .popular: sortName = "popular"
            case .unknown: sortName = "unknown"
            default: sortName = "\(sort.rawValue)"
            }
        } else {
            sortName = "none"
        }

        let mediaName = search?.mediaName ?? "none"
        let artistName = search?.artistName ?? "none"
        let albumName = search?.albumName ?? "none"

        return "\(path): outcome=\(outcome), mediaType=\(typeName), mediaName=\(mediaName), artistName=\(artistName), albumName=\(albumName), sortOrder=\(sortName), prechosen=\(prechosen)"
    }
}
