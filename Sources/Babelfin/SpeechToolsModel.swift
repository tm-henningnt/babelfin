import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import BridgeCore

enum SpeechToolsPage: String, CaseIterable, Identifiable {
    case recording, notes, voice
    var id: String { rawValue }
    var title: String {
        switch self { case .recording: return "Audio file"; case .notes: return "Meeting notes"; case .voice: return "Voice clip" }
    }
    var symbol: String {
        switch self { case .recording: return "waveform"; case .notes: return "note.text"; case .voice: return "text.bubble" }
    }
}

enum RecordingService: String, CaseIterable, Identifiable {
    case elevenLabs, openAI, onThisMac
    var id: String { rawValue }
    var title: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        case .onThisMac: return "On this Mac"
        }
    }
    /// The key the service needs; On this Mac needs none.
    var account: ProviderService? {
        switch self {
        case .elevenLabs: return .elevenLabs
        case .openAI: return .openAI
        case .onThisMac: return nil
        }
    }
}

/// One generated voice clip, kept so takes with different directions can be compared.
struct VoiceTake: Identifiable, Equatable {
    let id = UUID()
    let number: Int
    let direction: SpeechDirection
    let audio: Data
    var title: String { "Take \(number) · \(direction.delivery.displayName) · \(String(format: "%.2f", direction.speed))×" }
}

/// Where Audio file takes its audio from.
enum AudioInput: String, CaseIterable, Identifiable {
    case file, microphone
    var id: String { rawValue }
    var title: String { self == .file ? "File" : "Microphone" }
}

/// What Voice clip speaks: typed text, or the microphone recording with a new voice.
enum VoiceSource: String, CaseIterable, Identifiable {
    case text, recording
    var id: String { rawValue }
    var title: String { self == .text ? "Text" : "My recording" }
}

private final class PreviewDeviceObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// The services that speak a voice clip or a dub.
enum ClipVoiceService: String, CaseIterable, Identifiable, Sendable {
    case elevenLabs, fish, gemini, system
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .fish: return "Fish Audio"
        case .gemini: return "Gemini"
        case .system: return "System voices on this Mac"
        }
    }
    /// The key the service needs. The system voices need none.
    var account: ProviderService? {
        switch self {
        case .elevenLabs: return .elevenLabs
        case .fish: return .fish
        case .gemini: return .gemini
        case .system: return nil
        }
    }
    /// The account that lists voices, or nil when Babelfin has the list.
    var accountVoices: VoiceProvider? {
        switch self {
        case .elevenLabs: return .elevenLabs
        case .fish: return .fish
        case .gemini, .system: return nil
        }
    }
    /// The voices Babelfin lists without a request.
    @MainActor var localVoices: [ProviderVoice] {
        switch self {
        case .elevenLabs, .fish: return []
        case .gemini:
            return GeminiSpeechSynthesisStage.voices.map {
                ProviderVoice(id: $0, name: $0, provider: nil, state: "available", isReady: true)
            }
        case .system: return Self.installedSystemVoices()
        }
    }
    var route: TranslationRoute {
        switch self {
        case .elevenLabs: return .elevenLabs
        case .fish: return .fish
        case .gemini: return .gemini
        case .system: return .appleLocal
        }
    }

    /// The installed system voices, best quality first.
    @MainActor static func installedSystemVoices() -> [ProviderVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !AppleSpeechSynthesisStage.isPersonalVoice($0) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { voice in
                return ProviderVoice(id: voice.identifier, name: voice.name + qualitySuffix(voice.quality), provider: nil, state: "available",
                                     isReady: true, language: AppleLanguage.babelfin(AppleLanguage.code(voice.language)))
            }
    }
    private static func qualitySuffix(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return " (Premium)"
        case .enhanced: return " (Enhanced)"
        default: return ""
        }
    }
}

