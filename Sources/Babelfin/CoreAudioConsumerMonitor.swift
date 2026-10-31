import Foundation
import CoreAudio
import BridgeCore

/// Observes HAL metadata only. It never opens an input stream or starts capture.
/// Active means another process reports input IO using the selected device, not an
/// unmuted meeting. Unknown/unsupported must never be treated as permission to record.
@MainActor final class CoreAudioConsumerMonitor {
    var onChange: (@MainActor @Sendable (ConsumerObservation) -> Void)?
    private var worker: ConsumerObserverWorker?
    private var generation = UUID()
    func start(deviceID: AudioDeviceID) {
        stop()
        let current = generation
        worker = ConsumerObserverWorker(deviceID: deviceID) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.onChange?(value)
            }
        }
    }
    func stop() { generation = UUID(); worker?.stop(); worker = nil }
}

private final class ConsumerObserverWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Babelfin.consumer-observation", qos: .utility)
    private let timer: DispatchSourceTimer
    private let deviceID: AudioDeviceID
    private let callback: @Sendable (ConsumerObservation) -> Void
    private var debounce = ConsumerDebouncer()
    private var last: ConsumerObservation?
    init(deviceID: AudioDeviceID, callback: @escaping @Sendable (ConsumerObservation) -> Void) {
        self.deviceID = deviceID; self.callback = callback
        timer = DispatchSource.makeTimerSource(queue: queue)
        // Bounded polling also reconciles process exits, device changes and HAL reset.
        // No process names, PIDs or device identities are logged or persisted.
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
    }
    func stop() { timer.cancel() }
    deinit { timer.cancel() }
    private func poll() {
        let value = debounce.update(observe(), at: ProcessInfo.processInfo.systemUptime)
        if value != last { last = value; callback(value) }
    }
    private func observe() -> ConsumerObservation {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectHasProperty(system, &address) else { return .unsupported }
        guard let processes: [UInt32] = Self.readList(system, address) else { return .unknown }
        var uncertain = false
        for process in processes {
            guard let pid: Int32 = Self.readScalar(process, Self.address(kAudioProcessPropertyPID)) else { uncertain = true; continue }
            if pid == getpid() { continue }
            guard let running: UInt32 = Self.readScalar(process, Self.address(kAudioProcessPropertyIsRunningInput)) else { uncertain = true; continue }
            guard running != 0 else { continue }
            guard let inputs: [UInt32] = Self.readList(process, Self.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)) else { uncertain = true; continue }
            if ConsumerObservation.matches(processID: pid, ownProcessID: getpid(), runningInput: running != 0,
                                           inputDevices: inputs, selectedDevice: deviceID) { return .active }
        }
        return uncertain ? .unknown : .idle
    }
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func readScalar<T: FixedWidthInteger>(_ object: AudioObjectID, _ requested: AudioObjectPropertyAddress) -> T? {
        var address = requested; var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<T>.size else { return nil }
        return value
    }
    private static func readList(_ object: AudioObjectID, _ requested: AudioObjectPropertyAddress) -> [UInt32]? {
        var address = requested; var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size % 4 == 0, size <= 65_536 else { return nil }
        if size == 0 { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / 4)
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, size % 4 == 0, Int(size) <= values.count * 4 else { return nil }
        return Array(values.prefix(Int(size) / 4))
    }
}
