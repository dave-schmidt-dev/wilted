import CoreLocation
import Foundation

/// What Settings shows for this iPhone's weather-alert location.
enum LibraryLocationStatus: Equatable, Sendable {
    /// Alerts are off, permission has not been asked, or no fix has arrived yet.
    case none
    /// The user declined (or restrictions forbid) location, so alerts pause.
    case denied
    /// The newest fix is older than 24 hours and is not used, so alerts pause.
    case stale
    case located
}

enum LibraryLocationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized
}

/// An approximate position, rounded to 2 decimals (about 1 km), with the time it was taken.
/// Held in memory only; never written to disk.
struct LibraryLocationFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let fixedAt: Date
}

/// The slice of `CLLocationManager` the provider needs, so tests inject a fake and never
/// trigger a real permission prompt.
@MainActor
protocol LibraryLocationManaging: AnyObject {
    var authorization: LibraryLocationAuthorization { get }
    var onAuthorizationChange: (() -> Void)? { get set }
    var onFix: ((_ latitude: Double, _ longitude: Double, _ at: Date) -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func requestOneShotFix()
}

/// Location for weather alerts on the phone: When In Use, approximate accuracy, asked only when
/// the user turns alerts on for this iPhone. Fixes are one-shot and only taken in the foreground
/// (app becomes active, or playback starts while the app is in front). While playing in the
/// background the cached fix is used. iOS does not document `requestLocation` for an app that is
/// only playing audio (b64 facts, item 9), so no background fix is attempted and no background
/// location mode exists.
@MainActor
final class LibraryLocationProvider {
    /// A cached fix older than this is not used.
    static let maximumFixAge: TimeInterval = 24 * 60 * 60

    private let manager: LibraryLocationManaging
    private let now: () -> Date
    private(set) var alertsEnabled = false
    private var cachedFix: LibraryLocationFix?
    private var fixRequestInFlight = false

    init(manager: LibraryLocationManaging, now: @escaping () -> Date = Date.init) {
        self.manager = manager
        self.now = now
        manager.onAuthorizationChange = { [weak self] in self?.authorizationChanged() }
        manager.onFix = { [weak self] latitude, longitude, at in self?.received(latitude, longitude, at) }
        manager.onFailure = { [weak self] in self?.fixRequestInFlight = false }
    }

    /// The fix to use now, or nil when there is none or it is older than 24 hours.
    var currentFix: LibraryLocationFix? {
        guard alertsEnabled, let fix = cachedFix, isFresh(fix) else { return nil }
        return fix
    }

    var status: LibraryLocationStatus {
        guard alertsEnabled else { return .none }
        switch manager.authorization {
        case .denied: return .denied
        case .notDetermined: return .none
        case .authorized: break
        }
        guard let fix = cachedFix else { return .none }
        return isFresh(fix) ? .located : .stale
    }

    /// The user turned weather alerts on (or off) for this iPhone. Permission is requested here
    /// and nowhere else; turning alerts off drops the in-memory fix.
    func setAlertsEnabled(_ enabled: Bool, appIsActive: Bool = true) {
        alertsEnabled = enabled
        guard enabled else {
            cachedFix = nil
            fixRequestInFlight = false
            return
        }
        switch manager.authorization {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorized: if appIsActive { requestFix() }
        case .denied: break
        }
    }

    /// The app came to the foreground.
    func appBecameActive() { requestFix() }

    /// Playback started. Only a foreground start takes a fix; a background start uses the cache.
    func playbackStarted(inForeground: Bool) { if inForeground { requestFix() } }

    private func authorizationChanged() {
        guard alertsEnabled, manager.authorization == .authorized else { return }
        requestFix()
    }

    private func requestFix() {
        guard alertsEnabled, manager.authorization == .authorized, !fixRequestInFlight else { return }
        fixRequestInFlight = true
        manager.requestOneShotFix()
    }

    private func received(_ latitude: Double, _ longitude: Double, _ at: Date) {
        fixRequestInFlight = false
        guard alertsEnabled else { return }
        let fix = LibraryLocationFix(latitude: Self.round2(latitude), longitude: Self.round2(longitude), fixedAt: at)
        if let held = cachedFix, held.fixedAt > fix.fixedAt { return }
        cachedFix = fix
    }

    private func isFresh(_ fix: LibraryLocationFix) -> Bool {
        now().timeIntervalSince(fix.fixedAt) <= Self.maximumFixAge
    }

    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

/// The live manager. Reduced accuracy comes from `NSLocationDefaultAccuracyReduced` in Info.plist.
@MainActor
final class LibraryCoreLocationManager: NSObject, LibraryLocationManaging, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double, Date) -> Void)?
    var onFailure: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var authorization: LibraryLocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        default: return .denied
        }
    }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestOneShotFix() { manager.requestLocation() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onAuthorizationChange?() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let (latitude, longitude, at) = (location.coordinate.latitude, location.coordinate.longitude, location.timestamp)
        Task { @MainActor in self.onFix?(latitude, longitude, at) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.onFailure?() }
    }
}
