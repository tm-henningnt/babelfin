import Foundation
import Security
import LocalAuthentication
import BridgeCore

enum KeychainStore {
    private static let revision = CredentialCacheRevision()
    static var credentialRevision: String { storageMode.rawValue + "/" + revision.value }
    static let storagePreferenceKey = "credentialStorageMode"
    static var storageMode: CredentialStorageMode {
        get { storageMode(in: .standard) }
        set { setStorageMode(newValue, in: .standard) }
    }
    static func storageMode(in defaults: UserDefaults) -> CredentialStorageMode {
        CredentialStorageMode(rawValue: defaults.string(forKey: storagePreferenceKey) ?? "") ?? .keychain
    }
    static let recommendedStorageMode: CredentialStorageMode = .localFile
    static func needsStorageSelection(in defaults: UserDefaults = .standard) -> Bool {
        CredentialStorageMode(rawValue: defaults.string(forKey: storagePreferenceKey) ?? "") == nil
    }
    /// The caller confirms a specific store before invoking this synchronous operation.
    /// Each deletion is independent so a failed provider does not hide successful removals.
    static func removeAll(storage: CredentialStorageMode,
                          remove: (ProviderService, CredentialStorageMode) throws -> Void = { try delete(for: $0, storage: $1) }) -> CredentialRemovalResult {
        var removed: [ProviderService] = [], failed: [ProviderService] = []
        for service in ProviderService.allCases {
            do { try remove(service, storage); removed.append(service) }
            catch { failed.append(service) }
        }
        return CredentialRemovalResult(removed: removed, failed: failed)
    }
    /// Selection only: never loads, migrates or deletes credentials in either location.
    static func setStorageMode(_ mode: CredentialStorageMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: storagePreferenceKey)
    }
    /// Presence only; never returns secret data or presents an authentication prompt.
    static func containsSavedKey(for provider: ProviderService = .openAI, storage: CredentialStorageMode? = nil,
                                 localStore: LocalCredentialStore = .defaultStore) -> Bool? {
        if (storage ?? storageMode) == .localFile { return localStore.containsSavedKey(for: provider) }
        var request = query(provider)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        return nil
    }
    // Stable legacy service: rebranding must keep the user’s existing saved key accessible.
    private static let service = "no.tallmaker.Babelfin"
    private static func query(_ provider: ProviderService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: provider == .openAI ? service : service + "." + provider.rawValue,
         kSecAttrAccount as String: provider == .openAI ? "openai-api-key" : "api-key"]
    }
    static func load(for provider: ProviderService = .openAI, storage: CredentialStorageMode? = nil,
                     localStore: LocalCredentialStore = .defaultStore) throws -> String {
        if (storage ?? storageMode) == .localFile { return try localStore.load(for: provider) }
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw BridgeError.unavailable("Save the required service key in Settings first. Keychain may ask for access.")
        }
        return key
    }
    static func save(_ raw: String, for provider: ProviderService = .openAI, storage: CredentialStorageMode? = nil,
                     localStore: LocalCredentialStore = .defaultStore) throws {
        if (storage ?? storageMode) == .localFile {
            try localStore.save(raw, for: provider); revision.changed(); return
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else {
            throw BridgeError.unavailable("Enter a valid API key.")
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(provider) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider).merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw BridgeError.unavailable("Could not save the API key to Keychain.")
            }
        } else if status != errSecSuccess {
            throw BridgeError.unavailable("Could not update the API key in Keychain.")
        }
        revision.changed()
    }
    static func delete(for provider: ProviderService = .openAI, storage: CredentialStorageMode? = nil,
                       localStore: LocalCredentialStore = .defaultStore) throws {
        if (storage ?? storageMode) == .localFile {
            try localStore.delete(for: provider); revision.changed(); return
        }
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BridgeError.unavailable("Could not remove the API key from Keychain.")
        }
        revision.changed()
    }
    static func credentials(for route: TranslationRoute) throws -> ProviderCredentials {
        let selectedStorage = storageMode
        switch route {
        case .openAI: return try ProviderCredentials(openAI: load(storage: selectedStorage))
        case .elevenLabs: return try ProviderCredentials(openAI: load(storage: selectedStorage), elevenLabs: load(for: .elevenLabs, storage: selectedStorage))
        case .fish: return try ProviderCredentials(openAI: load(storage: selectedStorage), elevenLabs: load(for: .elevenLabs, storage: selectedStorage), fish: load(for: .fish, storage: selectedStorage))
        }
    }
}

/// Non-secret, process-local invalidation; never persists a credential or changes user settings.
private final class CredentialCacheRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var token = UUID().uuidString
    var value: String { lock.lock(); defer { lock.unlock() }; return token }
    func changed() { lock.lock(); token = UUID().uuidString; lock.unlock() }
}

struct CredentialRemovalResult {
    let removed: [ProviderService]
    let failed: [ProviderService]
    var notice: String {
        if failed.isEmpty { return "Removed all saved keys from the selected storage." }
        return "Some keys could not be removed. Check the service rows and try again."
    }
}
