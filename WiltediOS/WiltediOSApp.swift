import Foundation
import SwiftUI
import WiltedListener

@main
struct WiltediOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = WiltedListenerAppModel.makeDefault()

    var body: some Scene {
        WindowGroup {
            let fixture = WiltedPreviewFixture.fromLaunchArguments(ProcessInfo.processInfo.arguments)
            let fixtureMode = ProcessInfo.processInfo.arguments.contains("--wilted-ui-smoke")
                || ProcessInfo.processInfo.arguments.contains("--wilted-ui-fixture-playing")
            WiltedRootView(
                fixture: fixture,
                iOSLibrary: fixtureMode
                    ? AnyView(WiltedLibraryShell(fixture: fixture))
                    : AnyView(WiltedListenerLibraryView(model: model)),
                iOSDownloads: fixtureMode
                    ? AnyView(WiltedDownloadsShell())
                    : AnyView(WiltedListenerDownloadsView(model: model))
            )
            .onAppear { Task { await model.install(remoteCommands: MediaPlayerRemoteCommands()) } }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .background: await model.enterBackground()
                case .active: await model.resumeForeground()
                default: break
                }
            }
        }
    }
}
