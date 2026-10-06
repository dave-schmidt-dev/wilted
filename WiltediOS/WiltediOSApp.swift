import SwiftUI
#if DEBUG
@preconcurrency import Intents
import UIKit
#endif

/// Thin launcher: every launch hosts the library list.
/// In DEBUG, `--wilted-library-root-fixture` hosts the same `LibraryRoot` over the deterministic
/// `LibraryUITestFixture` objects, decided before anything reads `LibraryRuntime.shared`.
@main
struct WiltediOSApp: App {
#if DEBUG
    @UIApplicationDelegateAdaptor(WiltediOSDebugAppDelegate.self) private var pushDelegate

    init() {
        if let scenario = LibraryUITestFixture.scenario() {
            LibraryUITestFixture.launch(scenario)
        }
    }
#else
    @UIApplicationDelegateAdaptor(LibraryPushAppDelegate.self) private var pushDelegate
#endif

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let stack = LibraryUITestFixture.stack {
                LibraryUITestFixtureHost(stack: stack)
            } else {
                LibraryRoot()
            }
#else
            LibraryRoot()
#endif
        }
    }
}

#if DEBUG
/// `LibraryPushAppDelegate` for DEBUG builds, except that a production-root fixture launch never
/// registers for remote notifications. Every other call is forwarded unchanged.
/// It must forward every method `LibraryPushAppDelegate` implements (`WiltediOSDebugAppDelegateTests`).
final class WiltediOSDebugAppDelegate: NSObject, UIApplicationDelegate {
    private let push = LibraryPushAppDelegate()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if LibraryUITestFixture.scenario() != nil { return true }
        return push.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await push.application(application, didReceiveRemoteNotification: userInfo)
    }

    func application(
        _ application: UIApplication, handle intent: INIntent, completionHandler: @escaping (INIntentResponse) -> Void
    ) {
        push.application(application, handle: intent, completionHandler: completionHandler)
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        push.application(application, handlerFor: intent)
    }
}
#endif
