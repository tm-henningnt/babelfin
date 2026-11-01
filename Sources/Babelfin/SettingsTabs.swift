import AppKit
import SwiftUI
import BridgeCore

/// Settings › General: how the window opens, the subtitles and updates.
struct GeneralSettingsView: View {
    @ObservedObject var conversation: ConversationModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(CompactPreferences.atLaunch) private var compact = true
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }
    var body: some View {
        Form {
            Section {
                Picker("At launch, show", selection: $compact) {
                    Text("Home").tag(false)
                    Text("Compact controls").tag(true)
                }.pickerStyle(.radioGroup)
            } header: { Text("Window") }
            SubtitleSettingsSection()
            Section {
                LabeledContent("Version", value: version)
                HStack {
                    Button("Check for Updates…") { UpdatesWindow.show(beforeQuit: {}) }
                    Button("Babelfin Help") { AppLinks.openHelp() }
                    Button("Setup Assistant…") { openWindow(id: "welcome") }
                }
            } header: { Text("Updates") }
        }.formStyle(.grouped)
    }
}

/// Settings › Audio devices: the devices of both directions, then the Babelfin audio drivers.
struct DeviceSettingsView: View {
    @ObservedObject var conversation: ConversationModel
    var body: some View {
        Form {
            direction(conversation.outgoing, incoming: false)
            direction(conversation.incoming, incoming: true)
            Section {
                HStack {
                    Label(deviceCheck, systemImage: deviceIssue ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(deviceIssue ? Color.orange : Color.green)
                    Spacer()
                    Button("Refresh Devices") { conversation.outgoing.refresh(); conversation.incoming.refresh() }
                        .disabled(conversation.locked)
                }
            } header: { Text("Device check") }
            if AudioDriverInstaller.bundlesDrivers() { AudioDriverSettingsView(conversation: conversation) }
        }
        .formStyle(.grouped)
        .onAppear { conversation.outgoing.refresh(); conversation.incoming.refresh() }
    }
    private func direction(_ model: AppModel, incoming: Bool) -> some View {
        let rows = DeviceRows(model: model, incoming: incoming)
        return Section {
            rows.disabled(model.configurationLocked)
        } header: { Text(incoming ? "Listen" : "Speak") } footer: {
            Text(rows.help).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var sharedLoopback: Bool {
        let speak = conversation.outgoing, listen = conversation.incoming
        return speak.destination == .teams && !speak.outputUID.isEmpty && speak.outputUID == listen.inputUID
    }
    private var missing: [String] {
        [(conversation.outgoing, "Speak"), (conversation.incoming, "Listen")].flatMap { model, name in
            (model.inputAvailable ? [] : ["\(name) needs an audio source."]) + (model.outputAvailable ? [] : ["\(name) needs an output."])
        }
    }
    private var deviceIssue: Bool { sharedLoopback || !missing.isEmpty }
    private var deviceCheck: String {
        if sharedLoopback { return "Speak sends to the loopback that Listen hears. Use a separate loopback for each direction." }
        return missing.first ?? "Both directions have their devices."
    }
}

/// Settings › Languages and services: suggestions for both directions, then each direction's details.
struct LanguageSettingsView: View {
    enum Page: Hashable { case suggestions, speak, listen }
    @ObservedObject var conversation: ConversationModel
    @Binding var page: Page
    var openAccounts: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $page) {
                Text("Suggestions").tag(Page.suggestions)
                Text("Speak").tag(Page.speak)
                Text("Listen").tag(Page.listen)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.top, 12)
            switch page {
            case .suggestions:
                SetupWizardView(conversation: conversation, openAccounts: openAccounts)
            case .speak:
                SettingsView(model: conversation.outgoing, direction: .outgoing, allAudioStopped: { !conversation.locked }, openAccounts: openAccounts)
                    .id(Page.speak)
            case .listen:
                SettingsView(model: conversation.incoming, direction: .incoming, allAudioStopped: { !conversation.locked }, openAccounts: openAccounts)
                    .id(Page.listen)
            }
        }
    }
}

/// Settings › Advanced: connection checks, session details, your own server and the Azure endpoint.
struct AdvancedSettingsView: View {
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var activity = CredentialOperationActivity.shared
    private var model: AppModel { conversation.selected }
    private var editsAllowed: Bool { !conversation.locked && !activity.active }
    var body: some View {
        Form {
            Section {
                Picker("Direction", selection: $conversation.direction) {
                    Text("Speak").tag(ConversationDirection.outgoing)
                    Text("Listen").tag(ConversationDirection.incoming)
                }.pickerStyle(.segmented)
                HStack {
                    Button(model.checkingAPI ? "Checking connection…" : "Check the \(model.route.displayName) connection") {
                        Task { await model.testAPIConnection() }
                    }.disabled(conversation.locked)
                    if model.checkingAPI { ProgressView().controlSize(.small) }
                }
                Text("Sends one second of generated silence. Your microphone is not used.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.keyNotice.isEmpty { Text(model.keyNotice).font(.callout).foregroundStyle(.secondary) }
            } header: { Text("Check a route") }
            Section {
                if model.logs.isEmpty {
                    Text("No session details yet.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(model.logs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 160)
                    HStack {
                        Text("Audio, API keys and transcripts are excluded.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { model.clearDiagnostics() }.accessibilityLabel("Clear diagnostic details")
                    }
                }
            } header: { Text("Session details for support") }
            TranslationServerSection(editsAllowed: editsAllowed)
            if ProviderRegistry.azureAvailable { AzureEndpointSection(editsAllowed: editsAllowed) }
            Section {
                Button("Setup and routing help") { AppLinks.openHelp() }
            }
        }.formStyle(.grouped)
    }
}
