import AppKit
import SwiftUI
import BridgeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var onQuit: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Babelfin lives in the menu bar. While one of its windows is open it is a regular app,
    /// so its menu bar (About, Check for Updates, Translation, Window, Help) and Dock icon appear.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        DiagnosticLog.shared.write("app", "Babelfin \(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?")) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        updateActivationPolicy()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // willClose fires before the window leaves the list; re-evaluate on the next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateActivationPolicy() } }
            })
        }
    }
    private func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationWillTerminate(_ notification: Notification) { Self.onQuit?() }
    /// Quitting deletes a meeting recording, so Babelfin asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = MeetingRecorder.shared
        guard recorder.state == .recording || recorder.hasRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = recorder.state == .recording ? "A meeting is being recorded" : "You have a meeting recording"
        alert.informativeText = "Quitting deletes the recording. Save the audio or transcribe it first to keep it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete and Quit").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct BabelfinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var conversation: ConversationModel
    init() {
        // Register the server routes before saved preferences decode their route IDs.
        TranslationServerSettings.applyToRegistry()
        if CommandLine.arguments.contains("--diagnostics") {
            for device in AudioDevices.all() {
                print("\(device.name): input=\(device.inputChannels), output=\(device.outputChannels), physicalMic=\(device.isPhysicalInput), blackHole=\(device.isBlackHole)")
            }
            exit(0)
        }
        #if canImport(MicrosoftCognitiveServicesSpeech)
        ProviderRegistry.azureAvailable = true
        #endif
        #if canImport(Speech) && canImport(Translation)
        if #available(macOS 26.0, *) { Task { ProviderRegistry.localLanguages = await LocalLanguageLoader.load() } }
        #endif
        #if BABELFIN_SCREENSHOTS
        let instance = ScreenshotDemo.conversation()
        #else
        LegacySettingsImport.run()
        let instance = ConversationModel()
        for model in [instance.outgoing, instance.incoming] { model.keyDiagnosis = { await KeyCheckStore.shared.diagnose($0) } }
        #endif
        MeetingRecorder.shared.recoverLeftovers()
        let callPrompt = CallPromptController(model: instance.outgoing)
        SubtitleOverlay.shared.attach(instance)
        MeetingModel.shared.conversation = instance
        LiveTranscriptExporter.shared.start(instance)
        SpeechToolsModel.autoExport = { AutoExport.export($0, name: $1, date: Date()) }
        _conversation = StateObject(wrappedValue: instance)
        AppDelegate.onQuit = { callPrompt.close(); instance.abort(); MeetingRecorder.shared.discard(); MeetingModel.shared.stopRunningNotes() }
    }
    var body: some Scene {
        Window("Babelfin", id: "main") { ConversationView(conversation: conversation) }
            .defaultSize(width: 1120, height: 740)
            .windowResizability(.automatic)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    AboutButton()
                    Button("Check for Updates…") { UpdatesWindow.show(beforeQuit: {}) }
                }
                CommandGroup(replacing: .help) {
                    Button("Babelfin Help") { AppLinks.openHelp() }.keyboardShortcut("?")
                    Button("Set Up a Call…") { HelpWindow.show(topic: "Be heard in a call") }
                    Link("Babelfin Website", destination: AppLinks.website)
                }
                CommandMenu("Translation") {
                    DirectionCommands(model: conversation.outgoing, title: "Speak", modifiers: [.command, .shift])
                    Divider()
                    DirectionCommands(model: conversation.incoming, title: "Listen", modifiers: [.command, .shift, .option])
                    Divider()
                    TurnBothOffButton(conversation: conversation).keyboardShortcut(".", modifiers: [.command, .shift])
                    RestartBothButton(conversation: conversation).keyboardShortcut("r", modifiers: [.command, .shift])
                    Divider()
                    SubtitleToggleButton().keyboardShortcut("u", modifiers: [.command, .option])
                }
                CommandGroup(before: .windowList) {
                    ForEach(Array(MainSection.allCases.enumerated()), id: \.element) { index, section in
                        SectionButton(section: section).keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    }
                    CompactButton().keyboardShortcut("0")
                    Divider()
                }
            }
        Settings { ConversationSettingsView(conversation: conversation) }
        Window("Welcome to Babelfin", id: "welcome") { FirstRunView(conversation: conversation) }
            .windowResizability(.contentSize)
            .commandsRemoved()
        Window("Compact Controls", id: "compact") { CompactWindow(conversation: conversation) }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .commandsRemoved()
        Window("About Babelfin", id: "about") { AboutView() }.windowResizability(.contentSize).commandsRemoved()
        #if BABELFIN_SCREENSHOTS
        // Private documentation build only: the menu bar panel in a window, for screenshots.
        Window("Menu Bar Panel", id: "menu-preview") { ConversationMenu(conversation: conversation) }.windowResizability(.contentSize)
        #endif
        MenuBarExtra { ConversationMenu(conversation: conversation) } label: { MenuBarLabel(conversation: conversation) }
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    static let babelfinSettingsDestination = Notification.Name("babelfin.settings.destination")
}
@MainActor enum SettingsRequest {
    static var destination: SettingsDestination?
    static func select(_ value: SettingsDestination?) {
        guard let value else { return }
        destination = value
        NotificationCenter.default.post(name: .babelfinSettingsDestination, object: value)
    }
}
struct OpenSettingsButton: View {
    var destination: SettingsDestination? = nil
    var title = "Settings…"
    var body: some View {
        if #available(macOS 14.0, *) {
            ModernSettingsButton(destination: destination, title: title)
        } else {
            Button {
                SettingsRequest.select(destination)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { Label(title, systemImage: "gearshape") }
        }
    }
}
@available(macOS 14.0, *)
private struct ModernSettingsButton: View {
    var destination: SettingsDestination?
    var title: String
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button { SettingsRequest.select(destination); openSettings() } label: { Label(title, systemImage: "gearshape") }
    }
}
private struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("About Babelfin") { openWindow(id: "about"); NSApp.activate(ignoringOtherApps: true) } }
}
/// Opens the main window expanded at one sidebar section.
struct SectionButton: View {
    let section: MainSection
    var title: String? = nil
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(title ?? section.title) { MainNavigation.open(section, openWindow: openWindow) }
    }
}
extension MainNavigation {
    /// True until the main window first appears.
    static var launching = true
    /// Shows compact controls and closes the main window.
    static func openCompact(openWindow: OpenWindowAction) {
        openWindow(id: "compact"); NSApp.activate(ignoringOtherApps: true)
        close("main")
    }
    /// Shows the main window at one section and closes compact controls.
    static func open(_ section: MainSection, openWindow: OpenWindowAction) {
        launching = false
        shared.section = section
        openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        close("compact")
    }
    /// SwiftUI names a window after its scene ID: "main", or "main-AppWindow-1" for a window group.
    private static func close(_ scene: String) {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                guard let id = window.identifier?.rawValue, id == scene || id.hasPrefix(scene + "-") else { continue }
                window.close()
            }
        }
    }
}
/// The menu bar icon: the fish while idle or translating, a record symbol while recording.
private struct MenuBarLabel: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var recorder = MeetingRecorder.shared
    var body: some View {
        if recorder.state == .recording {
            Label("Babelfin recording", systemImage: "record.circle.fill")
        } else {
            Label {
                Text(conversation.active ? "Babelfin active" : "Babelfin stopped")
            } icon: {
                Image(nsImage: conversation.active ? MenuBarSymbol.live : MenuBarSymbol.idle).renderingMode(.template)
            }
        }
    }
}

