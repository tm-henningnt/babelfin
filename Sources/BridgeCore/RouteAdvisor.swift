import Foundation

/// Suggests routes for the setup wizard. Speak translates the user's language into the
/// meeting language; Listen translates the meeting into the user's language and detects
/// the input language automatically, assuming that the other participants speak one language.
public enum RouteAdvisor {
    public enum Direction: Sendable { case yourVoice, meetingAudio }

    public struct Suggestion: Sendable, Equatable {
        public let route: RouteDescriptor
        /// The input language to set, or nil for automatic detection.
        public let sourceLanguage: String?
        public let targetLanguage: String
        /// Accounts the route needs that the user has not saved yet.
        public let missingServices: Set<ProviderService>
        /// Permissions the route needs that a key check found missing on a saved key.
        public let missingPermissions: [KeyPermission]
        public var ready: Bool { missingServices.isEmpty && missingPermissions.isEmpty }
    }

    /// Routes that can serve the direction, best first. A route qualifies when it can speak the
    /// target language and either accepts the source language as a hint or detects it.
    /// Ranking: no missing accounts or permissions first; for Speak, routes that lock the input language
    /// next; then fewer accounts, then direct routes.
    public static func suggestions(direction: Direction, userLanguage: String, meetingLanguage: String?,
                                   savedServices: Set<ProviderService>, missingPermissions: Set<String> = [],
                                   routes: [RouteDescriptor] = ProviderRegistry.routes) -> [Suggestion] {
        let source: String?, target: String
        switch direction {
        case .yourVoice:
            guard let meetingLanguage else { return [] }
            source = userLanguage; target = meetingLanguage
        case .meetingAudio:
            source = nil; target = userLanguage
        }
        guard source != target else { return [] }
        let candidates: [Suggestion] = routes.compactMap { route in
            guard route.outputLanguages.contains(where: { $0.code == target }) else { return nil }
            var hint: String?
            if let source {
                if route.acceptsLanguageHint {
                    guard route.inputLanguages.contains(where: { $0.code == source }) else { return nil }
                    hint = source
                } else if !route.stages[0].detectsLanguage {
                    return nil
                }
            } else if !route.stages[0].detectsLanguage {
                return nil
            }
            return Suggestion(route: route, sourceLanguage: hint, targetLanguage: target,
                              missingServices: route.services.subtracting(savedServices),
                              missingPermissions: KeyPermissions.needed(by: route).filter { missingPermissions.contains($0.id) })
        }
        return candidates.sorted { a, b in
            if a.ready != b.ready { return a.ready }
            if (a.sourceLanguage != nil) != (b.sourceLanguage != nil) { return a.sourceLanguage != nil }
            if a.route.services.count != b.route.services.count { return a.route.services.count < b.route.services.count }
            if a.route.isDirect != b.route.isDirect { return a.route.isDirect }
            return a.route.id < b.route.id
        }
    }
}
