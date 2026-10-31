import Foundation
import BridgeCore

@main struct Checks {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4, let url = URL(string: args[2]) else { exit(2) }
        let send: @Sendable (String) async throws -> Void
        let receive: @Sendable () async throws -> Data
        let cancel: @Sendable () -> Void
        let limit = args[1] == "openai" ? 400_000 : 65_536
        if args[1] == "openai" {
            let socket = URLTranslationWebSocket(testURL: url)
            guard socket.messageLimitForChecks == 400_000 else { exit(3) }
            send = { try await socket.send($0) }; receive = { try await socket.receive() }; cancel = { socket.cancel() }
        } else {
            var request = URLRequest(url: url)
            request.setValue("synthetic-fixture", forHTTPHeaderField: "xi-api-key")
            let socket = URLProviderWebSocket(request: request)
            guard socket.messageLimitForChecks == 65_536 else { exit(3) }
            send = { try await socket.send($0) }; receive = { try await socket.receive() }; cancel = { socket.cancel() }
        }
        let watchdog = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { cancel() } }
        defer { watchdog.cancel(); cancel() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await send("hello")
            let reply = try await receive()
            let valid = (args[3] == "echo" && String(data: reply, encoding: .utf8) == "hello") ||
                (args[3] == "large" && reply.count == limit && reply.allSatisfy { $0 == 120 })
            guard valid else { exit(1) }
            print("PASS: echo and cancellation")
        } catch {
            guard args[3] == "refuse", error is SocketTransportError, ProcessInfo.processInfo.systemUptime - started < 2.5 else { print("FAIL: positive control"); exit(1) }
            print("PASS: refused without exposing response or credential")
        }
    }
}
