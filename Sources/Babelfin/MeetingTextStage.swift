import Foundation
import BridgeCore

/// Text requests for clean-up, notes and questions: OpenAI Responses with `store: false`.
@MainActor final class MeetingTextStage {
    static let model = "gpt-5.6-luna"
    private let transport: any ProviderHTTPTransport
    private var operation: ProviderCancellation?
    init(transport: any ProviderHTTPTransport = URLProviderHTTPTransport()) { self.transport = transport }
    func complete(instructions: String, input: String, maximumOutput: Int, credentials: ProviderCredentials) async throws -> String {
        guard operation == nil else { throw ProviderNetworkError.busy }
        let token = ProviderCancellation(); operation = token; defer { operation = nil }
        var request = try providerJSONRequest(URL(string: "https://api.openai.com/v1/responses")!, body: [
            "model": Self.model, "store": false, "reasoning": ["effort": "low"], "max_output_tokens": maximumOutput,
            "instructions": instructions, "input": [["role": "user", "content": input]]
        ], header: "Authorization", credential: "Bearer \(try credentials.require(.openAI))")
        request.timeoutInterval = 300
        let response = try await transport.json(request, maximumBytes: 4 * 1_024 * 1_024)
        try token.check(); try Task.checkCancellation()
        guard response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else { throw ProviderNetworkError.invalidResponse }
        let text = output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderNetworkError.invalidResponse }
        return text
    }
    func cancel() { operation?.cancel(); transport.cancel() }
}
