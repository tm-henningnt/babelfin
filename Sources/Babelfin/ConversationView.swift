import SwiftUI
import BridgeCore

/// The main window. Compact controls are a separate window (see `CompactWindow`).
struct ConversationView: View {
    @ObservedObject var conversation: ConversationModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        MainWindowView(conversation: conversation) { MainNavigation.openCompact(openWindow: openWindow) }
            .frame(minWidth: ConversationWindowSizing.expandedMinimum.width, minHeight: ConversationWindowSizing.expandedMinimum.height)
            .background(ConversationWindowSizing(compact: false))
            .onAppear {
                // At first launch, open the setup assistant. Later, open compact controls instead
                // when the user chose them in Settings › General.
                if MainNavigation.launching && FirstRunPreferences.shouldShow {
                    openWindow(id: "welcome")
                } else if MainNavigation.launching, UserDefaults.standard.object(forKey: CompactPreferences.atLaunch) as? Bool ?? true {
                    MainNavigation.openCompact(openWindow: openWindow)
                }
                MainNavigation.launching = false
            }
    }
}

/// Settings: five tabs. The live controls are on Home; Settings holds what changes rarely.
struct ConversationSettingsView: View {
    /// Not observed here: the model publishes every level change of both directions, and a redraw
    /// of the TabView moves its toolbar icons. Each tab observes what it shows.
    let conversation: ConversationModel
    @StateObject private var navigation: SettingsNavigationState
    init(conversation: ConversationModel, initialDestination: SettingsDestination? = nil) {
        self.conversation = conversation
        _navigation = StateObject(wrappedValue: SettingsNavigationState(selection: initialDestination ?? SettingsRequest.destination ?? .general))
    }
    var body: some View {
        TabView(selection: $navigation.selection) {
            GeneralSettingsView(conversation: conversation)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsDestination.general)
            AccountsTab(conversation: conversation)
                .tabItem { Label("Accounts", systemImage: "key") }.tag(SettingsDestination.accounts)
            DeviceSettingsView(conversation: conversation)
                .tabItem { Label("Audio devices", systemImage: "hifispeaker.2") }.tag(SettingsDestination.audioDevices)
            LanguageSettingsView(conversation: conversation, page: $navigation.languagePage,
                                 openAccounts: { navigation.selection = .accounts })
                .tabItem { Label("Languages and services", systemImage: "globe") }.tag(SettingsDestination.languages)
            AdvancedSettingsView(conversation: conversation)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsDestination.advanced)
        }
        .frame(width: 780, height: 700)
        .onAppear { navigation.apply(navigation.selection) }
        .onReceive(NotificationCenter.default.publisher(for: .babelfinSettingsDestination)) { notification in
            if let destination = notification.object as? SettingsDestination { navigation.apply(destination) }
        }
    }
}

/// Settings › Accounts, redrawn when translation starts or stops, so key edits lock while audio runs.
private struct AccountsTab: View {
    @ObservedObject var conversation: ConversationModel
    var body: some View { AccountSettingsView(allAudioStopped: { !conversation.locked }) }
}

/// A Settings tab, or a page inside Languages and services.
enum SettingsDestination: Hashable {
    case general, accounts, audioDevices, languages, advanced
    /// Languages and services, at one direction's details.
    case outgoing, incoming
    var tab: SettingsDestination {
        switch self {
        case .outgoing, .incoming: return .languages
        default: return self
        }
    }
}

@MainActor private final class SettingsNavigationState: ObservableObject {
    @Published var selection: SettingsDestination
    @Published var languagePage: LanguageSettingsView.Page = .suggestions
    init(selection: SettingsDestination) { self.selection = selection.tab; apply(selection) }
    func apply(_ destination: SettingsDestination) {
        selection = destination.tab
        if destination == .outgoing { languagePage = .speak }
        if destination == .incoming { languagePage = .listen }
    }
}

