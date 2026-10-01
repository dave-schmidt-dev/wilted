@preconcurrency import Intents
import UIKit

/// Routes silent CloudKit pushes to the library model.
///
/// The app root attaches the delegate with
/// `@UIApplicationDelegateAdaptor(LibraryPushAppDelegate.self)`; that is what lets a
/// SwiftUI app register for remote notifications and receive `didReceiveRemoteNotification`.
/// A push that lands before `LibraryRoot` has attached is remembered and replayed on attach.
@MainActor
final class LibraryPushHandler {
    static let shared = LibraryPushHandler()

    private var onSilentPush: (@MainActor () async -> Bool)?
    private var pushWaiting = false

    /// Installs the fetch to run on a silent push; replays one that arrived early.
    func attach(_ onSilentPush: @escaping @MainActor () async -> Bool) {
        self.onSilentPush = onSilentPush
        guard pushWaiting else { return }
        pushWaiting = false
        Task { _ = await onSilentPush() }
    }

    /// Runs the fetch a silent push asks for and reports whether anything changed.
    func receiveSilentPush() async -> UIBackgroundFetchResult {
        guard let onSilentPush else {
            pushWaiting = true
            return .noData
        }
        return await onSilentPush() ? .newData : .noData
    }
}

/// Registers for remote notifications and forwards silent pushes to `LibraryPushHandler`.
final class LibraryPushAppDelegate: NSObject, UIApplicationDelegate {
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
        await LibraryPushHandler.shared.receiveSilentPush()
    }

    /// The Intents extension answers `.handleInApp`; the app then plays the request itself, so playback
    /// runs in the app (an extension's lifespan is short), through the shared player.
    func application(
        _ application: UIApplication, handle intent: INIntent, completionHandler: @escaping (INIntentResponse) -> Void
    ) {
        guard let play = intent as? INPlayMediaIntent else {
            completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        nonisolated(unsafe) let complete = completionHandler
        Task { complete(await PlayMediaIntentHandler().handle(intent: play)) }
    }

    /// SiriKit media requests are also handled in the app itself when no extension is in the way.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaIntentHandler() : nil
    }
}
