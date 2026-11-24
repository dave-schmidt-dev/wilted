import AppKit
import Foundation

private nonisolated(unsafe) var headlineCatalogStoreKey: UInt8 = 0

extension WiltedMacModel {
    /// One Mac-owned catalog store shared by UI refreshes and the intent applier.
    var headlineCatalogStore: WiltedMacHeadlineCatalogStore {
        if let store = objc_getAssociatedObject(self, &headlineCatalogStoreKey) as? WiltedMacHeadlineCatalogStore {
            return store
        }
        let fileURL = libraryURL.deletingLastPathComponent().appendingPathComponent("headline-catalog.json")
        let store = WiltedMacHeadlineCatalogStore(fileURL: fileURL)
        objc_setAssociatedObject(self, &headlineCatalogStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return store
    }
}
