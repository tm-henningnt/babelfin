import AppKit
import SwiftUI
import BridgeCore

/// Sidebar destinations of the main window.
enum MainSection: String, CaseIterable, Hashable {
    case home, transcript, tools
    var title: String {
        switch self {
        case .home: return "Home"
        case .transcript: return "Transcript"
        case .tools: return "Tools"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .transcript: return "text.bubble"
        case .tools: return "wrench.and.screwdriver"
        }
    }
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
    #if BABELFIN_SCREENSHOTS
    @StateObject private var tools = ScreenshotDemo.tools()
    #else
    @StateObject private var tools = SpeechToolsModel()
    #endif
    var showCompact: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { subtitles.toggle() } label: { Label(subtitles.visible ? "Hide Subtitles" : "Show Subtitles", systemImage: "captions.bubble") }
                    .help(subtitles.visible ? "Hide the subtitles" : "Show the subtitles over other windows")
                Button(action: showCompact) { Label("Compact", systemImage: "rectangle.compress.vertical") }
                    .help("Show compact controls")
            }
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { navigation.section }, set: { if let value = $0 { navigation.section = value } })) {
                ForEach(MainSection.allCases, id: \.self) { section in
                    HStack {
                        Label(section.title, systemImage: section.symbol)
                        Spacer()
                        if section == .home && conversation.active {
                            Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Translating")
                        }
                        if section == .transcript && !conversation.transcript.entries.isEmpty {
                            Text("\(conversation.transcript.entries.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.tag(section)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Sections")
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button { AppLinks.openHelp() } label: { Label("Help", systemImage: "questionmark.circle") }
                OpenSettingsButton(title: "Settings")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 190)
    }
    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .home:
            HomeView(conversation: conversation) { navigation.section = .transcript }
        case .transcript:
            MeetingTranscriptView(conversation: conversation)
        case .tools:
            SpeechToolsView(model: tools, meetingText: { conversation.transcript.plainText(selection: .source) }, showsSidebar: false)
        }
    }
}
