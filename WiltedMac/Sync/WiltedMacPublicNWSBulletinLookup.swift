import Foundation
import WiltedLibrary
import WiltedWeather

/// Resolves a phone-local weather alert by its public NWS identity. The request carries only
/// that identity; this adapter never reads or forwards the phone's location or alert text.
struct WiltedMacPublicNWSBulletinLookup {
    private let client: NWSClient
    private let now: @Sendable () -> Date

    init(transport: any NWSTransport = URLSessionNWSTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        client = NWSClient(
            transport: transport,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            repositoryURL: "https://github.com/dave-schmidt-dev/wilted",
            contact: nil,
            now: now)
    }

    /// Returns only the exact, unexpired, narratable NWS alert. Mac-local bulletins should be
    /// checked first; this network lookup is the fallback for alerts created on the phone.
    func bulletin(id: String) async -> Bulletin? {
        guard let alert = try? await client.alert(id: id),
              let bulletin = AlertMonitor.bulletin(for: alert, now: now()),
              bulletin.id == id else { return nil }
        return bulletin
    }
}
