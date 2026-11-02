import AppKit
import SwiftUI
import BridgeCore

enum MeetingPreferences {
    static let consentShown = "babelfin.recorder.consentShown.v1"
    static let kind = "babelfin.recorder.kind"
    static let consent = "Tell everyone in the meeting that you are recording. You are responsible for their consent. The recording stays on this Mac until you transcribe or discard it."
}

/// `@State` needs the SwiftUI macro plugin, which the command-line toolchain lacks.
@MainActor private final class RecorderCardState: ObservableObject { @Published var askingConsent = false }

/// Home › Record a meeting: the recorder, then what to do with the recording.
struct RecorderCard: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var meeting = MeetingModel.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @AppStorage(MeetingPreferences.kind) private var kind: MeetingRecordingKind = .online
    @AppStorage(MeetingPreferences.consentShown) private var consentShown = false
    @StateObject private var state = RecorderCardState()
    var openTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ColumnsOrRows(minimumColumnWidth: 340, spacing: 16) {
                session
                ownNotes
            }
            if recorder.state == .stopped { afterRecording }
            messages
        }
        .alert("Before you record", isPresented: $state.askingConsent) {
            Button("Record") { consentShown = true; start() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(MeetingPreferences.consent) }
    }

    // MARK: Session

    private var session: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PanelLabel("Session")
                Spacer()
                Text(stateTitle).font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background((recorder.state == .recording ? Color.red : Color.secondary).opacity(0.16), in: Capsule())
                    .foregroundStyle(recorder.state == .recording ? Color.red : Color.secondary)
            }
            Text(Self.clock(recorder.seconds))
                .font(.system(size: 44, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(recorder.state == .recording ? Color.red : Color.primary)
                .accessibilityLabel("\(Int(recorder.seconds)) seconds recorded")
            Picker("Where", selection: $kind) {
                Text("Online meeting").tag(MeetingRecordingKind.online)
                Text("In the room").tag(MeetingRecordingKind.room)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .disabled(recorder.state != .idle)
            VStack(spacing: 8) {
                sourceRow("mic.fill", "Microphone", microphone?.name ?? "Choose a microphone for Speak in Settings › Audio devices",
                          level: recorder.microphoneLevel)
                if (recorder.state == .idle ? kind : recorder.kind) == .online {
                    sourceRow("person.2.wave.2.fill", "Meeting audio", meetingAudio?.name ?? "Choose the meeting loopback for Listen in Settings › Audio devices",
                              level: recorder.meetingLevel)
                }
            }
            HStack(spacing: 10) {
                switch recorder.state {
                case .idle:
                    Button { record() } label: { Label("Record", systemImage: "record.circle.fill").frame(minWidth: 120) }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                        .disabled(microphone == nil || (kind == .online && meetingAudio == nil))
                case .recording:
                    Button { recorder.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(minWidth: 120) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                case .stopped:
                    Button { meeting.discard() } label: { Label("New Recording", systemImage: "plus.circle").frame(minWidth: 120) }
                        .controlSize(.large).help("Discards this recording and its results")
                }
                Spacer()
            }
            Text(consentShown ? "Tell everyone that you are recording." : "The first time, Babelfin explains consent before it records.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel(padding: 20, highlight: recorder.state == .recording ? .red : nil)
    }
    private var stateTitle: String {
        switch recorder.state {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .stopped: return "Stopped"
        }
    }
    private func sourceRow(_ symbol: String, _ title: String, _ device: String, level: Float) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(device).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            LevelMeter(level: level).accessibilityLabel("\(title) level")
        }
        .padding(10)
        .background(Surface.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Your notes

    /// Granola-style: what the user writes during the meeting guides the summary.
    private var ownNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelLabel("Your notes")
            TextField("Meeting title", text: $meeting.meetingTitle).textFieldStyle(.roundedBorder).controlSize(.large)
                .accessibilityLabel("Meeting title")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $meeting.userNotes).font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: 180, maxHeight: .infinity).accessibilityLabel("Your notes")
                if meeting.userNotes.isEmpty {
                    Text("Write what matters to you during the meeting. The notes cover it first and fill in the rest from the transcript.")
                        .foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(Surface.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel(padding: 20)
    }

    // MARK: After recording

    private var afterRecording: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PanelLabel("Transcribe \(Self.clock(recorder.seconds))")
                Spacer()
                if meeting.busy {
                    ProgressView().controlSize(.small)
                    Text(meeting.activity).font(.callout).foregroundStyle(.secondary)
                    Button("Cancel") { meeting.cancel() }
                }
            }
            HStack(spacing: 12) {
                choice("person.wave.2", "ElevenLabs Scribe", "Speaker names, and finds which speaker is you. About $0.22 per hour of audio.") {
                    meeting.transcribeWithScribe()
                }
                choice("lock.laptopcomputer", "On this Mac", "Nothing is sent and no key is needed. No speaker names; needs macOS 26.") {
                    meeting.transcribeOnThisMac(microphoneLanguage: microphoneLanguage, meetingLanguage: meetingLanguage)
                }
            }
            .disabled(meeting.busy)
            HStack(spacing: 10) {
                if meeting.document != nil {
                    Button("Open Notes", action: openTranscript).buttonStyle(.borderedProminent).controlSize(.large)
                }
                Menu("Save Audio") {
                    Button("M4A…") { meeting.saveAudio(wav: false) }
                    Button("WAV…") { meeting.saveAudio(wav: true) }
                }.fixedSize().controlSize(.large)
                Spacer()
                Button("Discard", role: .destructive) { meeting.discard() }.controlSize(.large)
            }
            .disabled(meeting.busy)
        }
        .panel(padding: 20)
    }
    private func choice(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Surface.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transcribe with \(title)")
    }

    @ViewBuilder private var messages: some View {
        if !recorder.notice.isEmpty { Label(recorder.notice, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
        if !meeting.notice.isEmpty {
            Text(meeting.notice).font(.callout).foregroundStyle(meeting.isError ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let failure = meeting.exportError { Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
    }

    private var microphone: AudioDevice? {
        conversation.outgoing.inputs.first { $0.uid == conversation.outgoing.inputUID && $0.isPhysicalInput }
    }
    private var meetingAudio: AudioDevice? {
        conversation.incoming.inputs.first { $0.uid == conversation.incoming.inputUID && !$0.isPhysicalInput }
    }

    /// Your language: Speak's input, or the language Listen translates into.
    private var microphoneLanguage: String {
        let speak = conversation.outgoing
        return speak.sourceLanguage.isEmpty ? conversation.incoming.targetLanguage : speak.sourceLanguage
    }
    private var meetingLanguage: String {
        let listen = conversation.incoming
        return listen.sourceLanguage.isEmpty ? conversation.outgoing.targetLanguage : listen.sourceLanguage
    }

    private func record() { if consentShown { start() } else { state.askingConsent = true } }
    private func start() {
        guard let microphone else { return }
        Task { await recorder.start(kind: kind, microphone: microphone, meeting: kind == .online ? meetingAudio : nil) }
    }
    /// h:mm:ss, so the timer keeps its width as a recording passes one hour.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }
}

/// `@State` needs the SwiftUI macro plugin, which the command-line toolchain lacks.
@MainActor private final class MeetingDocumentState: ObservableObject {
    enum Page: String, CaseIterable { case transcript = "Transcript", clean = "Clean", notes = "Notes", ask = "Ask" }
    @Published var page = Page.transcript
    @Published var question = ""
    @Published var renaming: String?
    @Published var newName = ""
}

/// Transcript › Recording: the improved transcript beside the live one.
struct MeetingDocumentView: View {
    @ObservedObject private var meeting = MeetingModel.shared
    @StateObject private var state = MeetingDocumentState()
    @AppStorage("babelfin.recorder.notesLanguage") private var notesLanguage = "en"
    @AppStorage("babelfin.recorder.template") private var template: NoteTemplate = .general

    var body: some View {
        if let document = meeting.document {
          Page(document.title, subtitle: "\(document.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(document.service.rawValue) · \(document.segments.count) passages",
               scrolls: false, actions: { exportMenu(document) }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    Picker("Page", selection: $state.page) {
                        ForEach(MeetingDocumentState.Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.large)
                    speakers(document)
                }
                Group {
                    switch state.page {
                    case .transcript: transcript(document)
                    case .clean: clean(document)
                    case .notes: notes(document)
                    case .ask: ask(document)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panel(padding: 18)
                if meeting.busy {
                    HStack { ProgressView().controlSize(.small); Text(meeting.activity).foregroundStyle(.secondary); Spacer(); Button("Cancel") { meeting.cancel() } }
                } else if !meeting.notice.isEmpty {
                    Text(meeting.notice).font(.callout).foregroundStyle(meeting.isError ? Color.orange : Color.secondary)
                }
            }
            .padding(20)
          }
            .alert("Name this speaker", isPresented: Binding(get: { state.renaming != nil }, set: { if !$0 { state.renaming = nil } })) {
                TextField("Name", text: $state.newName)
                Button("Rename") { if let label = state.renaming { meeting.rename(label, to: state.newName) }; state.renaming = nil }
                Button("Cancel", role: .cancel) { state.renaming = nil }
            } message: { Text("The name replaces the label in this recording's transcript, clean version and notes.") }
        }
    }

    private func exportMenu(_ document: MeetingDocument) -> some View {
            Menu("Export") {
                Button("Copy Transcript") { meeting.copy(document.verbatimText) }
                Button("Transcript (TXT)…") { meeting.save(.verbatim) }
                if document.clean != nil { Button("Clean Version (TXT)…") { meeting.save(.clean) } }
                if document.notes != nil { Button("Notes (Markdown)…") { meeting.save(.notes) } }
                if document.translatedNotes != nil { Button("Translated Notes (Markdown)…") { meeting.save(.translatedNotes) } }
                if document.email != nil { Button("Follow-up Email (TXT)…") { meeting.save(.email) } }
                Divider()
                ForEach(SubtitleFile.Format.allCases, id: \.self) { format in
                    Button("Subtitles (\(format.rawValue.uppercased()))…") { meeting.saveSubtitles(format) }
                }
            }.fixedSize().disabled(meeting.busy)
    }

    private func speakers(_ document: MeetingDocument) -> some View {
        HStack(spacing: 8) {
            Text("Speakers").foregroundStyle(.secondary)
            ForEach(document.speakers, id: \.self) { label in
                Button { state.newName = document.name(label); state.renaming = label } label: {
                    Label(document.name(label), systemImage: "person.crop.circle")
                }
                .help("Rename this speaker").accessibilityLabel("Rename \(document.name(label))")
            }
            Spacer()
        }
    }

    private func transcript(_ document: MeetingDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(document.segments) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(time(segment.startSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing)
                        Text(document.name(segment.speaker)).font(.callout.weight(.semibold)).frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(segment.sourceText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let translated = segment.translatedText {
                                Text(translated).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }.padding(.vertical, 4)
        }
    }
    private func clean(_ document: MeetingDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let clean = document.clean {
                ScrollView { Text(clean).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Text("The clean version removes filler words and false starts and joins broken sentences. Each paragraph keeps its speaker and language.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(document.clean == nil ? "Clean Up with OpenAI" : "Clean Up Again") { meeting.cleanUp() }.disabled(meeting.busy)
        }
    }
    private func notes(_ document: MeetingDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Meeting", selection: $template) {
                    ForEach(NoteTemplate.allCases, id: \.self) { Text($0.title).tag($0) }
                }.fixedSize()
                Picker("In", selection: $notesLanguage) {
                    ForEach(TranslationLanguage.composedOutputs) { Text($0.name).tag($0.code) }
                }.fixedSize()
                Button(document.notes == nil ? "Make Notes" : "Make Notes Again") { meeting.makeNotes(language: notesLanguage, template: template) }
                    .buttonStyle(.borderedProminent)
                Spacer()
                if document.notes != nil {
                    Menu("More") {
                        Button("Copy Notes") { meeting.copy(document.notes ?? "") }
                        Button("Draft Follow-up Email") { meeting.draftEmail(language: notesLanguage) }
                        Menu("Translate Notes") {
                            ForEach(TranslationLanguage.composedOutputs) { language in Button(language.name) { meeting.translateNotes(to: language.code) } }
                        }
                    }.fixedSize()
                }
            }.disabled(meeting.busy)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let notes = document.notes {
                        NotesView(markdown: notes)
                    } else {
                        Text("Notes have a summary, key points by topic, decisions, action items with owner and due date, key facts, open questions and next steps, each with the time it comes from. Your own notes, written while recording, come first.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let email = document.email {
                        Divider()
                        HStack { Text("Follow-up email").font(.headline); Spacer(); Button("Copy") { meeting.copy(email) }.controlSize(.small) }
                        Text(email).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let translated = document.translatedNotes {
                        Divider()
                        Text("Translated notes").font(.headline)
                        NotesView(markdown: translated)
                    }
                }.frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func ask(_ document: MeetingDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Ask about this meeting", text: $state.question).textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("Ask", action: submit).disabled(meeting.busy || state.question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(document.answers.reversed()) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.question).font(.headline)
                            Text(item.answer).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("OpenAI receives the question and the transcript.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func submit() { meeting.ask(state.question, language: notesLanguage); state.question = "" }
    private func time(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let total = Int(seconds)
        return total >= 3_600 ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Markdown notes with headings, a checklist, bullets and bold or italic text.
struct NotesView: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(NotesBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text): Text(inline(text)).font(.title3.weight(.semibold)).padding(.top, 8)
                case .subheading(let text): Text(inline(text)).font(.headline).padding(.top, 4)
                case .task(let text, let done): row(done ? "checkmark.square" : "square", text, label: done ? "Done" : "To do")
                case .bullet(let text): row("circle.fill", text, small: true)
                case .text(let text): Text(inline(text)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }
    /// `label` names the symbol for VoiceOver when it carries meaning, as a checkbox does.
    private func row(_ symbol: String, _ text: String, small: Bool = false, label: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(small ? .system(size: 5) : .callout).foregroundStyle(.secondary)
                .frame(width: 14).alignmentGuide(.firstTextBaseline) { small ? $0[VerticalAlignment.center] + 4 : $0[.firstTextBaseline] }
                .accessibilityHidden(true)
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(text, label: label))
    }
    private func spoken(_ text: String, label: String?) -> String {
        let plain = String(inline(text).characters)
        guard let label else { return plain }
        return label + ": " + plain
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
