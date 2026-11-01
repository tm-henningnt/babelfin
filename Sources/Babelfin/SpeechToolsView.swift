import AppKit
import SwiftUI
import BridgeCore

/// Optional tools live in their own window, leaving the everyday audio controls compact.
struct SpeechToolsView: View {
    @StateObject private var model: SpeechToolsModel
    private let meetingText: (@MainActor () -> String)?
    private let showsSidebar: Bool

    init(initialNotesText: String = "", meetingText: (@MainActor () -> String)? = nil) {
        _model = StateObject(wrappedValue: SpeechToolsModel(initialNotesText: initialNotesText))
        self.meetingText = meetingText; showsSidebar = true
    }
    /// Source-rendered previews inject a model whose credential storage and services are isolated.
    /// The main window embeds the pages without this view's own sidebar and keeps the
    /// model, so switching sections does not cancel a running transcription.
    init(model: SpeechToolsModel, meetingText: (@MainActor () -> String)? = nil, showsSidebar: Bool = true) {
        _model = StateObject(wrappedValue: model); self.meetingText = meetingText; self.showsSidebar = showsSidebar
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                List(selection: $model.page) {
                    ForEach(SpeechToolsPage.allCases) { page in Label(page.title, systemImage: page.symbol).tag(page) }
                }
                .listStyle(.sidebar).frame(width: 176).accessibilityLabel("Audio tools")
                Divider()
            }
            VStack(spacing: 0) {
                if !showsSidebar {
                    Picker("Tool", selection: Binding(get: { model.page ?? .voice }, set: { model.page = $0 })) {
                        ForEach([SpeechToolsPage.voice, .recording, .notes]) { page in Label(page.title, systemImage: page.symbol).tag(page) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .padding(.top, 16).padding(.bottom, 4)
                }
                Group {
                    switch model.page ?? .recording {
                    case .recording: recordingPage
                    case .notes: notesPage
                    case .voice: voicePage
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                operationStatus
            }
        }
        .frame(minWidth: showsSidebar ? 760 : 520, idealWidth: 840, minHeight: showsSidebar ? 580 : 480, idealHeight: 680)
        .onAppear { model.refreshKeyPresence(); model.observePreviewDevices(); model.refreshMicrophones() }
        .onChange(of: model.page) { _ in model.cancel(); model.clearNotice() }
        .onDisappear { if showsSidebar { model.cancel() }; model.endPreviewObservation() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshKeyPresence(); model.refreshPreviewOutputs() }
    }

    private var recordingPage: some View {
        VStack(spacing: 0) {
            heading("Audio file", "Turn a recording into text, then translate it if you need to.")
            Form {
                Section {
                    Picker("Source", selection: $model.audioInput) {
                        ForEach(AudioInput.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.busy || model.microphone.recording)
                    if model.audioInput == .microphone {
                        MicrophoneControls(model: model, recorder: model.microphone)
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: model.fileURL == nil ? "waveform" : "doc")
                                .font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.fileURL?.lastPathComponent ?? "Choose a recording")
                                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                Text(model.fileURL == nil ? "Audio and video files up to 25 MB" : model.fileSize)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button(model.fileURL == nil ? "Choose file…" : "Change…") { model.chooseFile() }
                                .disabled(model.busy).accessibilityLabel("Choose an audio file")
                        }
                    }
                    Picker("Transcription service", selection: $model.recordingService) {
                        ForEach(RecordingService.allCases) { Text($0.title).tag($0) }
                    }.disabled(model.busy)
                        .help("ElevenLabs can also label the different speakers in a recording.")
                    Picker("Spoken language", selection: $model.sourceLanguage) {
                        Text("Detect automatically").tag("")
                        ForEach(TranslationLanguage.elevenLabsOutputs) { Text($0.name).tag($0.code) }
                    }.disabled(model.busy)
                    if model.recordingService == .elevenLabs {
                        Toggle("Label different speakers", isOn: $model.diarize).disabled(model.busy)
                            .help("Labels distinguish voices in this recording. They do not identify people.")
                    }
                    HStack {
                        Text("\(model.recordingService.title) receives the audio when you choose Transcribe.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button("Transcribe") { model.transcribe() }.buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.audioSource == nil || model.missingKeys.contains(model.recordingService.account))
                    }
                    missingKey(model.recordingService.account)
                }
                if let recording = model.recording, !recording.segments.isEmpty {
                    Section {
                        HStack(spacing: 12) {
                            Picker("Translate to", selection: $model.targetLanguage) {
                                ForEach(TranslationLanguage.elevenLabsOutputs) { Text($0.name).tag($0.code) }
                            }
                            Button("Translate") { model.translateRecording() }
                                .disabled(model.busy || model.missingKeys.contains(.openAI))
                        }.disabled(model.busy)
                        Text("OpenAI receives the transcript for translation. Your original text is kept.")
                            .font(.caption).foregroundStyle(.secondary)
                        missingKey(.openAI)
                    }
                    if recording.targetLanguage != nil {
                        Section {
                            Toggle("Keep the original under the dub", isOn: $model.dubIncludesOriginal).disabled(model.busy)
                            HStack {
                                Button("Create dub") { model.createDub() }
                                    .disabled(!model.canDub || model.voiceKeyMissing)
                                if model.dub != nil { Button("Save WAV…") { model.saveDub() }.disabled(model.busy) }
                            }
                            Text(dubHelp(recording)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let account = model.voiceAccount { missingKey(account) }
                        } header: { Text("Dub") }
                    }
                    Section {
                        Text(model.recordingContext).font(.caption).foregroundStyle(.secondary)
                        if model.recordingNeedsRefresh {
                            Text("This is the previous transcript. Transcribe again to update it with the selected settings.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button("Copy text") { model.copy(recording.plainText()) }
                            Menu("Save…") {
                                Button("Plain text…") { model.saveRecording(json: false) }
                                Button("Structured transcript (JSON)…") { model.saveRecording(json: true) }
                            }.fixedSize()
                            Spacer(minLength: 8)
                            Button("Make notes…") { model.useRecordingForNotes() }
                        }.disabled(model.busy)
                        recordingText(recording)
                    } header: { Text(model.recordingNeedsRefresh ? "Previous transcript" : "Transcript") }
                } else {
                    Section {
                        Text(model.recording == nil ? "Your transcript will appear here, with speaker labels and timing when available." : "No speech was found. Try another recording or choose the spoken language.")
                            .foregroundStyle(.secondary).padding(.vertical, 12)
                    } header: { Text("Transcript") }
                }
            }.formStyle(.grouped)
        }
    }

    private var notesPage: some View {
        VStack(spacing: 0) {
            heading("Meeting notes", "Pull the main points, decisions and open questions from your text.")
            Form {
                Section {
                    if let meetingText {
                        HStack {
                            Text("Start with meeting text or paste your own.").font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Use meeting text") { model.replaceNotes(with: meetingText()) }.disabled(model.busy)
                        }
                    }
                    textEditor($model.notesInput, label: "Text for meeting notes", placeholder: "Paste a transcript or notes here…", height: 150)
                    HStack(alignment: .center, spacing: 12) {
                        Text("OpenAI receives this text when you choose Make notes.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Make notes") { model.makeNotes() }.buttonStyle(.borderedProminent)
                            .disabled(!model.canMakeNotes || model.missingKeys.contains(.openAI))
                    }
                    if model.notesInput.utf8.count > SpeechToolsLimits.notesBytes {
                        Label("This text is too long. Select a shorter section.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    missingKey(.openAI)
                } header: { Text("Source text") }
                Section {
                    if let notes = model.notesResult {
                        HStack {
                            Button("Copy notes") { model.copy(notes.text) }
                            Button("Save notes…") { model.saveNotes() }
                            Spacer()
                        }.disabled(model.busy)
                        ScrollView {
                            Text(notes.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 140, maxHeight: 260)
                        Text(notes.isComplete ? "All supplied text was processed. Review the notes before sharing." : "These notes cover only part of the supplied text.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Your notes will appear here, ready to review and copy.")
                            .foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                } header: { Text("Notes") }
            }.formStyle(.grouped)
        }
    }

    private var voicePage: some View {
        VStack(spacing: 0) {
            heading("Voice clip", "Give a short text or your own recording a voice, ready to save and share.")
            Form {
                Section {
                    Picker("Voice service", selection: $model.voiceProvider) {
                        ForEach(ClipVoiceService.allCases) { Text($0.displayName).tag($0) }
                    }.disabled(model.busy)
                    Picker("Language", selection: $model.voiceLanguage) {
                        ForEach(model.voiceLanguages) { Text($0.name).tag($0.code) }
                    }.disabled(model.busy)
                    HStack(spacing: 12) {
                        Picker("Voice", selection: $model.voiceID) {
                            Text(model.voiceProvider == .elevenLabs ? "Choose a voice" : "Default voice").tag("")
                            ForEach(model.readyVoices) { Text($0.name).tag($0.id) }
                        }
                        Button(model.voicesLoaded ? "Refresh" : "Load voices") { model.refreshVoices() }
                            .accessibilityLabel("Load voices from \(model.voiceProvider.displayName)")
                            .disabled(model.voiceKeyMissing)
                    }.disabled(model.busy)
                    if !voiceHelp.isEmpty { Text(voiceHelp).font(.caption).foregroundStyle(.secondary) }
                    if let account = model.voiceAccount { missingKey(account) }
                }
                Section {
                    Picker("Speak", selection: $model.voiceSource) {
                        ForEach(VoiceSource.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Delivery", selection: $model.voiceDelivery) {
                        ForEach(SpeechDirection.Delivery.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.pickerStyle(.segmented)
                    if model.voiceSource == .text {
                        HStack {
                            Slider(value: $model.voiceSpeed, in: SpeechDirection.speeds, step: 0.05) { Text("Speed") }
                                .accessibilityValue("\(speedText) times")
                            Text("\(speedText)×").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    if !deliveryHelp.isEmpty { Text(deliveryHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                } header: { Text("Delivery") }
                .disabled(model.busy)
                if model.voiceSource == .recording {
                    Section {
                        MicrophoneControls(model: model, recorder: model.microphone)
                        HStack {
                            Text(revoiceHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            Button(model.takes.isEmpty ? "Give it a new voice" : "Generate another take") { model.generateClip() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.canRevoice || model.microphoneRecording == nil || model.missingKeys.contains(.elevenLabs))
                        }
                    } header: { Text("Your recording") }
                } else {
                    Section {
                        if #available(macOS 15.0, *) {
                            TaggedTextEditor(model: model, tagsAvailable: model.voiceProvider == .elevenLabs)
                        } else {
                            textEditor($model.voiceText, label: "Voice clip text", placeholder: "Write the words you want to hear…", height: 96)
                            if model.voiceProvider == .elevenLabs {
                                TagButtons { model.appendTag($0) }.disabled(model.busy)
                            }
                        }
                        HStack {
                            Text("\(model.voiceText.count.formatted()) / 2,000 characters")
                                .foregroundStyle(model.voiceText.count > SpeechToolsLimits.voiceCharacters ? Color.orange : Color.secondary)
                                .font(.caption).monospacedDigit()
                            Spacer()
                            Button(model.takes.isEmpty ? "Generate clip" : "Generate another take") { model.generateClip() }.buttonStyle(.borderedProminent)
                                .disabled(!model.canGenerate || model.voiceKeyMissing)
                        }
                        if model.voiceText.utf8.count > 8_000 && model.voiceText.count <= SpeechToolsLimits.voiceCharacters {
                            Text("This text is too long for one clip. Shorten it, then generate again.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text(model.voiceProvider == .system ? "The text stays on this Mac."
                             : "\(model.voiceProvider.displayName) receives this text for speech generation.")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: { Text("Words to speak") }
                }
            }.formStyle(.grouped)
            // The takes and the player stay in view below the form.
            if !model.takes.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    Button(model.playingClip ? "Stop" : "Play") {
                        if model.playingClip { model.stopClip() } else { model.playClip() }
                    }.disabled(!model.playingClip && !model.canPlayClip).keyboardShortcut(.space, modifiers: [])
                    Picker("Take", selection: $model.selectedTakeID) {
                        ForEach(model.takes.reversed()) { Text($0.title).tag(Optional($0.id)) }
                    }.disabled(model.busy).frame(maxWidth: 260)
                    Picker("Through", selection: $model.previewOutputUID) {
                        Text("Choose headphones or speakers").tag("")
                        if !model.previewOutputUID.isEmpty && !model.previewOutputs.contains(where: { $0.uid == model.previewOutputUID }) {
                            Text("Selected device — disconnected").tag(model.previewOutputUID)
                        }
                        ForEach(model.previewOutputs) { Text($0.name).tag($0.uid) }
                    }.frame(maxWidth: 260)
                    Spacer(minLength: 0)
                    if let clip = model.clip {
                        Text(clipDuration(clip)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button("Save WAV…") { model.saveClip() }.disabled(model.busy)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
    }

    private var revoiceHelp: String {
        if model.voiceProvider != .elevenLabs { return "A new voice for your recording needs ElevenLabs. Choose it as the voice service." }
        if model.voiceID.isEmpty { return "Choose a voice above." }
        if (model.microphoneRecording?.count ?? 0) > SpeechToolsLimits.voicePCMBytes + 44 {
            return SpeechToolsError.revoiceTooLong.errorDescription ?? ""
        }
        return "ElevenLabs speaks your recording with the chosen voice and keeps your timing and intonation. Delivery applies; speed does not."
    }

    private func dubHelp(_ recording: RecordingTranscript) -> String {
        if recording.segments.contains(where: { $0.translatedText != nil && $0.startSeconds == nil }) {
            return SpeechToolsError.dubUntimed.errorDescription ?? ""
        }
        if model.voiceProvider == .elevenLabs && model.voiceID.isEmpty { return "Choose a voice under Voice clip first." }
        let upload = model.voiceProvider == .system ? "The translation and the original stay on this Mac."
            : "\(model.voiceProvider.displayName) receives about \(model.dubCharacters.formatted()) characters. The original stays on this Mac."
        return "Speaks the translation at the original times with the voice and delivery from Voice clip. " + upload
    }

    private var speedText: String { String(format: "%.2f", model.voiceSpeed) }

    private var deliveryHelp: String {
        switch model.voiceProvider {
        case .system: return "System voices read every delivery the same way. Speed applies."
        case .gemini: return "Gemini reads every delivery the same way. Speed applies."
        case .elevenLabs, .fish: break
        }
        switch model.voiceDelivery {
        case .steady, .natural: return ""
        case .expressive: return model.voiceProvider == .elevenLabs
            ? "More emotion and variation. Uses ElevenLabs v3, which performs tags such as [whispers] best and takes longer."
            : "More emotion and variation. Fish Audio performs tags such as [whispers]."
        }
    }

    private var voiceHelp: String {
        if model.voiceProvider == .system {
            return "The default is the best installed voice for the language. Add voices in System Settings › Accessibility › Read & Speak."
        }
        if model.voiceProvider == .gemini {
            return "Gemini's voices speak every language. The default is \(GeminiSpeechSynthesisStage.defaultVoice)."
        }
        if model.voiceProvider == .elevenLabs && model.voiceID.isEmpty {
            if model.voicesLoaded && model.readyVoices.isEmpty {
                return "No ready voices were found. Check voice access in your ElevenLabs account, then refresh."
            }
            return model.voicesLoaded ? "Choose a voice to generate your clip." : "Load voices, then choose one to generate a clip."
        }
        return ""
    }

    private func recordingText(_ recording: RecordingTranscript) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(recording.segments) { segment in
                    VStack(alignment: .leading, spacing: 5) {
                        let label = segmentHeading(segment)
                        if !label.isEmpty { Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                        Text(segment.sourceText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let translation = segment.translatedText {
                            Text(languageName(recording.targetLanguage) + " · translated").font(.caption).foregroundStyle(.secondary)
                            Text(translation).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 180, maxHeight: 320)
    }
    @ViewBuilder private func heading(_ title: String, _ description: String) -> some View {
        // In the main window the tabs name the tool.
        if showsSidebar { headingText(title, description) }
    }
    private func headingText(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 4)
    }
    private func textEditor(_ text: Binding<String>, label: String, placeholder: String, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text).font(.body).accessibilityLabel(label).disabled(model.busy)
                .padding(4).scrollContentBackground(.hidden)
            if text.wrappedValue.isEmpty {
                Text(placeholder).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 12)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }.frame(height: height).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
    @ViewBuilder private func missingKey(_ service: ProviderService) -> some View {
        if model.missingKeys.contains(service) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add your \(serviceName(service)) API key to use this action.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                    .controlSize(.small)
            }
        }
    }
    private var operationStatus: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if model.busy {
                    ProgressView().controlSize(.small).accessibilityLabel(model.operationTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.operationTitle).font(.callout)
                        if let progress = model.progress, progress.total > 1 {
                            Text("\(progress.completed) of \(progress.total) sections")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer()
                    Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                } else if !model.notice.isEmpty {
                    if model.isError { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true) }
                    Text(model.notice).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                } else {
                    Text("Text and clips stay in memory. Copy or save anything you want to keep.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 10)
        }
    }
    private func serviceName(_ service: ProviderService) -> String { service.displayName }
    private func languageName(_ code: String?) -> String {
        TranslationLanguage.elevenLabsOutputs.first { $0.code == code }?.name ?? "Translation"
    }
    private func segmentHeading(_ segment: RecordingSegment) -> String {
        var parts: [String] = []
        if let speaker = segment.speaker { parts.append(speaker) }
        if let start = segment.startSeconds, start.isFinite, start >= 0, start < 86_401 {
            let seconds = Int(start)
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        return parts.joined(separator: " · ")
    }
    private func clipDuration(_ data: Data) -> String {
        let duration = max(0, Double(data.count - 44) / 48_000)
        return "\(duration.formatted(.number.precision(.fractionLength(1)))) sec · WAV"
    }
}

/// Records the tools' microphone recording. Both Audio file and Voice clip use the same recording.
private struct MicrophoneControls: View {
    @ObservedObject var model: SpeechToolsModel
    @ObservedObject var recorder: VoiceSampleRecorder
    var body: some View {
        Picker("Microphone", selection: $model.microphoneUID) {
            Text("Choose a microphone").tag("")
            ForEach(model.microphones) { Text($0.name).tag($0.uid) }
        }.disabled(recorder.recording || model.busy)
        HStack(spacing: 12) {
            Button { model.toggleMicrophone() } label: {
                Label(recorder.recording ? "Stop" : (model.microphoneRecording == nil ? "Record" : "Record again"),
                      systemImage: recorder.recording ? "stop.circle.fill" : "record.circle")
            }.disabled(model.busy || (!recorder.recording && model.microphoneUID.isEmpty))
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(recorder.level), total: 1).accessibilityLabel("Recording level")
                HStack {
                    Text(recorder.recording ? "Recording" : (model.microphoneRecording == nil ? "Not recorded" : "Recorded"))
                    Spacer()
                    Text("\(Self.time(recorder.seconds)) / \(Self.time(Double(recorder.sample.maximum)))").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            }
            Button("Discard") { model.discardMicrophoneRecording() }
                .disabled(recorder.recording || model.microphoneRecording == nil || model.busy)
        }
        Text(recorder.notice.isEmpty
             ? "The recording stays in memory until you discard it or quit. It is uploaded only when you choose an action."
             : recorder.notice)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private static func time(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

/// The voice clip tags. ElevenLabs performs them; other services would speak them as words.
private struct TagButtons: View {
    var add: (String) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text("Add").font(.caption).foregroundStyle(.secondary)
            ForEach(["[whispers]", "[laughs]", "[sighs]", "[excited]", "[pause]"], id: \.self) { tag in
                Button(tag) { add(tag) }.controlSize(.small)
                    .accessibilityLabel("Add the \(tag.dropFirst().dropLast()) tag")
            }
        }
    }
}

/// The voice clip text with tag buttons that insert at the cursor or replace the selection.
@available(macOS 15.0, *)
private struct TaggedTextEditor: View {
    @ObservedObject var model: SpeechToolsModel
    var tagsAvailable: Bool
    @StateObject private var editor = EditorSelection()
    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.voiceText, selection: $editor.selection).font(.body).accessibilityLabel("Voice clip text")
                .disabled(model.busy).padding(4).scrollContentBackground(.hidden)
            if model.voiceText.isEmpty {
                Text("Write the words you want to hear…").foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 12)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }.frame(height: 96)
        if tagsAvailable {
            TagButtons { tag in
                guard case .selection(let range) = editor.selection?.indices, range.upperBound <= model.voiceText.endIndex else {
                    model.appendTag(tag); return
                }
                let cursor = model.insertTag(tag, replacing: range)
                editor.selection = TextSelection(insertionPoint: cursor)
            }.disabled(model.busy)
        }
    }
}

@available(macOS 15.0, *)
private final class EditorSelection: ObservableObject {
    @Published var selection: TextSelection?
}
