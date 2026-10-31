import AppKit
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
    case elevenLabs, openAI
    var id: String { rawValue }
    var title: String { self == .elevenLabs ? "ElevenLabs" : "OpenAI" }
    var account: ProviderService { self == .elevenLabs ? .elevenLabs : .openAI }
}

private final class PreviewDeviceObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor final class SpeechToolsModel: ObservableObject {
    @Published var page: SpeechToolsPage? = .recording
    @Published private(set) var busy = false
    @Published private(set) var progress: SpeechToolsProgress?
    @Published private(set) var operationTitle = ""
    @Published private(set) var notice = ""
    @Published private(set) var isError = false
    @Published private(set) var missingKeys: Set<ProviderService> = []
    @Published private(set) var fileURL: URL?
    @Published private(set) var fileSize = ""
    @Published var sourceLanguage = ""
    @Published var recordingService: RecordingService = .elevenLabs
    @Published var diarize = true
    @Published var targetLanguage = "en"
    @Published private(set) var recording: RecordingTranscript?
    @Published private(set) var recordingContext = ""
    @Published private var completedRecordingSignature: String?
    @Published private var recordingAttemptIncomplete = false
    @Published var notesInput: String { didSet { if notesInput != oldValue { notesResult = nil; clearNotice() } } }
    @Published private(set) var notesResult: MeetingNotes?
    @Published var voiceText = "" { didSet { if voiceText != oldValue { clip = nil; clearNotice() } } }
    @Published var voiceProvider: VoiceProvider = .elevenLabs {
        didSet {
            guard voiceProvider != oldValue else { return }
            voices = []; voiceID = ""; clip = nil; voicesLoaded = false; clearNotice()
            if !voiceLanguages.contains(where: { $0.code == voiceLanguage }) { voiceLanguage = "en" }
        }
    }
    @Published var voiceLanguage = "en" { didSet { if voiceLanguage != oldValue { clip = nil; clearNotice() } } }
    @Published var voiceID = "" { didSet { if voiceID != oldValue { clip = nil; clearNotice() } } }
    @Published private(set) var voices: [ProviderVoice] = []
    @Published private(set) var voicesLoaded = false
    @Published private(set) var clip: Data? { didSet { if clip != oldValue { stopClip() } } }
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
                     fish: services.contains(.fish) ? KeychainStore.load(for: .fish, storage: storage) : nil)
             }.value
         }) {
        self.clipPlayer = clipPlayer ?? VoicePreviewPlayer(); self.previewDeviceList = previewDeviceList
        notesInput = initialNotesText; self.service = service ?? SpeechToolsService(); self.voiceService = voiceService ?? VoiceService()
        self.keyPresence = keyPresence; self.credentialVersion = credentialVersion; self.loadCredentials = loadCredentials
        lastCredentialVersion = credentialVersion()
        if !initialNotesText.isEmpty { page = .notes }
        self.service.onProgress = { [weak self] in self?.progress = $0 }
    }

    var voiceLanguages: [TranslationLanguage] {
        voiceProvider == .elevenLabs ? TranslationLanguage.elevenLabsOutputs : TranslationLanguage.composedOutputs
    }
    var readyVoices: [ProviderVoice] { voices.filter(\.isReady) }
    private var recordingSignature: String {
        "\(recordingService.rawValue)/\(sourceLanguage)/\(recordingService == .elevenLabs && diarize)"
    }
    var recordingNeedsRefresh: Bool {
        recording != nil && (recordingAttemptIncomplete || completedRecordingSignature != recordingSignature)
    }
    var voiceAccount: ProviderService { voiceProvider == .elevenLabs ? .elevenLabs : .fish }
    var canGenerate: Bool {
        !busy && !voiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && voiceText.count <= SpeechToolsLimits.voiceCharacters && voiceText.utf8.count <= 8_000
        && (voiceProvider == .fish || !voiceID.isEmpty)
    }
    var canMakeNotes: Bool {
        !busy && !notesInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && notesInput.utf8.count <= SpeechToolsLimits.notesBytes
    }

    func refreshKeyPresence() {
        let version = credentialVersion()
        if let previous = lastCredentialVersion, previous != version {
            cancel()
            voices = []; voicesLoaded = false; voiceID = ""; clip = nil
            clearNotice()
        }
        lastCredentialVersion = version
        let presence = [ProviderService.openAI, .elevenLabs, .fish].map { ($0, keyPresence($0)) }
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
    func selectFile(_ url: URL) {
        guard !busy else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes > 0 else {
                throw SpeechToolsError.invalidRecording
            }
            guard bytes <= SpeechToolsLimits.recordingBytes else { throw SpeechToolsError.recordingTooLarge }
            fileURL = url; fileSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            recording = nil; recordingContext = ""; completedRecordingSignature = nil
            recordingAttemptIncomplete = false; clearNotice()
        } catch let safe as SpeechToolsError { showError(safe.localizedDescription) }
        catch { showError("The file could not be read. Choose another recording.") }
    }
    func transcribe() {
        guard !busy, let fileURL else { return }
        let source = sourceLanguage.isEmpty ? nil : sourceLanguage, selectedService = recordingService
        let speakers = selectedService == .elevenLabs && diarize
        let signature = recordingSignature
        let language = TranslationLanguage.elevenLabsOutputs.first(where: { $0.code == source })?.name ?? "Automatic language"
        recordingAttemptIncomplete = true
        perform("Transcribing audio…", services: [selectedService.account]) { model, keys in
            let transcriber = selectedService == .elevenLabs ? model.service : SpeechToolsService(transcriber: OpenAIRecordingTranscriber())
            model.fileService = transcriber
            transcriber.onProgress = { [weak model] in model?.progress = $0 }
            defer { model.fileService = nil }
            let result = try await transcriber.transcribe(fileURL: fileURL, sourceLanguage: source, diarize: speakers, credentials: keys)
            try model.checkCurrentOperation(); model.recording = result
            model.completedRecordingSignature = signature; model.recordingAttemptIncomplete = false
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
        }
    }
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
        let provider = voiceProvider
        perform("Loading voices…", services: [voiceAccount]) { model, keys in
            let voices = try await model.voiceService.list(provider: provider, credentials: keys)
            try model.checkCurrentOperation(); model.voices = voices; model.voicesLoaded = true
            if !voices.contains(where: { $0.id == model.voiceID && $0.isReady }) { model.voiceID = "" }
            model.notice = voices.filter(\.isReady).isEmpty ? "No ready account voices were found." : "Voices refreshed."
        }
    }
    func generateClip() {
        stopClip()
        refreshKeyPresence()
        guard canGenerate else { return }
        let text = voiceText, language = voiceLanguage, voice = voiceID.isEmpty ? nil : voiceID
        let route: TranslationRoute = voiceProvider == .elevenLabs ? .elevenLabs : .fish
        perform("Generating voice clip…", services: [voiceAccount]) { model, keys in
            let data = try await model.service.voiceClip(text: text, language: language, voiceID: voice, route: route, credentials: keys)
            try model.checkCurrentOperation()
            guard model.voiceText == text, model.voiceLanguage == language,
                  (model.voiceID.isEmpty ? nil : model.voiceID) == voice,
                  (model.voiceProvider == .elevenLabs ? TranslationRoute.elevenLabs : .fish) == route else { throw CancellationError() }
            model.clip = data; model.notice = "Voice clip is ready to play or save."
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
    func saveNotes() { if let notesResult { save(Data(notesResult.text.utf8), name: "Babelfin notes", extension: "txt") } }
    func saveClip() { if let clip { save(clip, name: "Babelfin voice clip", extension: "wav") } }

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
            } catch {
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
            let names = services.map { service in
                switch service { case .openAI: return "OpenAI"; case .elevenLabs: return "ElevenLabs"; case .fish: return "Fish Audio" }
            }.sorted().joined(separator: " and ")
            return "Add your \(names) API key in Settings, or allow Keychain access, then try again."
        }
    }
}
