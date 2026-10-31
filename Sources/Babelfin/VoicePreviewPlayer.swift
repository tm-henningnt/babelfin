import AVFoundation
import BridgeCore

@MainActor protocol VoiceClipPlaying: AnyObject {
    func start(output: AudioDevice) throws
    func append(_ pcm: Data) async throws
    func finish() async throws
    func stop()
}

/// Output-only preview. It never opens a microphone or chooses a default device.
@MainActor final class VoicePreviewPlayer: VoiceClipPlaying {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let queue = PlaybackBufferQueue()
    private var device: AudioDevice?
    private var generation = UUID()
    private var observer: NSObjectProtocol?
    private var routeWatch: Task<Void, Never>?
    func start(output: AudioDevice) throws {
        stop()
        guard output.isPhysical, output.outputChannels > 0 else { throw BridgeError.unavailable("Choose physical headphones for the preview.") }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        try AudioDevices.select(output.id, on: engine.outputNode.audioUnit)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!)
        engine.prepare(); try engine.start(); player.play()
        self.engine = engine; self.player = player; device = output
        let token = generation
        do { try validateRoute(token) } catch { stop(); throw error }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.generation == token { self?.stop() } }
        }
        routeWatch = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    guard let self else { return }
                    try self.validateRoute(token)
                } catch {
                    if !Task.isCancelled, self?.generation == token { self?.stop() }
                    return
                }
            }
        }
    }
    func append(_ pcm: Data) async throws {
        guard pcm.count % 2 == 0, pcm.count <= 240_000 else { throw BridgeError.invalidPCM }
        let token = generation
        var offset = 0
        while offset < pcm.count {
            try Task.checkCancellation()
            try validateRoute(token)
            guard let player else { throw CancellationError() }
            let end = min(offset + 4800, pcm.count)
            let values = try PCM16.decode(pcm.subdata(in: offset..<end))
            let deadline = Date().addingTimeInterval(5)
            while queue.remainingFrames < values.count {
                try validateRoute(token)
                guard Date() < deadline else { throw BridgeError.timedOut }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try validateRoute(token)
            let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!, frameCapacity: AVAudioFrameCount(values.count))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 { values.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: values.count) } }
            try queue.schedule(buffer, on: NativeAudioBufferScheduler(player: player))
            offset = end
        }
    }
    func finish() async throws {
        let deadline = Date().addingTimeInterval(8), token = generation
        while queue.queuedFrames > 0 {
            try Task.checkCancellation()
            try validateRoute(token)
            guard Date() < deadline else { throw BridgeError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        try validateRoute(token)
        stop()
    }
    private func validateRoute(_ token: UUID) throws {
        guard token == generation, let engine, let device, engine.isRunning,
              AudioDevices.selected(on: engine.outputNode.audioUnit) == device.id,
              AudioDevices.cached().contains(where: { $0.id == device.id && $0.uid == device.uid && $0.isPhysical && $0.outputChannels > 0 }) else {
            throw BridgeError.unavailable("The preview output changed. Choose your headphones again.")
        }
    }
    func stop() {
        generation = UUID(); routeWatch?.cancel(); routeWatch = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil; device = nil; queue.reset()
    }
}
