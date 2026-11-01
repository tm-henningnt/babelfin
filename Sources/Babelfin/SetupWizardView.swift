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
    @Published var allSpeak = false
    @Published var allListen = false
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
        Form {
            Section {
                Picker("I speak", selection: $state.userLanguage) { languageOptions }
                Picker("The meeting is in", selection: $state.meetingLanguage) { languageOptions }
            }
            suggestionSection(title: "Speak", from: userLanguage, to: meetingLanguage, suggestions: voiceSuggestions,
                              current: conversation.outgoing.route, choice: $state.voiceChoice, showsAll: $state.allSpeak)
            suggestionSection(title: "Listen", from: nil, to: userLanguage, suggestions: meetingSuggestions,
                              current: conversation.incoming.route, choice: $state.meetingChoice, showsAll: $state.allListen)
            Section {
                HStack {
                    Button("Manage Keys…", action: openAccounts)
                    Spacer()
                    if state.applied { Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Button("Use These Services", action: apply).keyboardShortcut(.defaultAction)
                        .disabled(conversation.locked || (selected(voiceSuggestions, voiceChoice, current: conversation.outgoing.route) == nil && selected(meetingSuggestions, meetingChoice, current: conversation.incoming.route) == nil))
                }
                if conversation.locked {
                    Label("Stop both directions to change services.", systemImage: "lock").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            state.userLanguage = conversation.incoming.targetLanguage
            state.meetingLanguage = conversation.outgoing.targetLanguage
        }
    }

    @ViewBuilder private var languageOptions: some View {
        ForEach(ProviderRegistry.allLanguages) { Text($0.name).tag($0.code) }
    }

    /// Without a choice, the route the direction uses now when it fits, else the first suggestion.
    private static func defaultID(_ suggestions: [RouteAdvisor.Suggestion], current: TranslationRoute) -> String? {
        suggestions.contains { $0.route.id == current.rawValue } ? current.rawValue : suggestions.first?.route.id
    }
    private func selected(_ suggestions: [RouteAdvisor.Suggestion], _ choice: String?, current: TranslationRoute) -> RouteAdvisor.Suggestion? {
        suggestions.first { $0.route.id == (choice ?? Self.defaultID(suggestions, current: current)) }
    }

    private func languageName(_ code: String?) -> String {
        code.flatMap { code in ProviderRegistry.allLanguages.first { $0.code == code }?.name } ?? "Any language"
    }

    @ViewBuilder private func suggestionSection(title: String, from: String?, to: String, suggestions: [RouteAdvisor.Suggestion],
                                                current: TranslationRoute, choice: Binding<String?>, showsAll: Binding<Bool>) -> some View {
        let chosen = selected(suggestions, choice.wrappedValue, current: current)
        let pick: (String) -> Void = { choice.wrappedValue = $0; state.applied = false }
        Section {
            if suggestions.isEmpty {
                Text(userLanguage == meetingLanguage ? "Both languages are the same. This direction needs no translation."
                     : "No service supports this language pair.")
                    .foregroundStyle(.secondary)
            } else if let chosen {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chosen.route.displayName).font(.title3.weight(.semibold))
                    if chosen.route.id == suggestions.first?.route.id {
                        Text("Suggested").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor, in: Capsule())
                    }
                    if chosen.route.id == current.rawValue {
                        Text("In use").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                }
                keys(chosen)
                let others = suggestions.filter { $0.route.id != chosen.route.id }.prefix(2)
                if !others.isEmpty {
                    HStack(spacing: 6) {
                        Text("Also good:").foregroundStyle(.secondary)
                        ForEach(Array(others), id: \.route.id) { other in
                            Button(other.route.displayName) { pick(other.route.id) }.buttonStyle(.link)
                        }
                        Spacer()
                    }
                }
                DisclosureGroup("All \(suggestions.count) services", isExpanded: showsAll) {
                    Picker(title, selection: Binding(get: { chosen.route.id }, set: pick)) {
                        ForEach(suggestions, id: \.route.id) { suggestion in
                            HStack {
                                Text(suggestion.route.displayName)
                                Text(status(suggestion)).foregroundStyle(.secondary)
                            }.tag(suggestion.route.id)
                        }
                    }.pickerStyle(.radioGroup).labelsHidden()
                }
            }
        } header: { Text("\(title) · \(languageName(from)) → \(languageName(to))") }
    }

    /// The keys the route needs, each marked as saved or missing.
    private func keys(_ suggestion: RouteAdvisor.Suggestion) -> some View {
        let services = ProviderService.allCases.filter { suggestion.route.services.contains($0) }
        return HStack(spacing: 12) {
            if services.isEmpty {
                Label("No key needed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            ForEach(services, id: \.self) { service in
                let missing = suggestion.missingServices.contains(service)
                    || suggestion.missingPermissions.contains { $0.service == service }
                Label(service.displayName, systemImage: missing ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(missing ? Color.orange : Color.green)
            }
            Spacer()
            if !suggestion.ready { Button("Add Key…", action: openAccounts) }
        }
    }

    private func status(_ suggestion: RouteAdvisor.Suggestion) -> String {
        let missing = suggestion.missingServices.map(\.displayName).sorted()
        if !missing.isEmpty { return "needs " + missing.joined(separator: " and ") }
        if !suggestion.missingPermissions.isEmpty { return "key lacks a permission" }
        return "ready"
    }

    private func apply() {
        if let voice = selected(voiceSuggestions, voiceChoice, current: conversation.outgoing.route) { conversation.outgoing.apply(voice) }
        if let meeting = selected(meetingSuggestions, meetingChoice, current: conversation.incoming.route) { conversation.incoming.apply(meeting) }
        state.applied = true
    }
}
