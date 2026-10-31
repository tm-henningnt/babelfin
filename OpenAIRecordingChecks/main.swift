import Foundation
import BridgeCore

private struct CheckFailure: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}
private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func change(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}

private final class FakeHTTP: ProviderHTTPTransport, @unchecked Sendable {
    struct Call { let request: URLRequest; let maximumBytes: Int; let contentTypes: Set<String> }
    let calls = Locked<[Call]>([])
    let cancellationCount = Locked(0), waiting = Locked(false), cancelled = Locked(false)
    let payload: Data
    let failure: (any Error & Sendable)?
    let returnAfterCancellation: Bool
    init(_ payload: Data = Data(), failure: (any Error & Sendable)? = nil, returnAfterCancellation: Bool = false) {
        self.payload = payload; self.failure = failure; self.returnAfterCancellation = returnAfterCancellation
    }
    func stream(_ request: URLRequest, maximumBytes: Int, contentTypes: Set<String>,
                onChunk: @escaping @Sendable (Data) async throws -> Void) async throws {
        calls.change { $0.append(Call(request: request, maximumBytes: maximumBytes, contentTypes: contentTypes)) }
        while waiting.get(), !cancelled.get() {
            // Deliberately ignore task cancellation: the adapter must also cancel its transport.
            do { try await Task.sleep(nanoseconds: 1_000_000) } catch { await Task.yield() }
        }
        if cancelled.get(), !returnAfterCancellation { throw ProviderNetworkError.cancelled }
        if let failure { throw failure }
        // Deliberately do not enforce maximumBytes; exercise the adapter's independent buffer bound.
        for offset in stride(from: 0, to: payload.count, by: 733) {
            try await onChunk(payload.subdata(in: offset..<min(payload.count, offset + 733)))
        }
    }
    func cancel() { cancellationCount.change { $0 += 1 }; cancelled.change { $0 = true } }
}

