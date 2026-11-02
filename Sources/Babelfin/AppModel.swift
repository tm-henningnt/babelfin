import AppKit
import AVFoundation
import SwiftUI
import BridgeCore

private final class CaptureAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Data) throws -> Void)?
    private let failure: (@Sendable () -> Void)?
    init(_ handler: @escaping @Sendable (Data) throws -> Void, failure: (@Sendable () -> Void)? = nil) { self.handler = handler; self.failure = failure }
    func append(_ pcm: Data) throws {
        lock.lock()
        do { try handler?(pcm); lock.unlock() }
        catch {
            handler = nil; lock.unlock()
            if let failure { failure() } else { throw error }
        }
    }
    func close() { lock.lock(); handler = nil; lock.unlock() }
}

@MainActor final class AppModel: ObservableObject {
    enum Phase { case idle, starting, running, stopping, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Stopped"
    @Published private(set) var bypass = false
    @Published private(set) var requiresDeviceResume = false
    @Published private(set) var devices: [AudioDevice] = []
    @Published var destination: AudioDestination = .teams { didSet { destinationChanged(from: oldValue) } }
    @Published var inputUID = "" { didSet { inputChanged(from: oldValue) } }
    @Published var outputUID = "" { didSet { outputChanged(from: oldValue) } }
    @Published var targetLanguage = "en" { didSet { lockedSettingChanged(\.targetLanguage, from: oldValue, .outputLanguage) { $0.targetLanguage = self.targetLanguage } } }
    @Published var route: TranslationRoute = .openAI { didSet {
        guard !applyingPreferences else { return }
        if configurationLocked { applyingPreferences = true; route = oldValue; applyingPreferences = false; return }
        savedPreferences.providerRoute = route.rawValue
        applyingPreferences = true; voiceID = savedPreferences.voices[route.rawValue] ?? ""
        speakerVoices = savedPreferences.speakerVoices[route.rawValue] ?? []; applyingPreferences = false
        persistPreferences()
        settingChanged(.service)
    } }
    @Published var sourceLanguage = "" { didSet { lockedSettingChanged(\.sourceLanguage, from: oldValue, .inputLanguage) { $0.sourceLanguage = self.sourceLanguage } } }
    @Published var pacing: TranslationPacing = .balanced { didSet { lockedSettingChanged(\.pacing, from: oldValue, .delay) { $0.pacing = self.pacing.rawValue } } }
    /// The direction's output volume. It never locks: it applies at once, also during translation.
    @Published var outputVolume = 1.0 { didSet {
        guard !applyingPreferences else { return }
        let clamped = outputVolume.isFinite ? min(1, max(0, outputVolume)) : 1
        if clamped != outputVolume { outputVolume = clamped; return }
        audio?.setOutputVolume(Float(outputVolume))
        savedPreferences.outputVolume = outputVolume; persistPreferences()
    } }
    /// Off: the direction translates to text only (subtitles and transcript), and the original
    /// audio plays at full volume instead of a translated voice.
    @Published var speakTranslation = true { didSet { lockedSettingChanged(\.speakTranslation, from: oldValue, .speech) { $0.speakTranslation = self.speakTranslation } } }
    @Published var voiceID = "" { didSet { lockedSettingChanged(\.voiceID, from: oldValue, .voice) { $0.voices[self.route.rawValue] = self.voiceID } } }
    /// Voices for Speaker 1, 2, … on a route that labels speakers. Empty turns labels off.
    @Published var speakerVoices: [String] = [] { didSet {
        lockedSettingChanged(\.speakerVoices, from: oldValue, .voice) { $0.speakerVoices[self.route.rawValue] = self.speakerVoices }
    } }
    /// The speaker voices that apply: only on a route that labels speakers, and only while speaking the translation.
    var activeSpeakerVoices: [String] {
        guard route.descriptor.liveSpeakerLabels, speakTranslation else { return [] }
        return Array(speakerVoices.filter { !$0.isEmpty }.prefix(TranslationConfiguration.maximumSpeakerVoices))
    }
    var onTranscriptEvent: ((UUID, TranslationEvent) -> Void)?
    var onTranscriptSession: ((UUID, Bool, String?) -> Void)?
    private var recordedSessionID: UUID?
    var validateAdditionalRoute: ((AudioDevice, AudioDevice) throws -> Void)?
    @Published var transcriptVisible = false { didSet {
        guard !applyingPreferences else { return }
        savedPreferences.transcriptVisible = transcriptVisible; persistPreferences()
    } }
    @Published private(set) var transcriptLanguageName = "English"
    @Published private(set) var microphoneArmed = false
    @Published private(set) var muted = false
    @Published private(set) var consumerActive = false
    @Published private(set) var consumerStatus = "Not monitoring"
    @Published private(set) var translationIssue: String?
    /// Names a key permission that a check found missing after a translation failure.
    @Published private(set) var keyAdvice: String?
    /// Checks the keys that a route uses and returns advice for a missing permission. The app
    /// sets it; offline checks leave it nil, so they send no request.
    var keyDiagnosis: (@MainActor (TranslationRoute) async -> String?)?
    private var keyDiagnosisRan = false
    @Published private(set) var reconnecting = false
    @Published private(set) var requiresConsumerResume = false
    @Published var originalMixEnabled = false { didSet {
        guard !applyingPreferences else { return }
        savedPreferences.originalMixEnabled = originalMixEnabled; persistPreferences(); applyListening()
    } }
    @Published var originalMixLevel = 0.25 { didSet {
        guard !applyingPreferences else { return }
        let normalized = originalMixLevel.isFinite ? min(1, max(0, originalMixLevel)) : 0.25
        if originalMixLevel != normalized {
            applyingPreferences = true; originalMixLevel = normalized; applyingPreferences = false
        }
        savedPreferences.originalMixLevel = originalMixLevel; persistPreferences(); applyListening()
    } }
    @Published var originalMixDucking = true { didSet {
        guard !applyingPreferences else { return }
        savedPreferences.originalMixDucking = originalMixDucking; persistPreferences(); applyListening()
    } }
    /// Hear the original alone while translation keeps running. It resets at launch.
    @Published var speechMuted = false { didSet { if speechMuted != oldValue { applyListening() } } }
    enum Hearing: String, CaseIterable, Identifiable {
        case translation, both, original
        var id: String { rawValue }
        var title: String { switch self { case .translation: "Translation"; case .both: "Both"; case .original: "Original" } }
    }
    /// What the user hears while translating. It changes live and never locks.
    var hearing: Hearing {
        get { speechMuted ? .original : (originalMixEnabled ? .both : .translation) }
        set {
            switch newValue {
            case .original: speechMuted = true
            case .both: originalMixEnabled = true; speechMuted = false
            case .translation: originalMixEnabled = false; speechMuted = false
            }
        }
    }
    private func applyListening() {
        audio?.updateListening(mixEnabled: originalMixEnabled, level: Float(originalMixLevel), ducking: originalMixDucking, speechMuted: speechMuted)
    }
    @Published private(set) var source = ""
    @Published private(set) var translation = ""
    @Published private(set) var logs: [String] = []
    @Published private(set) var level: Float = 0
    /// Stage times of the latest recognized passages in a composed route, newest last.
    @Published private(set) var passageTimings: [PassageTiming] = []
    #if BABELFIN_SCREENSHOTS
    func seedDemoTimings(_ timings: [PassageTiming]) { passageTimings = timings }
    #endif
    @Published private(set) var checkingAPI = false
    @Published var keyNotice = ""
    private var audio: (any AudioPipelineControlling)?
    private var provider: (any TranslationProvider)?
    private var generation = UUID()
    @Published private var drainingGeneration: UUID?
    private var captureAdmission: CaptureAdmission?
    private var textFinisher: Task<Void, Never>?
    private var textDeadline: Task<Void, Never>?
    private var textProvider: (any TranslationProvider)?
    private let sleepForText: @Sendable (TimeInterval) async throws -> Void
    private let providerResolver: (@MainActor (TranslationRoute) -> any TranslationProvider)?
    private let loadProviderCredentials: (@MainActor (TranslationRoute) throws -> ProviderCredentials)?
    private var segmentTexts: [String: (TranscriptRole, TranscriptSegment)] = [:]
    private var segmentOrder: [String] = []
    /// Per role: the newest segment's key and the joined text before it, so a partial update of
    /// the newest segment does not join all 500 segments again.
    private var segmentTail: [TranscriptRole: (key: String, prefix: String)] = [:]
    private let providerFactory: @MainActor () -> any TranslationProvider
    private let audioFactory: @MainActor () -> any AudioPipelineControlling
    private let deviceList: @MainActor () -> [AudioDevice]
    private let loadKey: @MainActor () throws -> String
    private let requestPermission: @MainActor () async -> Bool
    @Published private(set) var accountPresence: [ProviderService: Bool] = [:]
    private let serviceKeyPresence: @MainActor (ProviderService) -> Bool?
    private let preferencesStore: any AppPreferencesStoring
    private var savedPreferences = AppPreferences()
    private var applyingPreferences = false
    private var inventoryObserver: NSObjectProtocol?
    private var inventory: AudioDeviceInventory?
    /// True for Listen: with no saved source, Babelfin Speaker becomes the source.
    private let selectsMeetingSource: Bool
    private var sessionConfiguration: AppSessionConfiguration?
    private let consumerFactory: (@MainActor () -> any ConsumerMonitoring)?
    private var consumerMonitor: (any ConsumerMonitoring)?
    private var consumerGeneration = UUID()
    private var failureRecoveryToken: UUID?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryDeadline: Task<Void, Never>?
    private var reconnectProvider: (any TranslationProvider)?
    /// Times of automatic reconnects. At most `automaticRecoveryLimit` run within
    /// `automaticRecoveryWindow`; after that the user chooses Retry.
    private var automaticRecoveries: [TimeInterval] = []
    static let automaticRecoveryLimit = 3
    static let automaticRecoveryWindow: TimeInterval = 600
    private var observationTask: Task<Void, Never>?
    private var observationToken = UUID()
    private var observationCandidate: ConsumerObservation = .unknown
    private let nowForControl: @MainActor () -> TimeInterval
    private let sleepForControl: @Sendable (TimeInterval) async throws -> Void
    var finishingTranscript: Bool { drainingGeneration != nil }
    var translationEnabled: Bool { !bypass }
    /// Settings change at any time except while a session starts or stops. During translation a
    /// change applies at once or waits for Restart (`pendingRestart`).
    var configurationLocked: Bool { phase == .starting || phase == .stopping || checkingAPI }
    enum PendingSetting: String, CaseIterable, Identifiable {
        case service, inputLanguage, outputLanguage, delay, voice, speech, devices
        var id: String { rawValue }
        var title: String {
            switch self {
            case .service: "Service"; case .inputLanguage: "Input language"; case .outputLanguage: "Output language"
            case .delay: "Delay"; case .voice: "Voice"; case .speech: "Speak the translation"; case .devices: "Audio devices"
            }
        }
    }
    /// Settings changed during translation that take effect after Restart.
    @Published private(set) var pendingRestart: Set<PendingSetting> = []
    /// A translation service session is connected or connecting.
    var translating: Bool { active && !bypass }
    /// Original audio with no translation service: settings can change while it plays.
    var playingOriginalOnly: Bool {
        phase == .running && bypass && provider == nil && !reconnecting && failureRecoveryToken == nil && !checkingAPI
    }
    /// A loopback input (meeting or Mac audio) plays its original audio whenever the direction is
    /// idle, until the user chooses Off. A physical microphone never starts by itself. The app
    /// allows it only after microphone access is granted, so launch never shows a permission prompt.
    private let playsLoopbackOriginal: @MainActor () -> Bool
    static let microphoneAuthorized: @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    private var originalDeclined = false
    var capabilities: ProviderCapabilities { ProviderCapabilities.forRoute(route) }
    var providerName: String { capabilities.providerName }
    var modelName: String { capabilities.modelID }
    var targetLanguageName: String { sessionConfiguration?.targetLanguageName ?? capabilities.outputLanguages.first { $0.code == targetLanguage }?.name ?? "Choose a language" }
    var transcriptIsCurrent: Bool { active || phase == .stopping }
    var selectedInputName: String { sessionConfiguration?.input.name ?? savedPreferences[destination].input?.name ?? "Choose an audio source" }
    var selectedOutputName: String { sessionConfiguration?.output.name ?? savedPreferences[destination].output?.name ?? "Choose an output" }
    var inputAvailable: Bool { inputs.contains { $0.uid == inputUID } }
    var outputAvailable: Bool { outputs.contains { $0.uid == outputUID } }
    var active: Bool { phase == .starting || phase == .running }
    var locked: Bool { active || phase == .stopping || checkingAPI }
    var inputs: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }
    var outputs: [AudioDevice] {
        devices.filter {
            if destination == .teams { return $0.isBlackHole && $0.outputChannels >= 2 }
            return $0.isPhysical && $0.outputChannels > 0
        }
    }
    convenience init() { self.init(providerFactory: { OpenAITranslationProvider() }, preferences: UserDefaultsAppPreferences(), serviceKeyPresence: { KeychainStore.containsSavedKey(for: $0) }, consumerFactory: { CoreAudioConsumerMonitor() }, providerResolver: { ProviderFactory.make($0) }, loadProviderCredentials: { try KeychainStore.credentials(for: $0) }, inventory: .shared, playsLoopbackOriginal: AppModel.microphoneAuthorized) }
    init(providerFactory: @escaping @MainActor () -> any TranslationProvider,
         audioFactory: @escaping @MainActor () -> any AudioPipelineControlling = { AudioPipeline() },
         deviceList: @escaping @MainActor () -> [AudioDevice] = { AudioDevices.cached() },
         loadKey: @escaping @MainActor () throws -> String = { try KeychainStore.load() },
         requestPermission: @escaping @MainActor () async -> Bool = { await AppModel.microphonePermission() },
         preferences: (any AppPreferencesStoring)? = nil,
         serviceKeyPresence: @escaping @MainActor (ProviderService) -> Bool? = { _ in nil },
         consumerFactory: (@MainActor () -> any ConsumerMonitoring)? = nil,
         providerResolver: (@MainActor (TranslationRoute) -> any TranslationProvider)? = nil,
         loadProviderCredentials: (@MainActor (TranslationRoute) throws -> ProviderCredentials)? = nil,
         inventory: AudioDeviceInventory? = nil,
         nowForControl: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleepForControl: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
         sleepForText: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
         selectsMeetingSource: Bool = false, playsLoopbackOriginal: @escaping @MainActor () -> Bool = { false }) {
        self.selectsMeetingSource = selectsMeetingSource
        self.playsLoopbackOriginal = playsLoopbackOriginal
        self.inventory = inventory
        self.sleepForText = sleepForText
        self.sleepForControl = sleepForControl
        self.nowForControl = nowForControl
        self.providerResolver = providerResolver
        self.loadProviderCredentials = loadProviderCredentials
        self.providerFactory = providerFactory
        self.audioFactory = audioFactory
        self.deviceList = deviceList
        self.loadKey = loadKey
        self.requestPermission = requestPermission
        self.serviceKeyPresence = serviceKeyPresence
        self.consumerFactory = consumerFactory
        self.preferencesStore = preferences ?? MemoryAppPreferences()
        self.savedPreferences = self.preferencesStore.load()
        applyingPreferences = true
        destination = AudioDestination(rawValue: savedPreferences.destination) ?? .teams
        route = TranslationRoute(rawValue: savedPreferences.providerRoute) ?? .openAI
        sourceLanguage = savedPreferences.sourceLanguage
        pacing = TranslationPacing(rawValue: savedPreferences.pacing) ?? .balanced
        speakTranslation = savedPreferences.speakTranslation
        voiceID = savedPreferences.voices[route.rawValue] ?? ""
        speakerVoices = savedPreferences.speakerVoices[route.rawValue] ?? []
        targetLanguage = savedPreferences.targetLanguage
        muted = savedPreferences.explicitlyMuted && !savedPreferences.explicitlyOff
        bypass = !savedPreferences.translationIntent
        transcriptVisible = savedPreferences.transcriptVisible
        originalMixEnabled = savedPreferences.originalMixEnabled
        originalMixLevel = savedPreferences.originalMixLevel.isFinite ? min(1, max(0, savedPreferences.originalMixLevel)) : 0.25
        originalMixDucking = savedPreferences.originalMixDucking
        outputVolume = savedPreferences.outputVolume.isFinite ? min(1, max(0, savedPreferences.outputVolume)) : 1
        transcriptLanguageName = ProviderCapabilities.forRoute(route).outputLanguages.first { $0.code == targetLanguage }?.name ?? "Translation"
        inputUID = savedPreferences[destination].input?.uid ?? ""
        outputUID = savedPreferences[destination].output?.uid ?? ""
        applyingPreferences = false
        refreshKeyStatus()
        refresh()
        if let inventory {
            inventoryObserver = NotificationCenter.default.addObserver(forName: .babelfinAudioDevicesChanged, object: inventory, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.inventoryChanged() }
            }
            inventoryChanged()
        }
        restoreReadinessWhenAvailable()
        playLoopbackOriginalIfIdle()
    }
    private func persistPreferences() { preferencesStore.save(savedPreferences) }
    /// Saves a setting and applies it, or restores `oldValue` while a session starts or stops.
    private func lockedSettingChanged<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, from oldValue: Value,
                                             _ setting: PendingSetting, save: (inout AppPreferences) -> Void) {
        guard !applyingPreferences else { return }
        if configurationLocked { applyingPreferences = true; self[keyPath: keyPath] = oldValue; applyingPreferences = false; return }
        save(&savedPreferences); persistPreferences()
        settingChanged(setting)
    }
    private func destinationChanged(from oldValue: AudioDestination) {
        guard !applyingPreferences else { return }
        if configurationLocked {
            applyingPreferences = true; destination = oldValue; applyingPreferences = false
            return
        }
        applyingPreferences = true
        inputUID = savedPreferences[destination].input?.uid ?? ""
        outputUID = savedPreferences[destination].output?.uid ?? ""
        applyingPreferences = false
        savedPreferences.destination = destination.rawValue
        persistPreferences()
        restartOriginalForNewDevices()
    }
    private func inputChanged(from oldValue: String) {
        guard !applyingPreferences else { return }
        if configurationLocked {
            applyingPreferences = true; inputUID = oldValue; applyingPreferences = false
            return
        }
        let previous = savedPreferences[destination].input
        let name = inputs.first(where: { $0.uid == inputUID })?.name ?? (previous?.uid == inputUID ? previous?.name : nil) ?? "Selected audio source"
        savedPreferences[destination].input = inputUID.isEmpty ? nil : SavedAudioDevice(uid: inputUID, name: name)
        if destination == .listen { savedPreferences.listenInputConfigured = true }
        persistPreferences()
        restartOriginalForNewDevices()
    }
    private func outputChanged(from oldValue: String) {
        guard !applyingPreferences else { return }
        if configurationLocked {
            applyingPreferences = true; outputUID = oldValue; applyingPreferences = false
            return
        }
        let previous = savedPreferences[destination].output
        let name = outputs.first(where: { $0.uid == outputUID })?.name ?? (previous?.uid == outputUID ? previous?.name : nil) ?? "Selected output"
        savedPreferences[destination].output = outputUID.isEmpty ? nil : SavedAudioDevice(uid: outputUID, name: name)
        if destination == .teams { savedPreferences.teamsOutputConfigured = true }
        persistPreferences()
        restartOriginalForNewDevices()
    }
    /// A device change while only original audio plays restarts it on the new devices. When
    /// idle, a new loopback input starts its original audio.
    private func restartOriginalForNewDevices() {
        if translating {
            pendingRestart.insert(.devices)
        } else if playingOriginalOnly {
            abortSession()
            refresh()
            Task { [weak self] in await self?.start() }
        } else if !active {
            refresh()
            playLoopbackOriginalIfIdle()
        }
    }
    /// Usage of the current translation session; see UsageStore.
    private var usageMeter: UsageMeter?
    private func beginUsage(_ route: TranslationRoute) -> UsageMeter {
        endUsage()
        let meter = UsageMeter(route: route)
        usageMeter = meter
        UsageStore.shared.begin(meter)
        return meter
    }
    private func endUsage() {
        if let usageMeter { UsageStore.shared.end(usageMeter) }
        usageMeter = nil
    }
    private func countedSink(_ sink: @escaping TranslationAudioHandler) -> TranslationAudioHandler {
        guard let meter = usageMeter else { return sink }
        return { pcm in meter.countReceived(pcm.count); try await sink(pcm) }
    }
    /// During translation a changed setting applies at once when the service accepts it;
    /// otherwise it waits for Restart.
    private func settingChanged(_ setting: PendingSetting) {
        guard translating else { return }
        if [.voice, .outputLanguage, .delay].contains(setting), let provider, provider.applyLive(currentTranslationConfiguration()) {
            log("\(setting.title) changed without restarting the session.")
            return
        }
        pendingRestart.insert(setting)
    }
    /// The translation settings as they are now, for a new or updated session.
    private func currentTranslationConfiguration() -> TranslationConfiguration {
        .init(targetLanguage: targetLanguage, noiseReduction: sessionConfiguration?.input.isPhysical == true ? .nearField : .disabled,
              route: route, sourceLanguage: !route.descriptor.acceptsLanguageHint || sourceLanguage.isEmpty ? nil : sourceLanguage,
              voiceID: route.descriptor.isDirect || voiceID.isEmpty ? nil : voiceID, pacing: pacing, speaksTranslation: speakTranslation,
              speakerVoices: activeSpeakerVoices)
    }
    /// Applies pending settings. Without a device or speech change, original audio continues while
    /// the new session connects; otherwise the audio restarts on the new devices.
    func restartTranslation() async {
        guard translating, !pendingRestart.isEmpty else { return }
        let full = pendingRestart.contains(.devices) || pendingRestart.contains(.speech)
        pendingRestart.removeAll()
        log("Restarting translation with the new settings.")
        if full {
            abortSession()
            await start()
        } else {
            do { try stopTranslating() } catch { fail(error.localizedDescription); return }
            await connectOnOriginal(automatic: false)
        }
    }
    private func playLoopbackOriginalIfIdle() {
        guard phase == .idle, !muted, !originalDeclined, !microphoneArmed, !requiresDeviceResume,
              !requiresConsumerResume, let input = inputs.first(where: { $0.uid == inputUID }), input.isBlackHole,
              outputs.contains(where: { $0.uid == outputUID }), inputUID != outputUID, playsLoopbackOriginal() else { return }
        bypass = true
        Task { [weak self] in
            guard let self, self.phase == .idle, !self.originalDeclined else { return }
            await self.start()
        }
    }
    func refreshKeyStatus() {
        accountPresence = Dictionary(uniqueKeysWithValues: ProviderService.allCases.compactMap { service in
            serviceKeyPresence(service).map { (service, $0) }
        })
    }
    private static func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    deinit { if let inventoryObserver { NotificationCenter.default.removeObserver(inventoryObserver) } }
    #if LIFECYCLE_CHECKS
    func reconcileDeviceInventoryForChecks() { inventoryChanged() }
    #endif
    private func restoreReadinessWhenAvailable() {
        guard savedPreferences.readyForCalls, !savedPreferences.explicitlyOff, destination == .teams,
              !microphoneArmed, inputAvailable, outputAvailable else { return }
        Task { [weak self] in
            guard let self, self.savedPreferences.readyForCalls, !self.savedPreferences.explicitlyOff else { return }
            await self.setMicrophoneArmed(true)
        }
    }
    private func inventoryChanged() {
        let previous = devices
        devices = deviceList()
        let lostInput = previous.contains { $0.uid == inputUID && $0.inputChannels > 0 } && !inputAvailable
        let lostOutput = previous.contains { $0.uid == outputUID && $0.outputChannels > 0 } && !outputAvailable
        restoreReadinessWhenAvailable()
        playLoopbackOriginalIfIdle()
        if lostInput || lostOutput {
            requiresDeviceResume = true
            let missing = lostInput ? selectedInputName : selectedOutputName
            abortSession()
            phase = .failed; status = "\(missing) disconnected. Reconnect it, then choose Resume."
        }
    }
    func resumeSelectedDevices() async {
        guard requiresDeviceResume, inputAvailable, outputAvailable, !muted else { return }
        requiresDeviceResume = false
        if requiresConsumerResume { await resumeConsumerAudio() }
        else { await start() }
    }
    func refresh() {
        inventory?.refresh()
        guard !locked else { return }
        devices = deviceList()
        // Remember unavailable selections. Enumeration must never substitute another microphone/output.
        if destination == .teams, outputUID.isEmpty, !savedPreferences.teamsOutputConfigured, savedPreferences.teams.output == nil,
           let uid = DefaultAudioDevice.outgoingOutput(from: outputs) { outputUID = uid }
        if selectsMeetingSource, destination == .listen, inputUID.isEmpty, !savedPreferences.listenInputConfigured, savedPreferences.listen.input == nil,
           let uid = DefaultAudioDevice.incomingSource(from: inputs) { inputUID = uid }
        if let device = inputs.first(where: { $0.uid == inputUID }) { savedPreferences[destination].input = SavedAudioDevice(uid: device.uid, name: device.name) }
        if let device = outputs.first(where: { $0.uid == outputUID }) { savedPreferences[destination].output = SavedAudioDevice(uid: device.uid, name: device.name) }
        persistPreferences()
    }
    func start() async {
        guard !requiresDeviceResume, !requiresConsumerResume else { return }
        guard !locked else { return }
        guard !microphoneArmed || consumerActive else { return }
        guard !muted else { status = "Microphone muted"; return }
        originalDeclined = false
        cancelTextCompletion(reason: "Interrupted by a new session")
        savedPreferences.explicitlyOff = false; persistPreferences()
        refresh()
        guard let input = inputs.first(where: { $0.uid == inputUID }) else {
            fail("Choose an audio source, then refresh devices.")
            return
        }
        guard let output = outputs.first(where: { $0.uid == outputUID }) else {
            if destination == .teams {
                fail("BlackHole is unavailable. Install it if needed; after installation, restart the Mac when convenient and refresh devices.")
            } else {
                fail("Choose headphones or speakers as the local output.")
            }
            return
        }
        do {
            try AudioRouting.validate(input: input.endpoint, output: output.endpoint, destination: destination)
            try validateAdditionalRoute?(input, output)
        }
        catch { fail(error.localizedDescription); return }
        guard bypass || capabilities.outputLanguages.contains(where: { $0.code == targetLanguage }) else {
            fail("Choose a supported translation language."); return
        }
        guard bypass || !capabilities.requiresVoiceID || !voiceID.isEmpty else { fail("Choose a voice in Settings first."); return }
        let configuration = AppSessionConfiguration(destination: destination, input: input, output: output, targetLanguage: targetLanguage, route: route, sourceLanguage: !route.descriptor.acceptsLanguageHint || sourceLanguage.isEmpty ? nil : sourceLanguage, voiceID: route.descriptor.isDirect || voiceID.isEmpty ? nil : voiceID, pacing: pacing, speaksTranslation: speakTranslation, originalAudio: bypass, originalMixEnabled: originalMixEnabled, originalMixLevel: originalMixLevel, originalMixDucking: originalMixDucking, speakerVoices: activeSpeakerVoices)
        sessionConfiguration = configuration
        source = ""; translation = ""; segmentTexts = [:]; segmentOrder = []; segmentTail = [:]
        transcriptLanguageName = configuration.targetLanguageName
        let token = UUID(); generation = token
        passageTimings = []
        keyAdvice = nil; keyDiagnosisRan = false
        phase = .starting
        status = configuration.originalAudio ? "Opening audio source…" : "Connecting to \(configuration.route.displayName)…"
        do {
            let credentials: ProviderCredentials
            do { credentials = configuration.originalAudio ? ProviderCredentials() : try (loadProviderCredentials?(configuration.route) ?? ProviderCredentials(openAI: loadKey())) }
            catch {
                if !configuration.originalAudio, await recoverOriginalAfterTranslationFailure(error.localizedDescription) { return }
                throw error
            }
            let permission = await requestPermission()
            guard generation == token, phase == .starting else { return }
            guard permission else { throw BridgeError.unavailable("Microphone access is disabled. Enable Babelfin in System Settings → Privacy & Security → Microphone.") }
            if !configuration.originalAudio {
                let provider = providerResolver?(configuration.route) ?? providerFactory()
                self.provider = provider
                provider.onEvent = { [weak self] event in
                    guard let self, self.generation == token || self.drainingGeneration == token else { return }
                    await self.handle(event, sessionID: token)
                }
                do {
                    try await provider.start(configuration: .init(targetLanguage: configuration.targetLanguage, noiseReduction: configuration.input.isPhysical ? .nearField : .disabled, route: configuration.route, sourceLanguage: configuration.sourceLanguage, voiceID: configuration.voiceID, pacing: configuration.pacing, speaksTranslation: configuration.speaksTranslation, speakerVoices: configuration.speakerVoices), credentials: credentials)
                } catch {
                    guard generation == token else { return }
                    diagnoseKeys(configuration.route)
                    if await recoverOriginalAfterTranslationFailure(error.localizedDescription) { return }
                    throw error
                }
                guard generation == token, phase == .starting else { provider.cancel(); return }
            }
            let audio = audioFactory()
            self.audio = audio
            audio.setOutputVolume(Float(outputVolume))
            // Text-only translation plays the original at full volume, without ducking.
            let mixEnabled = configuration.speaksTranslation ? configuration.originalMixEnabled : true
            let mixLevel = configuration.speaksTranslation ? Float(configuration.originalMixLevel) : 1
            let mixDucking = configuration.speaksTranslation && configuration.originalMixDucking
            audio.updateListening(mixEnabled: mixEnabled, level: mixLevel, ducking: mixDucking, speechMuted: speechMuted)
            audio.configureOriginalMix(enabled: mixEnabled, level: mixLevel, ducking: mixDucking)
            if configuration.originalAudio {
                audio.onPCM = { [weak audio] pcm in try audio?.play(pcm) }
            } else if let provider {
                let meter = beginUsage(configuration.route)
                // Capture owns ordering and bounds through delivery. Never enqueue a UI Task per packet.
                let admission = CaptureAdmission({ pcm in try provider.append(pcm); meter.countSent(pcm.count) }, failure: { [weak self] in
                    Task { @MainActor in guard let self, self.generation == token else { return }; await self.handle(.failure("audio_send_failed"), sessionID: token) }
                })
                captureAdmission = admission
                audio.onPCM = { pcm in try admission.append(pcm) }
            }
            audio.onFailure = { [weak self] detail in
                guard let self, self.generation == token else { return }
                self.fail(detail)
            }
            audio.onNotice = { [weak self] detail in
                guard let self, self.generation == token else { return }
                self.log(detail)
            }
            audio.onLevel = { [weak self] value in
                guard let self, self.generation == token else { return }
                self.level = value
            }
            try audio.start(input: configuration.input, output: configuration.output, destination: configuration.destination, translated: !configuration.originalAudio)
            guard generation == token, phase == .starting else { audio.stop(); return }
            if !configuration.originalAudio { provider?.onAudio = configuration.speaksTranslation ? countedSink(audio.translatedSink()) : { _ in } }
            phase = .running
            if !configuration.originalAudio {
                recordedSessionID = token
                onTranscriptSession?(token, true, nil)
            }
            if !configuration.originalAudio { translationIssue = nil }
            status = configuration.originalAudio ? "Original audio · not translated" : "Translating to \(configuration.targetLanguageName)"
            log(configuration.originalAudio ? "Original audio started. No cloud connection." : "Translation started using \(configuration.route.displayName).")
        } catch {
            guard generation == token else { return }
            fail(error.localizedDescription)
        }
    }
    func stop() async {
        originalDeclined = true
        savedPreferences.readyForCalls = false
        savedPreferences.explicitlyOff = true; savedPreferences.explicitlyMuted = false
        muted = false
        abortSession()
        disarmConsumerMonitoring()
        persistPreferences()
        status = "Stopped"
    }
    private func cancelTextCompletion(reason: String) {
        guard let token = drainingGeneration else { return }
        drainingGeneration = nil
        textDeadline?.cancel(); textDeadline = nil
        textFinisher?.cancel(); textFinisher = nil
        textProvider?.onEvent = nil; textProvider?.cancel(); textProvider = nil
        onTranscriptSession?(token, false, reason)
    }
    private func finishText(_ endingProvider: any TranslationProvider, token: UUID) {
        drainingGeneration = token; textProvider = endingProvider
        textFinisher = Task { [weak self] in
            await endingProvider.finish()
            guard let self, self.drainingGeneration == token else { return }
            self.cancelTextCompletion(reason: "Translation stopped")
        }
        let sleep = sleepForText
        textDeadline = Task { [weak self] in
            do { try await sleep(5) } catch { return }
            guard let self, self.drainingGeneration == token else { return }
            self.cancelTextCompletion(reason: "Interrupted: final text did not finish")
        }
    }
    private func stopTranslating() throws {
        guard phase == .running, let audio else { return }
        endUsage()
        // Close capture and queued transport input synchronously; device switching never awaits cloud work.
        let endingAdmission = captureAdmission; captureAdmission = nil
        let endingProvider = provider
        endingProvider?.onAudio = nil
        do { try audio.switchToOriginal() }
        catch { audio.stop(); endingProvider?.cancel(); endingAdmission?.close(); throw error }
        endingProvider?.stopInput()
        endingAdmission?.close()
        provider = nil
        let oldToken = generation; generation = UUID()
        let originalToken = generation
        audio.onFailure = { [weak self] detail in
            guard let self, self.generation == originalToken else { return }; self.fail(detail)
        }
        audio.onLevel = { [weak self] value in
            guard let self, self.generation == originalToken else { return }; self.level = value
        }
        audio.onNotice = { [weak self] detail in
            guard let self, self.generation == originalToken else { return }; self.log(detail)
        }
        endTranscriptSession(reason: "Translation stopped; final text pending")
        bypass = true
        savedPreferences.translationIntent = false; persistPreferences()
        status = "Original audio · not translated"
        if let endingProvider { finishText(endingProvider, token: oldToken) }
    }
    func setBypass(_ enabled: Bool) async {
        guard enabled != bypass, phase != .stopping else { return }
        guard enabled || !microphoneArmed || consumerActive else { return }
        if enabled, phase == .running, !bypass {
            do { try stopTranslating() } catch { fail(error.localizedDescription) }
            return
        }
        let restart = active
        abortSession()
        bypass = enabled
        savedPreferences.translationIntent = !enabled; persistPreferences()
        log(enabled ? "Original audio selected." : "Translation selected.")
        if !muted, restart && (!microphoneArmed || !enabled || consumerActive) { await start() }
    }
    func abort() {
        abortSession()
        disarmConsumerMonitoring()
    }
    private func endTranscriptSession(reason: String, includeDraining: Bool = false) {
        guard let session = recordedSessionID ?? (includeDraining ? drainingGeneration : nil) else { return }
        recordedSessionID = nil
        onTranscriptSession?(session, false, reason)
    }
    private func abortSession() {
        let endingAdmission = captureAdmission; captureAdmission = nil
        let endingAudio = audio, endingProvider = provider
        endingAudio?.onPCM = nil
        endingProvider?.onAudio = nil
        generation = UUID()
        // Stop native capture/output before a caller-owned append can delay fence closure.
        // Then cancel queued transport work and wait for any already-entered append to exit.
        endingAudio?.stop(); audio = nil
        endingProvider?.cancel(); provider = nil
        endingAdmission?.close()
        cancelRecovery()
        cancelTextCompletion(reason: "Interrupted: audio was cancelled")
        endTranscriptSession(reason: "Stopped without finalizing remaining text")
        failureRecoveryToken = nil
        drainingGeneration = nil
        level = 0; phase = .idle; status = "Stopped"
        sessionConfiguration = nil
        pendingRestart.removeAll()
        endUsage()
        if let endingAudio { log(endingAudio.metricsSummary()) }
    }
    func setMicrophoneArmed(_ enabled: Bool) async {
        guard enabled != microphoneArmed else { return }
        guard enabled else { await stop(); return }
        guard destination == .teams, phase != .stopping, !checkingAPI else { return }
        refresh()
        guard let output = outputs.first(where: { $0.uid == outputUID }), inputAvailable else {
            status = "Choose an available microphone and BlackHole output first."; return
        }
        microphoneArmed = true
        savedPreferences.readyForCalls = true; savedPreferences.explicitlyOff = false; persistPreferences()
        translationIssue = nil
        if !active { if !muted { bypass = true }; status = muted ? "Audio muted" : "Ready for calls" }
        guard let consumerFactory else { consumerStatus = "Automatic detection unavailable"; return }
        let token = UUID(); consumerGeneration = token
        let monitor = consumerFactory(); consumerMonitor = monitor
        monitor.onChange = { [weak self] state in
            guard let self, self.consumerGeneration == token else { return }
            Task { @MainActor [weak self] in
                guard let self, self.consumerGeneration == token else { return }
                await self.consumerChanged(state)
            }
        }
        monitor.start(deviceID: output.id)
    }
    func setTranslationEnabled(_ enabled: Bool) async {
        cancelRecovery()
        if !enabled, active, bypass { status = "Original audio · not translated" }
        if enabled { automaticRecoveries = [] }
        guard !enabled || !microphoneArmed || consumerActive else { return }
        if enabled, bypass, active {
            await connectOnOriginal(automatic: false)
            return
        }
        let wasActive = active
        await setBypass(!enabled)
        // setBypass owns restarting an active route. A cancelled restart must stay cancelled.
        guard !wasActive else { return }
        if enabled, !active, !muted, phase != .stopping { await start() }
        if !enabled, microphoneArmed, consumerActive, !active, !muted, phase != .stopping { await start() }
    }
    func setMuted(_ enabled: Bool) async {
        guard enabled != muted else { return }
        muted = enabled
        savedPreferences.explicitlyMuted = enabled
        savedPreferences.explicitlyOff = false
        if enabled { abortSession(); status = "Audio muted" }
        persistPreferences()
        if !enabled {
            if requiresConsumerResume { status = "Microphone-use detection unavailable. Choose Resume." }
            else if !requiresDeviceResume {
                if !microphoneArmed || consumerActive { await start() }
                else { status = "Ready for calls" }
            }
        }
    }
    private func disarmConsumerMonitoring() {
        observationTask?.cancel(); observationTask = nil; observationToken = UUID()
        requiresConsumerResume = false

        microphoneArmed = false
        consumerGeneration = UUID()
        consumerMonitor?.stop(); consumerMonitor = nil
        consumerActive = false; consumerStatus = "Not monitoring"
    }
    private func consumerChanged(_ state: ConsumerObservation) async {
        guard microphoneArmed else { return }
        switch state {
        case .active:
            observationTask?.cancel(); observationTask = nil; observationToken = UUID()
            observationCandidate = .active; consumerActive = true; requiresConsumerResume = false
            consumerStatus = "Another app is using BlackHole"
            if bypass, !active, !muted, !requiresDeviceResume { await start() }
        case .idle:
            consumerStatus = "Waiting for an app to use BlackHole"
            scheduleObservation(.idle, seconds: 2)
        case .unknown, .unsupported:
            consumerStatus = "Microphone-use detection is unavailable"
            scheduleObservation(.unknown, seconds: 10)
        }
    }
    private func scheduleObservation(_ candidate: ConsumerObservation, seconds: TimeInterval) {
        guard candidate != observationCandidate || observationTask == nil else { return }
        // An expired uncertain observation stays expired until a confirmed observation.
        if candidate == .unknown, requiresConsumerResume { return }
        observationTask?.cancel(); observationCandidate = candidate
        let token = UUID(); observationToken = token; let sleep = sleepForControl
        observationTask = Task { [weak self] in
            do { try await sleep(seconds) } catch { return }
            guard let self, self.microphoneArmed, self.observationToken == token else { return }
            self.observationTask = nil
            self.consumerActive = false
            self.abortSession()
            self.bypass = true; self.savedPreferences.translationIntent = false; self.persistPreferences()
            self.requiresConsumerResume = candidate == .unknown
            self.status = self.muted ? "Audio muted" : (candidate == .unknown ? "Microphone-use detection unavailable. Choose Resume." : "Ready for calls")
        }
    }
    func resumeConsumerAudio() async {
        guard requiresConsumerResume, !requiresDeviceResume, !muted, microphoneArmed else { return }
        requiresConsumerResume = false; consumerActive = true; bypass = true
        await start()
        scheduleObservation(.unknown, seconds: 10)
    }
    private func handle(_ event: TranslationEvent, sessionID: UUID) async {
        if drainingGeneration == sessionID {
            switch event {
            case .segment, .sourceTranscript, .targetTranscript: break
            case .failure:
                cancelTextCompletion(reason: "Interrupted: final text could not finish"); return
            default: return
            }
        }
        onTranscriptEvent?(sessionID, event)
        switch event {
        case .segment(let segment, let role):
            guard (try? segment.validate()) != nil else { return }
            let key = "\(role.rawValue):\(segment.id)"
            if let prior = segmentTexts[key]?.1, prior.revision >= segment.revision || (prior.isFinal && !segment.isFinal) { return }
            if segment.isFinal, segmentTexts[key]?.1.isFinal != true, let route = usageMeter?.route {
                UsageStore.shared.addText(route: route, recognized: role == .source ? segment.text.count : 0,
                                          translated: role == .target ? segment.text.count : 0, spoken: speakTranslation)
            }
            if segmentTexts[key] == nil { segmentOrder.append(key) }
            segmentTexts[key] = (role, segment)
            if segmentOrder.count > 500 { for key in segmentOrder.prefix(segmentOrder.count - 500) { segmentTexts[key] = nil }; segmentOrder = Array(segmentOrder.suffix(500)) }
            let text: String
            if let tail = segmentTail[role], tail.key == key {
                text = tail.prefix.isEmpty ? segment.text : tail.prefix + " " + segment.text
            } else {
                let keys = segmentOrder.filter { segmentTexts[$0]?.0 == role }
                let texts = keys.compactMap { segmentTexts[$0]?.1.text }
                text = texts.joined(separator: " ")
                if let last = keys.last { segmentTail[role] = (last, texts.dropLast().joined(separator: " ")) }
            }
            if role == .source { source = String(text.suffix(24_000)) } else { translation = String(text.suffix(24_000)) }
        case .audio(let pcm):
            guard phase == .running, !bypass else { return }
            let token = generation
            do { try await audio?.playTranslated(pcm) }
            catch {
                guard generation == token else { return }
                fail(error.localizedDescription)
            }
        case .sourceTranscript(let text): source = String((source + text).suffix(24_000))
        case .targetTranscript(let text): translation = String((translation + text).suffix(24_000))
        case .failure(let code):
            let detail = Self.failureMessage(code)
            // An output-device error must stop safely. Late or bursty translated audio comes from the
            // service or the network: it returns to original audio, discards the stale translation and reconnects.
            if code == "audio_playback_failed" { fail(detail) }
            else {
                if !Self.retryable(code), let route = sessionConfiguration?.route { diagnoseKeys(route) }
                let recovered = await recoverOriginalAfterTranslationFailure(detail, retry: Self.retryable(code))
                if !recovered { fail(detail) }
            }
        case .notice(let detail): log(detail)
        case .passage(var timing):
            if let handedOff = timing.handedOffAt, let audible = audio?.audibleStart(after: handedOff - 0.001) {
                timing.playbackSeconds = max(0, audible - handedOff)
            }
            if let audible = timing.audibleSeconds {
                log(String(format: "Passage timing: audible %.2f s after commit (hand-off %.2f s, playback start %.2f s; translation %.2f s, voice %.2f s%@).",
                           audible, timing.totalSeconds, timing.playbackSeconds ?? 0, timing.translateSeconds ?? -1, timing.voiceSeconds ?? -1,
                           timing.preparedAhead ? ", prepared ahead" : ""))
            }
            passageTimings = Array((passageTimings + [timing]).suffix(20))
        default: break
        }
    }
    private func cancelRecovery() {
        failureRecoveryToken = nil; reconnecting = false
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        recoveryTask?.cancel(); recoveryTask = nil
        reconnectProvider?.onEvent = nil; reconnectProvider?.onAudio = nil
        reconnectProvider?.cancel(); reconnectProvider = nil
    }
    private static func retryable(_ code: String) -> Bool {
        ["translation_disconnected", "audio_send_failed", "audio_upload_stale", "unexpected_session_close", "session_expired", "recognition_transport", "text_translation_failed_transient", "speech_synthesis_failed_transient",
         "received_audio_stale", "received_audio_backlog", "audio_burst_too_long"].contains(code)
    }
    private func recoverOriginalAfterTranslationFailure(_ detail: String, retry: Bool = false) async -> Bool {
        guard !muted, !bypass, phase == .running, audio != nil, !requiresDeviceResume else { return false }
        cancelRecovery()
        do { try stopTranslating() } catch { return false }
        cancelTextCompletion(reason: "Interrupted: translation connection failed")
        translationIssue = detail
        status = "Original audio · translation unavailable. Retry when ready."
        let now = nowForControl()
        automaticRecoveries.removeAll { now - $0 >= Self.automaticRecoveryWindow }
        if retry, automaticRecoveries.count < Self.automaticRecoveryLimit {
            automaticRecoveries.append(now)
            scheduleRecovery()
        }
        return true
    }
    private func scheduleRecovery() {
        let operation = UUID(); failureRecoveryToken = operation
        let expiresAt = nowForControl() + 10
        recoveryTask = Task { [weak self] in
            guard !Task.isCancelled, let self, self.failureRecoveryToken == operation else { return }
            await self.connectOnOriginal(automatic: true, expectedOperation: operation, expiresAt: expiresAt)
        }
    }
    #if LIFECYCLE_CHECKS
    func cancelScheduledRetryForChecks() { scheduleRecovery(); cancelRecovery() }
    #endif
    func retryTranslation() async {
        guard bypass, active, !muted, !requiresDeviceResume, !requiresConsumerResume else { return }
        cancelRecovery(); automaticRecoveries = []
        await connectOnOriginal(automatic: false)
    }
    private func bindAudioCallbacks(_ audio: any AudioPipelineControlling, token: UUID) {
        audio.onFailure = { [weak self] detail in guard let self, self.generation == token else { return }; self.fail(detail) }
        audio.onLevel = { [weak self] value in guard let self, self.generation == token else { return }; self.level = value }
        audio.onNotice = { [weak self] detail in guard let self, self.generation == token else { return }; self.log(detail) }
    }
    private func expireRecovery(_ operation: UUID) {
        guard failureRecoveryToken == operation else { return }
        cancelRecovery()
        translationIssue = "The translation connection timed out."
        status = "Original audio · translation unavailable. Retry when ready."
    }
    private func connectOnOriginal(automatic: Bool, expectedOperation: UUID? = nil, expiresAt suppliedExpiry: TimeInterval? = nil) async {
        guard !Task.isCancelled, expectedOperation == nil || failureRecoveryToken == expectedOperation else { return }
        guard active, bypass, !muted, !requiresDeviceResume, !requiresConsumerResume, !microphoneArmed || consumerActive, let audio else { return }
        let expiresAt = suppliedExpiry ?? (nowForControl() + 10)
        cancelTextCompletion(reason: "Interrupted by a new translation session")
        guard !Task.isCancelled, active, bypass, !muted, !requiresDeviceResume, !requiresConsumerResume,
              expectedOperation == nil || failureRecoveryToken == expectedOperation else { return }
        let operation = expectedOperation ?? UUID(); failureRecoveryToken = operation
        reconnecting = true; status = automatic ? "Reconnecting… Original audio continues." : "Connecting… Original audio continues."
        guard !Task.isCancelled, failureRecoveryToken == operation, active, bypass, !muted,
              !requiresDeviceResume, !requiresConsumerResume else { return }
        guard nowForControl() < expiresAt else { expireRecovery(operation); return }
        let candidate = providerResolver?(route) ?? providerFactory()
        reconnectProvider = candidate
        let sleep = sleepForControl
        recoveryDeadline = Task { [weak self] in
            guard !Task.isCancelled, let self, self.failureRecoveryToken == operation else { return }
            let remaining = expiresAt - self.nowForControl()
            do { if remaining > 0 { try await sleep(remaining) } } catch { return }
            guard self.nowForControl() >= expiresAt else { return }
            self.expireRecovery(operation)
        }
        do {
            let credentials = try loadProviderCredentials?(route) ?? ProviderCredentials(openAI: loadKey())
            guard !Task.isCancelled, failureRecoveryToken == operation, active, bypass, !muted,
                  !requiresDeviceResume, !requiresConsumerResume else { candidate.cancel(); return }
            guard nowForControl() < expiresAt else { throw BridgeError.timedOut }
            let startup = StartupFailureFlag()
            candidate.onEvent = { event in
                if case .failure = event { startup.set() }
                if case .closed = event { startup.set() }
            }
            try await candidate.start(configuration: currentTranslationConfiguration(), credentials: credentials)
            guard !Task.isCancelled, failureRecoveryToken == operation, !muted, !requiresDeviceResume, !requiresConsumerResume, active, bypass else { candidate.cancel(); return }
            guard nowForControl() < expiresAt else { throw BridgeError.timedOut }
            guard !startup.failed else { throw ProviderNetworkError.transport }
            let token = UUID()
            let meter = beginUsage(route)
            let admission = CaptureAdmission({ pcm in try candidate.append(pcm); meter.countSent(pcm.count) }, failure: { [weak self] in
                Task { @MainActor in guard let self, self.generation == token else { return }; await self.handle(.failure("audio_send_failed"), sessionID: token) }
            })
            candidate.onEvent = { [weak self] event in guard let self, self.generation == token || self.drainingGeneration == token else { return }; await self.handle(event, sessionID: token) }
            try audio.switchToTranslation(deliver: { pcm in try admission.append(pcm) })
            candidate.onAudio = sessionConfiguration?.speaksTranslation == false ? { _ in } : countedSink(audio.translatedSink())
            generation = token; provider = candidate; captureAdmission = admission
            audio.onPCM = { pcm in try admission.append(pcm) }
            bindAudioCallbacks(audio, token: token)
            recordedSessionID = token; onTranscriptSession?(token, true, nil)
            bypass = false; savedPreferences.translationIntent = true; persistPreferences()
            translationIssue = nil; status = "Translating to \(targetLanguageName)"
            failureRecoveryToken = nil; reconnecting = false; reconnectProvider = nil
            recoveryDeadline?.cancel(); recoveryDeadline = nil; recoveryTask = nil
        } catch {
            candidate.cancel()
            guard failureRecoveryToken == operation else { return }
            failureRecoveryToken = nil; reconnectProvider = nil; reconnecting = false
            recoveryDeadline?.cancel(); recoveryDeadline = nil; recoveryTask = nil
            translationIssue = TranslationFailureReason(error: error).safeSummary
            status = "Original audio · translation unavailable. Retry when ready."
            if !TranslationFailureReason(error: error).isTransient { diagnoseKeys(route) }
        }
    }
    /// Once per session start: a check of the route's keys can name a missing permission that the
    /// failure itself cannot, because streaming errors carry only a status.
    private func diagnoseKeys(_ route: TranslationRoute) {
        guard let keyDiagnosis, !keyDiagnosisRan else { return }
        keyDiagnosisRan = true
        let token = generation
        Task { [weak self] in
            let advice = await keyDiagnosis(route)
            guard let self, self.generation == token, let advice else { return }
            self.keyAdvice = advice; self.log(advice)
        }
    }
    private static func failureMessage(_ code: String) -> String {
        switch code {
        case "audio_playback_failed":
            return "Playback stopped. Check the selected output, refresh devices, and start again."
        case "received_audio_stale", "received_audio_backlog", "audio_burst_too_long":
            return "Translated audio fell behind, so Babelfin discarded it. Check the network if this repeats."
        case "audio_upload_stale", "audio_send_failed":
            return "Audio upload stopped. Check the network and source, then start again."
        case "control_event_backlog":
            return "Translation events fell behind. Stop other heavy work and start again."
        case "session_expired":
            return "The translation session expired. Start again to open a new session."
        case "finalization_timed_out", "finalization_failed":
            return "Audio is stopped, but final transcripts could not finish. Check the network."
        case "translation_segment_backlog", "translation_backlog_stale":
            return "Translation fell behind. Pause, then start again with shorter phrases."
        case "recognition_failed", "recognition_closed", "recognition_segment_invalid", "recognition_transport":
            return "Speech recognition stopped. Check service access and your network, then start again."
        case "text_translation_failed", "text_translation_failed_transient":
            return "Text translation stopped. Check OpenAI access and the session details in Settings."
        case "speech_synthesis_failed", "speech_synthesis_failed_transient":
            return "Speech generation stopped. Check your voice service access and the session details in Settings."
        default:
            return "Translation stopped. Check network, API access, or billing, then start again."
        }
    }
    private func fail(_ detail: String) {
        endTranscriptSession(reason: "Audio or translation failed; some text may be missing", includeDraining: true)
        abort()
        phase = .failed; status = detail
        log(detail)
    }
    /// Uses only generated silence. No microphone, speaker, transcript, or key is exposed to diagnostics.
    func testAPIConnection() async {
        guard !configurationLocked else { return }
        checkingAPI = true
        defer { checkingAPI = false }
        keyNotice = "Checking \(route.displayName) with generated silence…"
        // The direction's own route and keys; checks without a resolver use the OpenAI provider.
        let check = providerResolver?(route) ?? providerFactory()
        var failureCode: String?
        check.onEvent = { event in
            if case .failure(let code) = event { failureCode = code }
        }
        do {
            if providerResolver != nil, let loadProviderCredentials {
                try await check.start(configuration: currentTranslationConfiguration(), credentials: try loadProviderCredentials(route))
            } else {
                try await check.start(configuration: .init(), apiKey: try loadKey())
            }
            for _ in 0..<10 {
                try check.append(Data(repeating: 0, count: 4800))
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            await check.finish()
            if let code = failureCode { throw BridgeError.unavailable("API check failed (\(code)).") }
            keyNotice = "\(route.displayName) works: Babelfin connected, sent silence and closed. This check does not test translation."
            log("API connection check passed using generated silence. No microphone audio was captured.")
        } catch {
            check.cancel()
            keyNotice = error.localizedDescription
            log("API connection check failed. Check the key notice in Settings.")
        }
    }
    func clearTranscript() { source = ""; translation = ""; segmentTexts = [:]; segmentOrder = []; segmentTail = [:] }
    func clearDiagnostics() { logs = [] }
    func clearSessionText() { clearTranscript(); clearDiagnostics() }
    private func log(_ detail: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("\(time)  \(detail)")
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
        DiagnosticLog.shared.write(destination == .listen ? "listen" : "speak", detail)
    }
}


