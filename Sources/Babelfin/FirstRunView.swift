import AppKit
import SwiftUI
import BridgeCore

enum FirstRunPreferences {
    /// Set when the user finishes or skips the setup assistant.
    static let done = "babelfin.firstRun.done.v1"
    /// Only a new user sees the assistant at launch: not finished or skipped, and no key saved.
    @MainActor static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: done)
            && !ProviderService.allCases.contains { KeychainStore.containsSavedKey(for: $0) == true }
    }
}

extension AppModel {
    /// Uses a suggested route. The route goes first: changing it can reset values the new route does not support.
    func apply(_ suggestion: RouteAdvisor.Suggestion) {
        guard let route = TranslationRoute(rawValue: suggestion.route.id) else { return }
        self.route = route
        sourceLanguage = route.descriptor.acceptsLanguageHint ? (suggestion.sourceLanguage ?? "") : ""
        targetLanguage = suggestion.targetLanguage
    }
}

@MainActor private final class FirstRunState: ObservableObject {
    enum Step: Int, CaseIterable {
        case languages, services, devices
        var title: String {
            switch self {
            case .languages: return "Languages"
            case .services: return "Services"
            case .devices: return "Audio"
            }
        }
    }
    @Published var step = Step.languages
    @Published var userLanguage: String
    @Published var meetingLanguage = "en"
    /// Changes when the window becomes key, so key presence is read again after Settings.
    @Published var keysRevision = UUID()
    init() {
        let preferred = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let code = preferred == "nb" || preferred == "nn" ? "no" : preferred
        userLanguage = ProviderRegistry.allLanguages.contains { $0.code == code } ? code : "en"
    }
}