/// The menu bar panel: each direction's state, actions, what you hear and a volume slider,
/// then the windows. A window-style menu bar extra can hold sliders; a plain menu cannot.
struct ConversationMenu: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var recorder = MeetingRecorder.shared
    @ObservedObject private var subtitles = SubtitleOverlay.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarDirection(model: conversation.outgoing, title: "Speak", shortcut: "⇧⌘T")
            Divider().padding(.vertical, 6)
            MenuBarDirection(model: conversation.incoming, title: "Listen", shortcut: "⌥⇧⌘T")
            Divider().padding(.vertical, 6)
            if recorder.state == .recording {
                row("Stop Recording (\(RecorderCard.clock(recorder.seconds)))") { recorder.stop() }
                Divider().padding(.vertical, 6)
            }
            row("Open Babelfin", shortcut: "⌘1") { MainNavigation.open(.home, openWindow: openWindow) }
            row("Transcript", shortcut: "⌘2") { MainNavigation.open(.transcript, openWindow: openWindow) }
            row(subtitles.visible ? "Hide Subtitles" : "Show Subtitles", shortcut: "⌥⌘U") { subtitles.toggle() }
            row("Compact Controls", shortcut: "⌘0") { MainNavigation.openCompact(openWindow: openWindow) }
            Divider().padding(.vertical, 6)
            MenuBarSettingsRow()
            Menu {
                Button("Babelfin Help") { AppLinks.openHelp() }
                Button("Check for Updates…") { UpdatesWindow.show(beforeQuit: {}) }
                AboutMenuButton()
                Link("Babelfin Website", destination: AppLinks.website)
            } label: {
                HStack {
                    Text("Help, Updates and About")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider().padding(.vertical, 6)
            row("Quit Babelfin", shortcut: "⌘Q") { conversation.abort(); NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 300)
        .modifier(NoFocusRing())
    }
    private func row(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        MenuBarRow(title: title, shortcut: shortcut, action: action)
    }
}

/// Menu rows show a hover highlight; a keyboard focus ring on the first row looks like a selection.
struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.focusEffectDisabled() } else { content }
    }
}

/// A button that looks like a menu item: full width, highlighted under the pointer.
private struct MenuBarRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @StateObject private var hover = MenuBarHover()
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hover.inside ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hover.inside = $0 }
    }
}
/// `@State` needs the SwiftUI macro plugin, which the command-line toolchain lacks.
@MainActor private final class MenuBarHover: ObservableObject { @Published var inside = false }

private struct MenuBarSettingsRow: View {
    var body: some View {
        if #available(macOS 14.0, *) { ModernRow() } else {
            MenuBarRow(title: "Settings…", shortcut: "⌘,") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
    }
    @available(macOS 14.0, *)
    private struct ModernRow: View {
        @Environment(\.openSettings) private var openSettings
        var body: some View {
            MenuBarRow(title: "Settings…", shortcut: "⌘,") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

/// One direction in the menu bar panel.
private struct MenuBarDirection: View {
    @ObservedObject var model: AppModel
    let title: String
    let shortcut: String
    private var actions: TranslationControlActions { TranslationControlActions(model: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(model.statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("\(title) · \(model.shortStatus) · \(model.languageSummary)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 8)
            MenuBarRow(title: actions.primaryTitle, shortcut: shortcut) { Task { await actions.performPrimary() } }
                .disabled(actions.primaryDisabled)
            if !actions.muteDisabled {
                MenuBarRow(title: model.muted ? "Unmute" : "Mute") { Task { await actions.toggleMute() } }
            }
            if !actions.offDisabled {
                MenuBarRow(title: "Off") { Task { await actions.turnOff() } }
            }
            if !model.pendingRestart.isEmpty {
                MenuBarRow(title: "Restart to apply changes") { Task { await model.restartTranslation() } }
            }
            HStack(spacing: 8) {
                Text("Hear").foregroundStyle(.secondary)
                HearingPicker(model: model, incoming: title == "Listen").controlSize(.small)
            }.padding(.horizontal, 8).padding(.vertical, 2)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $model.outputVolume, in: 0...1).controlSize(.small)
                    .accessibilityLabel("\(title) output volume")
                    .accessibilityValue("\(Int((model.outputVolume * 100).rounded())) percent")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            }.padding(.horizontal, 8).padding(.vertical, 2)
        }
    }
}

struct MeetingTranscriptView: View {
    @ObservedObject var conversation: ConversationModel
    @StateObject private var options = MeetingCopyOptions()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                                HStack(spacing: 4) {
                                    Text("\(entry.direction.label) · \(entry.role == .source ? "Original" : "Translation")")
                                    if let speaker = conversation.transcript.speakerLabel(entry) {
                                        Text("·")
                                        Button(speaker) { conversation.renameSpeaker(of: entry) }
                                            .buttonStyle(.link).help("Rename this speaker")
                                    }
                                }
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
