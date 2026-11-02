import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BridgeCore

@MainActor private final class VoiceSettingsState: ObservableObject {
    @Published var voices: [ProviderVoice] = []
    @Published var busy = false
    @Published var notice = ""
    @Published var outputUID = ""
    @Published var name = ""
    @Published var consent = false
    @Published var sample: URL?
    @Published var creatingVoice = false
    enum SampleSource: Hashable { case record, file }
    @Published var sampleSource: SampleSource = .record { didSet { if oldValue != sampleSource { consent = false } } }
    @Published var recordInputUID = ""
    let recorder = VoiceSampleRecorder()
    private let service = VoiceService()
    private let player = VoicePreviewPlayer()
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var operationDescription = "Voice request"
    func cancel() { operation?.cancel(); service.cancel(); player.stop() }
    /// Provider change: abandon the old operation without a late notice from it.
    func reset() {
        generation = UUID(); cancel(); operation = nil; busy = false
        notice = ""; voices = []; sample = nil; consent = false
        recorder.discard(); creatingVoice = false
    }
    func chooseSample() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["wav", "mp3", "m4a"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { sample = panel.url; consent = false; recorder.discard() }
    }
    private func credentials(_ provider: VoiceProvider) throws -> ProviderCredentials {
        provider == .elevenLabs ? try ProviderCredentials(elevenLabs: KeychainStore.load(for: .elevenLabs)) : try ProviderCredentials(fish: KeychainStore.load(for: .fish))
    }
    func perform(_ description: String, _ body: @escaping @MainActor (VoiceSettingsState) async throws -> Void) {
        guard !busy else { return }; busy = true; notice = ""; operationDescription = description
        let token = UUID(); generation = token
        operation = Task { [weak self] in
            guard let self else { return }
            let credentialLease = CredentialOperationActivity.shared.begin()
            defer { CredentialOperationActivity.shared.end(credentialLease) }
            do {
                try Task.checkCancellation()
                guard self.generation == token else { throw CancellationError() }
                try await body(self)
            }
            catch {
                if self.generation == token {
                    self.notice = error is CancellationError ? "Cancelled." : "\(self.operationDescription) failed. \(TranslationFailureReason(error: error).safeSummary)"
                }
            }
            guard self.generation == token else { return }
            self.busy = false; self.operation = nil
        }
    }
    func refresh(_ provider: VoiceProvider) { perform("\(provider.displayName) voice listing") { state in
        let values = try await state.service.list(provider: provider, credentials: state.credentials(provider))
        try Task.checkCancellation(); state.voices = values; VoiceNameCache.remember(values)
        state.notice = values.isEmpty ? "No account voices found." : "Voices refreshed."
    } }
    var canEnroll: Bool {
        guard consent, !busy, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return sampleSource == .file ? sample != nil : (!recorder.recording && recorder.sample.meetsMinimum)
    }
    func enroll(_ provider: VoiceProvider) {
        guard canEnroll else { return }
        let source: VoiceService.EnrollmentSample
        if sampleSource == .file, let sample { source = .file(sample) }
        else {
            do { source = .recorded(try recorder.sample.wav()) }
            catch { notice = (error as? BridgeError)?.localizedDescription ?? "Record a longer sample."; return }
        }
        let name = name
        perform("\(provider.displayName) voice creation") { state in
            let voice = try await state.service.enroll(provider: provider, name: name, sample: source, consent: true, credentials: state.credentials(provider))
            try Task.checkCancellation()
            state.sample = nil; state.consent = false; state.recorder.discard(); state.creatingVoice = false
            // Reload so existing voices keep their names; keep the new voice if listing lags.
            var listed = (try? await state.service.list(provider: provider, credentials: state.credentials(provider))) ?? state.voices
            try Task.checkCancellation()
            if !listed.contains(where: { $0.id == voice.id }) { listed.append(voice) }
            state.voices = listed; VoiceNameCache.remember(listed)
            state.notice = voice.isReady ? "Voice created. Select it above." : "Voice submitted. Refresh to check when it is ready."
        }
    }
    func preview(_ provider: VoiceProvider, voiceID: String, output: AudioDevice) { perform("Voice credential access") { state in
        let credentials = try state.credentials(provider)
        state.operationDescription = "Preview output setup"
        try state.player.start(output: output)
        defer { state.player.stop() }
        state.operationDescription = "\(provider.displayName) speech generation"
        try await state.service.preview(provider: provider, voiceID: voiceID, text: "Hello. This is a preview of my voice in Babelfin.", credentials: credentials, onAudio: { [weak state] pcm in
            guard let state else { throw CancellationError() }
            try await state.player.append(pcm)
        })
        state.operationDescription = "Preview playback"
        try await state.player.finish(); state.notice = "Preview finished."
    } }
}

