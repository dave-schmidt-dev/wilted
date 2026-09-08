import AppKit
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
                // The only quit hook there is. Scene phase reports that the
                // windows went away, which is not the same event and must not
                // stop the audio, so termination is observed separately.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    model.pauseForQuit()
                }
                .onAppear {
                    if WiltedMacModel.isFixtureLaunch(arguments: ProcessInfo.processInfo.arguments) {
                        Self.placeFixtureWindowOnPrimaryScreen()
                    }
                }
        }
        .commands {
            SidebarCommands()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.reconcileSyncOnLaunchOrForeground()
                // Symmetric with the checkpoint below. Hiding the app
                // checkpoints and stops the ticker, and without this a window
                // left open past the first focus dip would never tick again for
                // the rest of the process, which is the one case the ticker
                // exists for. It is idempotent and guarded on a loaded store, so
                // an early .active before bootstrap does nothing and launch
                // still starts it.
                model.startAutomationTicker()
            } else if phase == .background || phase == .inactive {
                model.checkpointForBackground()
            }
        }
    }

    /// Puts a fixture run's window wholly on the screen that owns the menu bar.
    ///
    /// Measured 2026-09-07 on a three-display Mac: the fixture window opened at
    /// `(-1280, -399, 1280, 705)`, straddling a display boundary, and every
    /// control in the bottom rail reported `isHittable == false` while
    /// `isEnabled == true` -- XCUITest cannot click a point that is not on a
    /// display, so the walkthrough capture failed on where the window landed
    /// rather than on anything the app drew. The primary screen is
    /// `NSScreen.screens.first` and not `NSScreen.main`, which is merely the
    /// screen holding the key window and so is exactly the wrong one here.
    ///
    /// Fixture-only, for the same reason a fixture gets its own defaults domain
    /// and state directory: the owner's own window placement is theirs.
    private static func placeFixtureWindowOnPrimaryScreen() {
        guard let window = NSApplication.shared.windows.first,
              let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin = CGPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        )
        window.setFrame(frame, display: true)
    }
}
