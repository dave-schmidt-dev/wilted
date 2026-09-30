import Foundation

/// The protection class CarPlay depends on: the phone is usually locked in the car, so the
/// audio cache, the library snapshot and play positions must stay readable after the first
/// unlock. `completeUntilFirstUserAuthentication` is the strongest class that allows that;
/// anything stronger would break playback the moment the phone locks.
enum LibraryFileProtection {
    static let readableWhileLocked: FileProtectionType = .completeUntilFirstUserAuthentication

    static let writingOption: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication

    /// Best-effort: protection must never break playback, so a failure to set the class is
    /// ignored rather than thrown.
    static func apply(to url: URL, fileManager: FileManager = .default) {
        try? fileManager.setAttributes([.protectionKey: readableWhileLocked], ofItemAtPath: url.path)
    }
}
