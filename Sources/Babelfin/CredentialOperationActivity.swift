import Foundation
import Combine

/// Process-local leases prevent Accounts edits while tools/voice requests retain credentials.
/// Tokens remain active until the async body exits, including cancellation cleanup.
@MainActor final class CredentialOperationActivity: ObservableObject {
    static let shared = CredentialOperationActivity()
    @Published private(set) var active = false
    private var tokens = Set<UUID>()
    func begin() -> UUID {
        let token = UUID(); tokens.insert(token); active = true; return token
    }
    func end(_ token: UUID) {
        tokens.remove(token); active = !tokens.isEmpty
    }
}
