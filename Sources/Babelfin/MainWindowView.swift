import AppKit
import SwiftUI
import BridgeCore

/// Sidebar destinations of the main window. Each direction keeps its own audio model.
enum MainSection: String, CaseIterable, Hashable {
    case outgoing, incoming, transcript, recording, notes, voice
    var title: String {
        switch self {
        case .outgoing: return "Your voice"
        case .incoming: return "Meeting audio"
        case .transcript: return "Transcript"
        case .recording: return "Audio file"
        case .notes: return "Meeting notes"
        case .voice: return "Voice clip"
        }
    }
    var symbol: String {
        switch self {
        case .outgoing: return "mic"
        case .incoming: return "headphones"
        case .transcript: return "text.bubble"
        case .recording: return "waveform"
        case .notes: return "note.text"
        case .voice: return "speaker.wave.2"
        }
    }
    var toolPage: SpeechToolsPage? {
        switch self { case .recording: return .recording; case .notes: return .notes; case .voice: return .voice; default: return nil }
    }
}

/// Menus, compact controls and the status item open a section through this one owner.
@MainActor final class MainNavigation: ObservableObject {
    static let shared = MainNavigation()
    @Published var section: MainSection = .outgoing
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
        if route == .openAI { return "Follows the speaker" }
        if voiceID.isEmpty { return capabilities.requiresVoiceID ? "Choose a voice" : "Default voice" }
        return VoiceNameCache.name(for: voiceID) ?? "Saved voice"
    }
}

struct MainWindowView: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var navigation = MainNavigation.shared
    @StateObject private var tools = SpeechToolsModel()
    var showCompact: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .onAppear { sync(navigation.section) }
        .onChange(of: navigation.section) { sync($0) }
        .onChange(of: conversation.direction) { direction in
            if navigation.section == .outgoing || navigation.section == .incoming {
                navigation.section = direction == .outgoing ? .outgoing : .incoming
            }
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { navigation.section }, set: { if let value = $0 { navigation.section = value } })) {
                Section("Translation") {
                    directionRow(.outgoing, model: conversation.outgoing)
                    directionRow(.incoming, model: conversation.incoming)
                }
                Section("Conversation") {
                    HStack {
                        Label(MainSection.transcript.title, systemImage: MainSection.transcript.symbol)
                        Spacer()
                        if !conversation.transcript.entries.isEmpty {
                            Text("\(conversation.transcript.entries.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.tag(MainSection.transcript)
                }
                Section("Tools") {
                    ForEach([MainSection.recording, .notes, .voice], id: \.self) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Sections")
            Divider()
            HStack(spacing: 8) {
                Button { AppLinks.openHelp() } label: {
                    Label("How to use", systemImage: "questionmark.circle").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                OpenSettingsButton().labelStyle(.iconOnly).buttonStyle(.plain)
                    .help("Settings").accessibilityLabel("Settings")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 210)
    }
    private func directionRow(_ section: MainSection, model: AppModel) -> some View {
        DirectionSidebarRow(section: section, model: model).tag(section)
    }
    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .outgoing:
            MainView(model: conversation.outgoing, incoming: false, showCompact: showCompact).id(MainSection.outgoing)
        case .incoming:
            MainView(model: conversation.incoming, incoming: true, showCompact: showCompact).id(MainSection.incoming)
        case .transcript:
            MeetingTranscriptView(conversation: conversation)
        case .recording, .notes, .voice:
            SpeechToolsView(model: tools, meetingText: { conversation.transcript.plainText(selection: .source) }, showsSidebar: false)
        }
    }
    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("Your voice: \(conversation.outgoing.shortStatus)")
            Text("·").accessibilityHidden(true)
            Text("Meeting audio: \(conversation.incoming.shortStatus)")
            Spacer()
            if conversation.active {
                Button("Turn both off") { Task {
                    async let outgoing: Void = TranslationControlActions(model: conversation.outgoing).turnOff()
                    async let incoming: Void = TranslationControlActions(model: conversation.incoming).turnOff()
                    _ = await (outgoing, incoming)
                } }.controlSize(.small)
            } else {
                Text(conversation.transcript.entries.isEmpty ? "Transcript empty" : "Transcript: \(conversation.transcript.entries.count) lines in memory")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func sync(_ section: MainSection) {
        if section == .outgoing { conversation.direction = .outgoing }
        if section == .incoming { conversation.direction = .incoming }
        if let page = section.toolPage, tools.page != page { tools.page = page }
    }
}

private struct DirectionSidebarRow: View {
    let section: MainSection
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            Label(section.title, systemImage: section.symbol)
            Spacer()
            Text(model.shortStatus).font(.caption).foregroundStyle(model.statusColor == .secondary ? Color.secondary : model.statusColor)
        }
        .accessibilityElement(children: .combine)
    }
}
