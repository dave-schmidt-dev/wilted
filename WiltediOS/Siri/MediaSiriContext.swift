import Combine
import Foundation
@preconcurrency import Intents
import WiltedDomain
import WiltedLibrary

/// The part of SiriKit the media context uses, so tests can record instead of touching the system.
@MainActor
protocol MediaSiriContextServing: AnyObject {
    func setNumberOfLibraryItems(_ count: Int)
    func setVocabularyStrings(_ showTitles: [String])
}

@MainActor
final class SystemMediaSiriContext: MediaSiriContextServing {
    func setNumberOfLibraryItems(_ count: Int) {
        #if WILTED_SIRI
        let context = INMediaUserContext()
        context.numberOfLibraryItems = count
        context.becomeCurrent()
        #endif
    }

    func setVocabularyStrings(_ showTitles: [String]) {
        #if WILTED_SIRI
        let set = NSOrderedSet(array: showTitles)
        INVocabulary.shared().setVocabularyStrings(set, of: .mediaShowTitle)
        #endif
    }
}

/// Keeps SiriKit informed of the phone's downloaded episode count (via INMediaUserContext)
/// and the known show titles (via INVocabulary), so Siri's App Selection knows Wilted has content
/// and recognizes spoken show names.
@MainActor
final class MediaSiriContext {
    static let shared = MediaSiriContext()

    private let service: any MediaSiriContextServing
    private var lastCount: Int?
    private var lastShows: [String]?

    init(service: any MediaSiriContextServing = SystemMediaSiriContext()) {
        self.service = service
    }

    func update(downloadedCount: Int, showTitles: [String]) {
        if lastCount != downloadedCount {
            lastCount = downloadedCount
            service.setNumberOfLibraryItems(downloadedCount)
        }
        if lastShows != showTitles {
            lastShows = showTitles
            service.setVocabularyStrings(showTitles)
        }
    }

    func observe(_ model: LibraryAppModel) -> AnyCancellable {
        // Until the saved library has loaded the model is empty, and telling Siri "no episodes, no
        // shows" at every launch would wipe what it knew.
        model.$queued.combineLatest(model.$media, model.$localStateLoaded)
            .filter { queued, _, loaded in loaded || !queued.isEmpty }
            .sink { [weak self] queued, media, _ in
                MainActor.assumeIsolated {
                    let downloadedCount = queued.filter { media[$0.id] == .onPhone }.count
                    var seen = Set<String>()
                    let showTitles = queued.map(\.showTitle).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                    self?.update(downloadedCount: downloadedCount, showTitles: showTitles)
                }
            }
    }

    static func observe(_ model: LibraryAppModel, context: MediaSiriContext = MediaSiriContext.shared) -> AnyCancellable {
        context.observe(model)
    }
}
