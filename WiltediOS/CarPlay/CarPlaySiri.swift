import CarPlay

/// The Siri assistant cell on the car list (a "Siri" row that starts a voice request). Off until
/// the Siri capability is in the App ID and the provisioning profile: without it the cell would
/// open Siri with nothing in Wilted to answer. `CarPlaySourceTests` fails if this is switched on
/// while the entitlements lack `com.apple.developer.siri`.
enum CarPlaySiri {
    static let assistantCellEnabled = false

    /// `CPAssistantCellConfiguration` and the list initializer taking it are iOS 15, so no
    /// availability gate is needed at the iOS 26 floor.
    static func assistantCellConfiguration() -> CPAssistantCellConfiguration? {
        guard assistantCellEnabled else { return nil }
        return CPAssistantCellConfiguration(position: .top, visibility: .always, assistantAction: .playMedia)
    }
}
