import Foundation

/// The defaults domain unit tests hand `WiltedMacModel`.
///
/// The test host is the app bundle, so `UserDefaults.standard` here is the
/// daily driver's own domain; a model built on it once wrote the Larder
/// order a test chose into the owner's preferences. This suite is never the
/// app's and is emptied on every request.
enum WiltedMacTestPreferences {
    static let suite = "com.zerodelta.wilted.mac.tests"

    static func ephemeral() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
