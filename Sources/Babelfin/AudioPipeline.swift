import AVFoundation
import CoreAudio
import BridgeCore

/// UI-facing lifecycle only. Engines, scheduling, route checks and admission are owned by
/// AudioWorker's serial queue. Capture conversion/delivery has its own bounded serial queue.
@MainActor final class AudioPipeline: Sendable {
    nonisolated private let worker = AudioWorker()
    private var meter: Timer?
    var onPCM: (@Sendable (Data) throws -> Void)?
    var onFailure: (@MainActor @Sendable (String) -> Void)?
    var onLevel: (@MainActor @Sendable (Float) -> Void)?
    var onNotice: (@MainActor @Sendable (String) -> Void)?

    #if BABELFIN_BENCHMARK
    // Private opt-in harness: materialize all units before helpers bind any route.
    func benchmarkPrepare() { worker.benchmarkPrepare() }
    nonisolated func benchmarkRoutesMatch(input: UInt32, output: UInt32) -> Bool {
        worker.benchmarkRoutesMatch(input: input, output: output)
    }
    #endif

    #if LIFECYCLE_CHECKS
    /// Constructs engines only; no start, device binding or HAL inventory access.
    static func captureDeliveryFixtureForChecks(handler: @escaping @Sendable (Data) throws -> Void) -> CaptureDeliveryFixture {
        let worker = AudioWorker()
        let generation = worker.prepareCaptureDeliveryForChecks(handler)
        return CaptureDeliveryFixture(deliver: { try worker.deliverCapturedPCM($0, generation: generation) },
                                      level: { worker.level }, stop: { worker.stop() })
    }
    #endif
    func configureOriginalMix(enabled: Bool, level: Float, ducking: Bool) {
        worker.configureOriginalMix(enabled: enabled, level: level, ducking: ducking)
    }
    func setOutputVolume(_ volume: Float) { worker.setOutputVolume(volume) }
    func updateListening(mixEnabled: Bool, level: Float, ducking: Bool, speechMuted: Bool) {
        worker.updateListening(mixEnabled: mixEnabled, level: level, ducking: ducking, speechMuted: speechMuted)
    }

    func start(input: AudioDevice, output: AudioDevice, destination: AudioDestination, translated: Bool = true) throws {
        try worker.start(input: input, output: output, destination: destination, translated: translated,
            deliver: onPCM ?? { _ in },
            failure: { [weak self] text in Task { @MainActor in self?.onFailure?(text) } },
            notice: { [weak self] text in Task { @MainActor in self?.onNotice?(text) } })
        // Poll one latest-value slot. A busy UI never accumulates one task per capture callback.
        meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onLevel?(self.worker.level)
            }
        }
    }
    nonisolated func play(_ pcm: Data) throws { try worker.play(pcm) }
    nonisolated func playTranslated(_ pcm: Data) async throws { try await worker.playTranslated(pcm) }
    func translatedSink() -> TranslationAudioHandler { worker.translatedSink() }
    func switchToOriginal() throws { try worker.switchToOriginal() }
    func switchToTranslation(deliver: @escaping @Sendable (Data) throws -> Void) throws { try worker.switchToTranslation(deliver: deliver) }
    func stop() { meter?.invalidate(); meter = nil; worker.stop() }
    func stopAndDrain() async throws {
        meter?.invalidate(); meter = nil
        let capture = worker.stopForDrain()
        try await capture?.finish()
    }
    func metricsSummary() -> String { worker.metricsSummary() }
    func audibleStart(after time: TimeInterval) -> TimeInterval? { worker.audibleStarts.audible(after: time) }
    #if BABELFIN_AUDIO_TRACE
    func audioTraceAfterStop() -> AudioMixerTrace? { worker.audioTraceAfterStop() }
    #endif
}

