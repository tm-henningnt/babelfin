import Foundation
import CoreAudio
import AudioToolbox
import BridgeCore

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let transport: UInt32
    /// Babelfin's bundled loopback devices, keyed by the device UIDs their drivers publish.
    static let babelfinMicrophoneUID = "Babelfin Microphone_UID"
    static let babelfinSpeakerUID = "Babelfin Speaker_UID"
    /// A loopback device: BlackHole, or one of Babelfin's bundled BlackHole-derived devices.
    var isBlackHole: Bool {
        uid == Self.babelfinMicrophoneUID || uid == Self.babelfinSpeakerUID
            || (uid.lowercased().contains("blackhole") && name.lowercased().contains("blackhole"))
    }
    var isPhysical: Bool {
        !isBlackHole && transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate
    }
    var isPhysicalInput: Bool { inputChannels > 0 && isPhysical }
    var endpoint: AudioEndpoint {
        AudioEndpoint(uid: uid, inputChannels: inputChannels, outputChannels: outputChannels,
                      kind: isBlackHole ? .blackHole : (isPhysical ? .physical : .other))
    }
}

/// Devices that Babelfin selects when a direction has no saved device.
/// A saved device, also an unavailable one, always takes precedence.
enum DefaultAudioDevice {
    /// Speak output: Babelfin Microphone, else the only two-channel loopback.
    /// Babelfin Speaker belongs to Listen, so it is never a candidate here.
    static func outgoingOutput(from outputs: [AudioDevice]) -> String? {
        let candidates = outputs.filter {
            $0.isBlackHole && $0.inputChannels == 2 && $0.outputChannels == 2 && $0.uid != AudioDevice.babelfinSpeakerUID
        }
        if candidates.contains(where: { $0.uid == AudioDevice.babelfinMicrophoneUID }) { return AudioDevice.babelfinMicrophoneUID }
        return candidates.count == 1 ? candidates[0].uid : nil
    }
    /// Listen source: Babelfin Speaker only. Another loopback can carry Speak.
    static func incomingSource(from inputs: [AudioDevice]) -> String? {
        inputs.contains { $0.uid == AudioDevice.babelfinSpeakerUID && $0.inputChannels > 0 } ? AudioDevice.babelfinSpeakerUID : nil
    }
}

extension Notification.Name {
    static let babelfinAudioDevicesChanged = Notification.Name("BabelfinAudioDevicesChanged")
}

struct AudioDeviceObservation: Sendable {
    let update: @Sendable ([AudioDevice]) -> Void
    let cancel: @Sendable () -> Void
}

/// Enumeration and HAL callbacks stay on a dedicated serial queue. Readers only copy a snapshot.
final class AudioDeviceInventory: @unchecked Sendable {
    static let shared = AudioDeviceInventory(load: { AudioDevices.all() }, observe: { queue, changed in
        let observation = HALDeviceObservation(queue: queue, changed: changed)
        return AudioDeviceObservation(update: { observation.update($0) }, cancel: { observation.stop() })
    })
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Babelfin.device-inventory")
    private let load: @Sendable () -> [AudioDevice]
    private var devices: [AudioDevice] = []
    private var pending = false
    private var stopped = false
    private var observation: AudioDeviceObservation?
    init(load: @escaping @Sendable () -> [AudioDevice],
         observe: (@Sendable (DispatchQueue, @escaping @Sendable () -> Void) -> AudioDeviceObservation)? = nil) {
        self.load = load
        observation = observe?(queue, { [weak self] in self?.refresh() })
        refresh()
    }
    var snapshot: [AudioDevice] { lock.lock(); defer { lock.unlock() }; return devices }
    func refresh() {
        lock.lock()
        guard !stopped, !pending else { lock.unlock(); return }
        pending = true; lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending = false
            let live = !self.stopped; self.lock.unlock()
            guard live else { return }
            let next = self.load()
            self.lock.lock()
            guard !self.stopped else { self.lock.unlock(); return }
            let changed = next != self.devices
            self.devices = next
            let observation = self.observation; self.lock.unlock()
            if changed { observation?.update(next) }
            if changed { NotificationCenter.default.post(name: .babelfinAudioDevicesChanged, object: self) }
        }
    }
    func stop() {
        lock.lock(); stopped = true; devices = []; let observation = observation; self.observation = nil; lock.unlock()
        observation?.cancel()
    }
    deinit { observation?.cancel() }
}

/// Owns exact listener blocks/addresses so registration and removal are paired.
private final class HALDeviceObservation: @unchecked Sendable {
    private let queue: DispatchQueue
    private let changed: @Sendable () -> Void
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var stopped = false
    init(queue: DispatchQueue, changed: @escaping @Sendable () -> Void) {
        self.queue = queue; self.changed = changed
        queue.async { [weak self] in self?.install([]) }
    }
    /// This callback is passed directly to one inventory; unrelated inventory publications cannot reach it.
    func update(_ devices: [AudioDevice]) {
        queue.async { [weak self] in self?.install(devices) }
    }

    private func install(_ devices: [AudioDevice]) {
        guard !stopped else { return }
        remove()
        add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        for device in devices {
            for selector in [kAudioDevicePropertyDeviceUID, kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyTransportType, kAudioObjectPropertyName, kAudioDevicePropertyNominalSampleRate] {
                add(device.id, selector)
            }
            add(device.id, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
            add(device.id, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        }
    }
    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            self.changed()

        }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr { registrations.append((object, address, block)) }
    }
    private func remove() {
        for (object, var address, block) in registrations { AudioObjectRemovePropertyListenerBlock(object, &address, queue, block) }
        registrations.removeAll()
    }
    func stop() {
        queue.async { self.stopped = true; self.remove() }
    }
}

enum AudioDevices {
    static func cached() -> [AudioDevice] { AudioDeviceInventory.shared.snapshot }

    static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.compactMap { id -> AudioDevice? in
            guard number(id, kAudioDevicePropertyDeviceIsAlive) == 1 else { return nil }
            let device = AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                        inputChannels: channels(id, kAudioDevicePropertyScopeInput), outputChannels: channels(id, kAudioDevicePropertyScopeOutput),
                        transport: number(id, kAudioDevicePropertyTransportType))
            guard !device.uid.isEmpty, device.uid != "Unknown", device.transport != 0 else { return nil }
            return device
        }.sorted { $0.name < $1.name }
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let result = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        result.initialize(to: nil)
        defer { result.deinitialize(count: 1); result.deallocate() }
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, result) == noErr,
              let value = result.pointee else { return "Unknown" }
        return value as String
    }
    private static func number(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result)
        return result
    }
    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func select(_ device: AudioDeviceID, on unit: AudioUnit?) throws {
        guard let unit else { throw BridgeError.unavailable("Audio device could not be opened.") }
        var id = device
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw BridgeError.unavailable("Could not select audio device. Reconnect it and refresh devices.")
        }
    }
    static func selected(on unit: AudioUnit?) -> AudioDeviceID? {
        guard let unit else { return nil }
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr else { return nil }
        return device
    }
}
