import Foundation

public enum TranslationRoute: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAI = "openai", elevenLabs = "elevenlabs", fish = "fish"
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .openAI: return "OpenAI"; case .elevenLabs: return "ElevenLabs"; case .fish: return "Fish Audio" }
    }
    public var requiredServices: Set<ProviderService> {
        switch self { case .openAI: return [.openAI]; case .elevenLabs: return [.openAI, .elevenLabs]; case .fish: return [.openAI, .elevenLabs, .fish] }
    }
}
public enum ProviderService: String, CaseIterable, Codable, Sendable { case openAI = "openai", elevenLabs = "elevenlabs", fish = "fish" }

/// In-memory secrets only: deliberately not Codable and never suitable for preferences.
public struct ProviderCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let values: [ProviderService: String]
    public init(openAI: String? = nil, elevenLabs: String? = nil, fish: String? = nil) {
        var values: [ProviderService: String] = [:]
        if let openAI { values[.openAI] = openAI }
        if let elevenLabs { values[.elevenLabs] = elevenLabs }
        if let fish { values[.fish] = fish }
        self.values = values
    }
    public func require(_ service: ProviderService) throws -> String {
        guard let value = values[service], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.unavailable("Save the required \(service.rawValue) credential in Settings.")
        }
        return value
    }
    public func validate(for route: TranslationRoute) throws {
        for service in route.requiredServices { _ = try require(service) }
    }
    public var description: String { "ProviderCredentials(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}
