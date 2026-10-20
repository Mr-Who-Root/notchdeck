import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// **Where the Mac's sound goes, and how loud**: the system volume, mute, and
/// the output device — speakers, headphones, AirPods, a display — with the
/// choice of another, for the Now Playing card.
///
/// Read and set through Core Audio's public properties, and kept in step with
/// the volume keys and Control Center by listening for changes rather than
/// asking on a timer.
@MainActor
final class AudioOutput: ObservableObject {
    static let shared = AudioOutput()

    struct Device: Identifiable, Equatable {
        var id: AudioDeviceID
        var name: String
        var transport: UInt32

        /// The SF Symbol for the kind of device.
        var symbol: String {
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                let lower = name.lowercased()
                if lower.contains("airpods max") { return "airpodsmax" }
                if lower.contains("airpods pro") { return "airpodspro" }
                if lower.contains("airpods") { return "airpods" }
                if lower.contains("beats") { return "beats.headphones" }
                return "headphones"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
            case kAudioDeviceTransportTypeUSB: return "hifispeaker"
            case kAudioDeviceTransportTypeBuiltIn:
                return name.lowercased().contains("headphone") ? "headphones" : "laptopcomputer"
            default: return "speaker.wave.2"
            }
        }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var currentID: AudioDeviceID = kAudioObjectUnknown
    /// 0–1, or nil when the device has no volume of its own (most displays).
    @Published private(set) var volume: Float?
    @Published private(set) var isMuted = false

    private var running = false
    private var watchedDevice: AudioDeviceID = kAudioObjectUnknown
    private let queue = DispatchQueue.main

    private init() {}

    var current: Device? { devices.first { $0.id == currentID } }

    /// The speaker symbol for the level, as the menu bar draws it.
    var volumeSymbol: String {
        guard let volume, !isMuted, volume > 0 else { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func start() {
        guard !running else { return }
        running = true
        var devicesAddress = Self.address(kAudioHardwarePropertyDevices)
        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue,
                                            systemChanged)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue,
                                            systemChanged)
        reload()
    }

    func stop() {
        guard running else { return }
        running = false
        var devicesAddress = Self.address(kAudioHardwarePropertyDevices)
        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue,
                                               systemChanged)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue,
                                               systemChanged)
        unwatch()
    }

    // MARK: - Changing things

    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard currentID != kAudioObjectUnknown else { return }
        var level = Float32(clamped)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        if AudioObjectSetPropertyData(currentID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level) == noErr {
            volume = clamped
            if clamped > 0, isMuted { setMuted(false) }
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        guard currentID != kAudioObjectUnknown else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        if AudioObjectSetPropertyData(currentID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
            isMuted = muted
        }
    }

    /// Makes the device the Mac's sound output.
    func select(_ device: Device) {
        var id = device.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr {
            Log.usage.error("audio output not switched: \(status, privacy: .public)")
        }
    }

    /// A fixed set of devices, never read: demo mode's, and the tests'.
    func showDemo(devices: [Device], current: AudioDeviceID, volume: Float?) {
        stop()
        self.devices = devices
        currentID = current
        self.volume = volume
        isMuted = false
    }

    // MARK: - Reading

    private lazy var systemChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.reload() }
    }

    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.readLevel() }
    }

    private func reload() {
        devices = Self.outputDevices()
        currentID = Self.defaultOutput()
        if watchedDevice != currentID {
            unwatch()
            watch(currentID)
        }
        readLevel()
    }

    private func readLevel() {
        volume = Self.volume(of: currentID)
        isMuted = Self.isMuted(currentID)
    }

    private func watch(_ device: AudioDeviceID) {
        guard device != kAudioObjectUnknown else { return }
        watchedDevice = device
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeOutput)
            if AudioObjectHasProperty(device, &address) {
                AudioObjectAddPropertyListenerBlock(device, &address, queue, deviceChanged)
            }
        }
    }

    private func unwatch() {
        guard watchedDevice != kAudioObjectUnknown else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(watchedDevice, &address, queue, deviceChanged)
        }
        watchedDevice = kAudioObjectUnknown
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func outputDevices() -> [Device] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasOutput(id), !isHidden(id), let name = name(of: id) else { return nil }
            return Device(id: id, name: name, transport: transport(of: id))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyIsHidden)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func transport(of id: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func volume(of id: AudioDeviceID) -> Float? {
        guard id != kAudioObjectUnknown else { return nil }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return nil }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &level) == noErr else { return nil }
        return Float(level)
    }

    private static func isMuted(_ id: AudioDeviceID) -> Bool {
        guard id != kAudioObjectUnknown else { return false }
        var address = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }
}
