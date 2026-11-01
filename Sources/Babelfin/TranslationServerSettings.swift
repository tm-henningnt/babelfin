import Foundation
import SwiftUI
import BridgeCore

/// The user's OpenAI-compatible translation server, such as a local Ollama or LM Studio
/// server. The base URL and model name are not secret and live in UserDefaults. While a
/// server is saved, the registry offers the "with your translation server" routes.
enum TranslationServerSettings {
    static let baseURLKey = "babelfin.translationServer.baseURL"
    static let modelKey = "babelfin.translationServer.model"

    static func load(_ defaults: UserDefaults = .standard) -> OpenAICompatibleTextTranslationStage.Endpoint? {
        guard let url = defaults.string(forKey: baseURLKey), let model = defaults.string(forKey: modelKey) else { return nil }
        return try? .init(baseURL: url, model: model)
    }
    /// Validates before it saves, so a saved server always loads.
    static func save(baseURL: String, model: String, defaults: UserDefaults = .standard) throws {
        let endpoint = try OpenAICompatibleTextTranslationStage.Endpoint(baseURL: baseURL, model: model)
        defaults.set(endpoint.baseURL.absoluteString, forKey: baseURLKey)
        defaults.set(endpoint.model, forKey: modelKey)
        applyToRegistry(defaults)
    }
    static func remove(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: baseURLKey); defaults.removeObject(forKey: modelKey)
        applyToRegistry(defaults)
    }
    static func applyToRegistry(_ defaults: UserDefaults = .standard) {
        ProviderRegistry.translationServerAvailable = load(defaults) != nil
    }
}

/// Stands in for a server stage when the server was removed after the route was chosen.
@MainActor final class UnconfiguredTextTranslationStage: TextTranslationStage {
    func translate(text: String, sourceLanguage: String?, targetLanguage: String, credentials: ProviderCredentials) async throws -> String {
        throw BridgeError.unavailable("Set up your translation server in Settings › Accounts, or choose another service.")
    }
    func cancel() {}
}

@MainActor final class TranslationServerState: ObservableObject {
    @Published var baseURL = TranslationServerSettings.load()?.baseURL.absoluteString ?? ""
    @Published var model = TranslationServerSettings.load()?.model ?? ""
    @Published var notice = ""
    @Published var testing = false
    var saved: Bool { TranslationServerSettings.load() != nil }
}

/// Accounts › Translation server: base URL, model, Test, Save and Remove.
struct TranslationServerSection: View {
    var editsAllowed: Bool
    @StateObject private var state = TranslationServerState()
    var body: some View {
        Section {
            TextField("Base URL", text: $state.baseURL, prompt: Text("http://localhost:11434/v1"))
            TextField("Model", text: $state.model, prompt: Text("llama3.1:8b"))
            HStack {
                Button("Test") { Task { await test() } }.disabled(state.testing || state.baseURL.isEmpty || state.model.isEmpty)
                Spacer()
                if state.saved { Button("Remove", role: .destructive) { remove() }.disabled(!editsAllowed) }
                Button("Save") { save() }.disabled(!editsAllowed || state.baseURL.isEmpty || state.model.isEmpty)
            }
            if !state.notice.isEmpty { Text(state.notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        } header: { Text("Translation server (optional)") } footer: {
            Text("An OpenAI-compatible server, for example Ollama or LM Studio, can translate the text for the ElevenLabs and Fish Audio routes. Babelfin sends the recognized text to this server. Plain HTTP is allowed only for this Mac and .local hosts. After you save, choose a service “with your translation server”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func save() {
        do {
            try TranslationServerSettings.save(baseURL: state.baseURL, model: state.model)
            state.notice = "Saved. The services “with your translation server” are now available."
            state.objectWillChange.send()
        } catch { state.notice = "Enter an http(s) base URL without a user name or query, and a model name of letters, digits, . _ : / or -." }
    }
    private func remove() {
        TranslationServerSettings.remove()
        state.notice = "Removed. Directions that used your translation server need another service."
        state.objectWillChange.send()
    }
    private func test() async {
        state.testing = true; defer { state.testing = false }
        do {
            let endpoint = try OpenAICompatibleTextTranslationStage.Endpoint(baseURL: state.baseURL, model: state.model)
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await OpenAICompatibleTextTranslationStage(endpoint: endpoint)
                .translate(text: "God morgen, og velkommen til møtet.", sourceLanguage: "no", targetLanguage: "en", credentials: ProviderCredentials())
            state.notice = String(format: "The server answered in %.1f s: “%@”", ProcessInfo.processInfo.systemUptime - started, String(result.prefix(120)))
        } catch {
            state.notice = "The test failed. " + TranslationFailureReason(error: error).safeSummary
        }
    }
}
