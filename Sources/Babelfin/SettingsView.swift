import SwiftUI
import BridgeCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var direction: ConversationDirection = .outgoing
    var allAudioStopped: () -> Bool = { true }
    var openAccounts: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Service", selection: $model.route) {
                        ForEach(TranslationRoute.allCases) { Text($0.displayName).tag($0) }
                    }.disabled(model.configurationLocked)
                    Text(serviceExplanation).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: { Text("Translation") }
                Section {
                    Toggle("Speak the translation", isOn: $model.speakTranslation).disabled(model.configurationLocked).accessibilityLabel("Speak the translation")
                    Text(model.speakTranslation
                         ? "You hear a translated voice."
                         : "Text only: you hear the original audio and read the translation as subtitles (Translation › Show Subtitles) or in the transcript. Speech services are not used.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } header: { Text("Output") }
                if model.speakTranslation { VoiceSettingsView(model: model, allAudioStopped: allAudioStopped) }
                Section {
                    Toggle("Mix in original audio", isOn: $model.originalMixEnabled).accessibilityLabel("Mix in original audio")
                    if model.originalMixEnabled {
                        HStack(spacing: 12) {
                            Text("Original volume")
                            Slider(value: $model.originalMixLevel, in: 0...1).accessibilityLabel("Original audio volume")
                            Text(model.originalMixLevel, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 42, alignment: .trailing)
                        }
                        Toggle("Lower original audio while translation plays", isOn: $model.originalMixDucking).accessibilityLabel("Lower original audio while translation plays")
                    }
                } header: { Text("Original audio") }
                    .disabled(model.configurationLocked)
            }.formStyle(.grouped)
        }
        .onAppear { model.refresh(); model.refreshKeyStatus() }
    }

    private var serviceExplanation: String { ProviderRegistry.route(model.route).explanation }
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
    private var storageNote: String {
        if state.needsSelection {
            return "This Mac: files that only your macOS account can read, not encrypted, with no prompts after updates. Keychain: encrypted, and updates may ask for access again."
        }
        return (storageMode == .keychain ? "Encrypted by macOS Keychain. Updates may ask for access again."
                : "Files that only your macOS account can read. Not encrypted. No prompts after updates.")
            + " Changing storage does not move saved keys."
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if state.needsSelection {
                        Text("Choose where Babelfin saves your keys.")
                        HStack {
                            Spacer()
                            Button("Use Keychain") {
                                guard editsAllowed else { return }
                                storageMode = .keychain; state.needsSelection = false
                            }.disabled(!editsAllowed)
                            Button("Use This Mac (Recommended)") {
                                guard editsAllowed else { return }
                                storageMode = .localFile; state.needsSelection = false
                            }.buttonStyle(.borderedProminent).disabled(!editsAllowed)
                        }
                    } else {
                        Picker("Store keys in", selection: Binding(get: { storageMode }, set: { mode in
                            guard editsAllowed else { return }
                            storageMode = mode
                        })) {
                            ForEach(CredentialStorageMode.allCases) { Text($0.displayName).tag($0) }
                        }.disabled(!editsAllowed)
                    }
                    Text(storageNote)
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
                    // A row, not a section footer: the footer layout placed the last key row beside it.
                    Text("Use API keys from each provider's developer console. Consumer subscriptions do not include API usage.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("API keys") }
                UsageSection()
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
                        KeyCheckStore.shared.discardAll(storage: selected)
                        state.notice = result.notice; state.removalStorage = nil; state.refreshToken = UUID()
                        NotificationCenter.default.post(name: .babelfinCredentialMetadataChanged, object: nil)
                    }
                    Button("Cancel", role: .cancel) { state.removalStorage = nil }
                } message: {
                    Text("Remove all service keys from \(state.removalStorage?.displayName ?? storageMode.displayName)? Keys in the other storage location will remain.")
                }
        }
    }
}