@main private struct OpenAIRecordingChecks {
    @MainActor static func main() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("private-person-name.WAV")
            try Data([0, 1, 2, 255, 13, 10]).write(to: file)
            try await wireChecks(file)
            try await preflightChecks(file, directory: directory)
            try await transcriptChecks(file)
            try await responseBoundsChecks(file)
            try await cancellationChecks(file)
            try await errorChecks(file)
            print("PASS: 12 OpenAI recording check groups (offline synthetic transport; no credentials or hardware)")
        } catch let error as CheckFailure {
            fputs("FAIL: \(error.message)\n", stderr); exit(1)
        } catch {
            fputs("FAIL: unexpected check error\n", stderr); exit(1)
        }
    }

    @MainActor private static func wireChecks(_ file: URL) async throws {
        let http = FakeHTTP(try json(["text": " Hei, verden!\n", "languages": [["code": "no"]]]))
        let adapter = OpenAIRecordingTranscriber(transport: http)
        try expect(adapter.requiredServices == [.openAI], "Only OpenAI is required")
        let transcript = try await adapter.transcribe(fileURL: file, sourceLanguage: "no", diarize: false,
            credentials: .init(openAI: "synthetic-openai", elevenLabs: "synthetic-eleven", fish: "synthetic-fish"))
        let calls = http.calls.get()
        try expect(calls.count == 1, "Exactly one request")
        let request = calls[0].request
        try expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions" && request.httpMethod == "POST", "Current file endpoint")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-openai", "OpenAI authorization")
        try expect(request.value(forHTTPHeaderField: "xi-api-key") == nil, "No unrelated authorization")
        let body = request.httpBody ?? Data()
        let text = String(decoding: body, as: UTF8.self)
        try expect(text.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"), "Current model multipart field")
        try expect(text.contains("name=\"languages[]\"\r\n\r\nno\r\n"), "Current plural language hint")
        try expect(!text.contains("name=\"language\"") && !text.contains("response_format") && !text.contains("diarize"), "No legacy file options")
        try expect(text.contains("filename=\"recording.wav\"") && text.contains("Content-Type: audio/wav"), "Generic filename and MIME type")
        try expect(!text.contains("private-person") && !text.contains("synthetic-"), "No filename or key leakage into multipart")
        try expect(body.range(of: Data([0, 1, 2, 255, 13, 10])) != nil, "Binary file data survives multipart encoding")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let boundary = contentType.replacingOccurrences(of: "multipart/form-data; boundary=", with: "")
        try expect(contentType.hasPrefix("multipart/form-data; boundary=") && text.hasSuffix("\r\n--\(boundary)--\r\n"), "Multipart boundary completes")
        try expect(calls[0].maximumBytes == 2 * 1_024 * 1_024 && calls[0].contentTypes == ["application/json"], "Bounded JSON transport")
        try expect(transcript.sourceLanguage == "no" && transcript.segments.map(\.sourceText).joined() == " Hei, verden!\n", "Response language and whitespace retained")
        try expect(transcript.segments.allSatisfy { $0.speaker == nil && $0.startSeconds == nil && $0.endSeconds == nil && $0.translatedText == nil }, "No invented provenance")
        print("PASS: actual adapter endpoint, multipart, credential isolation and plain JSON")
    }

    @MainActor private static func preflightChecks(_ file: URL, directory: URL) async throws {
        let http = FakeHTTP(), adapter = OpenAIRecordingTranscriber(transport: http)
        do {
            _ = try await adapter.transcribe(fileURL: file, sourceLanguage: nil, diarize: true, credentials: .init(openAI: "synthetic"))
            throw CheckFailure(message: "Unsupported diarization accepted")
        } catch ProviderNetworkError.invalidRequest { }
        do {
            _ = try await adapter.transcribe(fileURL: file, sourceLanguage: "no\r\nInjected", diarize: false, credentials: .init(openAI: "synthetic"))
            throw CheckFailure(message: "Invalid language accepted")
        } catch ProviderNetworkError.invalidRequest { }
        do {
            _ = try await adapter.transcribe(fileURL: file, sourceLanguage: nil, diarize: false, credentials: .init(elevenLabs: "synthetic"))
            throw CheckFailure(message: "Missing OpenAI key accepted")
        } catch is BridgeError { }
        try expect(http.calls.get().isEmpty, "Unsupported options and missing key rejected before upload")
        print("PASS: diarization, hint and required-key preflight")

        let empty = directory.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        let link = directory.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let huge = directory.appendingPathComponent("large.wav")
        try Data().write(to: huge)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(SpeechToolsLimits.recordingBytes + 1)); try handle.close()
        for url in [empty, link, directory.appendingPathComponent("missing.wav"), URL(string: "https://example.invalid/private.wav")!] {
            do {
                _ = try await adapter.transcribe(fileURL: url, sourceLanguage: nil, diarize: false, credentials: .init(openAI: "synthetic"))
                throw CheckFailure(message: "Invalid local recording accepted")
            } catch SpeechToolsError.invalidRecording { }
        }
        do {
            _ = try await adapter.transcribe(fileURL: huge, sourceLanguage: nil, diarize: false, credentials: .init(openAI: "synthetic"))
            throw CheckFailure(message: "Oversized recording accepted")
        } catch SpeechToolsError.recordingTooLarge { }
        do {
            _ = try await adapter.transcribe(fileURL: directory.appendingPathComponent("private.exe"), sourceLanguage: nil,
                diarize: false, credentials: .init(openAI: "synthetic"))
            throw CheckFailure(message: "Unsupported file extension accepted")
        } catch SpeechToolsError.unsupportedFormat { }
        try expect(http.calls.get().isEmpty, "Unsafe files rejected before upload")
        print("PASS: empty, symlink, missing, remote, oversize and unsupported file rejection")
    }

    @MainActor private static func transcriptChecks(_ file: URL) async throws {
        let text = " \n" + String(repeating: "Hei 🌊 café og e\u{301}.\n", count: 2_000) + "  "
        let transcript = try await run(file, response: ["text": text, "languages": [["code": "no"]],
                                                      "segments": [["speaker": "invented", "start": 7]]])
        try expect(transcript.segments.count > 1 && transcript.segments.map(\.sourceText).joined() == text, "Long Unicode transcript remains lossless")
        try expect(transcript.segments.allSatisfy { $0.sourceText.utf8.count <= SpeechToolsLimits.segmentBytes }, "Every chunk stays bounded")
        try expect(Set(transcript.segments.map(\.id)).count == transcript.segments.count, "Chunk IDs are unique")
        try expect(transcript.segments.allSatisfy { $0.speaker == nil && $0.startSeconds == nil && $0.endSeconds == nil }, "Unknown metadata is not adopted")
        print("PASS: bounded lossless Unicode chunks and absent provenance")

        for text in [String(repeating: "x", count: SpeechToolsLimits.segmentBytes) + "\n",
                     "\n" + String(repeating: "x", count: SpeechToolsLimits.segmentBytes)] {
            let result = try await run(file, response: ["text": text])
            try expect(result.segments.map(\.sourceText).joined() == text, "Boundary whitespace survives without an empty segment")
            try expect(result.segments.allSatisfy { $0.sourceText.utf8.count <= SpeechToolsLimits.segmentBytes }, "Rebalanced boundary is bounded")
        }
        print("PASS: whitespace at the segment byte boundary is retained")

        for response in [["text": "Hello", "languages": []] as [String: Any], ["text": "Hello"],
                         ["text": "Hello. Bonjour.", "languages": [["code": "en"], ["code": "fr"]]]] {
            let result = try await run(file, response: response, hint: "no")
            try expect(result.sourceLanguage == nil, "Unknown or mixed languages never use requested hint as detection")
        }
        let empty = try await run(file, response: ["text": "", "languages": []])
        try expect(empty.segments.isEmpty && empty.sourceLanguage == nil, "Empty response does not fabricate speech")
        print("PASS: missing, empty and multiple detected languages; silence")

        for response in [["text": "Hello", "languages": [["code": "no\nprivate"]]] as [String: Any],
                         ["text": "Hello", "languages": [["code": 3]]], ["text": "Hello", "languages": "no"],
                         ["languages": []], ["text": 42], ["text": " \n "]] {
            do { _ = try await run(file, response: response); throw CheckFailure(message: "Malformed transcription accepted") }
            catch SpeechToolsError.invalidResponse { }
        }
        print("PASS: malformed response and language fields reject safely")
    }

    @MainActor private static func responseBoundsChecks(_ file: URL) async throws {
        for text in [String(repeating: "x", count: SpeechToolsLimits.transcriptBytes + 1),
                     "e" + String(repeating: "\u{301}", count: SpeechToolsLimits.segmentBytes)] {
            do { _ = try await run(file, response: ["text": text]); throw CheckFailure(message: "Oversized transcript accepted") }
            catch SpeechToolsError.transcriptTooLarge { }
        }
        let oversized = FakeHTTP(Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1))
        do {
            _ = try await OpenAIRecordingTranscriber(transport: oversized).transcribe(fileURL: file, sourceLanguage: nil,
                diarize: false, credentials: .init(openAI: "synthetic"))
            throw CheckFailure(message: "Oversized transport response accepted")
        } catch ProviderNetworkError.overflow { }
        print("PASS: decoded text, indivisible grapheme and streamed response bounds")
    }

    @MainActor private static func cancellationChecks(_ file: URL) async throws {
        for cancelTask in [false, true] {
            let http = FakeHTTP(try json(["text": "Late result", "languages": []]), returnAfterCancellation: true)
            http.waiting.change { $0 = true }
            let adapter = OpenAIRecordingTranscriber(transport: http)
            let pending = Task { try await adapter.transcribe(fileURL: file, sourceLanguage: nil, diarize: false,
                                                              credentials: .init(openAI: "synthetic")) }
            try await waitFor { !http.calls.get().isEmpty }
            do {
                _ = try await adapter.transcribe(fileURL: file, sourceLanguage: nil, diarize: false, credentials: .init(openAI: "synthetic"))
                throw CheckFailure(message: "Concurrent request accepted")
            } catch ProviderNetworkError.busy { }
            if cancelTask { pending.cancel() } else { adapter.cancel() }
            do { _ = try await pending.value; throw CheckFailure(message: "Cancelled result escaped") }
            catch is CancellationError { }
            try expect(http.cancellationCount.get() > 0 && http.calls.get().count == 1, "Cancellation reaches transport without extra request")
            // An idle cancel must not cancel another operation using an injected shared transport.
            let count = http.cancellationCount.get(); adapter.cancel()
            try expect(http.cancellationCount.get() == count, "Idle cancellation does not cancel shared transport")
        }
        print("PASS: operation exclusion, explicit cancellation and late result suppression")
        print("PASS: parent task cancellation reaches a non-cooperative transport")

        let http = FakeHTTP(try json(["text": "Unused", "languages": []]))
        let adapter = OpenAIRecordingTranscriber(transport: http)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.transcribe(fileURL: file, sourceLanguage: nil, diarize: false, credentials: .init(openAI: "synthetic"))
        }
        do { _ = try await cancelled.value; throw CheckFailure(message: "Precancelled operation accepted") }
        catch is CancellationError { }
        try expect(http.calls.get().isEmpty, "Precancelled operation never uploads")
        print("PASS: cancelled task rejected before file upload")
    }

    @MainActor private static func errorChecks(_ file: URL) async throws {
        let unsafe = NSError(domain: "synthetic-secret /private/customer.wav", code: 8,
                             userInfo: [NSLocalizedDescriptionKey: "synthetic-secret provider body /private/customer.wav"])
        let http = FakeHTTP(failure: unsafe)
        do {
            _ = try await OpenAIRecordingTranscriber(transport: http).transcribe(fileURL: file, sourceLanguage: nil,
                diarize: false, credentials: .init(openAI: "synthetic"))
            throw CheckFailure(message: "Unsafe transport error accepted")
        } catch ProviderNetworkError.transport { }
        let status = FakeHTTP(failure: ProviderNetworkError.http(429))
        do {
            _ = try await OpenAIRecordingTranscriber(transport: status).transcribe(fileURL: file, sourceLanguage: nil,
                diarize: false, credentials: .init(openAI: "synthetic"))
            throw CheckFailure(message: "HTTP failure accepted")
        } catch ProviderNetworkError.http(429) { }
        let invalid = FakeHTTP(Data("not-json synthetic-secret".utf8))
        do {
            _ = try await OpenAIRecordingTranscriber(transport: invalid).transcribe(fileURL: file, sourceLanguage: nil,
                diarize: false, credentials: .init(openAI: "synthetic"))
            throw CheckFailure(message: "Invalid JSON accepted")
        } catch SpeechToolsError.invalidResponse { }
        print("PASS: raw transport and decoder errors sanitized; safe HTTP status retained")
    }

    @MainActor private static func run(_ file: URL, response: [String: Any], hint: String? = nil) async throws -> RecordingTranscript {
        let http = FakeHTTP(try json(response))
        return try await OpenAIRecordingTranscriber(transport: http).transcribe(fileURL: file, sourceLanguage: hint,
            diarize: false, credentials: .init(openAI: "synthetic"))
    }

    @MainActor private static func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CheckFailure(message: "Timed out waiting for synthetic transport")
    }
}
