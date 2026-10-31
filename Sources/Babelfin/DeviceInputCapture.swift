import AVFoundation
import CoreAudio
import BridgeCore

/// Captures from one explicitly selected input device through a device-bound IOProc.
/// AVAudioEngine's input node first opens the system default input; with Bluetooth
/// headsets that switches their profile and disrupts capture on the chosen device.
/// An IOProc bound to the device ID never touches the default input.
final class DeviceInputCapture: @unchecked Sendable {
    let device: AudioDeviceID
    /// The device's first input stream, as delivered to the IOProc.
    let format: AVAudioFormat
    let maximumFrames: AVAudioFrameCount
    private let bytesPerFrame: UInt32
    private var procID: AudioDeviceIOProcID?

    init(device: AudioDeviceID) throws {
        self.device = device
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &description) == noErr,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0, description.mBitsPerChannel == 32,
              description.mSampleRate.isFinite, description.mSampleRate > 0,
              description.mChannelsPerFrame > 0, description.mBytesPerFrame > 0,
              let format = Self.format(for: &description) else {
            throw BridgeError.unavailable("This audio source uses an unsupported format. Choose another source.")
        }
        self.format = format
        bytesPerFrame = description.mBytesPerFrame
        address.mSelector = kAudioDevicePropertyBufferFrameSizeRange
        address.mScope = kAudioObjectPropertyScopeGlobal
        var range = AudioValueRange()
        size = UInt32(MemoryLayout<AudioValueRange>.size)
        let maximum = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &range) == noErr ? range.mMaximum : 4096
        maximumFrames = AVAudioFrameCount(min(16_384, max(512, maximum.isFinite ? maximum : 4096)))
    }
    deinit { stop() }
    /// AVAudioFormat needs an explicit layout above two channels (BlackHole 16ch).
    private static func format(for description: inout AudioStreamBasicDescription) -> AVAudioFormat? {
        guard description.mChannelsPerFrame > 2 else { return AVAudioFormat(streamDescription: &description) }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | description.mChannelsPerFrame) else { return nil }
        return AVAudioFormat(streamDescription: &description, channelLayout: layout)
    }

    /// `receive` runs on the device's real-time IO thread. It receives the first input
    /// stream as a one-buffer list and must only copy.
    func start(_ receive: @escaping (AVAudioFrameCount, UnsafePointer<AudioBufferList>) -> Void) throws {
        guard procID == nil else { return }
        let bytesPerFrame = bytesPerFrame
        var created: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&created, device, nil) { _, input, _, _, _ in
            guard input.pointee.mNumberBuffers > 0 else { return }
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: input.pointee.mBuffers)
            receive(AVAudioFrameCount(single.mBuffers.mDataByteSize / bytesPerFrame), &single)
        }
        guard status == noErr, let created else {
            throw BridgeError.unavailable("Could not open the selected audio source. Reconnect it and refresh devices.")
        }
        guard AudioDeviceStart(device, created) == noErr else {
            AudioDeviceDestroyIOProcID(device, created)
            throw BridgeError.unavailable("Could not start the selected audio source. Reconnect it and refresh devices.")
        }
        procID = created
    }
    /// Returns after the IOProc has stopped; no receive call follows.
    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
    }
    var isRunning: Bool {
        guard procID != nil else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }
    /// Current format of the device's first input stream, for format-change recovery.
    func currentFormatMatches() -> Bool {
        (try? DeviceInputCapture(device: device).format.isEqual(format)) ?? false
    }
}