@MainActor final class SpeechToolsModel: ObservableObject {
    @Published var page: SpeechToolsPage? = .voice
    @Published private(set) var busy = false
    @Published private(set) var progress: SpeechToolsProgress?
    @Published private(set) var operationTitle = ""
    @Published private(set) var notice = ""
    @Published private(set) var isError = false
    @Published private(set) var missingKeys: Set<ProviderService> = []
    @Published private(set) var fileURL: URL?
    @Published private(set) var fileSize = ""
    @Published var audioInput: AudioInput = .file { didSet { if audioInput != oldValue { resetRecording() } } }
    /// One microphone recording for both tools: record once, then transcribe it or give it a new voice.
    /// It stays in memory and is uploaded only when you choose an action.
    let microphone = VoiceSampleRecorder(minimumSeconds: 2, maximumSeconds: SpeechToolsLimits.microphoneSeconds)
    @Published var microphoneUID = ""
    @Published private(set) var microphones: [AudioDevice] = []
    @Published private(set) var microphoneRecording: Data? {
        didSet {
            guard microphoneRecording != oldValue else { return }
            if audioInput == .microphone { resetRecording() }
            if voiceSource == .recording { clearTakes() }
        }
    }
    @Published var voiceSource: VoiceSource = .text { didSet { if voiceSource != oldValue { clearTakes(); clearNotice() } } }
    private var microphoneObservation: AnyCancellable?
    @Published var sourceLanguage = ""
    @Published var recordingService: RecordingService = .elevenLabs
    @Published var diarize = true
    @Published var targetLanguage = "en"
    @Published private(set) var recording: RecordingTranscript? { didSet { if recording != oldValue { dub = nil } } }
    @Published var dubIncludesOriginal = true
    /// The latest dub WAV. It stays in memory until the recording changes or the app quits.
    @Published private(set) var dub: Data?
    @Published private(set) var recordingContext = ""
    @Published private var completedRecordingSignature: String?
    @Published private var recordingAttemptIncomplete = false
    @Published var notesInput: String { didSet { if notesInput != oldValue { notesResult = nil; clearNotice() } } }
    @Published private(set) var notesResult: MeetingNotes?
    @Published var voiceText = "" { didSet { if voiceText != oldValue { clearTakes(); clearNotice(); spokenText = nil } } }
    /// Translate the text into the clip language before it is spoken (OpenAI).
    @Published var voiceTranslates = false { didSet { if voiceTranslates != oldValue { clearTakes(); spokenText = nil } } }
    /// The translation that the last take spoke.
    @Published private(set) var spokenText: String?
    @Published var voiceProvider: ClipVoiceService = .elevenLabs {
        didSet {
            guard voiceProvider != oldValue else { return }
            voices = []; voiceID = ""; clearTakes(); voicesLoaded = false; clearNotice()
            // Babelfin has the Gemini and system voice lists, so they load at once.
            if voiceProvider.accountVoices == nil { voices = voiceProvider.localVoices; voicesLoaded = true }
            if !voiceLanguages.contains(where: { $0.code == voiceLanguage }) { voiceLanguage = "en" }
        }
    }
    @Published var voiceLanguage = "en" {
        didSet {
            guard voiceLanguage != oldValue else { return }
            clearTakes(); clearNotice()
            if !voiceID.isEmpty, !readyVoices.contains(where: { $0.id == voiceID }) { voiceID = "" }
        }
    }
    @Published var voiceID = "" { didSet { if voiceID != oldValue { clearTakes(); clearNotice() } } }
    /// Delivery and speed change only the next take; earlier takes stay for comparison.
    @Published var voiceDelivery: SpeechDirection.Delivery = .natural
    @Published var voiceSpeed = 1.0
    @Published private(set) var voices: [ProviderVoice] = []
    @Published private(set) var voicesLoaded = false
    @Published private(set) var takes: [VoiceTake] = []
    @Published var selectedTakeID: UUID? { didSet { if selectedTakeID != oldValue { stopClip() } } }
    /// The selected take's WAV, which Play and Save use.
    var clip: Data? { takes.first { $0.id == selectedTakeID }?.audio }
    @Published private(set) var playingClip = false
    @Published private(set) var previewOutputs: [AudioDevice] = []
    @Published var previewOutputUID = "" { didSet { if previewOutputUID != oldValue { stopClip() } } }
    private let clipPlayer: any VoiceClipPlaying
    private let previewDeviceList: @MainActor () -> [AudioDevice]
    private var clipTask: Task<Void, Never>?
    private var clipGeneration = UUID()
    private var previewObserver: PreviewDeviceObservation?