/// Providers listed on the Accounts page. Adding a provider adds one row here.
struct AccountProvider: Identifiable {
    let service: ProviderService
    let title: String
    let keysPage: URL
    var id: ProviderService { service }
    static var all: [AccountProvider] { [
        AccountProvider(service: .openAI, title: "OpenAI", keysPage: URL(string: "https://platform.openai.com/api-keys")!),
        AccountProvider(service: .elevenLabs, title: "ElevenLabs", keysPage: URL(string: "https://elevenlabs.io/app/settings/api-keys")!),
        AccountProvider(service: .fish, title: "Fish Audio", keysPage: URL(string: "https://fish.audio/app/api-keys/")!),
        AccountProvider(service: .gemini, title: "Gemini", keysPage: URL(string: "https://aistudio.google.com/app/apikey")!),
        AccountProvider(service: .palabra, title: "Palabra", keysPage: URL(string: "https://platform.palabra.ai/")!),
    ] + (ProviderRegistry.azureAvailable ? [
        AccountProvider(service: .azure, title: "Azure", keysPage: URL(string: "https://portal.azure.com/#view/Microsoft_Azure_ProjectOxford/CognitiveServicesHub/~/SpeechServices")!)
    ] : []) }
}

/// Accounts › Azure endpoint: the Speech resource endpoint that the Azure key belongs to.
@MainActor final class AzureEndpointState: ObservableObject {
    @Published var text = AzureSettings.load()?.absoluteString ?? ""
    @Published var notice = ""
}
struct AzureEndpointSection: View {
    var editsAllowed: Bool
    @StateObject private var state = AzureEndpointState()
    var body: some View {
        Section {
            TextField("Endpoint", text: $state.text, prompt: Text("https://my-speech.cognitiveservices.azure.com/"))
            HStack {
                Spacer()
                if AzureSettings.load() != nil {
                    Button("Remove", role: .destructive) { AzureSettings.remove(); state.text = ""; state.notice = "Removed." }.disabled(!editsAllowed)
                }
                Button("Save") {
                    do { try AzureSettings.save(state.text); state.notice = "Saved." }
                    catch { state.notice = (error as? BridgeError)?.localizedDescription ?? "Enter a valid endpoint." }
                }.disabled(!editsAllowed || state.text.isEmpty)
            }
            if !state.notice.isEmpty { Text(state.notice).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("Azure Speech endpoint") } footer: {
            Text("Live Interpreter needs the endpoint of your Azure Speech resource as well as its key. Live Interpreter is available only in some regions, such as West Europe.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Accounts › Usage: counts per service since the last reset. Prices are on each service's page.
struct UsageSection: View {
    @ObservedObject private var store = UsageStore.shared
    private static let pricing: [ProviderService: String] = [
        .openAI: "https://openai.com/api/pricing/", .elevenLabs: "https://elevenlabs.io/pricing/api",
        .fish: "https://fish.audio/plan/", .gemini: "https://ai.google.dev/gemini-api/docs/pricing",
        .palabra: "https://palabra.ai/api", .azure: "https://azure.microsoft.com/pricing/details/speech/",
    ]
    var body: some View {
        Section {
            let used = ProviderService.allCases.filter { store.ledger.services[$0].map { !$0.isEmpty } ?? false }
            if used.isEmpty {
                Text("No usage recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(used, id: \.self) { service in
                    let usage = store.ledger.services[service] ?? ServiceUsage()
                    HStack(alignment: .firstTextBaseline) {
                        Text(service.displayName).frame(width: 110, alignment: .leading)
                        Text(Self.summary(usage)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let page = Self.pricing[service].flatMap(URL.init(string:)) {
                            Link("Pricing", destination: page).font(.callout)
                        }
                    }
                }
            }
            HStack {
                Text("Since \(store.ledger.since.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { store.reset() }.disabled(store.ledger.services.isEmpty)
            }
        } header: { Text("Usage") } footer: {
            Text("Counted on this Mac and never sent anywhere. Each service bills your own account by its own measures; see its pricing page and your account for exact charges.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    static func summary(_ usage: ServiceUsage) -> String {
        var parts: [String] = []
        if usage.audioSecondsSent > 0 { parts.append("\(minutes(usage.audioSecondsSent)) audio sent") }
        if usage.audioSecondsReceived > 0 { parts.append("\(minutes(usage.audioSecondsReceived)) speech received") }
        if usage.charactersTranslated > 0 { parts.append("\(usage.charactersTranslated.formatted()) characters translated") }
        if usage.charactersSpoken > 0 { parts.append("\(usage.charactersSpoken.formatted()) characters spoken") }
        return parts.joined(separator: " · ")
    }
    private static func minutes(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0f s", seconds) : String(format: "%.1f min", seconds / 60)
    }
}
