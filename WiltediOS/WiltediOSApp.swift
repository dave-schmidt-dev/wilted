import SwiftUI

/// Thin launcher. Legacy fixture arguments host `LegacyListenerRoot`; every other launch hosts
/// the library list, so no legacy listener model (or its CKSyncEngine) exists in a normal launch.
@main
struct WiltediOSApp: App {
    @UIApplicationDelegateAdaptor(LibraryPushAppDelegate.self) private var pushDelegate

    var body: some Scene {
        WindowGroup {
            if LegacyListenerRoot.isFixtureLaunch() {
                LegacyListenerRoot()
            } else {
                LibraryRoot()
            }
        }
    }
}
