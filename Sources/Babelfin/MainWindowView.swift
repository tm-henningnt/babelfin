import AppKit
import SwiftUI
import BridgeCore

/// Sidebar destinations of the main window, in three groups.
enum MainSection: String, CaseIterable, Hashable {
    case home, transcript, record, notes, voiceClip, audioFile, meetingNotes
    var title: String {
        switch self {
        case .home: return "Home"
        case .transcript: return "Live transcript"
        case .record: return "Record"
        case .notes: return "Notes"
        case .voiceClip: return "Voice clip"
        case .audioFile: return "Audio file"
        case .meetingNotes: return "Meeting notes"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .transcript: return "text.bubble"
        case .record: return "record.circle"
        case .notes: return "list.bullet.clipboard"
        case .voiceClip: return "speaker.wave.2"
        case .audioFile: return "waveform"
        case .meetingNotes: return "note.text"
        }
    }
    enum Group: String, CaseIterable { case translate = "Translate", meetings = "Meetings", tools = "Tools" }
    var group: Group {
        switch self {
        case .home, .transcript: return .translate
        case .record, .notes: return .meetings
        case .voiceClip, .audioFile, .meetingNotes: return .tools
        }
    }
    var toolPage: SpeechToolsPage? {
        switch self {
        case .voiceClip: return .voice
        case .audioFile: return .recording
        case .meetingNotes: return .notes
        default: return nil
        }
    }
    /// The first tool, for menus that open the tools.
    static let tools = MainSection.voiceClip
}

/// Menus, compact controls and the status item open a section through this one owner.
@MainActor final class MainNavigation: ObservableObject {
    static let shared = MainNavigation()
    @Published var section: MainSection = .home
}