/// Presentation shared by every control surface. Raw provider events and audio
/// transitions remain in the model; views do not infer competing session states.
extension AppModel {
    var sessionTitle: String {
        if muted { return "Muted" }
        if requiresDeviceResume { return "Audio device disconnected" }
        if requiresConsumerResume { return "Resume required" }
        if reconnecting { return "Reconnecting…" }
        if finishingTranscript { return active ? "Original audio · finishing transcript…" : "Audio off · finishing transcript…" }
        switch phase {
        case .idle: return microphoneArmed ? "Ready for calls" : "Audio off"
        case .starting: return bypass ? "Opening original audio…" : "Connecting…"
        case .running: return bypass ? (translationIssue == nil ? "Original audio" : "Translation interrupted") : "Translating"
        case .stopping: return "Stopping audio…"
        case .failed: return "Needs your attention"
        }
    }
    var sessionNotice: String {
        if muted { return "This direction is silent. Unmute to continue." }
        if requiresDeviceResume { return "Reconnect the selected devices, then choose Resume. Audio will not switch to another device." }
        if requiresConsumerResume { return "Microphone use could not be confirmed. Choose Resume to continue." }
        if reconnecting { return "Original audio continues while translation reconnects." }
        if finishingTranscript { return (active ? "Original audio continues." : "Audio is off.") + " Only the last text updates can still arrive." }
        if phase == .running, bypass, let translationIssue { return "Original audio continues. \(translationIssue)" + (keyAdvice.map { " " + $0 } ?? "") }
        if phase == .failed { return status + (keyAdvice.map { " " + $0 } ?? "") }
        if microphoneArmed { return consumerStatus }
        if phase == .idle, status != "Stopped", status != "Audio off" { return status }
        if phase == .running { return bypass ? "Translation is off. No audio is sent to a translation service." : "\(selectedInputName) → \(selectedOutputName)" }
        if phase == .starting { return "Opening the selected audio route and translation service." }
        return "Choose Translate when you are ready."
    }
    var languageSummary: String {
        let source = !route.descriptor.acceptsLanguageHint || sourceLanguage.isEmpty ? "Automatic" : (capabilities.inputLanguages.first { $0.code == sourceLanguage }?.name ?? "Choose input language")
        return "\(source) → \(targetLanguageName)"
    }
    var translationSummary: String {
        "\(route.displayName) · \(voiceID.isEmpty ? (capabilities.requiresVoiceID ? "Choose a voice" : "Default voice") : "Saved voice") · \(originalMixEnabled ? "Original mix on" : "Original mix off")"
    }
    var requiredAccountNames: String {
        ProviderService.allCases.filter { route.requiredServices.contains($0) }.map { Self.serviceName($0) }.joined(separator: ", ")
    }
    static func serviceName(_ service: ProviderService) -> String { service.displayName }
    var setupRequirements: [String] {
        var items: [String] = []
        if !inputAvailable { items.append(inputUID.isEmpty ? "Choose an audio source." : "Reconnect the selected audio source.") }
        if !outputAvailable { items.append(destination == .teams ? "Choose a BlackHole output for the virtual microphone." : "Choose connected headphones or speakers for listening.") }
        for service in ProviderService.allCases where route.requiredServices.contains(service) {
            if accountPresence[service] == false { items.append("Add a \(Self.serviceName(service)) API key in Accounts.") }
        }
        if !capabilities.outputLanguages.contains(where: { $0.code == targetLanguage }) { items.append("Choose an output language for this service.") }
        if route.descriptor.acceptsLanguageHint && !sourceLanguage.isEmpty && !capabilities.inputLanguages.contains(where: { $0.code == sourceLanguage }) { items.append("Choose an input language for this service.") }
        if capabilities.requiresVoiceID && voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append("Choose a voice in Settings.") }
        if !inputUID.isEmpty && inputUID == outputUID { items.append("Choose different input and output devices to avoid feedback.") }
        return items
    }
}

extension Notification.Name {
    static let babelfinCredentialMetadataChanged = Notification.Name("babelfin.credentials.metadata.changed")
}

/// Set by a provider event during a reconnect start; read on the main actor after the start returns.
@MainActor private final class StartupFailureFlag {
    private(set) var failed = false
    func set() { failed = true }
}

