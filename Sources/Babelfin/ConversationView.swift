import SwiftUI
import BridgeCore

struct ConversationView: View {
    @ObservedObject var conversation: ConversationModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("babelfin.compactControls.v1") private var compact = true
    // Compact rows show their own Set up… action, so setup gaps never block compact mode.
    private var showCompact: Bool { compact }
    var body: some View {
        Group {
            if showCompact {
                CompactControlsView(conversation: conversation) { compact = false }
            } else {
                MainWindowView(conversation: conversation) { compact = true }
            }
        }
        .frame(minWidth: showCompact ? ConversationWindowSizing.compactMinimum.width : ConversationWindowSizing.expandedMinimum.width,
               minHeight: showCompact ? ConversationWindowSizing.compactMinimum.height : ConversationWindowSizing.expandedMinimum.height)
        .background(ConversationWindowSizing(compact: showCompact))
    }
}

struct ConversationSettingsView: View {
    @ObservedObject var conversation: ConversationModel
    @StateObject private var navigation: SettingsNavigationState
    init(conversation: ConversationModel, initialDestination: SettingsDestination? = nil) {
        self.conversation = conversation
        _navigation = StateObject(wrappedValue: SettingsNavigationState(selection: initialDestination ?? SettingsRequest.destination ?? (conversation.direction == .outgoing ? .outgoing : .incoming)))
    }
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $navigation.selection) {
                Section("Translation") {
                    Label("Language setup", systemImage: "wand.and.stars").tag(SettingsDestination.setup)
                    Label("Speak", systemImage: "mic").tag(SettingsDestination.outgoing)
                    Label("Listen", systemImage: "headphones").tag(SettingsDestination.incoming)
                }
                Section {
                    Label("Accounts", systemImage: "key").tag(SettingsDestination.accounts)
                    if AudioDriverInstaller.bundlesDrivers() {
                        Label("Audio devices", systemImage: "hifispeaker.2").tag(SettingsDestination.audioDevices)
                    }
                    Label("Troubleshooting", systemImage: "wrench.and.screwdriver").tag(SettingsDestination.troubleshooting)
                }
            }.listStyle(.sidebar).frame(width: 190)
                .accessibilityLabel("Settings categories")
            Divider()
            Group {
                switch navigation.selection ?? .outgoing {
                case .outgoing, .incoming:
                    let direction: ConversationDirection = navigation.selection == .incoming ? .incoming : .outgoing
                    SettingsView(model: direction == .outgoing ? conversation.outgoing : conversation.incoming,
                        direction: direction, allAudioStopped: { !conversation.locked }, openAccounts: { navigation.selection = .accounts })
                        .id(direction)
                case .setup:
                    SetupWizardView(conversation: conversation, openAccounts: { navigation.selection = .accounts })
                case .accounts:
                    AccountSettingsView(allAudioStopped: { !conversation.locked })
                case .audioDevices:
                    AudioDriverSettingsView(conversation: conversation)
                case .troubleshooting:
                    TroubleshootingSettingsView(conversation: conversation)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 740)
        .onReceive(NotificationCenter.default.publisher(for: .babelfinSettingsDestination)) { notification in
            if let destination = notification.object as? SettingsDestination { navigation.selection = destination }
        }

    }
}

enum SettingsDestination: Hashable {
    case setup, outgoing, incoming, accounts, audioDevices, troubleshooting
}

@MainActor private final class SettingsNavigationState: ObservableObject {
    @Published var selection: SettingsDestination?
    init(selection: SettingsDestination) { self.selection = selection }
}

