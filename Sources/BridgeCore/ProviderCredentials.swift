import Foundation

/// A route that a direction uses, identified by its registry ID. The set of routes is open:
/// `allCases` lists the routes that `ProviderRegistry` knows, and an unknown ID does not decode.
public struct TranslationRoute: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard ProviderRegistry.routes.contains(where: { $0.id == rawValue }) else { return nil }
        self.rawValue = rawValue
    }
    private init(registered id: String) { rawValue = id }
    public static let openAI = TranslationRoute(registered: "openai")
    public static let elevenLabs = TranslationRoute(registered: "elevenlabs")
    public static let fish = TranslationRoute(registered: "fish")
    public static let gemini = TranslationRoute(registered: "gemini")
    public static let palabra = TranslationRoute(registered: "palabra")
    public static let azure = TranslationRoute(registered: "azure")
    public static var allCases: [TranslationRoute] { ProviderRegistry.routes.map { TranslationRoute(registered: $0.id) } }
    public var id: String { rawValue }
    public var descriptor: RouteDescriptor { ProviderRegistry.route(self) }
    public var displayName: String { descriptor.displayName }
    public var requiredServices: Set<ProviderService> { descriptor.services }
}
public enum ProviderService: String, CaseIterable, Codable, Sendable {
    case openAI = "openai", elevenLabs = "elevenlabs", fish = "fish", gemini = "gemini", palabra = "palabra", azure = "azure"
}

/// In-memory secrets only: deliberately not Codable and never suitable for preferences.
public struct ProviderCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let values: [ProviderService: String]
    public init(openAI: String? = nil, elevenLabs: String? = nil, fish: String? = nil, gemini: String? = nil, palabra: String? = nil, azure: String? = nil) {
        var values: [ProviderService: String] = [:]
        if let openAI { values[.openAI] = openAI }
        if let elevenLabs { values[.elevenLabs] = elevenLabs }
        if let fish { values[.fish] = fish }
        if let gemini { values[.gemini] = gemini }
        if let palabra { values[.palabra] = palabra }
        if let azure { values[.azure] = azure }
        self.values = values
    }
    /// One key per service, for code that loads the keys of a route's services.
    public init(_ keys: [ProviderService: String]) { values = keys }
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