/// The setup assistant: languages, then services and keys, then audio devices.
struct FirstRunView: View {
    @ObservedObject var conversation: ConversationModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var state = FirstRunState()
    @ObservedObject private var checks = KeyCheckStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            steps
            switch state.step {
            case .languages: languages
            case .services: services
            case .devices: devices
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(width: 640, height: 540)
        .modifier(NoFocusRing())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in state.keysRevision = UUID() }
    }

    private var steps: some View {
        HStack(spacing: 8) {
            ForEach(FirstRunState.Step.allCases, id: \.self) { step in
                if step != .languages { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Text("\(step.rawValue + 1)  \(step.title)")
                    .font(.callout.weight(step == state.step ? .semibold : .regular))
                    .foregroundStyle(step.rawValue <= state.step.rawValue ? Color.primary : Color.secondary)
            }
        }
    }

    // MARK: Step 1

    private var languages: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which languages?").font(.largeTitle.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("I speak").gridColumnAlignment(.trailing)
                    Picker("I speak", selection: $state.userLanguage) { languageOptions }.labelsHidden().frame(width: 220)
                }
                GridRow {
                    Text("The meeting is in")
                    Picker("The meeting is in", selection: $state.meetingLanguage) { languageOptions }.labelsHidden().frame(width: 220)
                }
            }
            .font(.title3)
            .padding(.vertical, 8)
            Text("Speak translates you into the meeting language. Listen translates the meeting into yours.")
                .foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var languageOptions: some View {
        ForEach(ProviderRegistry.allLanguages) { Text($0.name).tag($0.code) }
    }

    // MARK: Step 2

    private var saved: Set<ProviderService> {
        _ = state.keysRevision
        return Set(ProviderService.allCases.filter { KeychainStore.containsSavedKey(for: $0) == true })
    }
    /// A ready route first. Without one, the routes Help recommends: a voice you choose for Speak,
    /// a direct service that follows each speaker for Listen.
    private func suggestion(_ direction: RouteAdvisor.Direction) -> RouteAdvisor.Suggestion? {
        let cloud = RouteAdvisor.suggestions(direction: direction, userLanguage: state.userLanguage, meetingLanguage: state.meetingLanguage,
                                             savedServices: saved, missingPermissions: checks.missingPermissions())
            .filter { $0.route.id != TranslationRoute.appleLocal.rawValue }
        if let ready = cloud.first(where: \.ready) { return ready }
        let preferred: [TranslationRoute] = direction == .yourVoice ? [.elevenLabs, .fish] : [.gemini, .openAI]
        return preferred.lazy.compactMap { route in cloud.first { $0.route.id == route.rawValue } }.first ?? cloud.first
    }
    private func onThisMac(_ direction: RouteAdvisor.Direction) -> RouteAdvisor.Suggestion? {
        RouteAdvisor.suggestions(direction: direction, userLanguage: state.userLanguage, meetingLanguage: state.meetingLanguage,
                                 savedServices: saved).first { $0.route.id == TranslationRoute.appleLocal.rawValue }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add the keys for your services").font(.largeTitle.weight(.semibold))
            serviceCard("Speak", suggestion(.yourVoice))
            serviceCard("Listen", suggestion(.meetingAudio))
            if onThisMac(.yourVoice) != nil || onThisMac(.meetingAudio) != nil {
                card {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No keys yet?").font(.headline)
                        Text("On this Mac works with no account and sends nothing, at a lower quality.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use On This Mac") { useOnThisMac() }
                }
            }
        }
    }
    private func serviceCard(_ title: String, _ suggestion: RouteAdvisor.Suggestion?) -> some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion.map { "\(title) with \($0.route.displayName)" } ?? "\(title): no service for these languages").font(.headline)
                if let suggestion {
                    HStack(spacing: 12) {
                        ForEach(ProviderService.allCases.filter { suggestion.route.services.contains($0) }, id: \.self) { service in
                            let missing = suggestion.missingServices.contains(service)
                            Label(service.displayName, systemImage: missing ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(missing ? Color.orange : Color.green)
                        }
                    }
                }
            }
            Spacer()
            if suggestion?.ready == false {
                OpenSettingsButton(destination: .accounts, title: "Add Key…")
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) { content() }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
    private func useOnThisMac() {
        if let speak = onThisMac(.yourVoice) { conversation.outgoing.apply(speak) }
        if let listen = onThisMac(.meetingAudio) { conversation.incoming.apply(listen) }
        state.step = .devices
    }

    // MARK: Step 3

    private var devices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your audio devices").font(.largeTitle.weight(.semibold))
            Form {
                deviceSection(conversation.outgoing, incoming: false)
                deviceSection(conversation.incoming, incoming: true)
            }
            .formStyle(.grouped)
            .onAppear { conversation.outgoing.refresh(); conversation.incoming.refresh() }
        }
    }
    private func deviceSection(_ model: AppModel, incoming: Bool) -> some View {
        let rows = DeviceRows(model: model, incoming: incoming)
        return Section {
            rows
        } header: { Text(incoming ? "Listen" : "Speak") } footer: {
            Text(rows.help).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            Button("Set Up Later") { finish() }
            Spacer()
            if state.step != .languages {
                Button("Back") { state.step = FirstRunState.Step(rawValue: state.step.rawValue - 1) ?? .languages }
            }
            Button(state.step == .devices ? "Finish" : "Continue") { next() }
                .keyboardShortcut(.defaultAction)
        }
    }
    private func next() {
        switch state.step {
        case .languages:
            state.step = .services
        case .services:
            if let speak = suggestion(.yourVoice), !conversation.outgoing.locked { conversation.outgoing.apply(speak) }
            if let listen = suggestion(.meetingAudio), !conversation.incoming.locked { conversation.incoming.apply(listen) }
            state.step = .devices
        case .devices:
            finish()
        }
    }
    private func finish() {
        UserDefaults.standard.set(true, forKey: FirstRunPreferences.done)
        MainNavigation.open(.home, openWindow: openWindow)
        for window in NSApp.windows where window.identifier?.rawValue == "welcome" { window.close() }
    }
}
