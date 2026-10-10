import Foundation
import Observation
import CoreLocation
import CoreWLAN
import AppKit
import os

/// A position rounded to two decimals (about 1 km) before anything else sees it.
struct WiltedCoordinates: Equatable, Sendable, Codable {
    let latitude: Double
    let longitude: Double

    /// Rounds to 2 decimals; nil for non-finite or out-of-range values.
    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else { return nil }
        self.latitude = (latitude * 100).rounded() / 100
        self.longitude = (longitude * 100).rounded() / 100
    }
}

/// What Settings shows. Located means a Core Location fix taken while Wi-Fi was on.
enum WiltedLocationStatus: String, Equatable, Sendable {
    case none, denied, noFix, typed, located
}

/// Why a status is what it is, for the Settings caption.
enum WiltedLocationDetail: Equatable, Sendable {
    case notRequested, permissionDenied, wifiOff, fixFailed, fixDiscardedWifiOff, usingTyped, fixAccepted
}

enum WiltedLocationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized
}

/// The Core Location surface the provider needs; tests inject a fake.
@MainActor
protocol WiltedLocationManaging: AnyObject {
    var authorization: WiltedLocationAuthorization { get }
    var onAuthorizationChange: (() -> Void)? { get set }
    var onFix: ((_ latitude: Double, _ longitude: Double) -> Void)? { get set }
    var onFailure: (() -> Void)? { get set }
    func requestPermission()
    func requestOneFix()
}

/// Whether the Wi-Fi interface is powered on (CoreWLAN in production).
@MainActor
protocol WiltedWiFiPowerReading: AnyObject {
    var isPoweredOn: Bool { get }
}

/// Mac location for weather alerts. Coordinates live in memory only; the typed
/// fallback is owned by the settings file and passed in through `typedCoordinates`.
///
/// Provenance fails closed. Apple's Mac help says Mac location comes from nearby Wi-Fi
/// information and offers no guarantee against IP-derived fixes (b64-api-facts.json
/// id 7, fetched 2026-10-10), so a fix counts only while the Wi-Fi interface is on, both
/// when asked for and when delivered. Horizontal accuracy is never treated as proof of
/// source. Reduced accuracy is requested through the manager (the plist default key is
/// undocumented on macOS, id 6) and results are rounded to 2 decimals here.
@MainActor
@Observable
final class WiltedLocationProvider {
    /// Apple documents macOS location as Wi-Fi based (b64-api-facts.json id 7). If this
    /// were false the provider would use typed coordinates only.
    static let wifiBasisDocumented = true
    static let wakeRefreshInterval: TimeInterval = 3600

    private(set) var status: WiltedLocationStatus = .none
    private(set) var detail: WiltedLocationDetail = .notRequested
    /// Located (in memory) or typed coordinates to use; nil when status is none, denied or noFix.
    private(set) var coordinates: WiltedCoordinates?

    var typedCoordinates: WiltedCoordinates? {
        didSet { if oldValue != typedCoordinates { reevaluate() } }
    }

    @ObservationIgnored private let manager: WiltedLocationManaging
    @ObservationIgnored private let wifi: WiltedWiFiPowerReading
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let logger = Logger(subsystem: "com.zerodelta.wilted.mac", category: "location")
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var awaitingFix = false
    @ObservationIgnored private var wakeObserver: (token: NSObjectProtocol, center: NotificationCenter)?

    init(manager: WiltedLocationManaging, wifi: WiltedWiFiPowerReading,
         typedCoordinates: WiltedCoordinates? = nil, now: @escaping () -> Date = Date.init) {
        self.manager = manager
        self.wifi = wifi
        self.typedCoordinates = typedCoordinates
        self.now = now
        manager.onAuthorizationChange = { [weak self] in self?.refresh() }
        manager.onFix = { [weak self] lat, lon in self?.receive(latitude: lat, longitude: lon) }
        manager.onFailure = { [weak self] in self?.fixFailed() }
        settle()
    }

    /// One fix at launch, then at most hourly on wake. Never prompts for permission.
    func start(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        if wakeObserver == nil {
            let token = notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshOnWake() }
            }
            wakeObserver = (token, notificationCenter)
        }
        refresh()
    }

    func stop() {
        if let wakeObserver { wakeObserver.center.removeObserver(wakeObserver.token) }
        wakeObserver = nil
    }

    /// The Settings permission button; the only place the system prompt can start.
    func requestPermission() {
        guard manager.authorization == .notDetermined else { refresh(); return }
        manager.requestPermission()
    }

    /// Asks for one fix when permission is granted and Wi-Fi is on; otherwise settles on typed or none.
    func refresh() {
        awaitingFix = false
        guard Self.wifiBasisDocumented, manager.authorization == .authorized, wifi.isPoweredOn else {
            settle()
            return
        }
        lastAttempt = now()
        awaitingFix = true
        logger.info("Requesting one approximate location fix")
        manager.requestOneFix()
    }

    func refreshOnWake() {
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < Self.wakeRefreshInterval { return }
        refresh()
    }

    // MARK: - Manager callbacks

    private func receive(latitude: Double, longitude: Double) {
        guard awaitingFix else { return }
        awaitingFix = false
        guard wifi.isPoweredOn else {
            logger.info("Discarded a fix received while Wi-Fi was off")
            settle(failure: .fixDiscardedWifiOff)
            return
        }
        guard let fix = WiltedCoordinates(latitude: latitude, longitude: longitude) else {
            fixFailed()
            return
        }
        status = .located
        detail = .fixAccepted
        coordinates = fix
    }

    private func fixFailed() {
        awaitingFix = false
        settle(failure: .fixFailed)
    }

    private func reevaluate() {
        // An accepted fix stays until the next refresh; typed values only fill the gap.
        if status == .located { return }
        settle(failure: detail == .fixFailed || detail == .fixDiscardedWifiOff ? detail : nil)
    }

    /// Typed coordinates are used whenever no accepted fix exists; otherwise report why there is nothing.
    private func settle(failure: WiltedLocationDetail? = nil) {
        if let typedCoordinates {
            status = .typed
            detail = .usingTyped
            coordinates = typedCoordinates
            return
        }
        coordinates = nil
        switch manager.authorization {
        case .denied:
            status = .denied
            detail = .permissionDenied
        case .notDetermined:
            status = .none
            detail = .notRequested
        case .authorized:
            status = .noFix
            detail = failure ?? (wifi.isPoweredOn ? .fixFailed : .wifiOff)
        }
    }
}

// MARK: - Production adapters

@MainActor
final class WiltedCoreLocationManager: NSObject, WiltedLocationManaging, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double) -> Void)?
    var onFailure: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var authorization: WiltedLocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorizedAlways: .authorized
        default: .denied
        }
    }

    func requestPermission() { manager.requestWhenInUseAuthorization() }
    func requestOneFix() { manager.requestLocation() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { onAuthorizationChange?() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { onFailure?(); return }
        onFix?(last.coordinate.latitude, last.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { onFailure?() }
}

@MainActor
final class WiltedCoreWLANPower: WiltedWiFiPowerReading {
    /// No Wi-Fi interface counts as off.
    var isPoweredOn: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }
}
