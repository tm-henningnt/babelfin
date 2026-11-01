import Foundation
import BridgeCore

struct Failure: Error { let message: String }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure(message: "Expected rejection")
}
@MainActor func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw Failure(message: message)
}
@MainActor final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    private var open = false
    func wait() async {
        entered = true
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ProcessInfo.processInfo.systemUptime
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ amount: TimeInterval) { lock.lock(); value += amount; lock.unlock() }
}
final class FakeSocket: TranslationWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Data>
    private let incoming: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator
    private var sent: [String] = []
    private var cancelled = false
    let blockedAppend: Gate?
    let acknowledgeUpdate: Bool
    init(acknowledgeUpdate: Bool = true, blockedAppend: Gate? = nil) {
        self.blockedAppend = blockedAppend
        self.acknowledgeUpdate = acknowledgeUpdate
        var captured: AsyncStream<Data>.Continuation!
        stream = AsyncStream { captured = $0 }
        incoming = captured
        iterator = stream.makeAsyncIterator()
        emit(["type": "session.created"])
    }
    func emit(_ object: [String: Any]) { incoming.yield(try! JSONSerialization.data(withJSONObject: object)) }
    func audio(seconds: Double, byte: UInt8 = 0) {
        emit(["type": "session.output_audio.delta", "delta": Data(repeating: byte, count: Int((seconds * 24_000).rounded()) * 2).base64EncodedString(), "sample_rate": 24_000, "channels": 1])
    }
    private func record(_ text: String) { lock.lock(); sent.append(text); lock.unlock() }
    func send(_ text: String) async throws {
        record(text)
        let type = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String
        if type == "session.input_audio_buffer.append" { await blockedAppend?.wait() }
        if type == "session.update", acknowledgeUpdate { emit(["type": "session.updated"]) }
        if type == "session.close" { emit(["type": "session.closed"]) }
    }
    // Exactly one receiver, including startup's handover to the background reader.
    func receive() async throws -> Data {
        guard let data = await iterator.next() else { throw CancellationError() }
        return data
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock(); incoming.finish() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var sendCount: Int { lock.lock(); defer { lock.unlock() }; return sent.count }
}
@MainActor final class Events {
    var audio: [Data] = []
    var transcripts = ""
    var failures: [String] = []
    func accept(_ event: TranslationEvent) {
        switch event {
        case .audio(let pcm): audio.append(pcm)
        case .sourceTranscript(let text): transcripts += text
        case .failure(let code): failures.append(code)
        default: break
        }
    }
}
@main struct ProviderChecks {
    @MainActor static func main() async throws {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("Input boundary discards queued PCM while retaining text completion", {
                let blocked = Gate(), socket = FakeSocket(blockedAppend: blocked)
                let provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                try await provider.start(configuration: .init(), apiKey: "fixture")
                try provider.append(Data([1,0]))
                try await eventually("Append did not enter transport", { blocked.entered })
                try provider.append(Data([2,0]))
                let sentAtBoundary = socket.sendCount
                provider.stopInput()
                try rejects { try provider.append(Data([3,0])) }
                blocked.release()
                await provider.finish()
                try require(socket.sendCount == sentAtBoundary + 1 && socket.isCancelled, "Unsent audio escaped boundary or text close did not finish")
            }),
            ("Wire metadata, audio validation, loopback preprocessing", {
                let audio = #"{"type":"session.output_audio.delta","delta":"AAA=","elapsed_ms":1200,"sample_rate":24000,"channels":1,"format":"pcm16"}"#
                let envelope = try TranslationWire.decodeEnvelope(Data(audio.utf8))
                try require(envelope.timing.elapsedMilliseconds == 1200, "Lost timing")
                for invalid in [audio.replacingOccurrences(of: "24000", with: "48000"),
                                audio.replacingOccurrences(of: "\"channels\":1", with: "\"channels\":2"),
                                audio.replacingOccurrences(of: "\"elapsed_ms\":1200", with: "\"elapsed_ms\":true")] {
                    try rejects { _ = try TranslationWire.decode(Data(invalid.utf8)) }
                }
                let expiry = try TranslationWire.decodeEnvelope(Data(#"{"type":"session.created","session":{"expires_at":2000000000}}"#.utf8))
                try require(expiry.timing.expiresAt == 2_000_000_000, "Lost expiry")
                let config = try JSONSerialization.jsonObject(with: Data(TranslationWire.update(.init(noiseReduction: .disabled)).utf8)) as! [String: Any]
                let session = config["session"] as! [String: Any]
                let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
                try require(input["noise_reduction"] is NSNull, "Loopback preprocessing not disabled")
            }),
            ("PCM budget includes in-flight packets, ordered tail drain", {
                let channel = BoundedPCMChannel(maximumFrames: 4800)
                channel.open()
                try channel.append(Data(repeating: 1, count: 4800), at: 10)
                try channel.append(Data(repeating: 2, count: 4800), at: 11)
                var iterator = channel.stream.makeAsyncIterator()
                let first = await iterator.next()!
                try require(first.pcm.first == 1, "Input reordered")
                try rejects { try channel.append(Data([0, 0]), at: 12) }
                try require(channel.snapshot(at: 12).oldestAge == 2, "In-flight age missing")
                channel.complete(first)
                try channel.append(Data([0, 0]), at: 12)
                channel.finish()
                let second = await iterator.next()!, tail = await iterator.next()!
                try require(second.pcm.first == 2 && tail.pcm.count == 2, "Tail lost or reordered")
                channel.complete(second); channel.complete(tail)
                let end = await iterator.next()
                try require(end == nil && channel.snapshot().frames == 0, "Finish did not drain")
                channel.cancel(); channel.complete(first)
                try require(channel.snapshot().frames == 0, "Stale completion changed capacity")
            }),
            ("2.4 second delta drains while transcripts bypass blocked playback", {
                let socket = FakeSocket(), provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                let events = Events(), gate = Gate()
                provider.onEvent = { events.accept($0) }
                provider.onAudio = { pcm in
                    if await events.audio.isEmpty { await gate.wait() }
                    await events.accept(.audio(pcm))
                }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.audio(seconds: 2.4, byte: 3)
                try await eventually("Audio never reached consumer") { gate.entered }
                socket.emit(["type": "session.input_transcript.delta", "delta": "fixture"])
                try await eventually("Transcript blocked by playback") { events.transcripts == "fixture" }
                gate.release()
                try await eventually("Large delta failed to drain") { events.audio.count == 24 }
                try require(events.audio.allSatisfy { $0.count == 4800 && $0.allSatisfy { $0 == 3 } }, "Chunks corrupted")
                await provider.finish()
                try require(events.failures.isEmpty && socket.isCancelled, "Clean close failed")
            }),
            ("Slow transcript handling cannot block incoming audio", {
                let socket = FakeSocket(), provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                let events = Events(), gate = Gate()
                provider.onEvent = { event in
                    if case .sourceTranscript = event { await gate.wait() }
                    events.accept(event)
                }
                provider.onAudio = { pcm in await events.accept(.audio(pcm)) }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.emit(["type": "session.input_transcript.delta", "delta": "fixture"])
                try await eventually("Transcript handler not entered") { gate.entered }
                socket.audio(seconds: 0.1)
                try await eventually("Audio blocked behind transcript UI") { events.audio.count == 1 }
                gate.release()
                await provider.finish()
                try require(events.transcripts == "fixture", "Final transcript did not drain")
            }),
            ("Control mailbox overflow cancels instead of growing UI tasks", {
                let socket = FakeSocket(), provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                let events = Events(), gate = Gate()
                provider.onEvent = { event in
                    if case .sourceTranscript = event { await gate.wait() }
                    events.accept(event)
                }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.emit(["type": "session.input_transcript.delta", "delta": "fixture"])
                try await eventually("No control consumer") { gate.entered }
                for _ in 0..<64 { socket.emit(["type": "session.input_transcript.delta", "delta": "fixture"]) }
                try await eventually("Control overflow not surfaced") { events.failures.contains("control_event_backlog") }
                try require(socket.isCancelled, "Control overflow left transport active")
                gate.release()
            }),
            ("A single audio burst exceeding five seconds fails clearly", {
                let socket = FakeSocket(), provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                let events = Events()
                provider.onEvent = { events.accept($0) }
                provider.onAudio = { pcm in await events.accept(.audio(pcm)) }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.audio(seconds: 5.1)
                try await eventually("Oversized burst not surfaced") { events.failures.contains("audio_burst_exceeds_five_seconds") }
                try require(events.audio.isEmpty, "Oversized burst partly admitted")
            }),
            ("Sustained overproduction fails explicitly", {
                let socket = FakeSocket(), provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                let events = Events(), gate = Gate()
                provider.onEvent = { events.accept($0) }
                provider.onAudio = { pcm in
                    await gate.wait()
                    await events.accept(.audio(pcm))
                }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.audio(seconds: 2.4)
                try await eventually("Missing in-flight packet") { gate.entered }
                socket.audio(seconds: 2.4); socket.audio(seconds: 0.3)
                try await eventually("Overflow not surfaced") { events.failures.contains("received_audio_backlog") }
                try require(socket.isCancelled, "Overflow left socket active")
                gate.release()
            }),
            ("Stop finishes independently of blocked audio", {
                let socket = FakeSocket(), provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                let events = Events(), gate = Gate()
                provider.onEvent = { events.accept($0) }
                provider.onAudio = { pcm in
                    await gate.wait()
                    await events.accept(.audio(pcm))
                }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.audio(seconds: 0.1)
                try await eventually("No audio consumer") { gate.entered }
                await provider.finish()
                try require(socket.isCancelled && events.failures.isEmpty, "Stop waited for audio or failed")
                gate.release()
                try rejects { try provider.append(Data([0, 0])) }
            }),
            ("Stop cancellation of capacity wait is not a playback failure", {
                let socket = FakeSocket(), provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                let events = Events()
                provider.onEvent = { events.accept($0) }
                provider.onAudio = { pcm in
                    await events.accept(.audio(pcm))
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.audio(seconds: 0.1)
                try await eventually("No pending playback wait") { events.audio.count == 1 }
                await provider.finish()
                try require(events.failures.isEmpty, "Intentional Stop became playback failure")
            }),
            ("Startup cancellation cannot reopen upload", {
                let socket = FakeSocket(acknowledgeUpdate: false)
                let provider = OpenAITranslationProvider(transportFactory: { _ in socket })
                let startup = Task { try await provider.start(configuration: .init(), apiKey: "fixture") }
                try await eventually("Update not sent") { socket.sendCount == 1 }
                provider.cancel()
                socket.emit(["type": "session.updated"])
                var cancelled = false
                do { try await startup.value } catch { cancelled = true }
                try require(cancelled, "Cancelled startup succeeded")
                try rejects { try provider.append(Data([0, 0])) }
            }),
            ("Age watchdog expires without further arrivals", {
                let socket = FakeSocket(), clock = Clock()
                let provider = OpenAITranslationProvider(transportFactory: { _ in socket }, clock: { clock.read() })
                let events = Events(), gate = Gate()
                provider.onEvent = { events.accept($0) }
                provider.onAudio = { pcm in
                    await gate.wait()
                    await events.accept(.audio(pcm))
                }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.audio(seconds: 0.1)
                try await eventually("No audio consumer") { gate.entered }
                clock.advance(6)
                try await eventually("Watchdog did not fire") { events.failures.contains("received_audio_stale") }
                gate.release()
            }),
            ("Expired session fails and closes the transport", {
                let socket = FakeSocket(), wall = Clock()
                let provider = OpenAITranslationProvider(transportFactory: { _ in socket }, wallClock: { wall.read() })
                let events = Events()
                provider.onEvent = { events.accept($0) }
                try await provider.start(configuration: .init(), apiKey: "fixture")
                socket.emit(["type": "session.created", "session": ["expires_at": Int(wall.read()) + 30]])
                try provider.append(Data([0, 0]))
                try await Task.sleep(nanoseconds: 600_000_000)
                try require(events.failures.isEmpty && !socket.isCancelled, "A live session expired early")
                wall.advance(31)
                try await eventually("Expiry did not fire") { events.failures.contains("session_expired") }
                try require(socket.isCancelled, "Expired session left the transport open")
                try rejects { try provider.append(Data([0, 0])) }
            })
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) provider checks passed")
        if failures > 0 { exit(1) }
    }
}
