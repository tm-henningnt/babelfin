import SwiftUI
import BridgeCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var direction: ConversationDirection = .outgoing
    var allAudioStopped: () -> Bool = { true }
    var openAccounts: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeading(title: direction == .outgoing ? "Your voice" : "Meeting audio",
                detail: direction == .outgoing ? "Choose how your translated voice sounds." : "Choose how you hear translated meeting audio.")
            Form {
                Section {
                    Picker("Service", selection: $model.route) {
                        ForEach(TranslationRoute.allCases) { Text($0.displayName).tag($0) }
                    }.disabled(model.configurationLocked)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(serviceExplanation).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Manage API keys…", action: openAccounts)
                    }
                } header: { Text("Translation") }
                VoiceSettingsView(model: model, allAudioStopped: allAudioStopped)
                Section {
                    Toggle("Mix in original audio", isOn: $model.originalMixEnabled)
                    if model.originalMixEnabled {
                        HStack(spacing: 12) {
                            Text("Original volume")
                            Slider(value: $model.originalMixLevel, in: 0...1).accessibilityLabel("Original audio volume")
                            Text(model.originalMixLevel, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 42, alignment: .trailing)
                        }
                        Toggle("Lower original audio while translation plays", isOn: $model.originalMixDucking)
                    }
                    Text("Keep the original voice quietly underneath the translation. The two voices are not synchronized.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Original audio") }
                    .disabled(model.configurationLocked)
                if model.configurationLocked {
                    Section { Label("Stop this direction to change its service, voice or audio mix.", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped)
        }
        .onAppear { model.refresh(); model.refreshKeyStatus() }
    }

    private var serviceExplanation: String {
        switch model.route {
        case .openAI: return "OpenAI receives your audio and returns translated speech."
        case .elevenLabs: return "ElevenLabs recognizes and speaks the audio. OpenAI translates the text. Both accounts are used."
        case .fish: return "ElevenLabs recognizes the audio, OpenAI translates the text, and Fish Audio speaks it. All three accounts are used."
        }
    }
}

@MainActor private final class AccountSettingsState: ObservableObject {
    @Published var needsSelection = KeychainStore.needsStorageSelection()
    @Published var removalStorage: CredentialStorageMode?
    @Published var notice = ""
    @Published var refreshToken = UUID()
}

