import CoreAudio
import Foundation

/// The physical output identity retained for the entire spoken hold.
public struct MacAudioRoute: Equatable, Sendable {
    public let device: UInt32
    public let source: UInt32?
    public let jackConnected: Bool?
    public let alive: Bool

    public init(device: UInt32, source: UInt32? = nil, jackConnected: Bool? = nil, alive: Bool = true) {
        self.device = device
        self.source = source
        self.jackConnected = jackConnected
        self.alive = alive
    }

    public var isAvailable: Bool { device != kAudioObjectUnknown && alive }
}

/// Registration and synchronous reads are injectable; fixtures never need the owner's audio route.
@MainActor
public protocol MacAudioRouteSource: AnyObject, Sendable {
    var monitoringAvailable: Bool { get }
    func start(changed: @escaping @MainActor () -> Void) -> Bool
    func currentRoute() -> MacAudioRoute?
    func stop()
    /// Whether `device` is still alive and present. A failed read is gone.
    func isDeviceAvailable(_ device: UInt32) -> Bool
}

public extension MacAudioRouteSource {
    var monitoringAvailable: Bool { true }
    func isDeviceAvailable(_ device: UInt32) -> Bool { true }
}

struct MacAudioRouteProperty: Hashable, Sendable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

@MainActor
protocol MacAudioRouteHardware: AnyObject, Sendable {
    func has(_ property: MacAudioRouteProperty) -> Bool
    func read(_ property: MacAudioRouteProperty) -> UInt32?
    func add(_ property: MacAudioRouteProperty, changed: @escaping @Sendable () -> Void) -> UUID?
    func remove(_ token: UUID)
}

/// Watches the default output and its source, jack and liveness. Every removal uses the exact
/// object, address and block registered, including partial registration failure and retargeting.
@MainActor
public final class MacAudioRouteLossObserver: MacAudioRouteSource {
    private let hardware: any MacAudioRouteHardware
    private var listeners: [UUID] = []
    private var deviceListeners: [UUID] = []
    private var device: UInt32?
    private var generation: UInt64 = 0
    private var changed: (@MainActor () -> Void)?
    private var protected = false
    public var monitoringAvailable: Bool { protected }

    public convenience init() { self.init(hardware: CoreAudioRouteHardware()) }
    init(hardware: any MacAudioRouteHardware) { self.hardware = hardware }

    deinit {
        let hardware = hardware
        let tokens = listeners + deviceListeners
        Task { @MainActor in
            for token in tokens { hardware.remove(token) }
        }
    }

    private static let output = MacAudioRouteProperty(
        object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice,
        scope: kAudioObjectPropertyScopeGlobal)
    private static let devices = MacAudioRouteProperty(
        object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices,
        scope: kAudioObjectPropertyScopeGlobal)

    public func start(changed: @escaping @MainActor () -> Void) -> Bool {
        stop()
        self.changed = changed
        let token = generation
        for property in [Self.output, Self.devices] {
            guard let listener = register(property, generation: token) else { stop(); return false }
            listeners.append(listener)
        }
        guard retarget(generation: token) else { stop(); return false }
        protected = true
        return true
    }

    public func currentRoute() -> MacAudioRoute? {
        guard protected, let id = hardware.read(Self.output), id != kAudioObjectUnknown else { return nil }
        let alive = property(id, kAudioDevicePropertyDeviceIsAlive)
        guard let live = hardware.read(alive) else { return nil }
        let source = property(id, kAudioDevicePropertyDataSource, output: true)
        let jack = property(id, kAudioDevicePropertyJackIsConnected, output: true)
        let hasSource = hardware.has(source), hasJack = hardware.has(jack)
        let sourceValue = hasSource ? hardware.read(source) : nil
        let jackValue = hasJack ? hardware.read(jack) : nil
        guard (!hasSource || sourceValue != nil), (!hasJack || jackValue != nil) else { return nil }
        return MacAudioRoute(device: id, source: sourceValue, jackConnected: jackValue.map { $0 != 0 }, alive: live != 0)
    }

    public func isDeviceAvailable(_ device: UInt32) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        let alive = property(device, kAudioDevicePropertyDeviceIsAlive)
        guard hardware.has(alive), let value = hardware.read(alive) else { return false }
        return value != 0
    }

    public func stop() {
        generation &+= 1
        protected = false
        changed = nil
        for token in listeners + deviceListeners { hardware.remove(token) }
        listeners = []
        deviceListeners = []
        device = nil
    }

    private func property(_ id: UInt32, _ selector: UInt32, output: Bool = false) -> MacAudioRouteProperty {
        MacAudioRouteProperty(object: id, selector: selector,
                              scope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal)
    }

    private func register(_ property: MacAudioRouteProperty, generation token: UInt64) -> UUID? {
        hardware.add(property) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.changed != nil else { return }
                if !self.retarget(generation: token) { self.protected = false }
                self.changed?()
            }
        }
    }

    private func retarget(generation token: UInt64) -> Bool {
        guard let id = hardware.read(Self.output), id != kAudioObjectUnknown else { return false }
        guard device != id else { return true }
        for listener in deviceListeners { hardware.remove(listener) }
        deviceListeners = []
        device = nil
        for candidate in [property(id, kAudioDevicePropertyDeviceIsAlive),
                          property(id, kAudioDevicePropertyDataSource, output: true),
                          property(id, kAudioDevicePropertyJackIsConnected, output: true)] {
            guard hardware.has(candidate) else { continue }
            guard let listener = register(candidate, generation: token) else {
                for listener in deviceListeners { hardware.remove(listener) }
                deviceListeners = []
                return false
            }
            deviceListeners.append(listener)
        }
        device = id
        return true
    }
}

@MainActor
private final class CoreAudioRouteHardware: MacAudioRouteHardware {
    private var registrations: [UUID: (MacAudioRouteProperty, AudioObjectPropertyListenerBlock)] = [:]

    func has(_ property: MacAudioRouteProperty) -> Bool {
        var address = property.address
        return AudioObjectHasProperty(property.object, &address)
    }

    func read(_ property: MacAudioRouteProperty) -> UInt32? {
        var address = property.address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(property.object, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    func add(_ property: MacAudioRouteProperty, changed: @escaping @Sendable () -> Void) -> UUID? {
        var address = property.address
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        guard AudioObjectAddPropertyListenerBlock(property.object, &address, nil, block) == noErr else { return nil }
        let token = UUID()
        registrations[token] = (property, block)
        return token
    }

    func remove(_ token: UUID) {
        guard let (property, block) = registrations.removeValue(forKey: token) else { return }
        var address = property.address
        AudioObjectRemovePropertyListenerBlock(property.object, &address, nil, block)
    }
}
