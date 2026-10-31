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
        .onAppear { model.refreshKeyPresence(); model.observePreviewDevices() }
        .onChange(of: model.page) { _ in model.cancel(); model.clearNotice() }
        .onDisappear { if showsSidebar { model.cancel() }; model.endPreviewObservation() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshKeyPresence(); model.refreshPreviewOutputs() }
    }

    private var recordingPage: some View {
        VStack(spacing: 0) {
            heading("Audio file", "Turn a recording into text, then translate it if you need to.")
            Form {
                Section {
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
                        Text("\(model.recordingService.title) receives the file when you choose Transcribe.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button("Transcribe") { model.transcribe() }.buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.fileURL == nil || model.missingKeys.contains(model.recordingService.account))
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
            heading("Voice clip", "Give a short piece of text a voice, ready to save and share.")
            Form {
                Section {
                    Picker("Voice service", selection: $model.voiceProvider) {
                        ForEach(VoiceProvider.allCases) { Text($0.displayName).tag($0) }
                    }.disabled(model.busy)
                    Picker("Language", selection: $model.voiceLanguage) {
                        ForEach(model.voiceLanguages) { Text($0.name).tag($0.code) }
                    }.disabled(model.busy)
                    HStack(spacing: 12) {
                        Picker("Voice", selection: $model.voiceID) {
                            Text(model.voiceProvider == .fish ? "Default voice" : "Choose a voice").tag("")
                            ForEach(model.readyVoices) { Text($0.name).tag($0.id) }
                        }
                        Button(model.voicesLoaded ? "Refresh" : "Load voices") { model.refreshVoices() }
                            .accessibilityLabel("Load voices from \(model.voiceProvider.displayName)")
                            .disabled(model.missingKeys.contains(model.voiceAccount))
                    }.disabled(model.busy)
                    Text(voiceHelp)
                        .font(.caption).foregroundStyle(.secondary)
                    missingKey(model.voiceAccount)
                }
                Section {
                    textEditor($model.voiceText, label: "Voice clip text", placeholder: "Write the words you want to hear…", height: 150)
                    HStack {
                        Text("\(model.voiceText.count.formatted()) / 2,000 characters")
                            .foregroundStyle(model.voiceText.count > SpeechToolsLimits.voiceCharacters ? Color.orange : Color.secondary)
                            .font(.caption).monospacedDigit()
                        Spacer()
                        Button("Generate clip") { model.generateClip() }.buttonStyle(.borderedProminent)
                            .disabled(!model.canGenerate || model.missingKeys.contains(model.voiceAccount))
                        if model.clip != nil { Button("Save WAV…") { model.saveClip() }.disabled(model.busy) }
                    }
                    if model.voiceText.utf8.count > 8_000 && model.voiceText.count <= SpeechToolsLimits.voiceCharacters {
                        Text("This text is too long for one clip. Shorten it, then generate again.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("\(model.voiceProvider.displayName) receives this text for speech generation.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Words to speak") }
                if model.clip != nil {
                    Section {
                        Picker("Listen through", selection: $model.previewOutputUID) {
                            Text("Choose headphones or speakers").tag("")
                            if !model.previewOutputUID.isEmpty && !model.previewOutputs.contains(where: { $0.uid == model.previewOutputUID }) {
                                Text("Selected device — disconnected").tag(model.previewOutputUID)
                            }
                            ForEach(model.previewOutputs) { Text($0.name).tag($0.uid) }
                        }
                        HStack {
                            Button(model.playingClip ? "Stop" : "Play") {
                                if model.playingClip { model.stopClip() } else { model.playClip() }
                            }.disabled(!model.playingClip && !model.canPlayClip)
                            Text("Playback stays on the device you choose.").font(.caption).foregroundStyle(.secondary)
                        }
                    } header: { Text("Preview") }
                }
                if let clip = model.clip {
                    Text("\(clipDuration(clip)) ready to save.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }

    private var voiceHelp: String {
        if model.voiceProvider == .elevenLabs && model.voiceID.isEmpty {
            if model.voicesLoaded && model.readyVoices.isEmpty {
                return "No ready voices were found. Check voice access in your ElevenLabs account, then refresh."
            }
            return model.voicesLoaded ? "Choose a voice to generate your clip." : "Load voices, then choose one to generate a clip."
        }
        return "Use a ready account voice, including one you have created in Settings."
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
    private func heading(_ title: String, _ description: String) -> some View {
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
    private func serviceName(_ service: ProviderService) -> String {
        switch service { case .openAI: return "OpenAI"; case .elevenLabs: return "ElevenLabs"; case .fish: return "Fish Audio" }
    }
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