struct AccountSettingsView: View {
    var allAudioStopped: () -> Bool
    @AppStorage(KeychainStore.storagePreferenceKey) private var storageMode: CredentialStorageMode = .keychain
    @ObservedObject private var activity = CredentialOperationActivity.shared
    @StateObject private var state = AccountSettingsState()
    private var editsAllowed: Bool { allAudioStopped() && !activity.active }
    var body: some View {
        VStack(spacing: 0) {
            SettingsHeading(title: "Accounts", detail: "API keys for the services you use. Both directions share them, and each service bills your account separately.")
            Form {
                Section {
                    if state.needsSelection {
                        Text("Choose where to save your keys. This Mac is recommended for this unnotarized release. Local files are unencrypted and readable by apps running as your account. Existing keys stay where they are.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Use This Mac (recommended)") {
                            guard editsAllowed else { return }
                            storageMode = .localFile; state.needsSelection = false
                        }.disabled(!editsAllowed)
                        Button("Use Keychain") {
                            guard editsAllowed else { return }
                            storageMode = .keychain; state.needsSelection = false
                        }.disabled(!editsAllowed)
                    }
                    Picker("Store keys in", selection: Binding(get: { storageMode }, set: { mode in
                        guard editsAllowed else { return }
                        storageMode = mode; state.needsSelection = false
                    })) {
                        ForEach(CredentialStorageMode.allCases) { Text($0.displayName).tag($0) }
                    }.disabled(!editsAllowed)
                    Text((storageMode == .keychain
                         ? "Encrypted by macOS Keychain. App updates may ask for access again."
                         : "Unencrypted files readable by apps running as your macOS account. No Keychain prompts after updates.")
                         + " Changing storage does not move existing keys.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !editsAllowed {
                        Text("Stop translation and wait for audio tools or voice requests to finish before changing keys.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Key storage") }
                Section {
                    ForEach(AccountProvider.all) { provider in
                        CredentialKeyRow(service: provider.service, title: provider.title, keysPage: provider.keysPage,
                                         storageMode: storageMode, allAudioStopped: { editsAllowed && !state.needsSelection })
                    }
                } header: { Text("API keys") } footer: {
                    Text("Use API keys from each provider's developer console. Consumer subscriptions do not include API usage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Remove all saved keys…", role: .destructive) {
                        guard editsAllowed else { return }
                        state.removalStorage = storageMode
                    }.disabled(!editsAllowed)
                    if !state.notice.isEmpty { Text(state.notice).font(.caption).foregroundStyle(.secondary) }
                } header: { Text("Remove keys from \(storageMode.displayName)") }
            }.formStyle(.grouped)
                .id(state.refreshToken)
                .alert("Remove all saved keys?", isPresented: Binding(get: { state.removalStorage != nil }, set: { if !$0 { state.removalStorage = nil } })) {
                    Button("Remove all", role: .destructive) {
                        guard editsAllowed, let selected = state.removalStorage else { state.removalStorage = nil; return }
                        let result = KeychainStore.removeAll(storage: selected)
                        state.notice = result.notice; state.removalStorage = nil; state.refreshToken = UUID()
                        NotificationCenter.default.post(name: .babelfinCredentialMetadataChanged, object: nil)
                    }
                    Button("Cancel", role: .cancel) { state.removalStorage = nil }
                } message: {
                    Text("Remove OpenAI, ElevenLabs and Fish Audio keys from \(state.removalStorage?.displayName ?? storageMode.displayName)? Keys in the other storage location will remain.")
                }
        }
    }
}

struct TroubleshootingSettingsView: View {
    @ObservedObject var conversation: ConversationModel
    private var model: AppModel { conversation.selected }
    var body: some View {
        VStack(spacing: 0) {
            SettingsHeading(title: "Troubleshooting", detail: "Check a connection or copy session details when something does not work.")
            Form {
                Section {
                    Picker("Direction", selection: $conversation.direction) {
                        Text("Your voice").tag(ConversationDirection.outgoing)
                        Text("Meeting audio").tag(ConversationDirection.incoming)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                Section {
                    HStack {
                        Button(model.checkingAPI ? "Checking connection…" : "Check OpenAI direct connection") {
                            Task { await model.testAPIConnection() }
                        }.disabled(conversation.locked)
                        if model.checkingAPI { ProgressView().controlSize(.small) }
                    }
                    Text("Sends one second of generated silence. Your microphone is not used.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.keyNotice).font(.callout).foregroundStyle(.secondary)
                } header: { Text("Connection") }
                Section {
                    ScrollView {
                        Text(model.logs.isEmpty ? "No session details yet." : model.logs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 160)
                    HStack {
                        Text("Audio, API keys and transcripts are excluded.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { model.clearDiagnostics() }.disabled(model.logs.isEmpty)
                            .accessibilityLabel("Clear diagnostic details")
                    }
                } header: { Text("Session details") }
                Section {
                    Button("Setup and routing help") { AppLinks.openHelp() }
                }
            }.formStyle(.grouped)
        }
    }
}

struct SettingsHeading: View {
    var title: String
    var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 4)
    }
}

/// Providers listed on the Accounts page. Adding a provider adds one row here.
struct AccountProvider: Identifiable {
    let service: ProviderService
    let title: String
    let keysPage: URL
    var id: ProviderService { service }
    static let all = [
        AccountProvider(service: .openAI, title: "OpenAI", keysPage: URL(string: "https://platform.openai.com/api-keys")!),
        AccountProvider(service: .elevenLabs, title: "ElevenLabs", keysPage: URL(string: "https://elevenlabs.io/app/settings/api-keys")!),
        AccountProvider(service: .fish, title: "Fish Audio", keysPage: URL(string: "https://fish.audio/app/api-keys/")!)
    ]
}
