import AppKit
import SpikeCloudKit
import SwiftUI

/// Mac spike host: publishes the handoff checkpoint and runs the transfer matrix.
@main
struct SpikeMacApp: App {
    @NSApplicationDelegateAdaptor(SpikeMacDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Transport Spike (Mac)") {
            SpikeRunnerView(runner: SpikeRunner.shared, role: .publisher)
                .frame(minWidth: 640, minHeight: 560)
        }
    }
}

final class SpikeMacDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { @MainActor in await SpikeRunner.shared.handlePush() }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in SpikeRunner.shared.log("push registration failed: \(error)") }
    }
}
