import Foundation

/// Where production code puts disposable scratch files and directories.
enum ScratchParent {
    #if DEBUG
    /// Tests point scratch at their owned root so a concurrent run's temp audit
    /// never sees it in the shared parent.
    nonisolated(unsafe) static var overrideForTesting: URL?
    #endif

    static func url(_ manager: FileManager = .default) -> URL {
        #if DEBUG
        if let override = overrideForTesting { return override }
        #endif
        return manager.temporaryDirectory
    }
}