struct VoiceSettingsView: View {
    @ObservedObject var model: AppModel
    var allAudioStopped: () -> Bool
    @StateObject private var state = VoiceSettingsState()
    private var provider: VoiceProvider { model.route.descriptor.speechService == .fish ? .fish : .elevenLabs }
    var body: some View {
        Section {
            if model.route.descriptor.isDirect {
                LabeledContent("Voice", value: "Follows the speaker")
            } else if model.route.descriptor.speechService == nil {
                LabeledContent("Voice", value: "The best system voice for the language")
            } else {
                HStack(spacing: 12) {
                    Picker("Voice", selection: $model.voiceID) {
                        Text(provider == .fish ? "Default voice" : "Choose a voice").tag("")
                        if !model.voiceID.isEmpty, !state.voices.contains(where: { $0.id == model.voiceID }) { Text("Saved voice").tag(model.voiceID) }
                        ForEach(state.voices.filter(\.isReady)) { Text($0.name).tag($0.id) }
                    }.disabled(model.configurationLocked || state.busy)
                    Button { state.refresh(provider) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh voices").help("Refresh account voices")
                        .disabled(state.busy || !allAudioStopped())
                }
                SpeakerVoicesRows(model: model, voices: state.voices.filter(\.isReady), placeholder: provider == .fish ? "Default voice" : "Choose a voice")
                HStack(spacing: 12) {
                    Picker("Preview through", selection: $state.outputUID) {
                        Text("Choose headphones").tag("")
                        ForEach(model.devices.filter { $0.isPhysical && $0.outputChannels > 0 }) { Text($0.name).tag($0.uid) }
                    }.disabled(state.busy).accessibilityLabel("Preview output")
                    Button {
                        guard allAudioStopped(), let device = model.devices.first(where: { $0.uid == state.outputUID }) else { return }
                        state.preview(provider, voiceID: model.voiceID, output: device)
                    } label: { Label("Preview", systemImage: "play.fill") }
                        .accessibilityLabel("Preview voice")
                        .disabled(state.busy || !allAudioStopped() || state.outputUID.isEmpty || (provider == .elevenLabs && model.voiceID.isEmpty))
                }
                HStack {
                    Text("Create a voice from your own recording or an audio file.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Create a voice…") { state.consent = false; state.creatingVoice = true }
                        .disabled(state.busy || !allAudioStopped())
                }
                if state.busy && !state.creatingVoice {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { state.cancel() }
                    }
                } else if !state.notice.isEmpty {
                    Text(state.notice).font(.callout).foregroundStyle(.secondary)
                }
                if !allAudioStopped() {
                    Text("Stop both directions to refresh voices, preview or create a voice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Voice") }
        .sheet(isPresented: $state.creatingVoice, onDismiss: { state.recorder.discard() }) {
            VoiceCreationSheet(state: state, recorder: state.recorder, provider: provider, devices: model.devices, allAudioStopped: allAudioStopped)
        }
        .onChange(of: model.route) { _ in state.reset() }
        .onChange(of: allAudioStopped()) { stopped in if !stopped { state.cancel() } }
        .onDisappear { state.cancel() }
    }
}

/// Voice per speaker: on a route that labels speakers live, Speaker 1, 2, … each get a voice in order.
private struct SpeakerVoicesRows: View {
    @ObservedObject var model: AppModel
    var voices: [ProviderVoice]
    var placeholder: String
    private var enabled: Binding<Bool> {
        Binding(get: { !model.speakerVoices.isEmpty },
                set: { model.speakerVoices = $0 ? [model.voiceID, ""] : [] })
    }
    var body: some View {
        if model.route.descriptor.liveSpeakerLabels {
            Toggle("Voice per speaker", isOn: enabled).disabled(model.configurationLocked).accessibilityLabel("Voice per speaker")
            if !model.speakerVoices.isEmpty {
                ForEach(model.speakerVoices.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Picker("Speaker \(index + 1)", selection: Binding(
                            get: { model.speakerVoices.indices.contains(index) ? model.speakerVoices[index] : "" },
                            set: { value in if model.speakerVoices.indices.contains(index) { model.speakerVoices[index] = value } })) {
                            Text(placeholder).tag("")
                            let chosen = model.speakerVoices[index]
                            if !chosen.isEmpty, !voices.contains(where: { $0.id == chosen }) { Text(VoiceNameCache.name(for: chosen) ?? "Saved voice").tag(chosen) }
                            ForEach(voices) { Text($0.name).tag($0.id) }
                        }
                        Button { model.speakerVoices.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove the voice for speaker \(index + 1)")
                            .disabled(model.speakerVoices.count <= 1)
                    }.disabled(model.configurationLocked)
                }
                HStack {
                    Button("Add a speaker voice") { model.speakerVoices.append("") }
                        .disabled(model.configurationLocked || model.speakerVoices.count >= TranslationConfiguration.maximumSpeakerVoices)
                    Spacer()
                }
                Text("Fish Audio labels the speakers in order of appearance. With more speakers than voices, the voices repeat. Turning this on or off applies after Restart.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if !model.route.descriptor.isDirect {
            Text("Speaker voices need Fish Audio recognition.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The voice row of the main window: the account's voices as a menu, loaded once when shown.
/// Settings keeps preview and voice creation.
struct MainVoicePicker: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = VoiceSettingsState()
    private var provider: VoiceProvider { model.route.descriptor.speechService == .fish ? .fish : .elevenLabs }
    var body: some View {
        if model.route.descriptor.isDirect {
            Text("Follows the speaker")
        } else if model.route.descriptor.speechService == nil {
            Text("System voice")
        } else {
            HStack(spacing: 8) {
                Picker("Voice", selection: $model.voiceID) {
                    Text(provider == .fish ? "Default voice" : "Choose a voice").tag("")
                    if !model.voiceID.isEmpty, !state.voices.contains(where: { $0.id == model.voiceID }) {
                        Text(model.voiceDisplayName).tag(model.voiceID)
                    }
                    ForEach(state.voices.filter(\.isReady)) { Text($0.name).tag($0.id) }
                }.labelsHidden().disabled(model.configurationLocked || state.busy)
                Button { state.refresh(provider) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh account voices").accessibilityLabel("Refresh voices")
                    .disabled(state.busy)
            }
            .onAppear { if state.voices.isEmpty { state.refresh(provider) } }
            .onChange(of: model.route) { _ in state.reset(); state.refresh(provider) }
        }
    }
}

@MainActor private final class CredentialFieldState: ObservableObject {
    @Published var draft = ""
    @Published var notice = ""
    @Published var saved: Bool?
}
struct CredentialKeyRow: View {
    let service: ProviderService
    let title: String
    var keysPage: URL? = nil
    let storageMode: CredentialStorageMode
    var allAudioStopped: () -> Bool
    @ObservedObject private var activity = CredentialOperationActivity.shared
    @ObservedObject private var checks = KeyCheckStore.shared
    @StateObject private var state = CredentialFieldState()
    private var report: KeyCheckReport? { checks.report(for: service, storage: storageMode) }
    /// One line per provider: name, key field, saved state and actions. Notices appear below only when present.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text(title)
                    if let keysPage {
                        Link(destination: keysPage) { Image(systemName: "arrow.up.right.square") }
                            .help("Open the \(title) API keys page").accessibilityLabel("\(title) API keys page")
                    }
                }.frame(width: 120, alignment: .leading)
                SecureField("\(title) API key", text: $state.draft,
                    prompt: Text(state.saved == true ? "Saved — paste to replace" : "Paste your API key"))
                    .textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel("\(title) API key")
                Group {
                    if state.saved == true, let report, !report.missing.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    else if state.saved == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if state.saved == false { Image(systemName: "circle.dashed").foregroundStyle(.secondary) }
                    else { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) }
                }
                .help(statusText).accessibilityLabel(statusText)
                Button("Save") {
                    guard allAudioStopped(), !activity.active else { return }
                    do {
                        let key = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        try KeychainStore.save(state.draft, for: service, storage: storageMode)
                        state.draft = ""; state.saved = true
                        checks.discard(service, storage: storageMode)
                        NotificationCenter.default.post(name: .babelfinCredentialMetadataChanged, object: nil)
                        state.notice = storageMode == .keychain ? "Saved in Keychain." : "Saved on this Mac."
                        let storage = storageMode
                        Task { await checks.check(service, storage: storage, key: key) }
                    }
                    catch let error as LocalCredentialError { state.notice = error.errorDescription ?? "Could not save the key." }
                    catch { state.notice = "Could not save the key." }
                }.disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fixedSize().accessibilityLabel("Save \(title) API key")
                Button("Remove", role: .destructive) {
                    guard allAudioStopped(), !activity.active else { return }
                    do {
                        try KeychainStore.delete(for: service, storage: storageMode); state.saved = false
                        checks.discard(service, storage: storageMode)
                        NotificationCenter.default.post(name: .babelfinCredentialMetadataChanged, object: nil)
                        state.notice = storageMode == .keychain ? "Removed from Keychain." : "Removed from this Mac."
                    }
                    catch let error as LocalCredentialError { state.notice = error.errorDescription ?? "Could not remove the key." }
                    catch { state.notice = "Could not remove the key." }
                }.disabled(state.saved == false).fixedSize().accessibilityLabel("Remove \(title) API key")
            }
            if !state.notice.isEmpty {
                Text(state.notice).font(.caption).foregroundStyle(.secondary).padding(.leading, 130)
            }
            if state.saved == true, !KeyPermissions.for(service).isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let report {
                        Text(report.summary).font(.caption).foregroundStyle(report.missing.isEmpty ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(checkButtonTitle) {
                        let storage = storageMode
                        Task { await checks.check(service, storage: storage) }
                    }.controlSize(.small).disabled(checks.checking.contains(service))
                        .help("Checks which permissions the key has. The check sends requests that produce nothing and cost no credits.")
                        .accessibilityLabel("Check \(title) API key permissions")
                }.padding(.leading, 130)
            }
        }.disabled(!allAudioStopped() || activity.active)
            .onAppear { refreshPresence() }
            .onChange(of: storageMode) { _ in refreshPresence(); NotificationCenter.default.post(name: .babelfinCredentialMetadataChanged, object: nil) }
            .onDisappear { state.draft = ""; state.notice = "" }
    }
    private var statusText: String {
        switch state.saved {
        case true?: return report.map { $0.missing.isEmpty ? "Key saved" : "Key saved, but it lacks permissions" } ?? "Key saved"
        case false?: return "No key saved"
        case nil: return "Key status unavailable"
        }
    }
    private var checkButtonTitle: String {
        if checks.checking.contains(service) { return "Checking…" }
        return report == nil ? "Check key" : "Check again"
    }
    private func refreshPresence() {
        state.draft = ""; state.notice = ""
        state.saved = KeychainStore.containsSavedKey(for: service, storage: storageMode)
    }
}

/// Sample, name and rights confirmation for one provider. Nothing is uploaded until
/// Create voice; the recording stays in memory and is discarded when the sheet closes.
private struct VoiceCreationSheet: View {
    @ObservedObject var state: VoiceSettingsState
    @ObservedObject var recorder: VoiceSampleRecorder
    let provider: VoiceProvider
    let devices: [AudioDevice]
    var allAudioStopped: () -> Bool
    @StateObject private var output = PreviewOutputChoice()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create a voice").font(.title3.weight(.semibold))
                Text("\(provider.displayName) creates the voice in your account. Use only your own voice or one you have permission to clone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Sample", selection: $state.sampleSource) {
                Text("Record").tag(VoiceSettingsState.SampleSource.record)
                Text("Choose a file").tag(VoiceSettingsState.SampleSource.file)
            }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(recorder.recording || state.busy)
            Group {
                if state.sampleSource == .record { recordPanel } else { filePanel }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            Grid(alignment: .leading, horizontalSpacing: 12) {
                GridRow {
                    Text("Voice name").foregroundStyle(.secondary)
                    TextField("Voice name", text: $state.name).textFieldStyle(.roundedBorder).labelsHidden()
                }
            }
            Toggle("I own this voice or have permission to clone it", isOn: $state.consent).toggleStyle(.checkbox).accessibilityLabel("I own this voice or have permission to clone it")
                .disabled(recorder.recording || state.busy)
            if state.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Creating voice…").foregroundStyle(.secondary) }
            } else if !state.notice.isEmpty {
                Text(state.notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { state.cancel(); state.creatingVoice = false }.keyboardShortcut(.cancelAction)
                Button("Create voice") { state.enroll(provider) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!state.canEnroll || !allAudioStopped())
            }
        }
        .padding(24).frame(width: 560)
    }
    private var inputs: [AudioDevice] { devices.filter(\.isPhysicalInput) }
    private var outputs: [AudioDevice] { devices.filter { $0.isPhysical && $0.outputChannels > 0 } }
    private var recordPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Microphone").foregroundStyle(.secondary)
                    Picker("Microphone", selection: $state.recordInputUID) {
                        Text("Choose a microphone").tag("")
                        ForEach(inputs) { Text($0.name).tag($0.uid) }
                    }.labelsHidden().disabled(recorder.recording)
                }
                GridRow {
                    Text("Play through").foregroundStyle(.secondary)
                    Picker("Play through", selection: $output.uid) {
                        Text("Choose headphones").tag("")
                        ForEach(outputs) { Text($0.name).tag($0.uid) }
                    }.labelsHidden()
                }
            }
            HStack(spacing: 12) {
                Button {
                    if recorder.recording { recorder.stop() }
                    else if let device = inputs.first(where: { $0.uid == state.recordInputUID }) {
                        state.consent = false
                        Task { await recorder.start(input: device) }
                    }
                } label: {
                    Label(recorder.recording ? "Stop" : (recorder.hasSample ? "Record again" : "Record"),
                          systemImage: recorder.recording ? "stop.circle.fill" : "record.circle")
                }
                .disabled(!allAudioStopped() || state.busy || (!recorder.recording && state.recordInputUID.isEmpty))
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(recorder.level), total: 1).accessibilityLabel("Recording level")
                    HStack {
                        Text(recorder.recording ? "Recording · read naturally, as in a meeting" : (recorder.hasSample ? "Recorded" : "Not recorded"))
                        Spacer()
                        Text("\(Self.time(recorder.seconds)) / \(Self.time(Double(VoiceSampleBuffer.maximumSeconds)))").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Button(recorder.playing ? "Stop" : "Play") {
                    if recorder.playing { recorder.stopPlayback() }
                    else if let device = outputs.first(where: { $0.uid == output.uid }) { recorder.play(output: device) }
                }.disabled(recorder.recording || !recorder.hasSample || output.uid.isEmpty)
                Button("Discard") { recorder.discard(); state.consent = false }
                    .disabled(recorder.recording || !recorder.hasSample)
            }
            Text(recorder.notice.isEmpty
                 ? "Aim for 30–90 seconds in a quiet room, and at least \(VoiceSampleBuffer.minimumSeconds) seconds. The recording stays in memory and is uploaded only when you choose Create voice."
                 : recorder.notice)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var filePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose sample…") { state.chooseSample() }.disabled(state.busy)
                Text(state.sample?.lastPathComponent ?? "No sample selected")
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Text("WAV, MP3 or M4A up to 20 MB. Use clean, single-speaker audio; your meeting is never used as a voice sample.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private static func time(_ seconds: Double) -> String {
        let value = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

@MainActor private final class PreviewOutputChoice: ObservableObject { @Published var uid = "" }
