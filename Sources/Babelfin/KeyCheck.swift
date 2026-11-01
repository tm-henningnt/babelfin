import Foundation
import BridgeCore

/// The latest check per saved key, kept in preferences because a report holds no secret.
/// Saving or removing a key discards its report.
@MainActor final class KeyCheckStore: ObservableObject {
    static let shared = KeyCheckStore()
    private static let preferenceKey = "babelfin.keyChecks"
    @Published private(set) var reports: [String: KeyCheckReport]
    @Published private(set) var checking: Set<ProviderService> = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reports = defaults.data(forKey: Self.preferenceKey).flatMap { try? JSONDecoder().decode([String: KeyCheckReport].self, from: $0) } ?? [:]
    }

    private static func slot(_ service: ProviderService, _ storage: CredentialStorageMode) -> String { storage.rawValue + "." + service.rawValue }

    func report(for service: ProviderService, storage: CredentialStorageMode = KeychainStore.storageMode) -> KeyCheckReport? {
        reports[Self.slot(service, storage)]
    }
    /// Permission IDs that checks of the saved keys found missing.
    func missingPermissions(storage: CredentialStorageMode = KeychainStore.storageMode) -> Set<String> {
        Set(ProviderService.allCases.flatMap { report(for: $0, storage: storage)?.missing.map(\.id) ?? [] })
    }

    func discard(_ service: ProviderService, storage: CredentialStorageMode) {
        reports[Self.slot(service, storage)] = nil; persist()
    }
    func discardAll(storage: CredentialStorageMode) {
        for service in ProviderService.allCases { reports[Self.slot(service, storage)] = nil }
        persist()
    }

    /// Checks the saved key, or `key` when the caller just saved it. Returns nil when no key
    /// is saved or the check is already running.
    @discardableResult
    func check(_ service: ProviderService, storage: CredentialStorageMode = KeychainStore.storageMode, key: String? = nil) async -> KeyCheckReport? {
        guard !checking.contains(service), let key = key ?? (try? KeychainStore.load(for: service, storage: storage)) else { return nil }
        checking.insert(service); defer { checking.remove(service) }
        let report = await KeyChecker.check(service, key: key)
        reports[Self.slot(service, storage)] = report; persist()
        return report
    }

    /// Checks each saved key that the route uses and names the missing permissions, if any.
    func diagnose(_ route: TranslationRoute) async -> String? {
        let needed = KeyPermissions.needed(by: ProviderRegistry.route(route))
        var missing: [KeyPermission] = [], rejected: [ProviderService] = []
        for service in Set(needed.map(\.service)).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let report = await check(service) else { continue }
            if report.keyRejected { rejected.append(service); continue }
            missing += report.missing.filter { needed.contains($0) }
        }
        var parts: [String] = []
        if !rejected.isEmpty { parts.append("\(rejected.map(\.displayName).joined(separator: " and ")) did not accept the saved key.") }
        if !missing.isEmpty {
            parts.append("The saved key lacks " + missing.map { "\($0.service.displayName) \($0.name)" }.joined(separator: " and ") + ".")
        }
        guard !parts.isEmpty else { return nil }
        return (parts + ["Fix the key in the provider's settings, then save it again in Settings › Accounts."]).joined(separator: " ")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(reports) { defaults.set(data, forKey: Self.preferenceKey) }
    }
}

extension KeyCheckReport {
    /// One line for Settings: the result per permission, in the provider's own names.
    var summary: String {
        if keyRejected { return "\(service.displayName) did not accept this key. Check that you copied all of it." }
        let permissions = KeyPermissions.for(service)
        let missing = missing
        let unknown = permissions.filter { if case .unknown? = outcomes[$0.id] { return true } else { return false } }
        var lines: [String] = []
        if missing.isEmpty && unknown.isEmpty {
            lines.append(permissions.count == 1 ? "The key works." : "The key has every permission Babelfin uses: \(permissions.map(\.name).joined(separator: ", ")).")
        }
        for permission in missing {
            var line = "Missing: \(permission.name), needed for \(permission.purpose)."
            if case .missing(let scope?)? = outcomes[permission.id], scope.lowercased() != permission.name.lowercased() { line += " The service calls it \(scope)." }
            lines.append(line)
        }
        for permission in unknown {
            if case .unknown(let reason)? = outcomes[permission.id] { lines.append("Not checked: \(permission.name). \(reason)") }
        }
        return lines.joined(separator: "\n")
    }
}