/// All graph/player state is accessed only inside `control`. The unchecked conformance
/// documents that queue confinement; immutable capture copies have a separate serial owner.
#if LIFECYCLE_CHECKS
struct CaptureDeliveryFixture: Sendable {
    let deliver: @Sendable (Data) throws -> Void
    let level: @Sendable () -> Float
    let stop: @Sendable () -> Void
}
#endif
private final class AudioWorker: @unchecked Sendable {
    private let control = DispatchQueue(label: "Babelfin.audio-control", qos: .userInitiated)
    private let playback = AVAudioEngine()
    private var renderMixer: RenderAudioMixer?
    private var renderSource: AVAudioSourceNode?
    private var completionWatch: DispatchSourceTimer?
    private var originalMixEnabled = false
    private var originalMixLevel: Float = 0.2
    private var originalDucking = true
    private var speechMuted = false
    private var translatedMode = true
    private var active = false
    private var inputCapture: DeviceInputCapture?
    private var input: AudioDevice?
    private var output: AudioDevice?
    private var captureFormat: AVAudioFormat?
    private var playbackFormat: AVAudioFormat?
    private var captureDelivery: CaptureDelivery?
    private var captureGeneration = UUID()
    private var retiredCaptureMetrics = CaptureMetrics()
    private var playbackQueue = BufferedAudioPlayback(prebufferFrames: 7200)
    let audibleStarts = AudibleStartLog()
    private var playbackGeneration = UUID()
    private var outputVolume: Float = 1
    private var bufferingDeadline: DispatchWorkItem?
    private var lastRefillNotice: TimeInterval = 0
    private var abandonedIncomingFrames: UInt64 = 0
    private var outputSignal = AudioSignalMetrics()
    private var captureProgress = CaptureProgressWatchdog()
    private var mixedRenderProgress = CaptureProgressWatchdog()
    private var lastTelemetryReport: TimeInterval = 0
    private var watch: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var recovery = AudioConfigurationRecovery()
    private var recoveryCheck: DispatchWorkItem?
    private var onPCM: @Sendable (Data) throws -> Void = { _ in }
    private var onFailure: @Sendable (String) -> Void = { _ in }
    private var onNotice: @Sendable (String) -> Void = { _ in }
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!

    #if BABELFIN_BENCHMARK
    func benchmarkPrepare() { control.sync { _ = playback.outputNode.audioUnit } }
    func benchmarkRoutesMatch(input: UInt32, output: UInt32) -> Bool { control.sync {
        inputCapture?.device == input && AudioDevices.selected(on: playback.outputNode.audioUnit) == output
    } }
    #endif

    func configureOriginalMix(enabled: Bool, level: Float, ducking: Bool) {
        control.sync {
            guard !active else { return }
            originalMixEnabled = enabled
            originalMixLevel = level.isFinite ? min(1, max(0, level)) : 0
            originalDucking = ducking
        }
    }
    /// What the user hears, applied live: the original under the translation, or the original
    /// alone while translated speech keeps playing out silently.
    func updateListening(mixEnabled: Bool, level: Float, ducking: Bool, speechMuted muted: Bool) {
        control.sync {
            originalMixEnabled = mixEnabled
            originalMixLevel = level.isFinite ? min(1, max(0, level)) : 0
            originalDucking = ducking
            speechMuted = muted
            guard active, let renderMixer else { return }
            renderMixer.setSpeechMuted(muted)
            if translatedMode { renderMixer.switchToTranslation(originalLevel: mixEnabled ? originalMixLevel : 0, ducking: ducking) }
        }
    }
    /// The direction's own output volume. It applies at once, also while audio plays, and
    /// does not change the device's system volume.
    func setOutputVolume(_ volume: Float) {
        control.sync {
            outputVolume = volume.isFinite ? min(1, max(0, volume)) : 1
            if active { playback.mainMixerNode.outputVolume = outputVolume }
        }
    }
    /// Translated audio goes through the render mixer, which every started session has.
    private var scheduler: (any AudioBufferScheduling)? { renderMixer }

