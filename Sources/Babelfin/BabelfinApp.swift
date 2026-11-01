import AppKit
import SwiftUI
import BridgeCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var onQuit: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Babelfin lives in the menu bar. While one of its windows is open it is a regular app,
    /// so its menu bar (About, Check for Updates, Translation, Window, Help) and Dock icon appear.
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        #if BABELFIN_SCREENSHOTS
        let instance = ScreenshotDemo.conversation()
        #else
        LegacySettingsImport.run()
        let instance = ConversationModel()
        for model in [instance.outgoing, instance.incoming] { model.keyDiagnosis = { await KeyCheckStore.shared.diagnose($0) } }
        #endif
        let callPrompt = CallPromptController(model: instance.outgoing)
        SubtitleOverlay.shared.attach(instance)
        _conversation = StateObject(wrappedValue: instance)
        AppDelegate.onQuit = { callPrompt.close(); instance.abort() }
    }
    var body: some Scene {
        Window("Babelfin", id: "main") { ConversationView(conversation: conversation) }
            .defaultSize(width: 980, height: 700)
            .windowResizability(.automatic)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    AboutButton()
                    Button("Check for Updates…") { UpdatesWindow.show(beforeQuit: {}) }
                }
                CommandGroup(replacing: .help) { Button("Babelfin Help") { AppLinks.openHelp() } }
                CommandMenu("Translation") {
                    DirectionCommands(model: conversation.outgoing, title: "Speak", modifiers: [.command, .shift])
                    Divider()
                    DirectionCommands(model: conversation.incoming, title: "Listen", modifiers: [.command, .shift, .option])
                    Divider()
                    TurnBothOffButton(conversation: conversation).keyboardShortcut(".", modifiers: [.command, .shift])
                    Divider()
                    SubtitleToggleButton().keyboardShortcut("u", modifiers: [.command, .option])
                }
                CommandGroup(before: .windowList) {
                    SectionButton(section: .outgoing).keyboardShortcut("1")
                    SectionButton(section: .incoming).keyboardShortcut("2")
                    SectionButton(section: .transcript).keyboardShortcut("3")
                    SectionButton(section: .recording, title: "Audio tools").keyboardShortcut("u", modifiers: [.command, .shift])
                    Divider()
                }
            }
        Settings { ConversationSettingsView(conversation: conversation) }
        Window("About Babelfin", id: "about") { AboutView() }.windowResizability(.contentSize)
        MenuBarExtra { ConversationMenu(conversation: conversation) } label: {
            Label {
                Text(conversation.active ? "Babelfin active" : "Babelfin stopped")
            } icon: {
                Image(nsImage: conversation.active ? MenuBarSymbol.live : MenuBarSymbol.idle).renderingMode(.template)
            }
        }
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
    static func open(_ section: MainSection, openWindow: OpenWindowAction) {
        UserDefaults.standard.set(false, forKey: "babelfin.compactControls.v1")
        shared.section = section
        openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
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
