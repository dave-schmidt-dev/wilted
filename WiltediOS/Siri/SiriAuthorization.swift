@preconcurrency import Intents

/// SiriKit authorization, asked once from the phone (never from CarPlay): Siri cannot reach the app's
/// `INPlayMediaIntent` handler until the user allows it, and the system prompt shows
/// `NSSiriUsageDescription`. Only builds that carry the Siri entitlement (`WILTED_SIRI`, the
/// Development configuration) ask; without the entitlement the request would just fail.
enum SiriAuthorization {
    static func requestIfNeeded() {
        #if WILTED_SIRI
        guard INPreferences.siriAuthorizationStatus() == .notDetermined else { return }
        INPreferences.requestSiriAuthorization { _ in }
        #endif
    }
}
