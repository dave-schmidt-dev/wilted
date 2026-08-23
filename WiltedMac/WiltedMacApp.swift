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
            Group {
                if usesStaticFixture {
                    WiltedRootView(
                        fixture: WiltedPreviewFixture.fromLaunchArguments(ProcessInfo.processInfo.arguments)
                    )
                } else {
                    WiltedMacRootView(model: model)
                }
            }
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

    private var usesStaticFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--wilted-ui-smoke")
            || arguments.contains("--wilted-ui-fixture-ready") && !arguments.contains("--wilted-ui-fixture-article-flow")
            || arguments.contains("--wilted-ui-fixture-playing") && !arguments.contains("--wilted-ui-fixture-article-flow")
    }
}