/// Menu-bar menu: one group per direction with its state and next actions.
struct ConversationMenu: View {
    @ObservedObject var conversation: ConversationModel
    var body: some View {
        StatusDirectionItems(model: conversation.outgoing, title: "Speak")
        Divider()
        StatusDirectionItems(model: conversation.incoming, title: "Listen")
        Divider()
        SectionButton(section: conversation.direction == .outgoing ? .outgoing : .incoming, title: "Open Babelfin")
        SectionButton(section: .transcript)
        SubtitleToggleButton()
        SectionButton(section: .recording, title: "Audio tools")
        Divider()
        OpenSettingsButton()
        Button("Check for Updates…") { UpdatesWindow.show(beforeQuit: {}) }
        Button("Babelfin Help") { AppLinks.openHelp() }
        AboutMenuButton()
        Divider()
        Button("Quit Babelfin") { conversation.abort(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
private struct StatusDirectionItems: View {
    @ObservedObject var model: AppModel
    let title: String
    private var actions: TranslationControlActions { TranslationControlActions(model: model) }
    var body: some View {
        Text("\(title) · \(model.shortStatus) · \(model.languageSummary)")
        Button(actions.primaryTitle) { Task { await actions.performPrimary() } }.disabled(actions.primaryDisabled)
        if !actions.muteDisabled {
            Button(model.muted ? "Unmute" : "Mute") { Task { await actions.toggleMute() } }
        }
        if !actions.offDisabled {
            Button("Off") { Task { await actions.turnOff() } }
        }
        if !model.pendingRestart.isEmpty {
            Button("Restart to Apply Changes") { Task { await model.restartTranslation() } }
        }
        Picker("Hear: \(model.hearing.title)", selection: Binding(get: { model.hearing }, set: { model.hearing = $0 })) {
            ForEach(AppModel.Hearing.allCases) { Text($0.title).tag($0) }
        }
        Picker("Volume: \(Int((model.outputVolume * 100).rounded()))%", selection: Binding(
            get: { Int((model.outputVolume * 10).rounded()) }, set: { model.outputVolume = Double($0) / 10 })) {
            ForEach((0...10).reversed(), id: \.self) { Text("\($0 * 10)%").tag($0) }
        }
    }
}

struct MeetingTranscriptView: View {
    @ObservedObject var conversation: ConversationModel
    @StateObject private var options = MeetingCopyOptions()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcript").font(.title2.weight(.semibold))
                Text("Text from both translation directions stays here until you clear it or quit. Original-only audio is not transcribed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Picker("Include", selection: $options.selection) {
                    ForEach(TranscriptExport.Selection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).fixedSize()
                Picker("Prompt", selection: $options.prompt) {
                    ForEach(TranscriptExport.Prompt.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
                Spacer()
                Button { conversation.copyTranscript(selection: options.selection, prompt: options.prompt) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }.disabled(empty)
                Menu {
                    Button("Plain text…") { conversation.exportTranscript(json: false) }
                    Button("Structured transcript (JSON)…") { conversation.exportTranscript(json: true) }
                } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .fixedSize().disabled(empty)
            }
            if !conversation.transcript.sessions.isEmpty {
                DisclosureGroup("Translation coverage") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(conversation.transcript.sessions, id: \.sessionID) { session in
                                Label("\(session.direction.label) · \(session.startedAt?.formatted(date: .omitted, time: .standard) ?? "Unknown start")–\(session.endedAt?.formatted(date: .omitted, time: .standard) ?? "now") · \(session.endReason ?? "Translating")", systemImage: session.endedAt == nil ? "waveform" : "pause.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }
            }
            if conversation.transcript.limitReached {
                Label("Transcript memory is full. Save and clear it to continue collecting text.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if conversation.transcript.skippedInvalidSegments > 0 {
                Text("Some transcript updates could not be recorded. The export includes this notice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if empty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.system(size: 32)).foregroundStyle(.tertiary).accessibilityHidden(true)
                    Text("No transcript yet").font(.headline)
                    Text("Start translating either direction to see the conversation here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(conversation.transcript.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(entry.direction.label) · \(entry.role == .source ? "Original" : "Translation")\(entry.segment.speaker.map { " · Speaker \($0)" } ?? "")")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(entry.role == .source ? Color.secondary : Color.accentColor)
                                Text(entry.segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(entry.direction == .outgoing ? Color.accentColor : Color.secondary.opacity(0.5))
                                    .frame(width: 2).accessibilityHidden(true)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text(conversation.exportNotice).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear transcript", role: .destructive) { conversation.clearTranscript() }.disabled(empty)
            }
        }.padding(24).frame(minWidth: 560, minHeight: 400)
    }
    private var empty: Bool { conversation.transcript.entries.isEmpty }
}

@MainActor private final class MeetingCopyOptions: ObservableObject {
    @Published var selection: TranscriptExport.Selection = .both
    @Published var prompt: TranscriptExport.Prompt = .none
}

struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("About Babelfin") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) } }
}