    private let service: SpeechToolsService
    private let voiceService: VoiceService
    private let keyPresence: @MainActor (ProviderService) -> Bool?
    private let credentialVersion: @MainActor () -> String
    private var lastCredentialVersion: String?
    private let loadCredentials: @MainActor (Set<ProviderService>) async throws -> ProviderCredentials
    private var task: Task<Void, Never>?
    private var fileService: SpeechToolsService?
    private var generation = UUID()
    private var operationCredentialVersion: String?
    private var didCheckKeys = false

    init(initialNotesText: String = "", service: SpeechToolsService? = nil,
         voiceService: VoiceService? = nil,
         clipPlayer: (any VoiceClipPlaying)? = nil,
         previewDeviceList: @escaping @MainActor () -> [AudioDevice] = { AudioDevices.cached() },
         keyPresence: @escaping @MainActor (ProviderService) -> Bool? = { KeychainStore.containsSavedKey(for: $0) },
         credentialVersion: @escaping @MainActor () -> String = { KeychainStore.credentialRevision },
         loadCredentials: @escaping @MainActor (Set<ProviderService>) async throws -> ProviderCredentials = { services in
             let storage = KeychainStore.storageMode
             return try await Task.detached {
                 try ProviderCredentials(openAI: services.contains(.openAI) ? KeychainStore.load(for: .openAI, storage: storage) : nil,
                     elevenLabs: services.contains(.elevenLabs) ? KeychainStore.load(for: .elevenLabs, storage: storage) : nil,
                     fish: services.contains(.fish) ? KeychainStore.load(for: .fish, storage: storage) : nil,
                     gemini: services.contains(.gemini) ? KeychainStore.load(for: .gemini, storage: storage) : nil)
             }.value
         }) {
        self.clipPlayer = clipPlayer ?? VoicePreviewPlayer(); self.previewDeviceList = previewDeviceList
        notesInput = initialNotesText; self.service = service ?? SpeechToolsService(); self.voiceService = voiceService ?? VoiceService()
        self.keyPresence = keyPresence; self.credentialVersion = credentialVersion; self.loadCredentials = loadCredentials
        lastCredentialVersion = credentialVersion()
        if !initialNotesText.isEmpty { page = .notes }
        self.service.onProgress = { [weak self] in self?.progress = $0 }
        // A finished recording becomes the tools' input, including one stopped at the length limit.
        microphoneObservation = microphone.$recording.removeDuplicates().dropFirst().sink { [weak self] recording in
            guard !recording else { return }
            Task { @MainActor [weak self] in self?.adoptMicrophoneRecording() }
        }
    }

    var voiceLanguages: [TranslationLanguage] {
        switch voiceProvider {
        case .elevenLabs: return TranslationLanguage.elevenLabsOutputs
        case .fish, .gemini: return TranslationLanguage.composedOutputs
        case .system:
            let installed = Set(voices.compactMap(\.language))
            return TranslationLanguage.composedOutputs.filter { installed.contains($0.code) }
        }
    }
    /// Account voices speak any language; a system voice speaks its own.
    var readyVoices: [ProviderVoice] { voices.filter { $0.isReady && ($0.language == nil || $0.language == voiceLanguage) } }
    private var recordingSignature: String {
        "\(recordingService.rawValue)/\(sourceLanguage)/\(recordingService == .elevenLabs && diarize)"
    }
    var recordingNeedsRefresh: Bool {
        recording != nil && (recordingAttemptIncomplete || completedRecordingSignature != recordingSignature)
    }
    var voiceAccount: ProviderService? { voiceProvider.account }
    var voiceKeyMissing: Bool { voiceAccounts.contains { missingKeys.contains($0) } }
    private var voiceAccounts: Set<ProviderService> {
        var services: Set<ProviderService> = voiceAccount.map { [$0] } ?? []
        if voiceTranslates && voiceSource == .text { services.insert(.openAI) }
        return services
    }
    var canGenerate: Bool {
        !busy && !voiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && voiceText.count <= SpeechToolsLimits.voiceCharacters && voiceText.utf8.count <= 8_000
        && (voiceProvider != .elevenLabs || !voiceID.isEmpty)
    }
    var canMakeNotes: Bool {
        !busy && !notesInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && notesInput.utf8.count <= SpeechToolsLimits.notesBytes
    }

