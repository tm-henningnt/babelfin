import SwiftUI
import BridgeCore

/// Language setup: the user names their language and the meeting language, and Babelfin
/// suggests a service for each direction from the services that support the pair and the
/// keys already saved. Speak locks the user's language when the service allows it;
/// Listen detects the input language.
@MainActor private final class SetupWizardState: ObservableObject {
    @Published var userLanguage = "en" { didSet { reset() } }
    @Published var meetingLanguage = "en" { didSet { reset() } }
    @Published var voiceChoice: String?
    @Published var meetingChoice: String?
    @Published var applied = false
    private func reset() { voiceChoice = nil; meetingChoice = nil; applied = false }
}

struct SetupWizardView: View {
    @ObservedObject var conversation: ConversationModel
    var openAccounts: () -> Void = {}
    @StateObject private var state = SetupWizardState()
    @ObservedObject private var checks = KeyCheckStore.shared
    private var userLanguage: String { state.userLanguage }
    private var meetingLanguage: String { state.meetingLanguage }
    private var voiceChoice: String? { state.voiceChoice }
    private var meetingChoice: String? { state.meetingChoice }

    private var saved: Set<ProviderService> {
        Set(ProviderService.allCases.filter { KeychainStore.containsSavedKey(for: $0) == true })
    }
    private var voiceSuggestions: [RouteAdvisor.Suggestion] {
        RouteAdvisor.suggestions(direction: .yourVoice, userLanguage: userLanguage, meetingLanguage: meetingLanguage, savedServices: saved, missingPermissions: checks.missingPermissions())
    }
    private var meetingSuggestions: [RouteAdvisor.Suggestion] {
        RouteAdvisor.suggestions(direction: .meetingAudio, userLanguage: userLanguage, meetingLanguage: meetingLanguage, savedServices: saved, missingPermissions: checks.missingPermissions())
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeading(title: "Language setup", detail: "Choose your language and the meeting language. Babelfin suggests a service for each direction.")
            Form {
                Section {
                    Picker("You speak", selection: $state.userLanguage) { languageOptions }
                    Picker("The meeting is in", selection: $state.meetingLanguage) { languageOptions }
                } footer: {
                    Text("Listen detects the language that others speak, so it also works if someone switches language.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                suggestionSection(title: "Speak", detail: "Translates your speech into the meeting language. ElevenLabs and Fish Audio let you choose the voice that speaks for you.",
                                  suggestions: voiceSuggestions, choice: $state.voiceChoice)
                suggestionSection(title: "Listen", detail: "Translates the meeting into your language. A direct service such as OpenAI follows the voice of each speaker.",
                                  suggestions: meetingSuggestions, choice: $state.meetingChoice)
                Section {
                    HStack {
                        Button("Manage API keys…", action: openAccounts)
                        Spacer()
                        if state.applied { Label("Applied", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                        Button("Apply", action: apply).keyboardShortcut(.defaultAction)
                            .disabled(conversation.locked || (selected(voiceSuggestions, voiceChoice) == nil && selected(meetingSuggestions, meetingChoice) == nil))
                    }
                    if conversation.locked {
                        Label("Stop both directions to apply a new setup.", systemImage: "lock").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
        }
        .onAppear {
            state.userLanguage = conversation.incoming.targetLanguage
            state.meetingLanguage = conversation.outgoing.targetLanguage
        }
    }

    @ViewBuilder private var languageOptions: some View {
        ForEach(ProviderRegistry.allLanguages) { Text($0.name).tag($0.code) }
    }

    private func selected(_ suggestions: [RouteAdvisor.Suggestion], _ choice: String?) -> RouteAdvisor.Suggestion? {
        suggestions.first { $0.route.id == (choice ?? suggestions.first?.route.id) }
    }

    @ViewBuilder private func suggestionSection(title: String, detail: String, suggestions: [RouteAdvisor.Suggestion],
                                                choice: Binding<String?>) -> some View {
        Section {
            if suggestions.isEmpty {
                Text(userLanguage == meetingLanguage ? "Both languages are the same, so this direction needs no translation."
                     : "No service supports this language pair yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker(title, selection: Binding(get: { choice.wrappedValue ?? suggestions.first?.route.id ?? "" },
                                                 set: { choice.wrappedValue = $0; state.applied = false })) {
                    ForEach(suggestions, id: \.route.id) { suggestion in
                        Text(label(suggestion)).tag(suggestion.route.id)
                    }
                }.pickerStyle(.radioGroup).labelsHidden()
            }
        } header: { Text(title) } footer: { Text(detail).font(.caption).foregroundStyle(.secondary) }
    }

    private func label(_ suggestion: RouteAdvisor.Suggestion) -> String {
        let language = suggestion.sourceLanguage == nil ? "detects the input language" : "fixed to your language"
        let missing = suggestion.missingServices.map(\.displayName).sorted()
        let lacking = suggestion.missingPermissions.map { "\($0.service.displayName) \($0.name)" }
        let status = !missing.isEmpty ? "needs a key for " + missing.joined(separator: " and ")
            : !lacking.isEmpty ? "the key lacks " + lacking.joined(separator: " and ") : "ready"
        return "\(suggestion.route.displayName) — \(language), \(status)"
    }

    private func apply() {
        if let voice = selected(voiceSuggestions, voiceChoice), let route = TranslationRoute(rawValue: voice.route.id) {
            configure(conversation.outgoing, route: route, source: voice.sourceLanguage, target: voice.targetLanguage)
        }
        if let meeting = selected(meetingSuggestions, meetingChoice), let route = TranslationRoute(rawValue: meeting.route.id) {
            configure(conversation.incoming, route: route, source: meeting.sourceLanguage, target: meeting.targetLanguage)
        }
        state.applied = true
    }

    /// The route first: changing it can reset values that the new route does not support.
    private func configure(_ model: AppModel, route: TranslationRoute, source: String?, target: String) {
        model.route = route
        model.sourceLanguage = route.descriptor.acceptsLanguageHint ? (source ?? "") : ""
        model.targetLanguage = target
    }
}
