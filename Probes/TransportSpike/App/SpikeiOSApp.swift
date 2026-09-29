import SpikeCloudKit
import SwiftUI
import UIKit

/// iPhone spike host: observes the handoff checkpoint and runs the transfer matrix.
@main
struct SpikeiOSApp: App {
    @UIApplicationDelegateAdaptor(SpikeiOSDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            SpikeRunnerView(runner: SpikeRunner.shared, role: .observer)
        }
    }
}

final class SpikeiOSDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await SpikeRunner.shared.handlePush()
        return .newData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in SpikeRunner.shared.log("push registration failed: \(error)") }
    }
}
