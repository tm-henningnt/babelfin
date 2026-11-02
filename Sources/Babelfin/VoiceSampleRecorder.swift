import AVFoundation
import BridgeCore

/// Records from one explicitly chosen physical microphone into memory: a voice-creation
/// sample, or a recording for the speech tools. It never selects a default device, never
/// records a loopback, and never writes the audio to disk. Recording stops at the length
/// limit or when the route changes. Capture is bound to the device ID, as in live translation,
/// so the system default input is never opened.
@MainActor final class VoiceSampleRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var level: Float = 0
    @Published private(set) var sample: VoiceSampleBuffer
    @Published private(set) var notice = ""
    private var capture: DeviceInputCapture?
    private var device: AudioDevice?
    private var generation = UUID()
    private var routeWatch: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private let player = VoicePreviewPlayer()

    init(minimumSeconds: Int = VoiceSampleBuffer.minimumSeconds, maximumSeconds: Int = VoiceSampleBuffer.maximumSeconds) {
        sample = VoiceSampleBuffer(minimumSeconds: minimumSeconds, maximumSeconds: maximumSeconds)
    }
    var seconds: Double { sample.seconds }
    var hasSample: Bool { !sample.pcm.isEmpty }

    func start(input: AudioDevice) async {
        stopPlayback()
        guard !recording else { return }
        notice = ""
        guard input.isPhysicalInput else { notice = "Choose a physical microphone. BlackHole and other virtual devices cannot record."; return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { notice = "Allow microphone access in System Settings to record."; return }
        default: notice = "Allow microphone access in System Settings › Privacy & Security › Microphone to record."; return
        }
        sample.discard()
        do {
            let capture = try DeviceInputCapture(device: input.id)
            guard let target = AVAudioFormat(standardFormatWithSampleRate: Double(VoiceSampleBuffer.sampleRate), channels: 1) else {
                throw BridgeError.unavailable("The microphone format is unavailable.")
            }
            let sink = RecorderSink(format: capture.format,
                                    conversion: try CaptureConversion(sourceFormat: capture.format, target: target, loopback: false, packetFrames: 2400))
            let token = UUID(); generation = token
            sink.onConverted = { [weak self] chunks, level in
                Task { @MainActor [weak self] in self?.receive(chunks, level: level, token: token) }
            }
            try capture.start { frames, buffers in sink.copy(frames: frames, buffers: buffers) }
            self.capture = capture; device = input; recording = true
            routeWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, self.generation == token else { return }
                    if !self.routeIntact() { self.fail("The microphone disconnected or changed. Record again."); return }
                }
            }
        } catch {
            notice = (error as? BridgeError)?.localizedDescription ?? "The microphone could not start recording."
        }
    }
    /// Keeps the audio already recorded.
    func stop() {
        generation = UUID()
        routeWatch?.cancel(); routeWatch = nil
        capture?.stop(); capture = nil; device = nil
        recording = false; level = 0
        if hasSample && !sample.meetsMinimum {
            notice = "Record at least \(sample.minimum) seconds of speech."
        }
    }
    func discard() { stop(); stopPlayback(); sample.discard(); notice = "" }
    func play(output: AudioDevice) {
        guard hasSample, !recording else { return }
        stopPlayback()
        let pcm = sample.pcm
        playing = true
        playback = Task { [weak self] in
            guard let self else { return }
            do {
                try self.player.start(output: output)
                var offset = 0
                while offset < pcm.count {
                    try Task.checkCancellation()
                    let end = min(offset + 48_000, pcm.count)
                    try await self.player.append(pcm.subdata(in: offset..<end))
                    offset = end
                }
                try await self.player.finish()
            } catch is CancellationError {
            } catch { self.notice = (error as? BridgeError)?.localizedDescription ?? "Playback stopped." }
            self.player.stop(); self.playing = false
        }
    }
    func stopPlayback() { playback?.cancel(); playback = nil; player.stop(); playing = false }

    private func receive(_ chunks: [Data], level: Float, token: UUID) {
        guard token == generation, recording else { return }
        self.level = level
        for chunk in chunks {
            guard (try? sample.append(chunk)) == true else {
                stop(); notice = "Recording stopped at the \(sample.maximum)-second limit."; return
            }
        }
        if sample.isFull { stop(); notice = "Recording stopped at the \(sample.maximum)-second limit." }
    }
    private func fail(_ message: String) { stop(); sample.discard(); notice = message }
    private func routeIntact() -> Bool {
        guard let capture, let device, capture.isRunning, capture.currentFormatMatches() else { return false }
        return AudioDevices.cached().contains { $0.id == device.id && $0.uid == device.uid && $0.isPhysicalInput }
    }
}

/// `copy` runs on the device's IO thread and only copies the samples. Conversion runs on a
/// serial queue, so `conversion` and `onConverted` are used from one thread at a time.
final class RecorderSink: @unchecked Sendable {
    private let format: AVAudioFormat
    private let conversion: CaptureConversion
    private let queue = DispatchQueue(label: "no.tallmaker.Babelfin.recorder")
    var onConverted: (([Data], Float) -> Void)?
    init(format: AVAudioFormat, conversion: CaptureConversion) { self.format = format; self.conversion = conversion }
    /// After the capture has stopped: waits for queued conversions and returns the converter's last samples.
    func drain() -> [Data] { queue.sync { (try? conversion.finish()) ?? [] } }
    func copy(frames: AVAudioFrameCount, buffers: UnsafePointer<AudioBufferList>) {
        guard frames > 0, let bytes = buffers.pointee.mBuffers.mData else { return }
        let samples = Data(bytes: bytes, count: Int(buffers.pointee.mBuffers.mDataByteSize))
        queue.async { self.convert(samples, frames: frames) }
    }
    private func convert(_ samples: Data, frames: AVAudioFrameCount) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
        // A new buffer reports zero bytes until its frame length is set.
        buffer.frameLength = frames
        let capacity = Int(buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize)
        samples.withUnsafeBytes { _ = memcpy(destination, $0.baseAddress!, min(capacity, $0.count)) }
        guard let (chunks, level) = try? conversion.convert(buffer) else { return }
        onConverted?(chunks, level)
    }
}
