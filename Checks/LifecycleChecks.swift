#if LIFECYCLE_CHECKS
import Foundation
import CoreAudio
import BridgeCore

private struct CheckError: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckError(message: message) }
}
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private let stopSignal: DispatchSemaphore?
    init(stopSignal: DispatchSemaphore? = nil) { self.stopSignal = stopSignal }
    func record(_ value: String) { lock.lock(); entries.append(value); lock.unlock(); if value == "audio-stop" { stopSignal?.signal() } }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}
private final class AppendFault: @unchecked Sendable {
    private let lock = NSLock(); private var enabled = false; private var blocked = false
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func block() { lock.lock(); blocked = true; lock.unlock() }
    func enable() { lock.lock(); enabled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let wait = blocked, fail = enabled; lock.unlock()
        if wait { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        if fail { throw BridgeError.uploadBacklog }
    }
}
private final class CallbackReference: @unchecked Sendable {
    private let lock = NSLock(); private var callback: (@Sendable () -> Float)?
    func set(_ value: @escaping @Sendable () -> Float) { lock.lock(); callback = value; lock.unlock() }
    func read() -> Float { lock.lock(); let value = callback; lock.unlock(); return value?() ?? 0 }
}
@MainActor private final class FakeProvider: TranslationProvider {
    nonisolated let appendFault = AppendFault()
    var onEvent: TranslationEventHandler?
    var onAudio: TranslationAudioHandler?
    let trace: Trace
    var onStart: (() -> Void)?
    var startFailure: Error?
    var holdStart = false, holdFinish = false
    private(set) var startEntered = false, finishEntered = false
    private(set) var starts = 0
    private(set) var configuration: TranslationConfiguration?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?
    init(_ trace: Trace) { self.trace = trace }
    func start(configuration: TranslationConfiguration, apiKey: String) async throws {
        self.configuration = configuration; startEntered = true; finishEntered = false; starts += 1
        onStart?()
        if holdStart { await withCheckedContinuation { startWaiter = $0 } }
        if let startFailure { throw startFailure }
    }
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        try credentials.validate(for: configuration.route)
        try await start(configuration: configuration, apiKey: "fixture-key")
    }
    nonisolated func append(_ pcm: Data) throws { try appendFault.check(); trace.record("append:\(pcm.count)") }
    func stopInput() { trace.record("input-closed") }
    func finish() async {
        trace.record("finish"); finishEntered = true
        if holdFinish { await withCheckedContinuation { finishWaiter = $0 } }
    }
    // Late completion deliberately survives cancellation; AppModel must reject it.
    func cancel() { trace.record("cancel") }
    func releaseStart() { startWaiter?.resume(); startWaiter = nil }
    func releaseFinish() { finishWaiter?.resume(); finishWaiter = nil }
}
@MainActor private final class FakeAudio: AudioPipelineControlling {
    var onPCM: (@Sendable (Data) throws -> Void)?
    var onFailure: (@MainActor @Sendable (String) -> Void)?
    var onNotice: (@MainActor @Sendable (String) -> Void)?
    var onLevel: (@MainActor @Sendable (Float) -> Void)?
    let trace: Trace
    private(set) var starts = 0
    private(set) var stopped = false, drainEntered = false
    private(set) var mixEnabled = false, mixDucking = true
    private(set) var mixLevel: Float = 0.25
    private var epoch = UUID()
    var holdDrain = false
    private var drainWaiter: CheckedContinuation<Void, Never>?
    init(_ trace: Trace) { self.trace = trace }
    func configureOriginalMix(enabled: Bool, level: Float, ducking: Bool) {
        mixEnabled = enabled; mixLevel = level; mixDucking = ducking
    }
    private(set) var volumes: [Float] = []
    private(set) var listening: [(mix: Bool, muted: Bool)] = []
    func updateListening(mixEnabled: Bool, level: Float, ducking: Bool, speechMuted: Bool) { listening.append((mixEnabled, speechMuted)) }
    func setOutputVolume(_ volume: Float) { volumes.append(volume) }
    func start(input: AudioDevice, output: AudioDevice, destination: AudioDestination, translated: Bool) throws {
        starts += 1; stopped = false; epoch = UUID(); trace.record("audio-start")
    }
    nonisolated func play(_ pcm: Data) throws { trace.record("play") }
    nonisolated func playTranslated(_ pcm: Data) async throws { trace.record("translated-play") }
    func switchToOriginal() throws { epoch = UUID(); trace.record("original-switch") }
    func switchToTranslation(deliver: @escaping @Sendable (Data) throws -> Void) throws { epoch = UUID(); onPCM = deliver; trace.record("translation-switch") }
    func translatedSink() -> TranslationAudioHandler {
        let expected = epoch
        return { [weak self] _ in guard let self else { return }; await MainActor.run { guard self.epoch == expected, !self.stopped else { return }; self.trace.record("translated-play") } }
    }
    func stop() { epoch = UUID(); stopped = true; trace.record("audio-stop") }
    func stopAndDrain() async throws {
        stop(); drainEntered = true
        if holdDrain { await withCheckedContinuation { drainWaiter = $0 } }
        try onPCM?(Data([0, 0])); trace.record("capture-drained")
    }
    func releaseDrain() { drainWaiter?.resume(); drainWaiter = nil }
    func metricsSummary() -> String { "Audio timing: synthetic counters only." }
}
@MainActor private final class PermissionGate {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Bool, Never>?
    func request() async -> Bool { entered = true; return await withCheckedContinuation { waiter = $0 } }
    func allow() { waiter?.resume(returning: true); waiter = nil }
}
@MainActor private final class DeviceCatalog {
    var devices: [AudioDevice] = [
        AudioDevice(id: 1, uid: "mic-one", name: "First microphone", inputChannels: 1, outputChannels: 0, transport: kAudioDeviceTransportTypeUSB),
        AudioDevice(id: 2, uid: "mic-two", name: "Second microphone", inputChannels: 1, outputChannels: 0, transport: kAudioDeviceTransportTypeUSB),
        AudioDevice(id: 3, uid: "headphones", name: "Headphones", inputChannels: 0, outputChannels: 2, transport: kAudioDeviceTransportTypeUSB),
        AudioDevice(id: 4, uid: "blackhole-2ch", name: "BlackHole 2ch", inputChannels: 2, outputChannels: 2, transport: kAudioDeviceTransportTypeVirtual)
    ]
}
private final class InventoryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AudioDevice]
    private var waitInitially: Bool
    let firstLoadGate = DispatchSemaphore(value: 0)
    init(_ items: [AudioDevice], waitInitially: Bool = false) { self.items = items; self.waitInitially = waitInitially }
    var snapshot: [AudioDevice] {
        lock.lock(); let wait = waitInitially; waitInitially = false; lock.unlock()
        if wait { firstLoadGate.wait() }
        lock.lock(); defer { lock.unlock() }; return items
    }
    func replace(_ items: [AudioDevice]) { lock.lock(); self.items = items; lock.unlock() }
}
@MainActor private final class FakeConsumer: ConsumerMonitoring {
    var onChange: (@MainActor @Sendable (ConsumerObservation) -> Void)?
    private(set) var started = false
    func start(deviceID: AudioDeviceID) { started = true }
    func stop() { started = false }
    func emit(_ state: ConsumerObservation) { onChange?(state) }
}
@MainActor private func configuredModel(_ provider: FakeProvider, _ audio: FakeAudio, catalog: DeviceCatalog,
                                       store: MemoryAppPreferences? = nil,
                                       permission: @escaping @MainActor () async -> Bool = { true },
                                       key: @escaping @MainActor () throws -> String = { "synthetic-test-value" },
                                       consumer: FakeConsumer? = nil, controlClock: TextClock? = nil) -> AppModel {
    AppModel(providerFactory: { provider }, audioFactory: { audio }, deviceList: { catalog.devices }, loadKey: key,
             requestPermission: permission, preferences: store ?? MemoryAppPreferences(), consumerFactory: consumer.map { value in { value } }, sleepForControl: { seconds in
                 if let controlClock { try await controlClock.sleep(seconds) }
             })
}
@MainActor private func until(_ predicate: () -> Bool) async throws {
    for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
    throw CheckError(message: "Timed out waiting for a test gate")
}
@MainActor private final class TextClock {
    private var instant: Int64 = 0
    private var waiters: [UUID: (Int64, CheckedContinuation<Void, Error>)] = [:]
    var pending: Bool { !waiters.isEmpty }
    var now: TimeInterval { Double(instant) / 1_000_000_000 }
    func sleep(_ seconds: TimeInterval) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[token] = (instant + Int64((seconds * 1_000_000_000).rounded()), continuation) }
            }
        } onCancel: { Task { @MainActor in self.waiters.removeValue(forKey: token)?.1.resume(throwing: CancellationError()) } }
    }
    func advance(_ seconds: TimeInterval) {
        instant += Int64((seconds * 1_000_000_000).rounded())
        for token in waiters.filter({ $0.value.0 <= instant }).map(\.key) {
            waiters.removeValue(forKey: token)?.1.resume(returning: ())
        }
    }
}
@MainActor private func model(_ provider: FakeProvider, _ audio: FakeAudio, loopback: Bool = false,
                              permission: @escaping @MainActor () async -> Bool = { true }, clock: TextClock? = nil) -> AppModel {
    let input = AudioDevice(id: 1, uid: loopback ? "blackhole-input" : "test-mic", name: loopback ? "BlackHole test" : "Test mic", inputChannels: 2, outputChannels: 0, transport: loopback ? kAudioDeviceTransportTypeVirtual : kAudioDeviceTransportTypeUSB)
    let output = AudioDevice(id: 2, uid: "test-headphones", name: "Test headphones", inputChannels: 0, outputChannels: 2, transport: kAudioDeviceTransportTypeUSB)
    let value = AppModel(providerFactory: { provider }, audioFactory: { audio }, deviceList: { [input, output] }, loadKey: { "synthetic-test-value" }, requestPermission: permission, sleepForText: { seconds in
        if let clock { try await clock.sleep(seconds) }
        else { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    })
    value.destination = .listen; value.inputUID = input.uid; value.outputUID = output.uid
    return value
}
@MainActor private func recoveryModel(_ providers: [FakeProvider], _ audio: FakeAudio, catalog: DeviceCatalog, clock: TextClock, outgoing: Bool = false, key: @escaping @MainActor () throws -> String = { "synthetic-fixture" }) -> AppModel {
    var index = 0
    let app = AppModel(providerFactory: { let provider = providers[min(index, providers.count - 1)]; index += 1; return provider }, audioFactory: { audio }, deviceList: { catalog.devices }, loadKey: key, requestPermission: { true }, nowForControl: { clock.now }, sleepForControl: { try await clock.sleep($0) })
    app.destination = outgoing ? .teams : .listen
    app.inputUID = outgoing ? "mic-one" : "blackhole-2ch"
    app.outputUID = outgoing ? "blackhole-2ch" : "headphones"
    return app
}
@main private struct LifecycleChecks {
    @MainActor static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Hear changes live during translation and resets to the translation at launch", {
                let trace = Trace(), audio = FakeAudio(trace)
                let app = model(FakeProvider(trace), audio)
                await app.setTranslationEnabled(true)
                try await until { app.phase == .running }
                try require(app.configurationLocked && app.hearing == .translation, "Fixture must translate with Hear: Translation")
                app.hearing = .original
                try require(app.hearing == .original && audio.listening.last?.muted == true, "Hear Original must mute speech live")
                app.hearing = .both
                try require(app.hearing == .both && audio.listening.last.map { $0.mix && !$0.muted } == true, "Hear Both must mix the original live")
                app.hearing = .translation
                try require(app.hearing == .translation && audio.listening.last.map { !$0.mix && !$0.muted } == true, "Hear Translation must apply live")
                try require(app.phase == .running && audio.starts == 1, "Changing Hear must not restart the session")
            }),
            ("Output volume applies at start and live, and is never locked", {
                let trace = Trace(), audio = FakeAudio(trace), store = MemoryAppPreferences()
                let app = model(FakeProvider(trace), audio)
                app.outputVolume = 0.4
                await app.setTranslationEnabled(true)
                try await until { app.phase == .running }
                try require(audio.volumes.last == 0.4, "Start must apply the saved volume: \(audio.volumes)")
                try require(app.configurationLocked, "Fixture must be translating with settings locked")
                app.outputVolume = 0.7
                try require(app.outputVolume == 0.7 && audio.volumes.last == 0.7, "Volume must change live during translation")
                app.outputVolume = 3
                try require(app.outputVolume == 1 && audio.volumes.last == 1, "Volume must clamp to 100 percent")
                var saved = AppPreferences(); saved.outputVolume = 0.3; store.save(saved)
                let restored = AppModel(providerFactory: { FakeProvider(trace) }, audioFactory: { audio }, deviceList: { [] },
                                        loadKey: { "synthetic-test-value" }, preferences: store)
                try require(restored.outputVolume == 0.3, "The saved volume must restore")
            }),
            ("A loopback input plays original audio until Off, with settings editable", {
                let trace = Trace(), catalog = DeviceCatalog(), audio = FakeAudio(trace)
                let app = AppModel(providerFactory: { FakeProvider(trace) }, audioFactory: { audio }, deviceList: { catalog.devices },
                                   loadKey: { "synthetic-test-value" }, requestPermission: { true }, playsLoopbackOriginal: { true })
                app.destination = .listen; app.inputUID = "blackhole-2ch"; app.outputUID = "headphones"
                try await until { app.phase == .running }
                try require(app.bypass && audio.starts == 1 && app.playingOriginalOnly, "A loopback input must start original audio")
                try require(!app.configurationLocked, "Settings must stay editable while only original audio plays")
                app.targetLanguage = "de"
                try require(app.targetLanguage == "de", "A language change was rejected during original audio")
                app.inputUID = "mic-one"
                try await until { app.phase == .running && audio.starts == 2 }
                try require(app.bypass, "A device change must restart original audio on the new device")
                await app.stop()
                app.inputUID = "blackhole-2ch"
                for _ in 0..<200 { await Task.yield() }
                try require(app.phase == .idle && audio.starts == 2, "Off must keep original audio off")
                let micAudio = FakeAudio(trace)
                let mic = AppModel(providerFactory: { FakeProvider(trace) }, audioFactory: { micAudio }, deviceList: { catalog.devices },
                                   loadKey: { "synthetic-test-value" }, requestPermission: { true }, playsLoopbackOriginal: { true })
                mic.destination = .listen; mic.inputUID = "mic-one"; mic.outputUID = "headphones"
                for _ in 0..<200 { await Task.yield() }
                try require(mic.phase == .idle && micAudio.starts == 0, "A physical microphone must never start by itself")
            }),
            ("Presentation keeps lifecycle notices consistent and visible", {
                let trace = Trace(), provider = FakeProvider(Trace())
                let app = model(provider, FakeAudio(trace))
                try require(app.sessionTitle == "Audio off", "Idle presentation differs")
                try require(app.setupRequirements.isEmpty, "Physical local route unexpectedly needs BlackHole")
                await app.start()
                try require(app.sessionTitle == "Translating", "Translation state missing")
                await app.setMuted(true)
                try require(app.sessionTitle == "Muted" && app.sessionNotice.contains("silent"), "Mute notice missing")
                await app.stop()
                if app.muted { await app.setMuted(false) }
                app.outputUID = "missing"
                await app.start()
                try require(app.sessionTitle == "Needs your attention" && app.sessionNotice == app.status, "Failure detail is hidden")
                try require(app.setupRequirements.contains(where: { $0.contains("headphones") }), "Physical output recovery missing")
            }),
            ("Setup requirements follow service dependencies without reading credentials", {
                var present: Set<ProviderService> = [.openAI]
                let app = AppModel(providerFactory: { FakeProvider(Trace()) }, deviceList: { [] }, serviceKeyPresence: { present.contains($0) })
                app.route = .elevenLabs
                try require(app.setupRequirements.contains(where: { $0.contains("ElevenLabs API key") }), "ElevenLabs dependency missing")
                try require(!app.setupRequirements.contains(where: { $0.contains("Fish Audio API key") }), "Unneeded Fish requirement")
                try require(app.setupRequirements.contains(where: { $0.contains("Choose a voice") }), "Voice setup missing")
                app.route = .fish
                try require(app.requiredAccountNames == "OpenAI, ElevenLabs, Fish Audio", "Fish dependencies incomplete")
                try require(!app.setupRequirements.contains(where: { $0.contains("Choose a voice") }), "Optional Fish voice blocked setup")
                present = Set(ProviderService.allCases); app.refreshKeyStatus()
                try require(!app.setupRequirements.contains(where: { $0.contains("API key") }), "Saved accounts did not collapse")
            }),
            ("Production capture callback may synchronously re-enter audio control", {
                let reference = CallbackReference()
                let fixture = AudioPipeline.captureDeliveryFixtureForChecks { _ in _ = reference.read() }
                reference.set(fixture.level)
                try fixture.deliver(Data([0,0])); fixture.stop()
            }),
            ("Slow production callback does not hold audio control or prevent Stop", {
                let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
                let fixture = AudioPipeline.captureDeliveryFixtureForChecks { _ in entered.signal(); _ = release.wait(timeout: .now() + 2) }
                DispatchQueue.global().async { try? fixture.deliver(Data([0,0])); done.signal() }
                try require(entered.wait(timeout: .now() + 1) == .success, "Callback was not entered")
                let before = ProcessInfo.processInfo.systemUptime
                _ = fixture.level(); fixture.stop()
                let elapsed = ProcessInfo.processInfo.systemUptime - before
                release.signal(); try require(done.wait(timeout: .now() + 1) == .success, "Callback did not exit")
                try require(elapsed < 0.5, "External callback held audio control/Stop")
                try fixture.deliver(Data([0,0]))
                try require(entered.wait(timeout: .now() + 0.02) == .timedOut, "Stopped capture admitted another callback")
            }),
            ("Mute silences native audio before waiting for an in-flight append fence", {
                let stop = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
                let trace = Trace(stopSignal: stop), catalog = DeviceCatalog(), provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog); app.destination = .listen
                app.inputUID = "mic-one"; app.outputUID = "headphones"; await app.start()
                provider.appendFault.block(); let callback = audio.onPCM
                DispatchQueue.global().async { try? callback?(Data([0,0])); completed.signal() }
                try require(provider.appendFault.entered.wait(timeout: .now() + 1) == .success, "Append did not enter")
                DispatchQueue.global().async {
                    _ = stop.wait(timeout: .now() + 1)
                    trace.record("append-release"); provider.appendFault.release.signal(); released.signal()
                }
                await app.setMuted(true)
                try require(released.wait(timeout: .now() + 1) == .success && completed.wait(timeout: .now() + 1) == .success, "Append release did not complete")
                let events = trace.values
                try require(events.firstIndex(of: "audio-stop")! < events.firstIndex(of: "append-release")!, "Mute waited for append before native silence")
                let sent = events.filter { $0.hasPrefix("append:") }.count
                try callback?(Data([0,0]))
                try require(trace.values.filter { $0.hasPrefix("append:") }.count == sent, "Closed admission accepted late upload")
                await app.stop()
            }),
            ("Confirmed idle waits exactly two seconds and resets muted intent", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer(), clock = TextClock()
                let app = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog, consumer: consumer, controlClock: clock)
                app.inputUID = "mic-one"; await app.setMicrophoneArmed(true)
                consumer.emit(.active); try await until { app.active }; await app.setTranslationEnabled(true)
                await app.setMuted(true)
                consumer.emit(.idle); try await until { clock.pending }
                clock.advance(1.999); for _ in 0..<20 { await Task.yield() }
                try require(app.consumerActive && app.translationEnabled, "Idle ended before two seconds")
                clock.advance(0.001); try await until { !app.consumerActive }
                try require(app.microphoneArmed && app.muted && app.bypass, "Confirmed departure did not preserve Mute/reset translation")
                consumer.emit(.active); try await until { app.consumerActive }; await app.setMuted(false)
                try require(app.active && app.bypass, "Unmute revived old call translation")
                await app.stop()
            }),
            ("Unknown observations never start capture and cannot renew ten-second deadline", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer(), clock = TextClock(), audio = FakeAudio(Trace())
                let app = configuredModel(FakeProvider(trace), audio, catalog: catalog, consumer: consumer, controlClock: clock)
                app.inputUID = "mic-one"; await app.setMicrophoneArmed(true)
                consumer.emit(.unknown); try await until { clock.pending }
                clock.advance(5); consumer.emit(.unsupported); for _ in 0..<20 { await Task.yield() }
                clock.advance(4.999); for _ in 0..<20 { await Task.yield() }
                try require(!app.active && !app.requiresConsumerResume && audio.starts == 0, "Unknown started capture or expired early")
                clock.advance(0.001); try await until { app.requiresConsumerResume }
                try require(app.microphoneArmed && audio.starts == 0, "Unknown disarmed readiness or started audio")
                consumer.emit(.active); try await until { app.active }
                try require(app.bypass && !app.requiresConsumerResume, "Confirmed return restored translation")
                await app.stop()
            }),
            ("Unknown preserves active translation until deadline then returns only original", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer(), clock = TextClock(), audio = FakeAudio(Trace())
                let app = configuredModel(FakeProvider(trace), audio, catalog: catalog, consumer: consumer, controlClock: clock)
                app.inputUID = "mic-one"; await app.setMicrophoneArmed(true); consumer.emit(.active); try await until { app.active }
                await app.setTranslationEnabled(true); consumer.emit(.unknown); try await until { clock.pending }
                clock.advance(9.999); for _ in 0..<20 { await Task.yield() }
                try require(app.active && !app.bypass, "Unknown interrupted translation before deadline")
                clock.advance(0.001); try await until { !app.active }
                try require(app.requiresConsumerResume && app.microphoneArmed && app.bypass, "Unknown timeout lost readiness or intent")
                consumer.emit(.active); try await until { app.active }; try require(app.bypass, "Uncertain call resumed translation")
                await app.stop()
            }),
            ("Ready opt-in survives recreation while explicit Mute and Off remain authoritative", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer(), clock = TextClock(), store = MemoryAppPreferences()
                let app = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog, store: store, consumer: consumer, controlClock: clock)
                app.inputUID = "mic-one"; await app.setMicrophoneArmed(true); await app.setMuted(true)
                let secondConsumer = FakeConsumer(), secondAudio = FakeAudio(trace)
                let second = configuredModel(FakeProvider(trace), secondAudio, catalog: catalog, store: store, consumer: secondConsumer, controlClock: clock)
                try await until { second.microphoneArmed }; secondConsumer.emit(.active); try await until { second.consumerActive }
                try require(second.muted && !second.active && secondAudio.starts == 0, "Relaunch overrode Mute")
                await second.stop()
                let third = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog, store: store, consumer: FakeConsumer())
                for _ in 0..<20 { await Task.yield() }
                try require(!third.microphoneArmed && !third.active && !store.load().readyForCalls, "Off restored readiness")
                app.abort()
            }),
            ("Both directions reconnect automatically up to three times per 10 minutes on the same graph", {
                for outgoing in [false, true] {
                    let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                    let first = FakeProvider(trace), second = FakeProvider(trace), third = FakeProvider(trace)
                    let fourth = FakeProvider(trace), fifth = FakeProvider(trace), sixth = FakeProvider(trace)
                    second.holdStart = true
                    let app = recoveryModel([first, second, third, fourth, fifth, sixth], audio, catalog: catalog, clock: clock, outgoing: outgoing)
                    await app.start(); let oldAudio = first.onAudio
                    await first.onEvent?(.failure("translation_disconnected")); try await until { second.startEntered && clock.pending }
                    try require(app.active && app.bypass && app.reconnecting && audio.starts == 1 && !audio.stopped && !audio.mixEnabled, "Recovery interrupted original route")
                    try require(app.sessionTitle == "Reconnecting…" && app.sessionNotice.contains("Original audio continues"), "Recovery presentation differs")
                    second.releaseStart(); try await until { !app.bypass }
                    let played = trace.values.filter { $0 == "translated-play" }.count
                    try await oldAudio?(Data([0,0])); try require(trace.values.filter { $0 == "translated-play" }.count == played, "Old speech replayed after reconnect")
                    try await second.onAudio?(Data([0,0])); try require(trace.values.filter { $0 == "translated-play" }.count == played + 1, "New translated sink did not play")
                    await second.onEvent?(.failure("translation_disconnected")); try await until { third.starts == 1 && !app.bypass }
                    await third.onEvent?(.failure("translation_disconnected")); try await until { fourth.starts == 1 && !app.bypass }
                    try require(audio.starts == 1, "Automatic reconnects rebound the graph")
                    await fourth.onEvent?(.failure("translation_disconnected")); for _ in 0..<40 { await Task.yield() }
                    try require(app.bypass && fifth.starts == 0, "A fourth automatic reconnect within 10 minutes must wait for Retry")
                    await app.retryTranslation(); try require(!app.bypass && fifth.starts == 1 && audio.starts == 1, "Explicit Retry failed")
                    clock.advance(AppModel.automaticRecoveryWindow)
                    await fifth.onEvent?(.failure("translation_disconnected")); try await until { sixth.starts == 1 && !app.bypass }
                    await app.stop()
                }
            }),
            ("Late translated audio returns to original and reconnects; only a playback failure stops", {
                for code in ["received_audio_stale", "received_audio_backlog", "audio_burst_exceeds_five_seconds"] {
                    let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                    let first = FakeProvider(trace), second = FakeProvider(trace)
                    let app = recoveryModel([first, second], audio, catalog: catalog, clock: clock)
                    await app.start(); let oldAudio = first.onAudio
                    await first.onEvent?(.failure(code)); try await until { second.starts == 1 && !app.bypass }
                    try require(app.active && !audio.stopped && audio.starts == 1, "\(code) stopped the session instead of recovering")
                    let played = trace.values.filter { $0 == "translated-play" }.count
                    try await oldAudio?(Data([0,0])); try require(trace.values.filter { $0 == "translated-play" }.count == played, "\(code) replayed stale audio")
                    await app.stop()
                }
                let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                let first = FakeProvider(trace), second = FakeProvider(trace)
                let app = recoveryModel([first, second], audio, catalog: catalog, clock: clock)
                await app.start(); await first.onEvent?(.failure("audio_playback_failed")); for _ in 0..<40 { await Task.yield() }
                try require(!app.active && second.starts == 0, "Playback failure did not stop safely")
            }),
            ("Absolute reconnect expiry includes synchronous credential loading", {
                let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                let first = FakeProvider(trace), second = FakeProvider(trace)
                var loads = 0
                let app = recoveryModel([first, second], audio, catalog: catalog, clock: clock, key: {
                    loads += 1
                    if loads == 2 { clock.advance(10.001) }
                    return "synthetic-fixture"
                })
                await app.start(); await first.onEvent?(.failure("translation_disconnected"))
                try await until { loads == 2 && !app.reconnecting }
                try require(second.starts == 0 && app.bypass && app.active && !audio.stopped && audio.starts == 1,
                            "Expired credential load started a provider or interrupted original audio")
                await app.stop()
            }),
            ("Absolute reconnect expiry rejects synchronous late startup success", {
                let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                let first = FakeProvider(trace), second = FakeProvider(trace)
                second.onStart = { clock.advance(10.001) }
                let app = recoveryModel([first, second], audio, catalog: catalog, clock: clock)
                await app.start(); await first.onEvent?(.failure("translation_disconnected"))
                try await until { second.startEntered && !app.reconnecting }
                try require(second.starts == 1 && app.bypass && app.active && !audio.stopped && audio.starts == 1 &&
                            !trace.values.contains("translation-switch"),
                            "Late synchronous startup was adopted after the deadline")
                await app.stop()
            }),
            ("Reconnect deadline and user/device actions reject late noncooperative success", {
                for action in ["deadline", "mute", "off", "device"] {
                    let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                    let first = FakeProvider(trace), second = FakeProvider(trace); second.holdStart = true
                    let app = recoveryModel([first, second], audio, catalog: catalog, clock: clock)
                    await app.start(); await first.onEvent?(.failure("translation_disconnected")); try await until { second.startEntered && clock.pending }
                    if action == "deadline" { clock.advance(10); try await until { !app.reconnecting } }
                    if action == "mute" { await app.setMuted(true) }
                    if action == "off" { await app.stop() }
                    if action == "device" { catalog.devices.removeAll { $0.uid == "blackhole-2ch" }; app.reconcileDeviceInventoryForChecks() }
                    second.releaseStart(); for _ in 0..<40 { await Task.yield() }
                    try require(app.bypass && !app.reconnecting && !trace.values.contains("translation-switch"), "Late recovery overrode \(action)")
                    if action == "deadline" { try require(app.active && !audio.stopped && audio.starts == 1, "Timeout lost original audio") }
                    else { try require(!app.active && audio.stopped, "Action did not stop audio") }
                    await app.stop()
                }
            }),
            ("Upload-admission failure closes once without invoking native capture failure", {
                let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                let first = FakeProvider(trace), second = FakeProvider(trace); second.holdStart = true
                let app = recoveryModel([first, second], audio, catalog: catalog, clock: clock)
                await app.start(); first.appendFault.enable()
                let capture = audio.onPCM
                for _ in 0..<20 { try capture?(Data([0,0])) }
                try await until { second.startEntered }
                try require(app.active && app.bypass && !audio.stopped && audio.starts == 1 && second.starts == 1, "Upload error tore down native audio or repeated reconnect")
                await app.stop(); second.releaseStart()
            }),
            ("Cancelled queued retry never creates a cloud candidate", {
                let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                let first = FakeProvider(trace), second = FakeProvider(trace)
                let app = recoveryModel([first, second], audio, catalog: catalog, clock: clock)
                await app.start(); await first.onEvent?(.failure("invalid_api_key"))
                app.cancelScheduledRetryForChecks()
                for _ in 0..<60 { await Task.yield() }
                try require(second.starts == 0 && app.bypass && !app.reconnecting, "Cancelled-before-entry task reopened cloud translation")
                await app.stop()
            }),
            ("Fallback then Off never claims original audio continues", {
                for outgoing in [false, true] {
                    let trace = Trace(), clock = TextClock(), first = FakeProvider(Trace())
                    let app = recoveryModel([first], FakeAudio(trace), catalog: DeviceCatalog(), clock: clock, outgoing: outgoing)
                    await app.start(); await first.onEvent?(.failure("quota_exceeded"))
                    try require(app.active && app.bypass && app.translationIssue != nil, "Fallback was not established")
                    try require(app.sessionNotice.contains("Original audio continues"), "Active fallback notice missing")
                    await app.stop()
                    try require(app.sessionTitle == "Audio off" && !app.sessionNotice.contains("Original audio continues"), "Off retained an active fallback notice")
                }
            }),
            ("A new startup failure is not masked by an earlier fallback", {
                for outgoing in [false, true] {
                    let trace = Trace(), clock = TextClock(), first = FakeProvider(Trace())
                    let app = recoveryModel([first], FakeAudio(trace), catalog: DeviceCatalog(), clock: clock, outgoing: outgoing)
                    await app.start(); await first.onEvent?(.failure("quota_exceeded"))
                    try require(app.translationIssue != nil, "Fallback was not established")
                    await app.stop(); app.outputUID = "unavailable-output"; await app.start()
                    try require(app.phase == .failed && app.sessionTitle == "Needs your attention", "Expected startup failure missing")
                    try require(app.sessionNotice == app.status && !app.sessionNotice.contains("Original audio continues"), "Old fallback masks current startup failure")
                }
            }),
            ("Credential billing and invalid configuration failures never automatically retry", {
                for code in ["invalid_api_key", "quota_exceeded", "recognition_failed", "text_translation_failed", "invalid_request"] {
                    let trace = Trace(), catalog = DeviceCatalog(), clock = TextClock(), audio = FakeAudio(trace)
                    let first = FakeProvider(trace), second = FakeProvider(trace)
                    let app = recoveryModel([first, second], audio, catalog: catalog, clock: clock)
                    await app.start(); await first.onEvent?(.failure(code)); for _ in 0..<30 { await Task.yield() }
                    try require(app.active && app.bypass && !audio.stopped && audio.starts == 1 && second.starts == 0, "Nonretryable failure retried or stopped original")
                    await app.stop()
                }
            }),
            ("Text-only completion expires at five seconds without stopping original", {
                let provider = FakeProvider(Trace()), audio = FakeAudio(Trace()), clock = TextClock()
                provider.holdFinish = true
                let app = model(provider, audio, clock: clock)
                await app.start()
                let oldEvents = provider.onEvent
                await app.setTranslationEnabled(false)
                try await until { clock.pending && provider.finishEntered }
                try require(app.sessionTitle == "Original audio · finishing transcript…" && app.sessionNotice.contains("Original audio continues"), "Text completion wrongly claims audio is off")
                clock.advance(4.999)
                await oldEvents?(.targetTranscript("accepted"))
                try require(app.translation == "accepted", "Text ended before deadline")
                clock.advance(0.001)
                try await until { provider.onEvent == nil }
                await oldEvents?(.targetTranscript("too late"))
                try require(app.translation == "accepted" && app.active && app.bypass && !audio.stopped, "Deadline admitted late text or stopped original")
                provider.releaseFinish(); await app.stop()
            }),
            ("Mute and Off cancel text completion and stale capture without waiting", {
                for mute in [false, true] {
                    let provider = FakeProvider(Trace()), audio = FakeAudio(Trace()), clock = TextClock()
                    provider.holdFinish = true
                    let app = model(provider, audio, clock: clock)
                    await app.start()
                    let oldEvents = provider.onEvent, oldCapture = audio.onPCM
                    await oldEvents?(.sourceTranscript("retained"))
                    await app.setTranslationEnabled(false)
                    try await until { clock.pending && provider.finishEntered }
                    if mute { await app.setMuted(true) } else { await app.stop() }
                    try oldCapture?(Data([0,0]))
                    await oldEvents?(.sourceTranscript("late"))
                    try require(!app.active && audio.stopped && app.source == "retained" && !provider.trace.values.contains("append:2"), "Cancellation admitted stale work")
                    clock.advance(5); provider.releaseFinish()
                    for _ in 0..<10 { await Task.yield() }
                    try require(!app.active, "Late finalizer restarted audio")
                }
            }),
            ("Mute restores fresh intent, preserves received text, and survives relaunch", {
                let catalog = DeviceCatalog(), store = MemoryAppPreferences(), provider = FakeProvider(Trace()), audio = FakeAudio(Trace())
                let app = configuredModel(provider, audio, catalog: catalog, store: store)
                app.inputUID = "mic-one"
                await app.start()
                let staleEvents = provider.onEvent, staleCapture = audio.onPCM
                await staleEvents?(.targetTranscript("retained"))
                await app.setMuted(true)
                try staleCapture?(Data([0,0]))
                await staleEvents?(.targetTranscript("obsolete"))
                try require(app.translation == "retained" && !provider.trace.values.contains("append:2"), "Mute admitted stale content")
                let recreated = configuredModel(FakeProvider(Trace()), FakeAudio(Trace()), catalog: catalog, store: store)
                try require(recreated.muted && !recreated.active, "Relaunch lost explicit Mute")
                await app.setMuted(false)
                try require(app.active && !app.bypass && provider.starts == 2, "Unmute did not open a fresh translated session")
                await staleEvents?(.targetTranscript("old session"))
                try require(app.translation.isEmpty, "Fresh session admitted old text")
                await app.stop()
                let off = configuredModel(FakeProvider(Trace()), FakeAudio(Trace()), catalog: catalog, store: store)
                try require(!off.muted && !off.active && !off.microphoneArmed, "Relaunch did not preserve Off")
            }),
            ("Off cancels immediately without draining capture or finalizing", {
                let trace = Trace(), provider = FakeProvider(Trace()), audio = FakeAudio(Trace())
                let app = model(provider, audio)
                var silencedBeforeCoverageCallback = false
                app.onTranscriptSession = { _, began, _ in if !began { silencedBeforeCoverageCallback = audio.stopped } }
                await app.start(); await app.stop()
                try require(silencedBeforeCoverageCallback, "Off notified transcript observers before silencing output")
                try require(!provider.finishEntered && !audio.drainEntered && !app.active, "Off drained or finalized instead of cancelling")
                _ = trace
            }),
            ("Provider settings migrate, remember per-service voices and freeze session configuration", {
                let old = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
                try require(old.providerRoute == "openai" && old.voices.isEmpty, "Legacy preferences did not migrate")
                let trace = Trace(), catalog = DeviceCatalog(), store = MemoryAppPreferences()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = AppModel(providerFactory: { provider }, audioFactory: { audio }, deviceList: { catalog.devices }, requestPermission: { true }, preferences: store,
                    providerResolver: { _ in provider }, loadProviderCredentials: { _ in ProviderCredentials(openAI: "fixture-a", elevenLabs: "fixture-b", fish: "fixture-c") })
                app.inputUID = "mic-one"; app.route = .elevenLabs; app.voiceID = "voice-eleven"; app.sourceLanguage = "no"; app.targetLanguage = "sv"
                app.route = .fish; app.voiceID = "voice-fish"; app.route = .elevenLabs
                try require(app.voiceID == "voice-eleven", "Per-route voice lost")
                provider.holdStart = true
                let starting = Task { await app.start() }; try await until { provider.startEntered }
                app.route = .fish; app.voiceID = "changed"; app.sourceLanguage = "en"
                provider.releaseStart(); await starting.value; provider.holdStart = false
                try require(app.phase == .running && provider.configuration?.route == .elevenLabs && provider.configuration?.voiceID == "voice-eleven" && provider.configuration?.sourceLanguage == "no", "Session did not freeze selected provider settings")
                app.abort(); app.route = .openAI; app.targetLanguage = "en"; await app.start()
                try require(provider.configuration?.sourceLanguage == nil && provider.configuration?.voiceID == nil, "Direct OpenAI received unsupported hint or voice")
                app.abort()
                let restored = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog, store: store)
                restored.route = .fish
                try require(restored.voiceID == "voice-fish" && restored.sourceLanguage == "no", "Provider settings did not persist")
            }),
            ("Missing composed credentials never open microphone capture", {
                let catalog = DeviceCatalog(), provider = FakeProvider(Trace()), audio = FakeAudio(Trace())
                let app = AppModel(providerFactory: { provider }, audioFactory: { audio }, deviceList: { catalog.devices }, requestPermission: { true },
                    providerResolver: { _ in provider }, loadProviderCredentials: { _ in ProviderCredentials(openAI: "fixture-a") })
                app.inputUID = "mic-one"; app.route = .fish
                await app.start()
                try require(app.phase == .failed && audio.starts == 0 && provider.starts == 0, "Missing service credentials opened capture")
            }),
            ("Duplex sessions remain independent and Stop both silences before either transcript finishes", {
                let catalog = DeviceCatalog()
                catalog.devices.append(AudioDevice(id: 5, uid: "blackhole-16ch", name: "BlackHole 16ch", inputChannels: 16, outputChannels: 16, transport: kAudioDeviceTransportTypeVirtual))
                let p1 = FakeProvider(Trace()), p2 = FakeProvider(Trace()), a1 = FakeAudio(Trace()), a2 = FakeAudio(Trace())
                let outgoing = configuredModel(p1, a1, catalog: catalog), incoming = configuredModel(p2, a2, catalog: catalog)
                outgoing.inputUID = "mic-one"; outgoing.outputUID = "blackhole-2ch"
                incoming.destination = .listen; incoming.inputUID = "blackhole-16ch"; incoming.outputUID = "headphones"
                let conversation = ConversationModel(outgoing: outgoing, incoming: incoming)
                await outgoing.start(); await incoming.start()
                try require(outgoing.active && incoming.active, "Separate duplex graph did not start")
                await p1.onEvent?(.sourceTranscript("hei")); await p2.onEvent?(.sourceTranscript("hello"))
                try require(Set(conversation.transcript.entries.map(\.direction)).count == 2, "Directions lost in meeting ledger")
                await outgoing.stop()
                try require(!outgoing.active && incoming.active && !a2.stopped, "Stopping outgoing interrupted incoming")
                await outgoing.start(); p1.holdFinish = true; p2.holdFinish = true
                await conversation.stopAll()
                try require(a1.stopped && a2.stopped && !p1.finishEntered && !p2.finishEntered, "Off must silence/cancel both without finalization")
                try require(!conversation.active && conversation.transcript.sessions.allSatisfy { $0.endedAt != nil }, "Session coverage did not close")
                incoming.inputUID = "blackhole-2ch"; await incoming.start()
                try require(incoming.active, "Incoming-only translation incorrectly reserved an idle outgoing route")
                await outgoing.start()
                try require(outgoing.phase == .failed && a1.starts == 2, "Shared loopback feedback route was admitted")
                conversation.abort()
            }),
            ("Off preserves text and explicitly marks interrupted coverage", {
                let catalog = DeviceCatalog(), provider = FakeProvider(Trace()), audio = FakeAudio(Trace())
                let outgoing = configuredModel(provider, audio, catalog: catalog)
                outgoing.inputUID = "mic-one"
                let incoming = configuredModel(FakeProvider(Trace()), FakeAudio(Trace()), catalog: catalog)
                let conversation = ConversationModel(outgoing: outgoing, incoming: incoming)
                await outgoing.start()
                await provider.onEvent?(.sourceTranscript("before"))
                let oldEvents = provider.onEvent
                await outgoing.stop()
                await oldEvents?(.sourceTranscript("after"))
                try require(outgoing.source == "before" && !provider.finishEntered, "Off admitted late text or finalized")
                try require(conversation.transcript.sessions.first?.endedAt != nil && conversation.transcript.plainText().contains("without finalizing"), "Interrupted coverage not recorded")
            }),
            ("Stop rejects late provider startup without opening capture", {
                let trace = Trace()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                provider.holdStart = true; provider.holdFinish = true
                let app = model(provider, audio)
                let starting = Task { await app.start() }
                try await until { provider.startEntered }
                let stopping = Task { await app.stop() }
                try await until { app.phase != .starting }
                provider.releaseStart(); await starting.value
                let opened = audio.starts
                provider.releaseFinish(); await stopping.value
                try require(opened == 0, "Late startup opened audio after Stop")
                try require(app.phase == .idle, "Stop did not reach idle")
                try require(!provider.finishEntered, "Connecting sessions must cancel instead of racing close")
            }),
            ("Stop rejects late microphone permission", {
                let trace = Trace(), permission = PermissionGate()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = model(provider, audio, permission: { await permission.request() })
                let starting = Task { await app.start() }
                try await until { permission.entered }
                await app.stop(); permission.allow(); await starting.value
                try require(!provider.startEntered && audio.starts == 0 && app.phase == .idle, "Late permission restarted capture")
            }),
            ("Stop translating switches original immediately and accepts text only", {
                let trace = Trace(), audio = FakeAudio(Trace()), sharedProvider = FakeProvider(Trace())
                sharedProvider.holdFinish = true
                let app = model(sharedProvider, audio)
                await app.start()
                let staleCapture = audio.onPCM
                await app.setTranslationEnabled(false)
                try await until { sharedProvider.finishEntered }
                try require(app.active && app.bypass && audio.starts == 1 && !audio.stopped && !audio.drainEntered, "Original switch restarted or drained devices")
                try require(audio.trace.values.contains("original-switch") && sharedProvider.trace.values.contains("input-closed"), "Immediate audio/input boundary missing")
                try staleCapture?(Data([0, 0]))
                await sharedProvider.onEvent?(.audio(Data([0, 0])))
                await sharedProvider.onEvent?(.targetTranscript("tail"))
                try require(!sharedProvider.trace.values.contains("append:2") && !audio.trace.values.contains("translated-play"), "Late PCM or translated speech admitted")
                sharedProvider.releaseFinish()
                for _ in 0..<20 { await Task.yield() }
                await sharedProvider.onEvent?(.targetTranscript("obsolete"))
                try require(app.translation == "tail", "Late completed text admitted")
                audio.onFailure?("fixture output failure")
                try require(app.phase == .failed, "Original route lost its failure callback")
                _ = trace
            }),
            ("Bypass rejects obsolete startup and loopback disables microphone preprocessing", {
                let trace = Trace()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                provider.holdStart = true
                let app = model(provider, audio, loopback: true)
                let starting = Task { await app.start() }
                try await until { provider.startEntered }
                await app.setBypass(true); provider.releaseStart(); await starting.value
                try require(app.phase == .running && app.bypass && audio.starts == 1, "Old startup replaced bypass")
                try require(provider.configuration?.noiseReduction == .disabled, "Loopback preprocessing was enabled")
                await provider.onEvent?(.failure("obsolete_failure"))
                try require(app.phase == .running, "Obsolete failure stopped bypass")
                await app.stop()
            }),
            ("Route preferences survive model recreation without substituting a missing microphone", {
                let trace = Trace(), catalog = DeviceCatalog(), store = MemoryAppPreferences()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, store: store)
                try require(app.inputUID.isEmpty && app.outputUID == "blackhole-2ch", "Initial route chose an input or missed unique BlackHole")
                app.inputUID = "mic-one"
                app.destination = .listen; app.inputUID = "blackhole-2ch"; app.outputUID = "headphones"
                app.targetLanguage = "fr"; app.transcriptVisible = true
                app.destination = .teams
                try require(app.inputUID == "mic-one" && app.outputUID == "blackhole-2ch", "Per-mode route was overwritten")
                catalog.devices.removeAll { $0.uid == "mic-one" }
                let restored = configuredModel(provider, audio, catalog: catalog, store: store)
                try require(restored.inputUID == "mic-one" && !restored.inputAvailable, "Missing microphone silently fell back")
                try require(restored.selectedInputName == "First microphone", "Missing-device friendly name was lost")
                try require(restored.targetLanguage == "fr" && restored.transcriptVisible, "Preferences were not restored")
                await restored.start()
                try require(!provider.startEntered && audio.starts == 0, "Unavailable route started capture")
                catalog.devices.append(AudioDevice(id: 99, uid: "mic-one", name: "First microphone", inputChannels: 1, outputChannels: 0, transport: kAudioDeviceTransportTypeUSB))
                restored.refresh()
                try require(restored.inputAvailable && audio.starts == 0, "Reappearance must restore availability without starting")
            }),
            ("Ambiguous BlackHole and unavailable saved output require explicit selection", {
                let trace = Trace(), catalog = DeviceCatalog()
                catalog.devices.append(AudioDevice(id: 5, uid: "blackhole-second", name: "BlackHole 2ch second", inputChannels: 2, outputChannels: 2, transport: kAudioDeviceTransportTypeVirtual))
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog)
                try require(app.outputUID.isEmpty, "Ambiguous BlackHole selected first match")
                app.outputUID = "blackhole-second"
                catalog.devices.removeAll { $0.uid == "blackhole-second" }
                app.refresh()
                try require(app.outputUID == "blackhole-second" && !app.outputAvailable, "Missing BlackHole silently changed variant")
                app.outputUID = ""; app.refresh()
                try require(app.outputUID.isEmpty, "Refresh replaced an explicitly cleared output")
            }),
            ("Your voice prefers Babelfin Microphone and never takes Babelfin Speaker", {
                let trace = Trace(), catalog = DeviceCatalog()
                catalog.devices.append(AudioDevice(id: 6, uid: AudioDevice.babelfinSpeakerUID, name: "Babelfin Speaker", inputChannels: 2, outputChannels: 2, transport: kAudioDeviceTransportTypeVirtual))
                catalog.devices.append(AudioDevice(id: 7, uid: AudioDevice.babelfinMicrophoneUID, name: "Babelfin Microphone", inputChannels: 2, outputChannels: 2, transport: kAudioDeviceTransportTypeVirtual))
                let app = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog)
                try require(app.outputUID == AudioDevice.babelfinMicrophoneUID, "Babelfin Microphone was not preferred")
                catalog.devices.removeAll { $0.uid == AudioDevice.babelfinMicrophoneUID || $0.uid == "blackhole-2ch" }
                let other = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog)
                try require(other.outputUID.isEmpty, "Your voice selected Babelfin Speaker")
            }),
            ("Meeting audio prefers Babelfin Speaker only when no source is saved", {
                let trace = Trace(), catalog = DeviceCatalog(), store = MemoryAppPreferences()
                let speaker = AudioDevice(id: 6, uid: AudioDevice.babelfinSpeakerUID, name: "Babelfin Speaker", inputChannels: 2, outputChannels: 2, transport: kAudioDeviceTransportTypeVirtual)
                @MainActor func incoming(_ store: MemoryAppPreferences, meeting: Bool = true) -> AppModel {
                    let app = AppModel(providerFactory: { FakeProvider(trace) }, audioFactory: { FakeAudio(trace) }, deviceList: { catalog.devices },
                                       preferences: store, selectsMeetingSource: meeting)
                    app.destination = .listen
                    return app
                }
                let missing = incoming(store)
                try require(missing.inputUID.isEmpty, "Meeting audio selected a source without Babelfin Speaker")
                catalog.devices.append(speaker)
                missing.refresh()
                try require(missing.inputUID == AudioDevice.babelfinSpeakerUID, "Babelfin Speaker was not selected after it appeared")
                try require(store.load().listen.input?.uid == AudioDevice.babelfinSpeakerUID, "Selected Babelfin Speaker was not saved")
                let local = incoming(MemoryAppPreferences(), meeting: false)
                try require(local.inputUID.isEmpty, "Listen locally in Your voice selected Babelfin Speaker")
                let savedStore = MemoryAppPreferences()
                let saved = incoming(savedStore)
                saved.inputUID = "mic-one"
                catalog.devices.removeAll { $0.uid == "mic-one" }
                saved.refresh()
                try require(saved.inputUID == "mic-one" && !saved.inputAvailable, "Saved source was replaced by Babelfin Speaker")
                try require(incoming(savedStore).inputUID == "mic-one", "Saved source was replaced after recreation")
                let clearedStore = MemoryAppPreferences()
                let cleared = incoming(clearedStore)
                cleared.inputUID = ""; cleared.refresh()
                try require(cleared.inputUID.isEmpty && incoming(clearedStore).inputUID.isEmpty, "Explicitly cleared source was replaced")
            }),
            ("Delayed startup uses the validated target and route snapshot", {
                let trace = Trace(), catalog = DeviceCatalog(), gate = PermissionGate()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, permission: { await gate.request() })
                app.inputUID = "mic-one"; app.targetLanguage = "fr"
                app.originalMixEnabled = true; app.originalMixLevel = 0.4; app.originalMixDucking = false
                let starting = Task { await app.start() }
                try await until { gate.entered }
                app.targetLanguage = "de"; app.destination = .listen; app.inputUID = "mic-two"
                app.outputUID = "headphones"
                app.originalMixEnabled = false; app.originalMixLevel = .nan; app.originalMixDucking = true
                gate.allow(); await starting.value
                try require(provider.configuration?.targetLanguage == "fr", "Target changed during permission wait")
                try require(app.destination == .teams && app.inputUID == "mic-one", "Route changed during startup")
                try require(app.outputUID == "blackhole-2ch", "Output changed during startup")
                try require(!app.originalMixEnabled && app.originalMixLevel == 0.25 && app.originalMixDucking,
                            "Mix settings must change live during startup; a non-finite level must reset to the default")
                try require(audio.mixEnabled && audio.mixLevel == Float(0.4) && !audio.mixDucking, "Audio did not receive frozen mix settings")
                try require(app.targetLanguageName == "French" && app.transcriptLanguageName == "French", "Session labels disagree with request")
                let object = try JSONSerialization.jsonObject(with: Data(TranslationWire.update(provider.configuration!).utf8)) as! [String: Any]
                let session = object["session"] as! [String: Any], format = session["audio"] as! [String: Any]
                try require((format["output"] as! [String: Any])["language"] as? String == "fr", "Selected target did not reach wire format")
                await app.stop()
            }),
            ("Original mix level safely clamps finite and nonfinite preferences", {
                let trace = Trace(), catalog = DeviceCatalog(), store = MemoryAppPreferences()
                let app = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog, store: store)
                for (input, expected) in [(2.0, 1.0), (-1.0, 0.0), (Double.nan, 0.25), (Double.infinity, 0.25), (-Double.infinity, 0.25), (0.6, 0.6)] {
                    app.originalMixLevel = input
                    try require(app.originalMixLevel == expected && store.load().originalMixLevel == expected, "Invalid mix level remained in UI or stored preferences")
                }
                app.originalMixEnabled = true; app.originalMixDucking = false
                let restored = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog, store: store)
                try require(restored.originalMixEnabled && restored.originalMixLevel == 0.6 && !restored.originalMixDucking, "Mix preferences were not restored")
            }),
            ("Invalid targets fail safely while original audio needs no credential", {
                let trace = Trace(), catalog = DeviceCatalog()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, key: { throw CheckError(message: "Key access must not occur") })
                app.inputUID = "mic-one"; app.targetLanguage = "unsupported"
                await app.start()
                try require(app.phase == .failed && !provider.startEntered && audio.starts == 0, "Invalid language reached provider")
                await app.setBypass(true); await app.start()
                try require(app.phase == .running && !provider.startEntered, "Original audio required API credentials")
                await app.stop(); await app.start()
                try require(app.bypass && audio.starts == 2, "Original mode did not survive Stop/Start")
                app.abort()
                let relaunched = configuredModel(provider, audio, catalog: catalog)
                try require(!relaunched.bypass && !relaunched.microphoneArmed, "Launch restored live/original intent")
            }),
            ("New validated session separates transcript language and independent clearing", {
                let trace = Trace(), catalog = DeviceCatalog()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog)
                app.inputUID = "mic-one"
                await app.start(); await provider.onEvent?(.targetTranscript("old text")); await app.stop()
                app.targetLanguage = "de"
                try require(app.translation == "old text" && app.transcriptLanguageName == "English" && !app.transcriptIsCurrent, "Last transcript was relabeled")
                await app.start()
                try require(app.translation.isEmpty && app.transcriptLanguageName == "German", "New session retained old transcript")
                await provider.onEvent?(.sourceTranscript(String(repeating: "x", count: 25_000)))
                try require(app.source.count == 24_000, "Transcript memory bound changed")
                let logCount = app.logs.count
                app.clearTranscript()
                try require(app.source.isEmpty && app.logs.count == logCount, "Transcript clearing erased diagnostics")
                await provider.onEvent?(.targetTranscript("new")); app.clearDiagnostics()
                try require(app.translation == "new" && app.logs.isEmpty, "Diagnostic clearing erased transcript")
                await app.stop()
            }),
            ("Armed original audio obeys consumer, Mute and explicit Off", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, key: { throw CheckError(message: "Automatic original must be local") }, consumer: consumer)
                app.inputUID = "mic-one"
                await app.setMicrophoneArmed(true)
                try require(app.microphoneArmed && app.bypass && audio.starts == 0, "Arming started capture without consumer")
                await app.setTranslationEnabled(true); await app.testAPIConnection()
                try require(!provider.startEntered && audio.starts == 0, "Idle armed watcher allowed cloud work or translation")
                consumer.emit(.unknown); await Task.yield()
                try require(audio.starts == 0, "Unknown consumer triggered capture")
                consumer.emit(.active); try await until { app.phase == .running }
                try require(!provider.startEntered && app.consumerActive, "Automatic original connected to cloud")
                await app.setMuted(true); consumer.emit(.idle); consumer.emit(.active)
                await Task.yield()
                try require(!app.active && app.muted && audio.starts == 1, "Consumer overrode Mute")
                await app.setMuted(false); try await until { app.phase == .running }
                await app.stop(); consumer.emit(.active); await Task.yield()
                try require(!app.active && !app.microphoneArmed, "Consumer overrode explicit Off")
            }),
            ("Ending an armed translated call restores local original intent", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, consumer: consumer)
                app.inputUID = "mic-one"
                await app.setMicrophoneArmed(true)
                consumer.emit(.active); try await until { app.phase == .running }
                await app.setTranslationEnabled(true)
                try require(app.active && !app.bypass && provider.startEntered, "Explicit translation did not start")
                consumer.emit(.idle); try await until { !app.active && app.phase != .stopping }
                try require(app.microphoneArmed && app.bypass && !provider.finishEntered, "Call end left cloud session or next-call translation intent")
                await app.stop()
            }),
            ("Consumer ending during translation startup cannot restart capture", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, consumer: consumer)
                app.inputUID = "mic-one"
                await app.setMicrophoneArmed(true)
                consumer.emit(.active); try await until { app.phase == .running }
                provider.holdStart = true
                let translating = Task { await app.setTranslationEnabled(true) }
                try await until { provider.startEntered }
                consumer.emit(.idle); try await until { app.phase == .idle }
                provider.releaseStart(); await translating.value
                try require(!app.active && app.bypass && provider.starts == 1 && audio.starts == 1, "Cancelled armed startup restarted capture")
                await app.start()
                try require(!app.active && audio.starts == 1, "Armed Start ignored absent consumer")
                await app.stop()
            }),
            ("Stale idle observation cannot change a newer active consumer", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer(), clock = TextClock()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, consumer: consumer, controlClock: clock)
                app.inputUID = "mic-one"; await app.setMicrophoneArmed(true)
                consumer.emit(.active); try await until { app.active }
                await app.setTranslationEnabled(true)
                consumer.emit(.idle); try await until { clock.pending }
                consumer.emit(.active); try await until { app.consumerActive }
                clock.advance(2)
                for _ in 0..<20 { await Task.yield() }
                try require(app.active && !app.bypass && audio.starts == 1, "Stale idle timer stopped current translation")
                app.abort()
            }),

            ("Inventory publications reach the model without polling HAL on the main actor", {
                let trace = Trace(), catalog = DeviceCatalog()
                let source = InventoryFixture(catalog.devices, waitInitially: true)
                let inventory = AudioDeviceInventory(load: { source.snapshot })
                defer { inventory.stop() }
                let store = MemoryAppPreferences()
                var saved = store.load()
                saved.teams.input = SavedAudioDevice(uid: "mic-one", name: "Saved microphone")
                saved.teams.output = SavedAudioDevice(uid: "blackhole-2ch", name: "Saved loopback")
                store.save(saved)
                let app = AppModel(providerFactory: { FakeProvider(trace) }, audioFactory: { FakeAudio(trace) }, deviceList: { inventory.snapshot }, loadKey: { "synthetic-fixture" }, requestPermission: { true }, preferences: store, inventory: inventory)
                try require(app.devices.isEmpty && !app.requiresDeviceResume && app.inputUID == "mic-one", "Empty initial cache changed saved selection or declared loss")
                source.firstLoadGate.signal()
                // Allow the background coalescing deadline without opening any audio engine.
                for _ in 0..<100 where app.devices.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
                try require(!app.devices.isEmpty && !app.requiresDeviceResume, "Initial inventory publication was lost or falsely marked device loss")
                app.inputUID = "mic-one"; await app.start()
                source.replace(catalog.devices.filter { $0.uid != "mic-one" }); inventory.refresh()
                for _ in 0..<100 where !app.requiresDeviceResume { try await Task.sleep(nanoseconds: 1_000_000) }
                try require(app.requiresDeviceResume && !app.active, "Inventory observer did not stop lost route")
            }),
            ("Selected device loss blocks automatic restart until explicit Resume", {
                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, consumer: consumer)
                app.inputUID = "mic-one"
                await app.start()
                let original = catalog.devices
                catalog.devices.removeAll { $0.uid == "mic-one" }
                app.reconcileDeviceInventoryForChecks()
                try require(app.requiresDeviceResume && !app.active && audio.stopped, "Selected device loss did not stop direction")
                try require(app.sessionTitle == "Audio device disconnected" && app.sessionNotice.contains("Resume"), "Disconnected recovery notice missing")
                catalog.devices = original
                app.reconcileDeviceInventoryForChecks()
                await app.start()
                try require(!app.active && app.requiresDeviceResume, "Device return automatically restarted")
                await app.resumeSelectedDevices()
                try require(app.active && !app.requiresDeviceResume, "Explicit Resume did not restart valid selected route")
                app.abort()
            }),
            ("Unrelated inventory changes preserve active direction; UID replacement stops it", {
                let trace = Trace(), catalog = DeviceCatalog()
                let app = configuredModel(FakeProvider(trace), FakeAudio(trace), catalog: catalog)
                app.inputUID = "mic-one"; await app.start()
                catalog.devices.removeAll { $0.uid == "mic-two" }
                app.reconcileDeviceInventoryForChecks()
                try require(app.active && !app.requiresDeviceResume, "Unrelated loss stopped direction")
                let old = catalog.devices.first { $0.uid == "mic-one" }!
                catalog.devices.removeAll { $0.uid == old.uid }
                catalog.devices.append(AudioDevice(id: old.id, uid: "different-device", name: "Replacement", inputChannels: 1, outputChannels: 0, transport: old.transport))
                app.reconcileDeviceInventoryForChecks()
                try require(!app.active && app.requiresDeviceResume && !app.inputAvailable, "Reused ID authorized another microphone")
            }),
            ("Armed Unmute preserves translation while cloud failure restores original", {

                let trace = Trace(), catalog = DeviceCatalog(), consumer = FakeConsumer()
                let provider = FakeProvider(trace), audio = FakeAudio(trace)
                let app = configuredModel(provider, audio, catalog: catalog, consumer: consumer)
                app.inputUID = "mic-one"
                await app.setMicrophoneArmed(true)
                consumer.emit(.active); try await until { app.phase == .running }
                await app.setTranslationEnabled(true)
                let startsBeforeMute = provider.starts
                await app.setMuted(true); await app.setMuted(false)
                try require(app.active && !app.bypass && provider.starts == startsBeforeMute + 1, "Unmute did not restore translation in a fresh session")
                await app.setTranslationEnabled(true)
                await provider.onEvent?(.failure("translation_disconnected"))
                try require(app.active && app.bypass && app.microphoneArmed && app.translationIssue != nil, "Cloud failure did not return armed call to original")
                let audioStarts = audio.starts
                audio.onFailure?("Selected output disconnected")
                try require(app.phase == .failed && !app.microphoneArmed && audio.starts == audioStarts, "Device failure retried capture")
            })
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) lifecycle checks passed")
        if failures > 0 { exit(1) }
    }
}
#endif
