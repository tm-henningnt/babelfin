import AVFoundation
import BridgeCore

/// Records a voice-creation sample from one explicitly chosen physical microphone into
/// memory. It never selects a default device, never records a loopback, and never writes
/// the sample to disk. Recording stops at the length limit or when the route changes.
@MainActor final class VoiceSampleRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var level: Float = 0
    @Published private(set) var sample = VoiceSampleBuffer()
    @Published private(set) var notice = ""
    private var engine: AVAudioEngine?
    private var device: AudioDevice?
    private var generation = UUID()
    private var observer: NSObjectProtocol?
    private var routeWatch: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private let player = VoicePreviewPlayer()

    var seconds: Double { sample.seconds }
    var hasSample: Bool { !sample.pcm.isEmpty }

    func start(input: AudioDevice) async {
        stopPlayback()
        guard !recording else { return }
        notice = ""
        guard input.isPhysicalInput else { notice = "Choose a physical microphone. BlackHole and other virtual devices cannot record a voice sample."; return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { notice = "Allow microphone access in System Settings to record a sample."; return }
        default: notice = "Allow microphone access in System Settings › Privacy & Security › Microphone to record a sample."; return
        }
        sample.discard()
        let engine = AVAudioEngine()
        do {
            try AudioDevices.select(input.id, on: engine.inputNode.audioUnit)
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  let target = AVAudioFormat(standardFormatWithSampleRate: Double(VoiceSampleBuffer.sampleRate), channels: 1) else {
                throw BridgeError.unavailable("The microphone format is unavailable.")
            }
            let sink = RecorderSink(conversion: try CaptureConversion(sourceFormat: format, target: target, loopback: false, packetFrames: 2400))
            let token = UUID(); generation = token
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let (chunks, level) = sink.convert(buffer) else { return }
                Task { @MainActor [weak self] in self?.receive(chunks, level: level, token: token) }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine; device = input; recording = true
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.generation == token { self?.fail("The microphone changed. Record the sample again.") } }
            }
            routeWatch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, self.generation == token else { return }
                    if !self.routeIntact() { self.fail("The microphone disconnected. Record the sample again."); return }
                }
            }
        } catch {
            engine.stop()
            notice = (error as? BridgeError)?.localizedDescription ?? "The microphone could not start recording."
        }
    }
    /// Keeps the audio already recorded.
    func stop() {
        generation = UUID()
        routeWatch?.cancel(); routeWatch = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil; device = nil
        recording = false; level = 0
        if hasSample && !sample.meetsMinimum {
            notice = "Record at least \(VoiceSampleBuffer.minimumSeconds) seconds of speech."
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
                stop(); notice = "Recording stopped at the \(VoiceSampleBuffer.maximumSeconds)-second limit."; return
            }
        }
        if sample.isFull { stop(); notice = "Recording stopped at the \(VoiceSampleBuffer.maximumSeconds)-second limit." }
    }
    private func fail(_ message: String) { stop(); sample.discard(); notice = message }
    private func routeIntact() -> Bool {
        guard let engine, let device, engine.isRunning,
              AudioDevices.selected(on: engine.inputNode.audioUnit) == device.id else { return false }
        return AudioDevices.cached().contains { $0.id == device.id && $0.uid == device.uid && $0.isPhysicalInput }
    }
}

/// Owned by the tap thread; the tap delivers buffers serially.
private final class RecorderSink: @unchecked Sendable {
    private let conversion: CaptureConversion
    init(conversion: CaptureConversion) { self.conversion = conversion }
    func convert(_ buffer: AVAudioPCMBuffer) -> ([Data], Float)? { try? conversion.convert(buffer) }
}
