import AppKit
import Combine
import UniformTypeIdentifiers
import BridgeCore

/// A transcribed meeting recording with its clean version, notes and answers. It stays in memory.
struct MeetingDocument: Equatable {
    enum Service: String { case scribe = "ElevenLabs Scribe", onThisMac = "On this Mac", live = "Live translation" }
    var id = UUID()
    /// The meeting's name in the notes heading and the export folder.
    var title = "Meeting"
    let createdAt: Date
    let kind: MeetingRecordingKind
    let service: Service
    /// Verbatim segments with raw speaker labels.
    var segments: [RecordingSegment]
    /// Display names per raw label: "You", "Speaker 1" or a name the user gave.
    var names: [String: String]
    var clean: String?
    var notes: String?
    var translatedNotes: String?
    var email: String?
    var answers: [Answer] = []
    struct Answer: Equatable, Identifiable { let id = UUID(); let question: String; let answer: String }

    var speakers: [String] {
        var seen = Set<String>()
        return segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }
    func name(_ label: String?) -> String { label.map { names[$0] ?? $0 } ?? "Speaker" }
    /// Segments with display names in place of raw labels, for exports.
    var namedSegments: [RecordingSegment] {
        segments.map { RecordingSegment(id: $0.id, sourceText: $0.sourceText, translatedText: $0.translatedText,
                                        speaker: $0.speaker.map { name($0) }, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
    }
    var verbatimText: String { MeetingPrompts.transcript(segments, names: names) }
    /// The document without the answers, which do not go to the export folder.
    var exported: MeetingDocument { var copy = self; copy.answers = []; return copy }
    var timedText: String { MeetingPrompts.transcript(segments, names: names, timed: true) }
}

/// The meeting recorder and what follows it: transcription, speaker names, clean-up, notes,
/// translated notes, questions and exports. Every upload is an explicit action.
@MainActor final class MeetingModel: ObservableObject {
    static let shared = MeetingModel()
    @Published private(set) var document: MeetingDocument? {
        didSet {
            guard let document, document.exported != oldValue?.exported else { return }
            exportError = AutoExport.export(document, userNotes: userNotes)
        }
    }
    /// The last auto-export failure, apart from the notice so a later notice does not hide it.
    @Published private(set) var exportError: String?
    @Published private(set) var busy = false
    @Published private(set) var activity = ""
    @Published var notice = ""
    @Published var isError = false
    /// The user's own notes, typed while recording or afterwards. The summary covers them first.
    @Published var userNotes = ""
    /// The meeting's name, typed in the recorder card; empty means "Meeting".
    @Published var meetingTitle = ""
    let recorder = MeetingRecorder.shared
    /// The live conversation, for speaker names given during translation.
    weak var conversation: ConversationModel?
    private let tools = SpeechToolsService(operationTimeout: 3_000)
    private let text = MeetingTextStage()
    private let translator = OpenAITextTranslationStage()
    private var task: Task<Void, Never>?
    /// Stops encoding and reading for the current operation; Cancel and Discard set it.
    private var operation = ProviderCancellation()

    // MARK: Running notes

    @Published private(set) var runningNotesOn = false
    @Published private(set) var runningNotes: String?
    @Published private(set) var runningNotesUpdated: Date?
    @Published private(set) var runningNotesError: String?
    private let runningText = MeetingTextStage()
    private var runningTask: Task<Void, Never>?
    static let runningInterval: UInt64 = 120

    /// Refreshes notes of the meeting so far every two minutes while on, when there is new text.
    /// OpenAI receives the live transcript at each refresh.
    func startRunningNotes(language: String, transcript: @escaping @MainActor () -> String) {
        guard !runningNotesOn else { return }
        runningNotesOn = true; runningNotesError = nil
        runningTask = Task { [weak self] in
            var last = "", failures = 0
            let storage = KeychainStore.storageMode
            let keys: ProviderCredentials
            do { keys = try await Task.detached { try ProviderCredentials(openAI: KeychainStore.load(for: .openAI, storage: storage)) }.value }
            catch { self?.runningNotesError = "Add your OpenAI API key in Settings › Accounts for running notes."; self?.stopRunningNotes(); return }
            while !Task.isCancelled {
                guard let self else { return }
                let text = String(transcript().suffix(200_000))
                if text.count >= 200, text.count - last.count >= 300 || (text != last && text.count < last.count) {
                    do {
                        let notes = try await self.runningText.complete(instructions: MeetingPrompts.runningNotes(language: language, glossary: GlossaryStore.terms),
                                                                         input: text, maximumOutput: 2_000, credentials: keys)
                        guard self.runningNotesOn else { return }
                        self.runningNotes = notes; self.runningNotesUpdated = Date(); self.runningNotesError = nil; last = text; failures = 0
                    } catch is CancellationError { return }
                    catch {
                        // A rejected key does not recover by waiting.
                        if case ProviderNetworkError.http(let status) = error, status == 401 || status == 403 { failures = 3 } else { failures += 1 }
                        guard failures < 3 else {
                            self.runningNotesError = "Running notes stopped after three failed updates. Check the OpenAI key in Settings › Accounts, then turn them on again."
                            self.stopRunningNotes(); return
                        }
                        self.runningNotesError = "The notes could not be updated. They try again in two minutes."
                    }
                }
                try? await Task.sleep(nanoseconds: Self.runningInterval * 1_000_000_000)
            }
        }
    }
    func stopRunningNotes() {
        runningTask?.cancel(); runningTask = nil; runningText.cancel()
        runningNotesOn = false
    }
    private var cancellation: AnyCancellable?

    /// Views of this model change with the recorder's state, not with its level meters, which
    /// publish about 20 times a second; views that show levels observe the recorder itself.
    init() { cancellation = recorder.$state.removeDuplicates().sink { [weak self] _ in self?.objectWillChange.send() } }

    // MARK: Transcribe

    /// Sends the mixed recording to Scribe with speaker labels. The microphone track finds "You".
    func transcribeWithScribe() {
        guard recorder.hasRecording else { return }
        let tracks = recorder.tracks, kind = recorder.kind, started = recorder.startedAt ?? Date()
        perform("Transcribing with ElevenLabs Scribe…", services: [.elevenLabs]) { model, keys in
            let upload = MeetingRecorder.folder.appendingPathComponent("upload-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: upload) }
            let token = model.operation
            try await Task.detached { try MeetingAudioExport.m4a(tracks, to: upload, check: token.check) }.value
            let transcript = try await model.tools.transcribe(source: .meeting(upload), sourceLanguage: nil, diarize: true, credentials: keys)
            var local: String?
            if kind == .online, let microphone = tracks.first {
                let activity = try await Task.detached { try MeetingAudioExport.activity(microphone) }.value
                local = LocalSpeaker.label(segments: transcript.segments, microphoneActivity: activity)
            }
            guard model.recorder.hasRecording, !Task.isCancelled else { throw CancellationError() }
            model.adopt(MeetingDocument(createdAt: started, kind: kind, service: .scribe, segments: transcript.segments, names: [:]), local: local)
        }
    }

    /// Transcribes on this Mac: each track in its language. No speaker labels beyond You and Others.
    func transcribeOnThisMac(microphoneLanguage: String, meetingLanguage: String) {
        guard recorder.hasRecording else { return }
        let tracks = recorder.tracks, kind = recorder.kind, started = recorder.startedAt ?? Date()
        perform("Transcribing on this Mac…", services: []) { model, _ in
            var segments: [RecordingSegment] = []
            let token = model.operation
            for (index, track) in tracks.enumerated() {
                let speaker = kind == .online ? (index == 0 ? "you" : "others") : nil
                segments += try await AppleFileTranscriber.transcribe(track: track, language: index == 0 ? microphoneLanguage : meetingLanguage,
                                                                     speaker: speaker, check: token.check)
            }
            segments.sort { ($0.startSeconds ?? 0) < ($1.startSeconds ?? 0) }
            guard model.recorder.hasRecording, !Task.isCancelled else { throw CancellationError() }
            model.adopt(MeetingDocument(createdAt: started, kind: kind, service: .onThisMac, segments: segments,
                                        names: kind == .online ? ["you": "You", "others": "Others"] : [:]), local: nil)
        }
    }

    private func adopt(_ document: MeetingDocument, local: String?) {
        var document = document
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { document.title = String(title.prefix(80)) }
        document.names.merge(liveNames(for: document), uniquingKeysWith: { current, _ in current })
        var number = 0
        for speaker in document.speakers where document.names[speaker] == nil {
            if speaker == local { document.names[speaker] = "You" } else { number += 1; document.names[speaker] = "Speaker \(number)" }
        }
        self.document = document
        notice = document.segments.isEmpty ? "No speech was found in the recording." : "The transcript is ready. Check the speaker names, then clean up or make notes."
    }

    /// Names the user gave live speaker labels, mapped to recording speakers by time. Live lines arrive
    /// about two seconds after the speech, so their time moves back by that much.
    private func liveNames(for document: MeetingDocument) -> [String: String] {
        guard let transcript = conversation?.transcript, !transcript.speakerNames.isEmpty else { return [:] }
        let named = transcript.entries.compactMap { entry -> (seconds: Double, name: String)? in
            guard entry.role == .source, let speaker = entry.segment.speaker, let name = transcript.speakerLabel(entry),
                  name != "Speaker \(speaker)" else { return nil }
            return (entry.firstReceivedAt.timeIntervalSince(document.createdAt) - 2, name)
        }
        return SpeakerNameTransfer.names(segments: document.segments, named: named)
    }

    func rename(_ label: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard document != nil, !clean.isEmpty, clean.count <= 60 else { return }
        guard let old = document?.names[label], old != clean else { return }
        // The clean version, notes and email keep their content; the old name becomes the new one.
        func renamed(_ text: String?) -> String? { text?.replacingOccurrences(of: old, with: clean) }
        document?.names[label] = clean
        document?.clean = renamed(document?.clean); document?.notes = renamed(document?.notes)
        document?.translatedNotes = renamed(document?.translatedNotes); document?.email = renamed(document?.email)
    }

    // MARK: Clean-up, notes, questions

    func cleanUp() {
        guard let document else { return }
        let chunks = Self.chunks(document.verbatimText.components(separatedBy: "\n\n"), maximumCharacters: 12_000)
        let glossary = GlossaryStore.terms
        perform("Cleaning up the transcript…", services: [.openAI]) { model, keys in
            var cleaned: [String] = []
            for chunk in chunks {
                cleaned.append(try await model.text.complete(instructions: MeetingPrompts.cleanUp(glossary: glossary), input: chunk,
                                                              maximumOutput: 8_000, credentials: keys))
                model.activity = "Cleaning up the transcript… \(cleaned.count) of \(chunks.count)"
            }
            model.document?.clean = cleaned.joined(separator: "\n\n")
            model.notice = "The clean version is ready."
        }
    }

    /// Granola-style notes: from the timed transcript, with the user's own notes first.
    func makeNotes(language: String, template: NoteTemplate) {
        guard let document else { return }
        let glossary = GlossaryStore.terms, own = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = document.timedText.components(separatedBy: "\n")
        perform("Making notes…", services: [.openAI]) { model, keys in
            let instructions = MeetingPrompts.notes(language: language, glossary: glossary, template: template, userNotes: own)
            let prefix = own.isEmpty ? "" : "The user's own notes:\n\(own)\n\nTranscript:\n"
            let parts = Self.chunks(lines, maximumCharacters: 200_000, separator: "\n")
            var notes: [String] = []
            for part in parts {
                notes.append(try await model.text.complete(instructions: instructions, input: prefix + part, maximumOutput: 6_000, credentials: keys))
            }
            let result = notes.count == 1 ? notes[0] : try await model.text.complete(
                instructions: instructions + " The input is notes from consecutive parts of one meeting; merge them into one set of notes with the same sections.",
                input: notes.joined(separator: "\n\n---\n\n"), maximumOutput: 6_000, credentials: keys)
            model.document?.notes = result; model.document?.translatedNotes = nil; model.document?.email = nil
            model.notice = "The notes are ready. Check them before you share them."
        }
    }

    func draftEmail(language: String) {
        guard let notes = document?.notes else { return }
        perform("Drafting the email…", services: [.openAI]) { model, keys in
            model.document?.email = try await model.text.complete(instructions: MeetingPrompts.followUpEmail(language: language), input: notes,
                                                                  maximumOutput: 1_500, credentials: keys)
        }
    }

    func translateNotes(to language: String) {
        guard let notes = document?.notes else { return }
        perform("Translating the notes…", services: [.openAI]) { model, keys in
            let parts = Self.chunks(notes.components(separatedBy: "\n\n"), maximumCharacters: 6_000)
            var translated: [String] = []
            for part in parts {
                translated.append(try await model.translator.translate(text: part, sourceLanguage: nil, targetLanguage: language, credentials: keys))
            }
            model.document?.translatedNotes = translated.joined(separator: "\n\n")
        }
    }

    func ask(_ question: String, language: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, !question.isEmpty, question.count <= 500 else { return }
        let transcript = document.clean ?? document.verbatimText
        guard transcript.count <= 400_000 else { showError("This transcript is too long to ask about. Make notes instead."); return }
        perform("Answering…", services: [.openAI]) { model, keys in
            let answer = try await model.text.complete(instructions: MeetingPrompts.question(language: language),
                                                       input: "Question: \(question)\n\nTranscript:\n\(transcript)", maximumOutput: 1_500, credentials: keys)
            model.document?.answers.append(.init(question: question, answer: answer))
        }
    }

    /// Paragraphs joined into chunks of at most `maximumCharacters`; a longer paragraph is its own chunk.
    nonisolated static func chunks(_ paragraphs: [String], maximumCharacters: Int, separator: String = "\n\n") -> [String] {
        var result: [String] = [], current = ""
        for paragraph in paragraphs where !paragraph.isEmpty {
            if !current.isEmpty, current.count + separator.count + paragraph.count > maximumCharacters { result.append(current); current = "" }
            current += (current.isEmpty ? "" : separator) + paragraph
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Save and discard

    func saveAudio(wav: Bool) {
        guard recorder.hasRecording else { return }
        let tracks = recorder.tracks
        guard let url = savePanel(name: "Babelfin meeting", extension: wav ? "wav" : "m4a") else { return }
        perform("Saving the audio…", services: []) { model, _ in
            try await Task.detached {
                if wav { try MeetingAudioExport.wav(tracks, to: url) } else { try MeetingAudioExport.m4a(tracks, to: url) }
            }.value
            model.notice = "Saved."
        }
    }
    enum TextExport { case verbatim, clean, notes, translatedNotes, email }
    func save(_ export: TextExport) {
        guard let document else { return }
        let content: String?
        switch export {
        case .verbatim: content = document.verbatimText
        case .clean: content = document.clean
        case .notes: content = document.notes
        case .translatedNotes: content = document.translatedNotes
        case .email: content = document.email
        }
        let markdown = export == .notes || export == .translatedNotes
        guard let content, let url = savePanel(name: "Babelfin meeting", extension: markdown ? "md" : "txt") else { return }
        write(Data(content.utf8), to: url)
    }
    func saveSubtitles(_ format: SubtitleFile.Format) {
        guard let document, let url = savePanel(name: "Babelfin meeting", extension: format.fileExtension) else { return }
        write(Data(SubtitleFile.make(document.namedSegments, text: .original, format: format).utf8), to: url)
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Copied."; isError = false
    }
    /// Deletes the recording and the results.
    func discard() { cancel(); recorder.discard(); document = nil; userNotes = ""; meetingTitle = ""; notice = ""; exportError = nil }

    /// The live transcript as a document, for notes, questions and exports without a recording.
    /// Each original line keeps its translation; times count from the first line.
    func adoptLive() {
        guard let transcript = conversation?.transcript, let first = transcript.entries.first?.firstReceivedAt else { return }
        var segments: [RecordingSegment] = [], names: [String: String] = [:]
        for entry in transcript.entries where !entry.segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if entry.role == .target {
                if let last = segments.indices.last, segments[last].translatedText == nil,
                   segments[last].speaker?.hasPrefix(entry.direction.rawValue) == true {
                    segments[last] = segments[last].translated(entry.segment.text)
                }
                continue
            }
            let label = entry.direction.rawValue + "-" + (entry.segment.speaker ?? "main")
            names[label] = transcript.speakerLabel(entry) ?? (entry.direction == .outgoing ? "You" : "Meeting")
            let start = entry.firstReceivedAt.timeIntervalSince(first)
            if let last = segments.indices.last, segments[last].endSeconds == nil || (segments[last].endSeconds ?? 0) > start {
                let previous = segments[last]
                segments[last] = RecordingSegment(id: previous.id, sourceText: previous.sourceText, translatedText: previous.translatedText,
                                                  speaker: previous.speaker, startSeconds: previous.startSeconds, endSeconds: max(previous.startSeconds ?? 0, start - 0.1))
            }
            segments.append(RecordingSegment(id: entry.id, sourceText: entry.segment.text, speaker: label, startSeconds: start,
                                             endSeconds: start + min(6, max(1.5, Double(entry.segment.text.count) / 15))))
        }
        guard !segments.isEmpty else { return }
        var document = MeetingDocument(createdAt: first, kind: .online, service: .live, segments: segments, names: names)
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        document.title = title.isEmpty ? "Live meeting" : String(title.prefix(80))
        self.document = document
        notice = "The live transcript is ready for notes, questions and exports."
    }
    func cancel() { operation.cancel(); task?.cancel(); tools.cancel(); text.cancel(); translator.cancel() }

    private func savePanel(name: String, extension ext: String) -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name + "." + ext
        panel.allowedContentTypes = UTType(filenameExtension: ext).map { [$0] } ?? []
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func write(_ data: Data, to url: URL) {
        do { try data.write(to: url, options: .atomic); notice = "Saved."; isError = false }
        catch { showError("Could not save the file. Choose a writable location.") }
    }
    private func showError(_ message: String) { notice = message; isError = true }

    private func perform(_ title: String, services: Set<ProviderService>,
                         body: @escaping @MainActor (MeetingModel, ProviderCredentials) async throws -> Void) {
        guard !busy else { return }
        busy = true; activity = title; notice = ""; isError = false
        operation = ProviderCancellation()
        task = Task { [weak self] in
            guard let self else { return }
            let lease = CredentialOperationActivity.shared.begin()
            defer { CredentialOperationActivity.shared.end(lease); self.busy = false; self.activity = "" }
            do {
                let storage = KeychainStore.storageMode
                let keys: ProviderCredentials
                do {
                    keys = try await Task.detached {
                        try ProviderCredentials(openAI: services.contains(.openAI) ? KeychainStore.load(for: .openAI, storage: storage) : nil,
                                                elevenLabs: services.contains(.elevenLabs) ? KeychainStore.load(for: .elevenLabs, storage: storage) : nil)
                    }.value
                } catch {
                    let names = services.map(\.displayName).sorted().joined(separator: " and ")
                    throw BridgeError.unavailable("Add your \(names) API key in Settings › Accounts, or allow Keychain access, then try again.")
                }
                try await body(self, keys)
            } catch {
                if error is CancellationError || Task.isCancelled { self.notice = "Cancelled."; self.isError = false }
                else if let safe = error as? SpeechToolsError { self.showError(safe.localizedDescription) }
                else if let safe = error as? BridgeError { self.showError(safe.localizedDescription) }
                else { self.showError(TranslationFailureReason(error: error).safeSummary) }
            }
        }
    }
}

#if BABELFIN_SCREENSHOTS
extension MeetingModel {
    /// Private documentation build only: a fictional recorded meeting with notes.
    func seedDemo() {
        let lines: [(String, String, Double)] = [
            ("speaker_0", "Good morning, everyone. Shall we start with the pilot site?", 4),
            ("speaker_1", "Ja, vi foreslår Holmvatn. Veien er åpen hele vinteren.", 9),
            ("speaker_0", "Great. Then the go-live is the first of March.", 15),
            ("speaker_2", "I'll send the hosting description by the eighteenth.", 21),
            ("speaker_1", "Og jeg sjekker leveringstiden for kontrollerne innen fredag.", 27),
        ]
        let segments = lines.enumerated().map { index, line in
            RecordingSegment(id: "\(index)", sourceText: line.1, speaker: line.0, startSeconds: line.2, endSeconds: line.2 + 5)
        }
        meetingTitle = "Pilot planning"
        document = MeetingDocument(title: meetingTitle, createdAt: Date(), kind: .online, service: .scribe, segments: segments,
                                   names: ["speaker_0": "You", "speaker_1": "Ingrid", "speaker_2": "Tom"],
                                   notes: """
                                   ## Summary
                                   The team chose Holmvatn as the pilot site and moved the go-live to **1 March**. Hosting stays in the EU, pending a security sign-off.

                                   ## Participants
                                   You, Ingrid, Tom

                                   ## Key points
                                   ### Pilot site
                                   - Holmvatn has stable fibre and an open road all winter. (0:09)
                                   - Controllers may need six to eight weeks of lead time. (0:27)
                                   ### Timeline
                                   - Go-live moves from February to 1 March. (0:15)

                                   ## Decisions
                                   - Holmvatn is the pilot site. (0:09)
                                   - Go-live is 1 March. (0:15)

                                   ## Action items
                                   - [ ] Tom: send the hosting description (due: 18 November). (0:21)
                                   - [ ] Ingrid: check the controller lead time (due: Friday). (0:27)

                                   ## Key facts
                                   - 40 sensor kits, about £9,000 for the extra 20. (0:21)

                                   ## Open questions
                                   - Who covers travel costs for the site visit?
                                   """)
    }
}
#endif