    func start(input: AudioDevice, output: AudioDevice, destination: AudioDestination, translated: Bool,
               deliver: @escaping @Sendable (Data) throws -> Void,
               failure: @escaping @Sendable (String) -> Void,
               notice: @escaping @Sendable (String) -> Void) throws {
        _ = AudioDeviceInventory.shared
        try control.sync {
            try AudioRouting.validate(input: input.endpoint, output: output.endpoint, destination: destination)
            onPCM = deliver; onFailure = failure; onNotice = notice
            translatedMode = translated
            renderMixer = nil
            playbackQueue = BufferedAudioPlayback(prebufferFrames: translated ? 7200 : 0)
            audibleStarts.reset()
            self.input = input; self.output = output
            // Device binding and Bluetooth profile negotiation can change the graph during
            // startup. Observe first, then handle notifications on this serial control queue.
            for engine in [playback] {
                observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.control.async { [weak self] in self?.scheduleConfigurationCheck() }
                })
            }
            do {
                // Lazily creating another IO unit after binding can reset a route.
                // Materialize units only during Start; offline fixtures never open IO.
                // Capture never uses AVAudioEngine's input node, which first opens the
                // system default input (see DeviceInputCapture).
                _ = playback.outputNode.audioUnit
                try AudioDevices.select(output.id, on: playback.outputNode.audioUnit)
                inputCapture = try DeviceInputCapture(device: input.id)
                reportFormats(stage: "device bound")
                // Translated sessions always mix, so the original plays until the first translated speech.
                let originalLevel: Float
                if !translated { originalLevel = 1 } else if originalMixEnabled { originalLevel = originalMixLevel } else { originalLevel = 0 }
                let mixer = RenderAudioMixer(originalLevel: originalLevel,
                                             ducking: translated && originalDucking, mixesTranslation: translated,
                                             initialOriginalLeadFrames: RenderAudioMixer.liveOriginalLeadFrames)
                let mono = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
                let source = AVAudioSourceNode(format: mono) { isSilence, _, count, buffers in
                    isSilence.pointee = false
                    let list = UnsafeMutableAudioBufferListPointer(buffers)
                    guard let data = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                    mixer.render(into: UnsafeMutableBufferPointer(start: data, count: Int(count)))
                    return noErr
                }
                mixer.setSpeechMuted(speechMuted)
                renderMixer = mixer; renderSource = source
                playback.attach(source)
                playback.connect(source, to: playback.mainMixerNode, format: mono)
                try connectPlaybackToHardware()
                try installCaptureSink()
                active = true
                #if BABELFIN_BENCHMARK
                try benchmarkAssertRoutes()
                #endif
                try playback.start()
                #if BABELFIN_BENCHMARK
                try benchmarkAssertRoutes()
                #endif
                try startCapture()
                #if BABELFIN_BENCHMARK
                try benchmarkAssertRoutes()
                #endif
                captureProgress.reset(at: ProcessInfo.processInfo.systemUptime)
                mixedRenderProgress.reset(at: ProcessInfo.processInfo.systemUptime)
                reportFormats(stage: "engines started")
                lastTelemetryReport = ProcessInfo.processInfo.systemUptime
                if renderMixer != nil {
                    let completions = DispatchSource.makeTimerSource(queue: control)
                    completions.schedule(deadline: .now(), repeating: .milliseconds(10))
                    completions.setEventHandler { [weak self] in self?.renderMixer?.retireRenderedCompletions() }
                    completionWatch = completions
                    completions.resume()
                }
            } catch {
                stopLocked(discardCapture: true)
                throw error
            }
            let timer = DispatchSource.makeTimerSource(queue: control)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.checkHealth() }
            watch = timer
            timer.resume()
            captureDelivery?.begin()
        }
    }
    #if BABELFIN_AUDIO_TRACE
    func audioTraceAfterStop() -> AudioMixerTrace? {
        control.sync {
            guard !active, !playback.isRunning else { return nil }
            return renderMixer?.traceAfterStop()
        }
    }
    #endif
    var level: Float { control.sync { captureDelivery?.snapshot.level ?? 0 } }
    func metricsSummary() -> String {
        control.sync { metricsSummaryLocked() }
    }
    private func metricsSummaryLocked() -> String {
        let capture = captureDelivery?.snapshot ?? retiredCaptureMetrics
        let output = playbackQueue.snapshot
        let flow = String(format: "Audio metrics: current capture generation=%llu source frames at %.0f Hz, sent=%llu PCM frames, capture queue=%d (peak=%d, age=%.3fs), rendered=%llu frames, playback=%.3fs (peak=%.3fs, oldest=%.3fs), refills=%d, empty intervals including natural silence=%.3fs, discarded=%llu frames, recovery abandoned=%llu frames.",
            capture.capturedFrames, captureFormat?.sampleRate ?? 0, capture.deliveredFrames, capture.queuedBuffers, capture.maximumQueuedBuffers,
            capture.oldestAge, output.renderedFrames, Double(output.queuedFrames) / 24_000,
            Double(output.maximumQueuedFrames) / 24_000, output.oldestAge, playbackQueue.refillCount,
            output.emptyIntervalSeconds, output.discardedFrames, abandonedIncomingFrames)
        let signal = String(format: " Capture callbacks=%llu (empty=%llu); capture PCM samples=%llu nonzero=%llu RMS=%.6f peak=%.6f; queued output PCM samples=%llu nonzero=%llu RMS=%.6f peak=%.6f.",
            capture.callbacks, capture.zeroFrameCallbacks, capture.signal.samples, capture.signal.nonzeroSamples,
            capture.signal.rms, capture.signal.peak, outputSignal.samples, outputSignal.nonzeroSamples,
            outputSignal.rms, outputSignal.peak)
        let mix = renderMixer.map { mixer in
            let state = mixer.snapshot
            return " Original render queue=\(state.originalFrames) frames; stale original discarded=\(state.discardedOriginalFrames) frames; mixer output=\(state.outputFrames) frames."
        } ?? ""
        #if BABELFIN_AUDIO_TRACE
        return flow + signal + mix + (captureDelivery?.diagnosticSummary ?? "")
        #else
        return flow + signal + mix
        #endif
    }
    private func reportFormats(stage: String) {
        let format = inputCapture?.format
        let inputMatches = input.map { inputCapture?.device == $0.id } ?? false
        let outputMatches = output.map { AudioDevices.selected(on: playback.outputNode.audioUnit) == $0.id } ?? false
        let selectedInput = inputCapture.map { String($0.device) } ?? "none"
        let selectedOutput = AudioDevices.selected(on: playback.outputNode.audioUnit).map(String.init) ?? "none"
        onNotice(String(format: "Audio format [%@]: capture device %.0f Hz/%u channels%@; selected input matches=%@ (device %@, expected %@); selected output matches=%@ (device %@, expected %@).",
            stage, format?.sampleRate ?? 0, format?.channelCount ?? 0, (format?.isInterleaved ?? false) ? " interleaved" : "",
            inputMatches ? "true" : "false", selectedInput, input.map { String($0.id) } ?? "none",
            outputMatches ? "true" : "false", selectedOutput, output.map { String($0.id) } ?? "none"))
    }
    private func checkHealth() {
        guard active else { return }
        if !routeIntact() { fail("Audio device disconnected or route changed. Refresh devices and start again."); return }
        if !(inputCapture?.isRunning ?? false) || !playback.isRunning || !(inputCapture?.currentFormatMatches() ?? false) {
            scheduleConfigurationCheck(); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let capturedFrames = captureDelivery?.snapshot.capturedFrames ?? 0
        if renderMixer?.snapshot.schedulingFailed == true {
            fail("Mixed playback rejected an audio buffer. Stop and start again.")
            return
        }
        if let renderMixer, mixedRenderProgress.isStalled(frames: renderMixer.snapshot.outputFrames, at: now) {
            fail("The selected output stopped rendering audio for five seconds. Reconnect it and start again.")
            return
        }
        if captureProgress.isStalled(frames: capturedFrames, at: now) {
            reportFormats(stage: "capture stalled")
            onNotice(metricsSummaryLocked())
            fail(capturedFrames == 0
                ? "No audio frames arrived from the selected source within five seconds. Check the microphone connection and selected input, then start again."
                : "The selected audio source stopped delivering frames for five seconds. Check the microphone connection and selected input, then start again.")
            return
        }
        if now - lastTelemetryReport >= 10 {
            lastTelemetryReport = now
            onNotice(metricsSummaryLocked())
        }
        if playbackQueue.snapshot.secondsSinceProgress >= 5 {
            fail("Playback is not draining. Reconnect the selected output and start again.")
        }
    }
    private func fail(_ detail: String) {
        guard active else { return }
        let callback = onFailure
        stopLocked(discardCapture: true)
        callback(detail)
    }
    private func routeIntact() -> Bool {
        guard let input, let output else { return false }
        let devices = AudioDevices.cached()
        return devices.contains(where: { $0.id == input.id && $0.uid == input.uid && $0.inputChannels > 0 })
            && devices.contains(where: { $0.id == output.id && $0.uid == output.uid && $0.outputChannels > 0 })
            && inputCapture?.device == input.id
            && AudioDevices.selected(on: playback.outputNode.audioUnit) == output.id
    }
    private func scheduleConfigurationCheck() {
        guard active, recoveryCheck == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.recoveryCheck = nil
            if self.active { self.recoverConfiguration() }
        }
        recoveryCheck = item
        control.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
    }
    private func recoverConfiguration() {
        reportFormats(stage: "configuration check")
        let current = input.flatMap { try? DeviceInputCapture(device: $0.id).format }
        let inputFormat = current.flatMap { try? CaptureFormatPolicy.select(hardware: $0, client: $0, installed: captureFormat) }
        let outputFormat = playback.outputNode.outputFormat(forBus: 0)
        var health = AudioGraphHealth()
        health.routeIntact = routeIntact()
        health.inputFormatValid = inputFormat != nil
        health.outputFormatValid = valid(outputFormat)
        health.captureRunning = inputCapture?.isRunning ?? false
        health.playbackRunning = playback.isRunning
        health.inputFormatChanged = inputFormat?.requiresRebuild ?? true
        health.outputFormatChanged = playbackFormat.map { !outputFormat.isEqual($0) } ?? true
        switch recovery.evaluate(health, at: ProcessInfo.processInfo.systemUptime) {
        case .unchanged: return
        case .stopRouteChanged: fail("Audio device disconnected or route changed. Refresh devices and start again.")
        case .stopFormatUnavailable: fail("Audio device format is unavailable. Reconnect the device and start again.")
        case .stopUnstable: fail("Audio device keeps changing format. Choose a stable output and start again.")
        case .recover(let rebuildCapture, let rebuildPlayback):
            // A native callback arrives every hardware quantum. Do not fill four
            // slots with consumers waiting on this control lane during recovery.
            captureDelivery?.pause()
            do {
                if rebuildPlayback {
                    let discarded = playbackQueue.queuedFrames
                    discardQueuedPlayback()
                    playback.stop()
                    playback.disconnectNodeOutput(playback.mainMixerNode)
                    try connectPlaybackToHardware()
                    onNotice(String(format: "Playback route recovery discarded %.3f seconds of queued audio.", Double(discarded) / 24_000))
                }
                if rebuildCapture {
                    renderMixer?.clearOriginal()
                    captureGeneration = UUID()
                    captureDelivery?.cancel()
                    detachCaptureSink()
                    if let input { inputCapture = try DeviceInputCapture(device: input.id) }
                    try installCaptureSink()
                    try startCapture()
                    captureProgress.reset(at: ProcessInfo.processInfo.systemUptime)
                }
                if rebuildPlayback {
                    try playback.start()
                    mixedRenderProgress.reset(at: ProcessInfo.processInfo.systemUptime)
                }
                reportFormats(stage: "configuration recovered")
                onNotice("Audio format changed; recovered the affected engine on the same selected device.")
                captureDelivery?.begin()
            } catch { fail("Could not recover the selected audio devices. Refresh devices and start again.") }
        }
    }
    private func valid(_ format: AVAudioFormat) -> Bool {
        format.sampleRate.isFinite && format.sampleRate > 0 && format.channelCount > 0
    }
    private func connectPlaybackToHardware() throws {
        let hardware = playback.outputNode.outputFormat(forBus: 0)
        guard valid(hardware) else { throw BridgeError.unavailable("Output audio format is unavailable.") }
        playback.connect(playback.mainMixerNode, to: playback.outputNode, format: hardware)
        playback.mainMixerNode.outputVolume = outputVolume
        playbackFormat = hardware
    }
    /// The device IOProc copies each quantum into the bounded capture ring on the IO thread.
    private func startCapture() throws {
        guard let inputCapture, let delivery = captureDelivery else { throw BridgeError.unavailable("The audio source is not ready. Start again.") }
        try inputCapture.start { frames, buffers in delivery.captureRaw(frames: frames, buffers: buffers) }
    }
    private func detachCaptureSink() {
        // Returns after the IOProc has stopped; a stopped source is never restarted.
        inputCapture?.stop()
        inputCapture = nil
    }
    private func installCaptureSink() throws {
        guard let inputCapture else { throw BridgeError.unavailable("The audio source is not ready. Start again.") }
        let format = try CaptureFormatPolicy.select(hardware: inputCapture.format, client: inputCapture.format, installed: nil).format
        guard valid(format), let target = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1) else {
            throw BridgeError.unavailable("This audio source cannot be converted to 24 kHz mono.")
        }
        captureFormat = format
        captureGeneration = UUID()
        let generation = captureGeneration
        #if BABELFIN_AUDIO_TRACE
        let diagnostics = CaptureDeliveryDiagnostics()
        #endif
        let originalSink: (@Sendable (Data) throws -> Void)?
        if let mixer = renderMixer {
            originalSink = { [weak self] pcm in
                guard let self else { return }
                #if BABELFIN_AUDIO_TRACE
                let queued = ProcessInfo.processInfo.systemUptime
                #endif
                try self.control.sync {
                    #if BABELFIN_AUDIO_TRACE
                    let entered = ProcessInfo.processInfo.systemUptime
                    diagnostics.record(.originalControlWait, begin: queued, end: entered)
                    defer { diagnostics.record(.originalControlExecution, begin: entered,
                        end: ProcessInfo.processInfo.systemUptime) }
                    #endif
                    guard self.active, self.captureGeneration == generation else { return }
                    try mixer.appendOriginal(pcm)
                    if !self.translatedMode { try self.outputSignal.recordPCM16(pcm) }
                }
            }
        } else { originalSink = nil }
        let conversion = try CaptureConversion(sourceFormat: format, target: target, loopback: input?.isBlackHole == true,
            // 50 ms packets in translated mode: the recognizer and the segment cutter see the end of speech sooner.
            packetFrames: translatedMode ? 1200 : 480, convertedPCM: originalSink)
        let maximumFrames = inputCapture.maximumFrames
        let delivery = try CaptureDelivery(conversion: conversion, maximumFrames: maximumFrames, initiallyAccepting: false,
            deliver: { [weak self] pcm in
                guard let self else { return }
                try self.deliverCapturedPCM(pcm, generation: generation)
            }, failure: { [weak self] message in
                guard let self else { return }
                self.control.async { [weak self] in
                    guard let self, self.captureGeneration == generation else { return }
                    self.fail(message)
                }
            })
        #if BABELFIN_AUDIO_TRACE
        delivery.configureDiagnostics(diagnostics)
        #endif
        captureDelivery = delivery
    }
    #if LIFECYCLE_CHECKS
    func prepareCaptureDeliveryForChecks(_ handler: @escaping @Sendable (Data) throws -> Void) -> UUID {
        control.sync {
            active = true; translatedMode = true; onPCM = handler
            captureGeneration = UUID(); return captureGeneration
        }
    }
    #endif
    func deliverCapturedPCM(_ pcm: Data, generation: UUID) throws {
        let callback: (@Sendable (Data) throws -> Void)? = try control.sync {
            guard active, captureGeneration == generation else { return nil }
            #if BABELFIN_BENCHMARK
            try benchmarkAssertRoutes()
            #endif
            // The original reaches the render mixer through the conversion's own sink.
            if !translatedMode { return nil }
            return onPCM
        }
        // CaptureDelivery still owns synchronous ordering and its bounded slot. External
        // callbacks must not run on control: they may synchronously play/read/stop audio.
        // AppModel fences cloud admission before a completed Stop/mode transition returns.
        try callback?(pcm)
    }
    #if BABELFIN_BENCHMARK
    private func benchmarkAssertRoutes() throws {
        guard let input, let output, input.isBlackHole, output.isBlackHole,
              input.inputChannels == 16, output.outputChannels == 2,
              inputCapture?.device == input.id,
              AudioDevices.selected(on: playback.outputNode.audioUnit) == output.id else {
            throw BridgeError.unavailable("Benchmark virtual route changed; cloud admission refused.")
        }
    }
    #endif
    func play(_ pcm: Data) throws { try control.sync { try playLocked(pcm) } }
    private func playLocked(_ pcm: Data) throws {
        guard active else { return }
        guard let output, AudioDevices.selected(on: playback.outputNode.audioUnit) == output.id else {
            throw BridgeError.unavailable("Output route changed. Refresh devices and start again.")
        }
        guard playback.isRunning else {
            scheduleConfigurationCheck()
            throw BridgeError.unavailable("Playback is recovering; original audio could not be delivered.")
        }
        if !translatedMode, let renderMixer {
            try renderMixer.appendOriginal(pcm)
            try outputSignal.recordPCM16(pcm)
            return
        }
        let samples = try PCM16.decode(pcm)
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { throw BridgeError.invalidPCM }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<2 {
            samples.withUnsafeBufferPointer { channels[channel].update(from: $0.baseAddress!, count: samples.count) }
        }
        let oldRefills = playbackQueue.refillCount
        let wasBuffering = playbackQueue.isBuffering
        guard let scheduler else { throw BridgeError.unavailable("Playback is not ready. Start again.") }
        try playbackQueue.append(buffer, on: scheduler)
        let now = ProcessInfo.processInfo.systemUptime
        if playbackQueue.isBuffering {
            audibleStarts.admitted(at: now, queuedAhead: nil)
        } else {
            if wasBuffering { audibleStarts.started(at: now) }
            audibleStarts.admitted(at: now, queuedAhead: Double(playbackQueue.queuedFrames - samples.count) / 24_000)
        }
        if renderMixer?.snapshot.schedulingFailed == true {
            throw BridgeError.unavailable("Mixed playback rejected an audio buffer. Stop and start again.")
        }
        try outputSignal.recordPCM16(pcm)
        if playbackQueue.refillCount != oldRefills, ProcessInfo.processInfo.systemUptime - lastRefillNotice > 10 {
            lastRefillNotice = ProcessInfo.processInfo.systemUptime
            onNotice("Refilling the playback buffer after an audio gap.")
        }
        updateBufferingDeadline()
    }
    func translatedSink() -> TranslationAudioHandler {
        let generation = control.sync { playbackGeneration }
        return { [weak self] pcm in guard let self else { return }; try await self.playTranslated(pcm, expectedGeneration: generation) }
    }
    func playTranslated(_ pcm: Data, expectedGeneration: UUID? = nil) async throws {
        let generation = expectedGeneration ?? control.sync { playbackGeneration }
        let abandoned = try await PlaybackAdmission().play(pcm, admit: { [self] piece in
            try control.sync {
                guard active, translatedMode, playbackGeneration == generation else { return .invalidated }
                if !playback.isRunning { scheduleConfigurationCheck(); return .wait }
                guard playbackQueue.remainingFrames >= piece.count / 2 else { return .wait }
                try playLocked(piece)
                return .admitted
            }
        })
        control.sync { abandonedIncomingFrames += UInt64(abandoned) }
    }
    private func updateBufferingDeadline() {
        guard playbackQueue.isBuffering else { bufferingDeadline?.cancel(); bufferingDeadline = nil; return }
        guard bufferingDeadline == nil else { return }
        let generation = playbackGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.playbackGeneration == generation else { return }
            self.bufferingDeadline = nil
            if self.playback.isRunning {
                if let scheduler = self.scheduler { self.playbackQueue.flush(on: scheduler) }
                self.audibleStarts.started(at: ProcessInfo.processInfo.systemUptime)
                if self.renderMixer?.snapshot.schedulingFailed == true {
                    self.fail("Mixed playback rejected an audio buffer. Stop and start again.")
                }
            }
        }
        bufferingDeadline = item
        // Short utterances that never fill the adaptive target still play after it elapses.
        control.asyncAfter(deadline: .now() + .milliseconds(Int(playbackQueue.prebufferSeconds * 1000) + 50), execute: item)
    }
    private func resetPlaybackBuffer() {
        playbackGeneration = UUID()
        discardQueuedPlayback()
    }
    /// Route recovery drops queued audio but keeps the playback generation, so the same
    /// session's later translated speech still plays. Stop and mode changes use
    /// resetPlaybackBuffer, which also fences out late packets from the old generation.
    private func discardQueuedPlayback() {
        bufferingDeadline?.cancel(); bufferingDeadline = nil
        playbackQueue.reset()
        renderMixer?.reset()
    }
    func switchToTranslation(deliver: @escaping @Sendable (Data) throws -> Void) throws {
        try control.sync {
            guard active, routeIntact() else { throw BridgeError.unavailable("The selected devices are unavailable.") }
            playbackGeneration = UUID(); bufferingDeadline?.cancel(); bufferingDeadline = nil
            playbackQueue.reset()
            renderMixer?.switchToTranslation(originalLevel: originalMixEnabled ? originalMixLevel : 0, ducking: originalDucking)
            playbackQueue = BufferedAudioPlayback(prebufferFrames: 7200)
            audibleStarts.reset()
            onPCM = deliver; translatedMode = true
        }
    }
    func switchToOriginal() throws {
        try control.sync {
            guard active else { throw BridgeError.unavailable("Audio is not running.") }
            translatedMode = false
            playbackGeneration = UUID()
            bufferingDeadline?.cancel(); bufferingDeadline = nil
            playbackQueue = playbackQueue.continuingOriginal(on: renderMixer)
        }
    }
    func stop() { control.sync { stopLocked(discardCapture: true) } }
    func stopForDrain() -> CaptureDelivery? {
        control.sync {
            let delivery = captureDelivery
            stopLocked(discardCapture: false)
            return delivery
        }
    }
    private func stopLocked(discardCapture: Bool) {
        active = false
        captureGeneration = UUID()
        recoveryCheck?.cancel(); recoveryCheck = nil
        resetPlaybackBuffer()
        watch?.cancel(); watch = nil
        completionWatch?.cancel(); completionWatch = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if discardCapture { captureDelivery?.cancel() }
        // Silence scheduled output before potentially slow input-device teardown.
        renderMixer?.stop()
        playback.stop()
        if let renderSource { playback.detach(renderSource); self.renderSource = nil }
        detachCaptureSink()
        if let captureDelivery { retiredCaptureMetrics = captureDelivery.snapshot }
    }
}
