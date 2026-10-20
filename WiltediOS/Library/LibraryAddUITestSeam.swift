import Foundation
import WiltedCatalog

#if DEBUG
/// DEBUG-only: what the Add sheet's Mac does inside the fixture's pixel scenario, chosen by
/// `--wilted-library-add-mac=ready|old|rejects-no-audio`. The fixture's in-memory Mac neither publishes
/// the actions it applies nor answers intents, so the captures need this stand-in; it is compiled out of
/// release builds and inert outside `--wilted-library-root-scenario=pixel`.
@MainActor
enum LibraryAddUITestSeam {
    enum Mac: String {
        /// Advertises both add actions and never answers: an add stays "Sent to your Mac".
        case ready
        /// Advertises nothing, like a Mac that predates the Add flow.
        case old
        /// Advertises both and refuses every add because the feed has no audio.
        case rejectsNoAudio = "rejects-no-audio"
    }

    static let argumentPrefix = "--wilted-library-add-mac="

    static var mac: Mac? {
        guard LibraryUITestFixture.scenario() == .pixel else { return nil }
        let raw = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(argumentPrefix) }?
            .dropFirst(argumentPrefix.count)
        return raw.flatMap { Mac(rawValue: String($0)) } ?? .ready
    }

    nonisolated static let shows: [PodcastCatalogShow] = [
        PodcastCatalogShow(
            collectionID: 9_001, title: "The Slow Garden", feedURL: URL(string: "https://feeds.example.com/slow-garden.xml")!,
            author: "Field Notes Audio"),
        PodcastCatalogShow(
            collectionID: 9_002, title: "Evening Compost", feedURL: URL(string: "https://feeds.example.com/evening-compost.xml")!,
            author: "Greenhouse Radio"),
        PodcastCatalogShow(
            collectionID: 9_003, title: "Seeds and Stories", feedURL: URL(string: "https://feeds.example.com/seeds.xml")!,
            author: "Open Plot")
    ]
}
#endif
