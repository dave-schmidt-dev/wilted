import Foundation
import SwiftUI

@main
struct WiltedMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: WiltedMacModel

    init() {
        // The system integration is built here and nowhere else. It is
        // process-global state, so the app is the only context in which owning
        // the machine's Now Playing widget and its media keys is correct.
        //
        // A fixture run drives the app with synthetic audio, so it is given
        // neither: a UI test would otherwise leave its episode sitting in the
        // menu bar after the run, with the machine's media keys pointed at a
        // process that has exited.
        //
        // The unit-test host is this same app bundle, so a test run launches
        // this initialiser too. It is excluded for the same reason and one
        // more: the tests drive the daily driver's own library, and publishing
        // it would put whatever the owner was listening to into the menu bar
        // under a process XCTest is about to kill.
        let arguments = ProcessInfo.processInfo.arguments
        let hostsTests = WiltedMacModel.hostsTests
        let ownsSystemPlayback = !hostsTests && !WiltedMacModel.isFixtureLaunch(arguments: arguments)
        _model = State(initialValue: WiltedMacModel(
            arguments: arguments,
            nowPlayingSink: ownsSystemPlayback ? MediaPlayerNowPlayingSink() : nil,
            remoteCommandSource: ownsSystemPlayback ? MediaPlayerRemoteCommandSource() : nil,
            preferences: .standard
        ))
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
                // Symmetric with the stop below. Hiding the app checkpoints and
                // stops the ticker, and without this a window left open past the
                // first focus dip would never tick again for the rest of the
                // process, which is the one case the ticker exists for. It is
                // idempotent and guarded on a loaded store, so an early .active
                // before bootstrap does nothing and launch still starts it.
                model.startAutomationTicker()
            } else if phase == .background || phase == .inactive {
                model.checkpointForQuit()
            }
        }
    }
}
