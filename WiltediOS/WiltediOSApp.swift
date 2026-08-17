import Foundation
import SwiftUI

@main
struct WiltediOSApp: App {
    var body: some Scene {
        WindowGroup {
            WiltedRootView(
                fixture: WiltedPreviewFixture.fromLaunchArguments(ProcessInfo.processInfo.arguments)
            )
        }
    }
}