/// Restarts each direction that has changes waiting for a restart.
struct RestartBothButton: View {
    @ObservedObject var conversation: ConversationModel
    var body: some View {
        Button("Restart to Apply Changes") { Task {
            for model in [conversation.outgoing, conversation.incoming] where !model.pendingRestart.isEmpty { await model.restartTranslation() }
        } }
        .disabled(conversation.outgoing.pendingRestart.isEmpty && conversation.incoming.pendingRestart.isEmpty)
    }
}
/// Opens the window as compact controls.
struct CompactButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Compact Controls") { MainNavigation.openCompact(openWindow: openWindow) }
    }
}
struct TurnBothOffButton: View {
    @ObservedObject var conversation: ConversationModel
    var body: some View {
        Button("Turn both off") { Task {
            async let outgoing: Void = TranslationControlActions(model: conversation.outgoing).turnOff()
            async let incoming: Void = TranslationControlActions(model: conversation.incoming).turnOff()
            _ = await (outgoing, incoming)
        } }
        .disabled(TranslationControlActions(model: conversation.outgoing).offDisabled && TranslationControlActions(model: conversation.incoming).offDisabled)
    }
}
/// Each direction owns its commands, so a shortcut never depends on the visible section.
struct DirectionCommands: View {
    @ObservedObject var model: AppModel
    let title: String
    let modifiers: EventModifiers
    private var actions: TranslationControlActions { TranslationControlActions(model: model) }
    var body: some View {
        Text("\(title) · \(model.shortStatus)")
        Button(actions.primaryTitle) { Task { await actions.performPrimary() } }
            .disabled(actions.primaryDisabled).keyboardShortcut("t", modifiers: modifiers)
        Button(model.muted ? "Unmute" : "Mute") { Task { await actions.toggleMute() } }
            .disabled(actions.muteDisabled).keyboardShortcut("m", modifiers: modifiers)
        Button("Off") { Task { await actions.turnOff() } }
            .disabled(actions.offDisabled).keyboardShortcut("o", modifiers: modifiers)
    }
}
enum AppLinks {
    static let website = URL(string: "https://tm-henningnt.github.io/babelfin/")!
    static let repository = URL(string: "https://github.com/tm-henningnt/babelfin")!
    @MainActor static func openHelp() { HelpWindow.show() }
    static func openLicense() {
        if let url = Bundle.main.url(forResource: "License", withExtension: "txt") { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(repository.appendingPathComponent("blob/main/LICENSE")) }
    }
    static let driverSource = repository.appendingPathComponent("tree/main/Drivers/BabelfinLoopback")
    static func openDriverLicense() {
        let bundled = AudioDriverInstaller.bundledDirectory()?.appendingPathComponent(AudioDriverInstaller.licenseFileName)
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { NSWorkspace.shared.open(bundled) }
        else { NSWorkspace.shared.open(repository.appendingPathComponent("blob/main/Drivers/BabelfinLoopback/upstream/LICENSE")) }
    }
}

/// One-time import of non-secret preferences from the retired prototype identity.
/// API keys are not preferences: Keychain items under the old service are never read.
enum LegacySettingsImport {
    static let legacyDomain = "no.tallmaker.NordMic.prototype"
    static let markerKey = "babelfin.legacySettingsImported.v1"
    static func run(into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: markerKey) else { return }
        defaults.set(true, forKey: markerKey)
        guard let legacy = UserDefaults.standard.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in legacy where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("com.apple")
            && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