    func refreshKeyPresence() {
        let version = credentialVersion()
        if let previous = lastCredentialVersion, previous != version {
            cancel()
            voices = []; voicesLoaded = false; voiceID = ""; clearTakes()
            clearNotice()
        }
        lastCredentialVersion = version
        let presence = [ProviderService.openAI, .elevenLabs, .fish, .gemini].map { ($0, keyPresence($0)) }
        missingKeys = Set(presence.filter { $0.1 == false }.map(\.0))
        if !didCheckKeys {
            if missingKeys.contains(.elevenLabs), presence.contains(where: { $0.0 == .openAI && $0.1 == true }) { recordingService = .openAI }
            if missingKeys.contains(.elevenLabs), presence.contains(where: { $0.0 == .fish && $0.1 == true }) { voiceProvider = .fish }
            didCheckKeys = true
        }
    }
    func clearNotice() { guard !busy else { return }; notice = ""; isError = false }
    func cancel() {
        stopClip()
        guard busy else { return }
        task?.cancel(); service.cancel(); fileService?.cancel(); voiceService.cancel()
    }
    func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an audio file"; panel.prompt = "Choose"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["wav", "mp3", "m4a", "mp4", "flac", "ogg", "webm"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectFile(url)
    }
    /// The audio Audio file transcribes and dubs.
    var audioSource: RecordingSource? {
        switch audioInput {
        case .file: return fileURL.map { .file($0) }
        case .microphone: return microphoneRecording.map { .memory(wav: $0) }
        }
    }
    func refreshMicrophones() {
        microphones = previewDeviceList().filter(\.isPhysicalInput)
        if !microphones.contains(where: { $0.uid == microphoneUID }) { microphoneUID = microphones.first?.uid ?? "" }
    }
    func toggleMicrophone() {
        if microphone.recording { microphone.stop(); return }
        guard !busy, let device = microphones.first(where: { $0.uid == microphoneUID }) else { return }
        stopClip()
        Task { await microphone.start(input: device) }
    }
    func discardMicrophoneRecording() { microphone.discard(); microphoneRecording = nil }
    private func adoptMicrophoneRecording() {
        guard !microphone.recording else { return }
        microphoneRecording = microphone.sample.meetsMinimum ? try? microphone.sample.wav() : nil
    }
    private func resetRecording() {
        recording = nil; recordingContext = ""; completedRecordingSignature = nil
        recordingAttemptIncomplete = false; clearNotice()
    }
    func selectFile(_ url: URL) {
        guard !busy else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes > 0 else {
                throw SpeechToolsError.invalidRecording
            }
            guard bytes <= SpeechToolsLimits.recordingBytes else { throw SpeechToolsError.recordingTooLarge }
            fileURL = url; fileSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            resetRecording()
        } catch let safe as SpeechToolsError { showError(safe.localizedDescription) }
        catch { showError("The file could not be read. Choose another recording.") }
    }
    func transcribe() {
        guard !busy, !microphone.recording, let audio = audioSource else { return }
        let source = sourceLanguage.isEmpty ? nil : sourceLanguage, selectedService = recordingService
        let speakers = selectedService == .elevenLabs && diarize
        let signature = recordingSignature
        let language = TranslationLanguage.elevenLabsOutputs.first(where: { $0.code == source })?.name ?? "Automatic language"
        recordingAttemptIncomplete = true
        perform("Transcribing audio…", services: Set([selectedService.account].compactMap { $0 })) { model, keys in
            let transcriber: SpeechToolsService
            switch selectedService {
            case .elevenLabs: transcriber = model.service
            case .openAI: transcriber = SpeechToolsService(transcriber: OpenAIRecordingTranscriber())
            case .onThisMac: transcriber = SpeechToolsService(transcriber: OnThisMacRecordingTranscriber(), operationTimeout: 3_000)
            }
            model.fileService = transcriber
            transcriber.onProgress = { [weak model] in model?.progress = $0 }
            defer { model.fileService = nil }
            let result = try await transcriber.transcribe(source: audio, sourceLanguage: source, diarize: speakers, credentials: keys)
            try model.checkCurrentOperation(); model.recording = result
            model.completedRecordingSignature = signature; model.recordingAttemptIncomplete = false
            model.autoExportRecording()
            model.recordingContext = "\(selectedService.title) · \(language)\(speakers ? " · Speaker labels" : "")"
            model.notice = result.segments.isEmpty ? "No speech was found in this recording." : "Transcription finished."
        }
    }
    func translateRecording() {
        guard let recording, !recording.segments.isEmpty else { return }
        let target = targetLanguage
        perform("Translating text…", services: [.openAI]) { model, keys in
            let result = try await model.service.translate(transcript: recording, targetLanguage: target, credentials: keys)
            try model.checkCurrentOperation(); model.recording = result; model.notice = "Translation finished."
            model.autoExportRecording()
        }
    }
    /// A dub needs a translation with segment times and a ready voice from Voice clip.
    var canDub: Bool {
        guard !busy, let recording, recording.targetLanguage != nil, audioSource != nil else { return false }
        let translated = recording.segments.filter { $0.translatedText != nil }
        return !translated.isEmpty && translated.allSatisfy { $0.startSeconds != nil } && (voiceProvider != .elevenLabs || !voiceID.isEmpty)
    }
    var dubCharacters: Int { recording?.segments.reduce(0) { $0 + ($1.translatedText?.count ?? 0) } ?? 0 }
    func createDub() {
        refreshKeyPresence()
        guard canDub, let recording, let audio = audioSource else { return }
        let route = voiceProvider.route
        let voice = voiceID.isEmpty ? nil : voiceID, direction = SpeechDirection(delivery: voiceDelivery, speed: voiceSpeed)
        let includeOriginal = dubIncludesOriginal
        perform("Dubbing…", services: voiceAccounts) { model, keys in
            let data = try await model.service.dub(transcript: recording, source: audio, includeOriginal: includeOriginal, originalLevel: 0.25,
                                                   voiceID: voice, route: route, direction: direction, credentials: keys)
            try model.checkCurrentOperation()
            guard model.recording == recording else { throw CancellationError() }
            model.dub = data; model.notice = "The dub is ready to save."
        }
    }
    /// Saves a transcript to the auto-export folder; the app sets it. It returns a message on failure.
    static var autoExport: (@MainActor (RecordingTranscript, String) -> String?)?
    private func autoExportRecording() {
        guard let recording else { return }
        let name = "Audio file " + (audioInput == .file ? fileURL?.deletingPathExtension().lastPathComponent ?? "recording" : "microphone recording")
        if let failure = Self.autoExport?(recording, name) { showError(failure) }
    }
    func saveDub() { if let dub { save(dub, name: "Babelfin dub", extension: "wav") } }
    func useRecordingForNotes() {
        guard let recording, !busy else { return }
        notesInput = recording.plainText(); page = .notes; clearNotice()
    }
    func replaceNotes(with text: String) {
        guard !busy else { return }
        notesInput = text; notesResult = nil; clearNotice()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notice = "There is no meeting text to use yet." }
    }
    func makeNotes() {
        let text = notesInput
        perform("Making notes…", services: [.openAI]) { model, keys in
            let result = try await model.service.notes(text: text, credentials: keys)
            try model.checkCurrentOperation(); model.notesResult = result; model.notice = "Notes finished. Review them before sharing."
        }
    }
    func refreshVoices() {
        refreshKeyPresence()
        guard let provider = voiceProvider.accountVoices else {
            voices = voiceProvider.localVoices; voicesLoaded = true; return
        }
        perform("Loading voices…", services: voiceAccounts) { model, keys in
            let voices = try await model.voiceService.list(provider: provider, credentials: keys)
            try model.checkCurrentOperation(); model.voices = voices; model.voicesLoaded = true
            if !voices.contains(where: { $0.id == model.voiceID && $0.isReady }) { model.voiceID = "" }
            model.notice = voices.filter(\.isReady).isEmpty ? "No ready account voices were found." : "Voices refreshed."
        }
    }
    func generateClip() {
        stopClip()
        refreshKeyPresence()
        if voiceSource == .recording { revoiceRecording(); return }
        guard canGenerate else { return }
        let text = voiceText, language = voiceLanguage, voice = voiceID.isEmpty ? nil : voiceID
        let route = voiceProvider.route, translates = voiceTranslates
        let direction = SpeechDirection(delivery: voiceDelivery, speed: voiceSpeed)
        perform(translates ? "Translating and generating…" : "Generating voice clip…", services: voiceAccounts) { model, keys in
            let spoken = translates ? try await model.service.translate(text: text, to: language, credentials: keys) : text
            let data = try await model.service.voiceClip(text: spoken, language: language, voiceID: voice, route: route,
                                                         direction: direction, credentials: keys)
            try model.checkCurrentOperation()
            guard model.voiceText == text, model.voiceLanguage == language, model.voiceTranslates == translates,
                  (model.voiceID.isEmpty ? nil : model.voiceID) == voice,
                  model.voiceProvider.route == route else { throw CancellationError() }
            model.spokenText = translates ? spoken : nil
            model.addTake(data, direction: direction)
        }
    }

    /// A new voice for the microphone recording needs ElevenLabs and a chosen voice.
    var canRevoice: Bool {
        !busy && !microphone.recording && voiceProvider == .elevenLabs && !voiceID.isEmpty
        && (microphoneRecording?.count ?? .max) <= SpeechToolsLimits.voicePCMBytes + 44
    }
    private func revoiceRecording() {
        guard canRevoice, let wav = microphoneRecording else { return }
        let voice = voiceID, direction = SpeechDirection(delivery: voiceDelivery)
        perform("Giving your recording a new voice…", services: [.elevenLabs]) { model, keys in
            let data = try await model.service.revoice(wav: wav, voiceID: voice, delivery: direction.delivery, credentials: keys)
            try model.checkCurrentOperation()
            guard model.microphoneRecording == wav, model.voiceID == voice, model.voiceSource == .recording else { throw CancellationError() }
            model.addTake(data, direction: direction)
        }
    }

    var canPlayClip: Bool {
        !busy && clip != nil && previewOutputs.contains { $0.uid == previewOutputUID && $0.isPhysical && $0.outputChannels > 0 }
    }
    func observePreviewDevices() {
        refreshPreviewOutputs()
        guard previewObserver == nil else { return }
        previewObserver = PreviewDeviceObservation(NotificationCenter.default.addObserver(forName: .babelfinAudioDevicesChanged, object: AudioDeviceInventory.shared, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPreviewOutputs() }
        })
        // Reconcile after registration so an initial async inventory publication cannot be missed.
        refreshPreviewOutputs()
    }
    func refreshPreviewOutputs() {
        previewOutputs = previewDeviceList().filter { $0.isPhysical && $0.outputChannels > 0 }
        if !previewOutputs.contains(where: { $0.uid == previewOutputUID }) { stopClip() }
    }
    func endPreviewObservation() {
        stopClip()
        previewObserver = nil
    }
    func stopClip() {
        clipGeneration = UUID(); clipTask?.cancel(); clipTask = nil
        clipPlayer.stop(); playingClip = false
    }
    func playClip() {
        refreshKeyPresence(); refreshPreviewOutputs()
        guard canPlayClip, let clip, let output = previewOutputs.first(where: { $0.uid == previewOutputUID }) else { return }
        stopClip()
        let token = UUID(); clipGeneration = token; playingClip = true
        clipTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.clipGeneration == token else { return }
                let pcm = try SpeechToolsWAV.decode(clip)
                try self.clipPlayer.start(output: output)
                var offset = 0
                while offset < pcm.count {
                    try Task.checkCancellation()
                    guard self.clipGeneration == token else { return }
                    let end = min(offset + 4800, pcm.count)
                    try await self.clipPlayer.append(pcm.subdata(in: offset..<end))
                    offset = end
                }
                try Task.checkCancellation()
                guard self.clipGeneration == token else { return }
                try await self.clipPlayer.finish()
                guard self.clipGeneration == token else { return }
                self.stopClip()
            } catch {
                guard self.clipGeneration == token else { return }
                self.stopClip()
                if !(error is CancellationError) { self.showError("Playback stopped. Check the selected listening device and try again.") }
            }
        }
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { notice = "Copied."; isError = false }
        else { showError("Could not copy the text. Try again.") }
    }
    func saveRecording(json: Bool) {
        guard let recording else { return }
        do {
            let data: Data
            if json {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(recording)
            } else { data = Data(recording.plainText().utf8) }
            save(data, name: "Babelfin recording", extension: json ? "json" : "txt")
        } catch { showError("Could not prepare the transcript. Try saving as plain text.") }
    }
    /// Saves the recording's timed segments as a subtitle file.
    func saveSubtitles(_ format: SubtitleFile.Format, text: SubtitleFile.Text) {
        guard let recording else { return }
        guard !SubtitleFile.cues(recording.segments, text: text).isEmpty else { showError("This transcript has no timed text for subtitles."); return }
        let content = SubtitleFile.make(recording.segments, text: text, format: format)
        save(Data(content.utf8), name: text == .translation ? "Babelfin subtitles (translation)" : "Babelfin subtitles",
             extension: format.fileExtension)
    }
    func saveNotes() { if let notesResult { save(Data(notesResult.text.utf8), name: "Babelfin notes", extension: "txt") } }
    func saveClip() {
        guard let take = takes.first(where: { $0.id == selectedTakeID }) else { return }
        save(take.audio, name: "Babelfin voice clip take \(take.number)", extension: "wav")
    }
    /// Inserts an audio tag such as [whispers] at the end of the text.
    func appendTag(_ tag: String) {
        voiceText += (voiceText.isEmpty || voiceText.hasSuffix(" ") ? "" : " ") + tag + " "
    }
    /// Replaces `range` with the tag, with a space on each side where the text has none.
    /// Returns where the cursor goes: after the tag.
    func insertTag(_ tag: String, replacing range: Range<String.Index>) -> String.Index {
        let before = range.lowerBound == voiceText.startIndex || voiceText[voiceText.index(before: range.lowerBound)].isWhitespace ? "" : " "
        let after = range.upperBound < voiceText.endIndex && voiceText[range.upperBound].isWhitespace ? "" : " "
        let inserted = before + tag + after
        let offset = voiceText.distance(from: voiceText.startIndex, to: range.lowerBound) + inserted.count
        voiceText.replaceSubrange(range, with: inserted)
        return voiceText.index(voiceText.startIndex, offsetBy: offset)
    }
    private func clearTakes() { takes = []; selectedTakeID = nil }
    private func addTake(_ audio: Data, direction: SpeechDirection) {
        let take = VoiceTake(number: (takes.last?.number ?? 0) + 1, direction: direction, audio: audio)
        takes = Array((takes + [take]).suffix(SpeechToolsLimits.voiceTakes))
        selectedTakeID = take.id
        notice = "Take \(take.number) is ready to play or save."
    }

    private func save(_ data: Data, name: String, extension ext: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name + "." + ext
        panel.allowedContentTypes = UTType(filenameExtension: ext).map { [$0] } ?? []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); notice = "Saved."; isError = false }
        catch { showError("Could not save the file. Choose a writable location.") }
    }
    private func showError(_ message: String) { notice = message; isError = true }

    /// Check before publishing any awaited result, not only after its operation body returns.
    private func checkCurrentOperation() throws {
        try Task.checkCancellation()
        guard let snapshot = operationCredentialVersion, credentialVersion() == snapshot else { throw CancellationError() }
    }

    private func perform(_ title: String, services: Set<ProviderService>,
                         body: @escaping @MainActor (SpeechToolsModel, ProviderCredentials) async throws -> Void) {
        guard !busy else { return }
        busy = true; notice = ""; isError = false; progress = nil; operationTitle = title
        let token = UUID(); generation = token
        let credentialSnapshot = credentialVersion()
        operationCredentialVersion = credentialSnapshot
        DiagnosticLog.shared.write("tools", "\(title) started")
        let started = ProcessInfo.processInfo.systemUptime
        task = Task { [weak self] in
            guard let self else { return }
            let credentialLease = CredentialOperationActivity.shared.begin()
            defer { CredentialOperationActivity.shared.end(credentialLease) }
            do {
                let keys: ProviderCredentials
                do { keys = try await self.loadCredentials(services) }
                catch { throw SpeechToolsUIError.credentials(services) }
                try Task.checkCancellation()
                guard self.generation == token, self.credentialVersion() == credentialSnapshot else { throw CancellationError() }
                try await body(self, keys)
                try Task.checkCancellation()
                guard self.credentialVersion() == credentialSnapshot else { throw CancellationError() }
                DiagnosticLog.shared.write("tools", "\(title) finished after \(DiagnosticLog.elapsed(since: started))")
            } catch {
                let reason: String
                if error is CancellationError || Task.isCancelled { reason = "cancelled" }
                else if error is SpeechToolsUIError { reason = "failed: no key" }
                else { reason = "failed: \(DiagnosticLog.kind(of: error))" }
                DiagnosticLog.shared.write("tools", "\(title) \(reason) after \(DiagnosticLog.elapsed(since: started))")
                guard self.generation == token else { return }
                if error is CancellationError || Task.isCancelled { self.notice = "Cancelled."; self.isError = false }
                else if let safe = error as? SpeechToolsError { self.showError(safe.localizedDescription) }
                else if let safe = error as? SpeechToolsUIError { self.showError(safe.localizedDescription) }
                else { self.showError(TranslationFailureReason(error: error).safeSummary) }
            }
            guard self.generation == token else { return }
            self.busy = false; self.task = nil; self.progress = nil; self.operationCredentialVersion = nil
            self.refreshKeyPresence()
        }
    }
}

private enum SpeechToolsUIError: LocalizedError {
    case credentials(Set<ProviderService>)
    var errorDescription: String? {
        switch self {
        case .credentials(let services):
            let names = services.map(\.displayName).sorted().joined(separator: " and ")
            return "Add your \(names) API key in Settings, or allow Keychain access, then try again."
        }
    }
}

#if BABELFIN_SCREENSHOTS
extension SpeechToolsModel {
    /// Private documentation build only: one fictional voice, a sentence and three silent takes.
    func seedDemoVoiceClip() {
        voices = [ProviderVoice(id: "demovoice", name: "Kari", provider: .elevenLabs, state: "available", isReady: true)]
        voicesLoaded = true; voiceID = "demovoice"
        voiceText = "Thank you for joining. Let's start with the launch date."
        let silence = Data(repeating: 0, count: 48_000)
        takes = [SpeechDirection(delivery: .steady), SpeechDirection(), SpeechDirection(delivery: .expressive, speed: 1.1)]
            .enumerated().map { VoiceTake(number: $0.offset + 1, direction: $0.element, audio: silence) }
        selectedTakeID = takes[1].id
    }
}
#endif
