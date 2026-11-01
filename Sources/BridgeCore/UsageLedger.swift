import Foundation

/// How much each service was used, so users can relate it to their own bills. It holds counts
/// only, never prices, and stays on this Mac.
public struct ServiceUsage: Codable, Equatable, Sendable {
    public var audioSecondsSent = 0.0
    public var audioSecondsReceived = 0.0
    public var charactersTranslated = 0
    public var charactersSpoken = 0
    public init() {}
    public var isEmpty: Bool { audioSecondsSent == 0 && audioSecondsReceived == 0 && charactersTranslated == 0 && charactersSpoken == 0 }
}

public struct UsageLedger: Codable, Equatable, Sendable {
    public private(set) var since: Date
    public private(set) var services: [ProviderService: ServiceUsage] = [:]
    public init(since: Date) { self.since = since }

    /// Attributes audio to a route's stages: sent audio to the direct or recognition service,
    /// received speech to the direct or voice service.
    public mutating func addAudio(route: RouteDescriptor, secondsSent: Double, secondsReceived: Double) {
        if let service = route.stages.first?.service, secondsSent > 0 { services[service, default: .init()].audioSecondsSent += secondsSent }
        if let service = route.isDirect ? route.stages.first?.service : route.speechService, secondsReceived > 0 {
            services[service, default: .init()].audioSecondsReceived += secondsReceived
        }
    }
    /// Text of a composed route: recognized text goes to the translation service, translated
    /// text to the voice service when the translation is spoken. A translation server has no service.
    public mutating func addText(route: RouteDescriptor, recognized: Int, translated: Int, spoken: Bool) {
        guard !route.isDirect else { return }
        if let service = route.stages[1].service, recognized > 0 { services[service, default: .init()].charactersTranslated += recognized }
        if spoken, let service = route.speechService, translated > 0 { services[service, default: .init()].charactersSpoken += translated }
    }
    public mutating func reset(at date: Date) { since = date; services = [:] }
}
