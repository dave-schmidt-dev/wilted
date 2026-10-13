import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

extension WiltedMacModel {
    func episodeInfoSource(id: String, showTitle: String?) -> WiltedMacEpisodeInfoSource {
#if canImport(WiltedProducer)
        if fixtureMode, let fixture = fixtureEpisodeInfoSource(id: id, showTitle: showTitle) { return fixture }
#endif
        return WiltedMacEpisodeInfoSource(
            loadInfo: { [self] in await episodeInfo(id: id, showTitle: showTitle) },
            loadTranscript: { [self] in await savedTranscript(forEpisodeID: id) }
        )
    }

    func savedTranscript(forEpisodeID rawID: String) async -> WiltedMacEpisodeTranscriptLoad {
#if canImport(WiltedProducer)
        guard let store, let itemID = try? ItemID(rawValue: rawID) else { return .failed }
        do {
            guard let stored = try await store.latestTranscript(for: itemID) else { return .none }
            return .loaded(WiltedMacTranscript(stored: stored))
        } catch {
            return .failed
        }
#else
        return .failed
#endif
    }

    func episodeInfo(id rawID: String, showTitle: String?) async -> WiltedMacEpisodeInfoLoad {
        if let episode = episodes.first(where: { $0.id == rawID }) {
            return .loaded(WiltedMacEpisodeInfo(episode: episode))
        }
#if canImport(WiltedProducer)
        guard let store, let itemID = try? ItemID(rawValue: rawID) else { return .failed }
        do {
            guard let stored = try await store.podcastEpisode(for: itemID) else { return .notFound }
            return .loaded(WiltedMacEpisodeInfo(stored: stored, showTitle: showTitle))
        } catch {
            return .failed
        }
#else
        return .notFound
#endif
    }
}
