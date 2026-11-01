import AppKit
import Combine
import SwiftUI
import BridgeCore

@MainActor final class ConversationModel: ObservableObject {
    let outgoing: AppModel
    let incoming: AppModel
    @Published var direction: ConversationDirection = .outgoing
    @Published private(set) var transcript = MeetingTranscript()
    @Published var exportNotice = ""
    private var subscriptions = Set<AnyCancellable>()
    var selected: AppModel { direction == .outgoing ? outgoing : incoming }
    var active: Bool { outgoing.active || incoming.active }
    var locked: Bool { outgoing.configurationLocked || incoming.configurationLocked }
    convenience init() {
        let outgoing = AppModel()
        let incoming = AppModel(providerFactory: { OpenAITranslationProvider() },
            preferences: UserDefaultsAppPreferences(key: "babelfin.incoming.preferences.v1"),
            serviceKeyPresence: { KeychainStore.containsSavedKey(for: $0) },
            providerResolver: { ProviderFactory.make($0) }, loadProviderCredentials: { try KeychainStore.credentials(for: $0) },
            selectsMeetingSource: true, playsLoopbackOriginal: AppModel.microphoneAuthorized)
        incoming.destination = .listen
        self.init(outgoing: outgoing, incoming: incoming)
    }
    init(outgoing: AppModel, incoming: AppModel) {
        self.outgoing = outgoing; self.incoming = incoming
        NotificationCenter.default.publisher(for: .babelfinCredentialMetadataChanged)
            .sink { [weak self] _ in
                self?.outgoing.refreshKeyStatus(); self?.incoming.refreshKeyStatus()
            }.store(in: &subscriptions)
        for model in [outgoing, incoming] {
            model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        outgoing.onTranscriptEvent = { [weak self] session, event in self?.record(event, session: session, direction: .outgoing) }
        incoming.onTranscriptEvent = { [weak self] session, event in self?.record(event, session: session, direction: .incoming) }
        outgoing.onTranscriptSession = { [weak self] session, began, reason in self?.recordSession(session, direction: .outgoing, began: began, reason: reason) }
        incoming.onTranscriptSession = { [weak self] session, began, reason in self?.recordSession(session, direction: .incoming, began: began, reason: reason) }
        outgoing.validateAdditionalRoute = { [weak self] input, output in
            guard let self else { return }
            try DuplexRouting.validate(outgoingInput: input.endpoint, outgoingOutput: output.endpoint,
                incomingInput: self.incoming.active ? self.incoming.inputs.first { $0.uid == self.incoming.inputUID }?.endpoint : nil,
                incomingOutput: self.incoming.active ? self.incoming.outputs.first { $0.uid == self.incoming.outputUID }?.endpoint : nil)
        }
        incoming.validateAdditionalRoute = { [weak self] input, output in
            guard let self else { return }
            try DuplexRouting.validate(outgoingInput: self.outgoing.active ? self.outgoing.inputs.first { $0.uid == self.outgoing.inputUID }?.endpoint : nil,
                outgoingOutput: self.outgoing.active ? self.outgoing.outputs.first { $0.uid == self.outgoing.outputUID }?.endpoint : nil,
                incomingInput: input.endpoint, incomingOutput: output.endpoint)
        }
    }
    private func recordSession(_ session: UUID, direction: ConversationDirection, began: Bool, reason: String?) {
        if began { transcript.begin(sessionID: session, direction: direction) }
        else { transcript.end(sessionID: session, direction: direction, reason: reason) }
    }
    private func record(_ event: TranslationEvent, session: UUID, direction: ConversationDirection) {
        switch event { case .sourceTranscript, .targetTranscript, .segment: transcript.receive(event, sessionID: session, direction: direction); default: break }
    }
    func abort() { outgoing.abort(); incoming.abort() }
    #if BABELFIN_SCREENSHOTS
    func demoTranscriptBegin(_ id: UUID, _ direction: ConversationDirection) { transcript.begin(sessionID: id, direction: direction) }
    func demoTranscriptReceive(_ event: TranslationEvent, _ id: UUID, _ direction: ConversationDirection) { transcript.receive(event, sessionID: id, direction: direction) }
    #endif
    func stopAll() async {
        async let first: Void = outgoing.stop()
        async let second: Void = incoming.stop()
        _ = await (first, second)
    }
    func clearTranscript() { transcript.clear(); exportNotice = "" }
    /// Asks for a name for the entry's speaker label. The name stays on this Mac.
    func renameSpeaker(of entry: MeetingTranscript.Entry) {
        guard let current = transcript.speakerLabel(entry) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(current)"
        alert.informativeText = "The name applies to this speaker in this session. Babelfin does not send it to a service."
        let field = NSTextField(string: current.hasPrefix("Speaker ") ? "" : current)
        field.placeholderString = "Name"; field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        transcript.renameSpeaker(of: entry, to: field.stringValue)
    }
    func copyTranscript(selection: TranscriptExport.Selection = .both, prompt: TranscriptExport.Prompt = .none) {
        let text = TranscriptExport.wrapping(transcript.plainText(selection: selection), prompt: prompt); guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        exportNotice = NSPasteboard.general.setString(text, forType: .string) ? "Copied." : "Could not copy."
    }
    func exportTranscript(json: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Babelfin transcript." + (json ? "json" : "txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = json ? try transcript.jsonData() : Data(transcript.plainText().utf8)
            try data.write(to: url, options: .atomic); exportNotice = "Transcript saved."
        } catch { exportNotice = "Could not save the transcript. Choose a writable location." }
    }
}
