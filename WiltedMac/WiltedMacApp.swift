import Foundation
import SwiftUI

@main
struct WiltedMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: WiltedMacModel

    init() {
        _model = State(initialValue: WiltedMacModel(arguments: ProcessInfo.processInfo.arguments))
    }

    var body: some Scene {
        WindowGroup {
            WiltedMacRootView(model: model)
                .task {
                    model.reconcileSyncOnLaunchOrForeground()
                }
        }
        .commands {
            SidebarCommands()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.reconcileSyncOnLaunchOrForeground()
            } else if phase == .background || phase == .inactive {
                model.checkpointForQuit()
            }
        }
    }
}