/// Account voice names are cached for display only; the voice ID stays the identity.
enum VoiceNameCache {
    private static let key = "babelfin.voiceNames.v1"
    static func name(for id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id]
    }
    static func remember(_ voices: [ProviderVoice]) {
        var names = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        for voice in voices where !voice.id.isEmpty { names[voice.id] = String(voice.name.prefix(80)) }
        if names.count > 500 { names = Dictionary(uniqueKeysWithValues: names.suffix(500).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(names, forKey: key)
    }
}

extension AppModel {
    /// One word or two for the sidebar and status bar.
    var shortStatus: String {
        if muted { return "Muted" }
        if requiresDeviceResume || requiresConsumerResume { return "Resume" }
        if reconnecting { return "Reconnecting" }
        switch phase {
        case .idle: return !setupRequirements.isEmpty ? "Setup" : (microphoneArmed ? "Ready" : "Off")
        case .starting: return "Connecting"
        case .running: return bypass ? (translationIssue == nil ? "Original" : "Interrupted") : "Translating"
        case .stopping: return "Stopping"
        case .failed: return "Attention"
        }
    }
    var statusColor: Color {
        if muted { return .secondary }
        if phase == .failed || requiresDeviceResume || requiresConsumerResume || translationIssue != nil { return .orange }
        if phase == .running && !bypass { return .green }
        if active { return .accentColor }
        return !setupRequirements.isEmpty ? .orange : .secondary
    }
    var voiceDisplayName: String {
        if route.descriptor.isDirect { return "Follows the speaker" }
        if route.descriptor.speechService == nil { return "System voice" }
        if voiceID.isEmpty { return capabilities.requiresVoiceID ? "Choose a voice" : "Default voice" }
        return VoiceNameCache.name(for: voiceID) ?? "Saved voice"
    }
}

struct MainWindowView: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var navigation = MainNavigation.shared
    @ObservedObject private var subtitles = SubtitleOverlay.shared
    @ObservedObject private var meeting = MeetingModel.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    #if BABELFIN_SCREENSHOTS
    @StateObject private var tools = ScreenshotDemo.tools()
    #else
    @StateObject private var tools = SpeechToolsModel()
    #endif
    var showCompact: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            StatusBar(conversation: conversation)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { subtitles.toggle() } label: { Label(subtitles.visible ? "Hide Subtitles" : "Show Subtitles", systemImage: subtitles.visible ? "captions.bubble.fill" : "captions.bubble") }
                    .help(subtitles.visible ? "Hide the subtitles" : "Show the subtitles over other windows")
                Button(action: showCompact) { Label("Compact", systemImage: "rectangle.compress.vertical") }
                    .help("Show compact controls")
            }
        }
        .onChange(of: navigation.section) { section in if let page = section.toolPage { tools.page = page } }
        .onAppear { if let page = navigation.section.toolPage { tools.page = page } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { navigation.section }, set: { if let value = $0 { navigation.section = value } })) {
                ForEach(MainSection.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(MainSection.allCases.filter { $0.group == group }, id: \.self) { section in
                            HStack(spacing: 8) {
                                Label(section.title, systemImage: section.symbol)
                                Spacer(minLength: 4)
                                badge(for: section)
                            }
                            .padding(.vertical, 2)
                            .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Sections")
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button { AppLinks.openHelp() } label: { Label("Help", systemImage: "questionmark.circle") }
                OpenSettingsButton(title: "Settings")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 210)
    }
    @ViewBuilder private func badge(for section: MainSection) -> some View {
        switch section {
        case .home where conversation.active:
            Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Translating")
        case .transcript where !conversation.transcript.entries.isEmpty:
            Text("\(conversation.transcript.entries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("\(conversation.transcript.entries.count) lines")
        case .record where recorder.state == .recording:
            Text(RecorderCard.clock(recorder.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.red)
                .accessibilityLabel("Recording, \(Int(recorder.seconds)) seconds")
        case .notes where meeting.document != nil:
            Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("Ready")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .home:
            HomeView(conversation: conversation) { navigation.section = .transcript }
        case .transcript:
            Page("Live transcript", subtitle: transcriptSubtitle, scrolls: false, actions: {
                Button("Notes and Export…") { meeting.adoptLive(); navigation.section = .notes }
                    .disabled(conversation.transcript.entries.isEmpty || meeting.busy || (meeting.document.map { $0.service != .live } ?? false))
                    .help(meeting.document.map { $0.service != .live } ?? false
                          ? "A recording is open in Notes. Discard it first to make notes from the live transcript."
                          : "Make notes, ask questions and export subtitles from the live transcript")
            }) { MeetingTranscriptView(conversation: conversation) }
        case .record:
            Page("Record a meeting", subtitle: "Record an online meeting or the room, then transcribe it and make notes.") {
                RecorderCard(conversation: conversation) { navigation.section = .notes }
            }
        case .notes:
            if meeting.document != nil {
                MeetingDocumentView()
            } else {
                Page("Notes", scrolls: false) {
                    EmptyState(symbol: "list.bullet.clipboard", title: "No meeting notes yet",
                               detail: "Record a meeting and transcribe it, or make notes from the live transcript.") {
                        Button("Record a Meeting") { navigation.section = .record }.buttonStyle(.borderedProminent)
                    }
                }
            }
        case .voiceClip, .audioFile, .meetingNotes:
            Page(navigation.section.title, subtitle: toolSubtitle, scrolls: false) {
                SpeechToolsView(model: tools, meetingText: { conversation.transcript.plainText(selection: .source) }, showsSidebar: false)
            }
        }
    }
    private var transcriptSubtitle: String {
        let count = conversation.transcript.entries.count
        return count == 0 ? "Both directions, while they translate" : "\(count) lines from both directions, kept in memory"
    }
    private var toolSubtitle: String {
        switch navigation.section {
        case .voiceClip: return "Give a short text or your own recording a voice."
        case .audioFile: return "Turn a recording into text, translate it and dub it."
        default: return "Turn a transcript or pasted text into structured notes."
        }
    }
}

/// The bottom line of the window: both directions, the transcript and the recorder at a glance.
private struct StatusBar: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var recorder = MeetingRecorder.shared
    var body: some View {
        HStack(spacing: 14) {
            item("Speak", conversation.outgoing)
            item("Listen", conversation.incoming)
            if recorder.state == .recording {
                Label("Recording \(RecorderCard.clock(recorder.seconds))", systemImage: "record.circle.fill").foregroundStyle(.red)
            }
            Spacer()
            Text(conversation.transcript.entries.isEmpty ? "Transcript empty" : "Transcript: \(conversation.transcript.entries.count) lines in memory")
            if conversation.active { TurnBothOffButton(conversation: conversation).controlSize(.small) }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        .padding(.horizontal, 14).frame(height: 28)
        .background(Surface.panel)
    }
    private func item(_ title: String, _ model: AppModel) -> some View {
        HStack(spacing: 5) {
            Circle().fill(model.statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
            Text("\(title): \(model.shortStatus)")
        }
    }
}
