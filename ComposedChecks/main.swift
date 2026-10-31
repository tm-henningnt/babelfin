import Foundation
import BridgeCore

private struct StageFailure: TranslationFailureDiagnosing { let translationFailureReason: TranslationFailureReason }
private struct CheckFailure: Error { let message: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}
@MainActor private func until(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !condition() {
        if ProcessInfo.processInfo.systemUptime > deadline { throw CheckFailure(message: "Async check exceeded deadline") }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
@MainActor private final class Recognizer: StreamingSpeechRecognizer {
    var onEvent: RecognitionEventHandler?
    var starts = 0
    var inputStops = 0
    var cancels = 0
    var delayStart = false
    var startWait: CheckedContinuation<Void, Never>?
    var finalSegment: TranscriptSegment?
    var hangFinish = false
    var finishWait: CheckedContinuation<Void, Never>?
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        starts += 1
        if delayStart { await withCheckedContinuation { startWait = $0 } }
    }
    nonisolated func append(_ pcm: Data) throws {}
    func stopInput() { inputStops += 1 }
    func finish() async throws {
        if hangFinish { await withCheckedContinuation { finishWait = $0 } }
        if let finalSegment { await onEvent?(.segment(finalSegment)) }
        await onEvent?(.closed)
    }
    func cancel() { cancels += 1 }
    func emit(_ segment: TranscriptSegment) async { await onEvent?(.segment(segment)) }
}
@MainActor private final class Translator: TextTranslationStage {
    var calls: [String] = []
    var blocked = false
    var failure: Error?
    var waiter: CheckedContinuation<String, Error>?
    var cancels = 0
    func translate(text: String, sourceLanguage: String?, targetLanguage: String, credentials: ProviderCredentials) async throws -> String {
        calls.append(text)
        if let failure { throw failure }
        if blocked { return try await withCheckedThrowingContinuation { waiter = $0 } }
        return "translated: " + text
    }
    func cancel() { cancels += 1 }
    func release(_ value: String = "late translation") { let waiter = waiter; self.waiter = nil; waiter?.resume(returning: value) }
}
@MainActor private final class Synthesizer: SpeechSynthesisStage {
    var calls: [String] = []
    var cancels = 0
    var wrapsSinkErrors = false
    var blocked = false
    /// Blocked calls in arrival order. Speech for the next segment can be prepared while the
    /// current one is blocked, so more than one call can wait.
    var waiters: [CheckedContinuation<Void, Error>] = []
    var waiter: CheckedContinuation<Void, Error>? {
        get { waiters.first }
        set { if newValue == nil, !waiters.isEmpty { waiters.removeFirst() } }
    }
    func synthesize(text: String, language: String, voiceID: String?, credentials: ProviderCredentials,
                    onAudio: @escaping TranslationAudioHandler) async throws {
        calls.append(text)
        if blocked { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in waiters.append(continuation) } }
        // Data slices can have nonzero indices; the canonical audio seam must handle them.
        let pcm = PCM16.encode([Float](repeating: 0.25, count: 3001))
        do { try await onAudio(pcm.dropFirst(2)) }
        catch {
            if wrapsSinkErrors { throw BridgeError.unavailable("Sanitized transport failure") }
            throw error
        }
    }
    func cancel() {
        cancels += 1
        let pending = waiters; waiters = []; pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
private final class Bytes: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    func append(_ data: Data) { lock.lock(); sizes.append(data.count); lock.unlock() }
    var packets: [Int] { lock.lock(); defer { lock.unlock() }; return sizes }
}
@MainActor private final class Events {
    var values: [TranslationEvent] = []
    var notices: [String] { values.compactMap { if case .notice(let detail) = $0 { return detail }; return nil } }
    var failures: [String] { values.compactMap { if case .failure(let code) = $0 { return code }; return nil } }
    var sources: [TranscriptSegment] { values.compactMap { if case .segment(let segment, role: .source) = $0 { return segment }; return nil } }
    var targets: [TranscriptSegment] { values.compactMap { if case .segment(let segment, role: .target) = $0 { return segment }; return nil } }
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
}
@MainActor private struct Fixture {
    let recognizer = Recognizer()
    let translator = Translator()
    let synthesizer = Synthesizer()
    let events = Events()
    let bytes = Bytes()
    let provider: ComposedTranslationProvider
    /// Fixtures compare exact audio sizes, so by default they never slow a segment down.
    static var steady: CompositionPolicy { var policy = CompositionPolicy(); policy.minimumRate = 1; return policy }
    init(policy: CompositionPolicy = Fixture.steady, clock: Clock? = nil) {
        provider = ComposedTranslationProvider(recognizer: recognizer, translator: translator, synthesizer: synthesizer,
            policy: policy, clock: { clock?.now ?? ProcessInfo.processInfo.systemUptime })
        provider.onEvent = { [events] event in events.values.append(event) }
        provider.onAudio = { [bytes] data in bytes.append(data) }
    }
    func start() async throws {
        try await provider.start(configuration: .init(targetLanguage: "no", route: .elevenLabs, voiceID: "fixture-voice"),
                                 credentials: .init(openAI: "fixture-openai", elevenLabs: "fixture-eleven"))
    }
}
@main struct ComposedChecks {
    @MainActor static func main() async {
        do {
            var passed = 0
            let missing = Fixture()
            do {
                try await missing.provider.start(configuration: .init(targetLanguage: "no", route: .elevenLabs, voiceID: "fixture"), credentials: .init(openAI: "fixture"))
                throw CheckFailure(message: "Missing stage credential accepted")
            } catch is CheckFailure { throw CheckFailure(message: "Missing stage credential accepted") }
            catch { try expect(missing.recognizer.starts == 0, "Credential validation must precede network startup") }
            try expect(String(describing: ProviderCredentials(openAI: "fixture-secret")) == "ProviderCredentials(redacted)", "Secret description leaked")
            try expect(Mirror(reflecting: ProviderCredentials(openAI: "fixture-secret")).children.isEmpty, "Credential reflection exposed secret fields")
            do { _ = try TranslationWire.update(.init(voiceID: "fixture")); throw CheckFailure(message: "OpenAI ignored unsupported selected voice") }
            catch is CheckFailure { throw CheckFailure(message: "OpenAI ignored unsupported selected voice") }
            catch {}
            try expect(!TranslationWire.supportedTargets.contains("no") && ProviderCapabilities.forRoute(.elevenLabs).outputLanguages.contains { $0.code == "no" }, "Route language coverage conflated")
            var revision = TranscriptRevisionLedger(maximumSegments: 1)
            _ = try revision.accept(.init(id: "one", text: "draft"))
            do { _ = try revision.accept(.init(id: "two", text: "overflow")); throw CheckFailure(message: "Ledger must bound unique IDs") }
            catch is CheckFailure { throw CheckFailure(message: "Ledger must bound unique IDs") }
            catch {}
            passed += 1; print("PASS: Typed credentials, per-route language coverage and bounded revision IDs")

            let startup = Fixture(); startup.recognizer.delayStart = true
            let starting = Task { try await startup.start() }
            try await until { startup.recognizer.startWait != nil }
            startup.provider.cancel()
            startup.recognizer.startWait?.resume(); startup.recognizer.startWait = nil
            do { try await starting.value; throw CheckFailure(message: "Cancelled startup returned ready") }
            catch is CancellationError {}
            try expect(startup.events.values.isEmpty, "Late recognizer startup emitted readiness after cancellation")
            do { try startup.provider.append(Data([0, 0])); throw CheckFailure(message: "Late startup reopened capture admission") }
            catch is CheckFailure { throw CheckFailure(message: "Late startup reopened capture admission") }
            catch {}
            passed += 1; print("PASS: Cancelled startup cannot reopen input or publish late readiness")

            let revisions = Fixture(); try await revisions.start()
            await revisions.recognizer.emit(.init(id: "s1", text: "dr", language: "en"))
            await revisions.recognizer.emit(.init(id: "s1", revision: 1, text: "draft", language: "en"))
            try expect(revisions.translator.calls.isEmpty, "Partial transcript was spoken")
            let final = TranscriptSegment(id: "s1", revision: 2, text: "final", isFinal: true, language: "en", startSeconds: 1, endSeconds: 2, timingReference: .sourceAudio)
            await revisions.recognizer.emit(final)
            try await until { revisions.bytes.packets.count == 2 }
            await revisions.recognizer.emit(final)
            await revisions.recognizer.emit(.init(id: "s1", revision: 3, text: "corrected", isFinal: true))
            try expect(revisions.translator.calls == ["final"] && revisions.events.sources.last?.text == "corrected", "Committed correction must update text without speaking twice")
            try expect(revisions.events.targets.first?.startSeconds == 1 && revisions.events.targets.first?.speaker == nil && revisions.events.targets.first?.timingReference == .sourceAudio, "Timing provenance or unknown speaker was fabricated")
            try expect(revisions.bytes.packets == [4800, 1200], "Canonical output must honor100ms sink backpressure pieces")
            try await until { revisions.events.values.contains { if case .passage = $0 { return true }; return false } }
            let timing = revisions.events.values.compactMap { if case .passage(let value) = $0 { return value }; return nil }.first
            try expect(timing?.passageSeconds == 1 && timing?.translateSeconds != nil && timing?.voiceSeconds != nil
                       && timing.map { $0.totalSeconds >= ($0.translateSeconds ?? 0) && $0.waitSeconds >= 0 } == true,
                       "Passage timing must report the passage length and each stage: \(String(describing: timing))")
            revisions.provider.cancel()
            passed += 1; print("PASS: Only committed source is spoken once; revisions and timing remain visible")

            let ordered = Fixture(); ordered.translator.blocked = true; try await ordered.start()
            await ordered.recognizer.emit(.init(id: "one", text: "one", isFinal: true))
            try await until { ordered.translator.waiter != nil }
            await ordered.recognizer.emit(.init(id: "two", text: "two", isFinal: true))
            try expect(ordered.translator.calls == ["one"], "Second segment overtook in-flight translation")
            ordered.translator.blocked = false; ordered.translator.release("translated: one")
            try await until { ordered.synthesizer.calls.count == 2 }
            try expect(ordered.synthesizer.calls == ["translated: one", "translated: two"], "Speech order changed")
            ordered.provider.cancel()
            passed += 1; print("PASS: Slow translation preserves committed segment and speech order")

            var boundedPolicy = Fixture.steady; boundedPolicy.maximumSegments = 2
            let bounded = Fixture(policy: boundedPolicy); bounded.translator.blocked = true; try await bounded.start()
            await bounded.recognizer.emit(.init(id: "one", text: "one", isFinal: true))
            try await until { bounded.translator.waiter != nil }
            await bounded.recognizer.emit(.init(id: "two", text: "two", isFinal: true))
            await bounded.recognizer.emit(.init(id: "three", text: "three", isFinal: true))
            try expect(bounded.events.failures.isEmpty && bounded.recognizer.cancels == 0, "A full queue must skip, not end translation")
            try expect(bounded.events.notices.contains { $0.contains("Skipped 1 recognized segment") }, "Skipping must be visible")
            bounded.translator.blocked = false; bounded.translator.release("translated: one")
            try await until { bounded.synthesizer.calls.count == 2 }
            try expect(bounded.synthesizer.calls == ["translated: one", "translated: three"], "The oldest waiting segment must be the one skipped")
            bounded.provider.cancel()
            passed += 1; print("PASS: In-flight segment counts toward budget and a full queue skips the oldest waiting segment")

            let drain = Fixture(); try await drain.start()
            drain.recognizer.finalSegment = .init(id: "tail", text: "tail", isFinal: true)
            try drain.provider.append(Data([0, 0]))
            await drain.provider.finish()
            try expect(drain.events.targets.count == 1 && drain.bytes.packets == [4800, 1200] && drain.events.values.last == .closed, "Finish must drain committed tail before closing")
            do { try drain.provider.append(Data([0, 0])); throw CheckFailure(message: "Closed input accepted audio") }
            catch is CheckFailure { throw CheckFailure(message: "Closed input accepted audio") }
            catch {}
            passed += 1; print("PASS: Finish closes input and drains final recognition, translation and audio")

            let detached = Fixture(); try await detached.start()
            detached.provider.onAudio = nil
            detached.recognizer.finalSegment = .init(id: "tail", text: "tail", isFinal: true)
            await detached.provider.finish()
            try expect(detached.events.targets.count == 1 && detached.synthesizer.calls.isEmpty && detached.events.failures.isEmpty,
                       "Stop must retain final text without synthesizing discarded speech or failing playback")
            passed += 1; print("PASS: Detached output finalizes transcript without extra synthesis or false playback failure")

            let textOnly = Fixture(); try await textOnly.start()
            textOnly.recognizer.finalSegment = .init(id: "tail", text: "already submitted", isFinal: true)
            textOnly.provider.stopInput()
            do { try textOnly.provider.append(Data([0, 0])); throw CheckFailure(message: "Text-only input accepted PCM") }
            catch is CheckFailure { throw CheckFailure(message: "Text-only input accepted PCM") }
            catch {}
            await textOnly.provider.finish()
            try expect(textOnly.recognizer.inputStops == 1 && textOnly.events.targets.count == 1 && textOnly.synthesizer.calls.isEmpty, "Text-only stop must close recognition uploads and prevent late synthesis")
            passed += 1; print("PASS: Text-only completion closes input and never synthesizes final speech")

            let interruptedSpeech = Fixture(); try await interruptedSpeech.start()
            interruptedSpeech.synthesizer.blocked = true
            await interruptedSpeech.recognizer.emit(.init(id: "one", text: "one", isFinal: true))
            try await until { interruptedSpeech.synthesizer.waiter != nil }
            await interruptedSpeech.recognizer.emit(.init(id: "two", text: "two", isFinal: true))
            await interruptedSpeech.recognizer.emit(.init(id: "three", text: "three", isFinal: true))
            interruptedSpeech.provider.stopInput()
            try expect(interruptedSpeech.synthesizer.cancels == 1 && interruptedSpeech.synthesizer.waiter == nil,
                       "Stop translating must cancel in-flight synthesis immediately")
            await interruptedSpeech.provider.finish()
            try expect(interruptedSpeech.events.targets.map(\.id) == ["one", "two", "three"] && interruptedSpeech.events.failures.isEmpty,
                       "Intentional speech cancellation must preserve queued text translation without synthesis failure")
            try expect(interruptedSpeech.synthesizer.calls.count == 1 && interruptedSpeech.bytes.packets.isEmpty,
                       "Text-only completion must not synthesize or play queued segments")
            passed += 1; print("PASS: In-flight synthesis is cancelled immediately while queued text completes")

            let playbackFailure = Fixture(); try await playbackFailure.start()
            playbackFailure.synthesizer.wrapsSinkErrors = true
            playbackFailure.provider.onAudio = { _ in throw BridgeError.unavailable("Synthetic output route changed") }
            await playbackFailure.recognizer.emit(.init(id: "playback", text: "test", isFinal: true))
            try await until { !playbackFailure.events.failures.isEmpty }
            try expect(playbackFailure.events.failures == ["audio_playback_failed"],
                       "Output failure must not become a cloud error that permits original-audio fallback")
            passed += 1; print("PASS: Playback sink failures retain device-stop classification")

            let privateFailure = Fixture(); try await privateFailure.start()
            privateFailure.translator.failure = NSError(domain: "PRIVATE_DOMAIN", code: 99,
                userInfo: [NSLocalizedDescriptionKey: "PRIVATE_RESPONSE_BODY_AND_CREDENTIAL"])
            await privateFailure.recognizer.emit(.init(id: "private-error", text: "PRIVATE_SPEECH", isFinal: true))
            try await until { !privateFailure.events.failures.isEmpty }
            try expect(privateFailure.events.failures == ["text_translation_failed"] &&
                privateFailure.events.notices == ["OpenAI text translation failed. The service operation could not finish. Check service access and network."],
                "Unknown provider error must retain its stage while withholding arbitrary details")
            try expect(TranslationFailureReason.httpStatus(Int.max).safeSummary == "The service returned an unsupported response.",
                "Unbounded HTTP status should not be interpolated into diagnostics")
            passed += 1; print("PASS: Unknown stage errors never expose raw error, transcript or credential details")

            for reason in [TranslationFailureReason.httpStatus(401), .httpStatus(402), .httpStatus(403), .httpStatus(429), .invalidRequest, .httpStatus(503), .transport, .timedOut] {
                let classified = Fixture(); classified.translator.failure = StageFailure(translationFailureReason: reason)
                try await classified.start(); await classified.recognizer.emit(.init(id: "typed", text: "test", isFinal: true))
                try await until { !classified.events.failures.isEmpty }
                let transient = reason == .httpStatus(503) || reason == .transport || reason == .timedOut
                try expect(classified.events.failures == ["text_translation_failed" + (transient ? "_transient" : "")], "Stage lost sanitized transient/account distinction")
            }
            let recognizerTransport = Fixture(); try await recognizerTransport.start()
            await recognizerTransport.recognizer.onEvent?(.failure("Speech recognition connection failed."))
            try expect(recognizerTransport.events.failures == ["recognition_transport"], "Recognition disconnect lost retry classification")
            let recognizerAccount = Fixture(); try await recognizerAccount.start()
            await recognizerAccount.recognizer.onEvent?(.failure("ElevenLabs could not continue recognition. Check account access and usage limits."))
            try expect(recognizerAccount.events.failures == ["recognition_failed"], "Recognition account rejection became retryable")
            passed += 1; print("PASS: Transient stage transport retains controlled classification without retrying account failures")

            var stageTimeoutPolicy = CompositionPolicy(); stageTimeoutPolicy.stageTimeout = 0.03
            let stageTimeout = Fixture(policy: stageTimeoutPolicy); stageTimeout.translator.blocked = true; try await stageTimeout.start()
            await stageTimeout.recognizer.emit(.init(id: "timeout", text: "test", isFinal: true))
            try await until { !stageTimeout.events.failures.isEmpty }
            try expect(stageTimeout.events.failures == ["text_translation_failed_transient"] &&
                stageTimeout.events.notices == ["OpenAI text translation failed. The service operation timed out."],
                "Stage deadline should retain a safe, actionable timeout reason")
            stageTimeout.translator.release()
            passed += 1; print("PASS: Stage deadlines retain stage-specific timeout diagnostics")

            var timeoutPolicy = CompositionPolicy(); timeoutPolicy.finishTimeout = 0.03
            let timeout = Fixture(policy: timeoutPolicy); timeout.recognizer.hangFinish = true; try await timeout.start()
            let before = ProcessInfo.processInfo.systemUptime
            await timeout.provider.finish()
            try expect(ProcessInfo.processInfo.systemUptime - before < 0.5 && timeout.events.failures == ["finalization_timed_out"], "Uncooperative stage defeated finish deadline")
            timeout.recognizer.finishWait?.resume(); timeout.recognizer.finishWait = nil
            passed += 1; print("PASS: Finish deadline returns even when a stage ignores task cancellation")

            let clock = Clock(); let stale = Fixture(clock: clock)
            stale.translator.blocked = true; try await stale.start()
            await stale.recognizer.emit(.init(id: "old", text: "old", isFinal: true))
            try await until { stale.translator.waiter != nil }
            clock.advance(16)
            try await until { !stale.events.failures.isEmpty }
            try expect(stale.events.failures == ["translation_backlog_stale"], "Old in-flight work must fail explicitly")
            stale.translator.release()
            passed += 1; print("PASS: Backlog age includes in-flight work")

            let behind = Fixture(clock: clock)
            behind.synthesizer.blocked = true; try await behind.start()
            await behind.recognizer.emit(.init(id: "a", text: "a", isFinal: true))
            try await until { behind.synthesizer.waiter != nil }
            await behind.recognizer.emit(.init(id: "b", text: "b", isFinal: true))
            clock.advance(16)
            await behind.recognizer.emit(.init(id: "c", text: "c", isFinal: true))
            try await until { behind.events.notices.contains { $0.contains("Skipped") } }
            try expect(behind.events.failures.isEmpty, "Waiting behind long speech must not end translation")
            behind.synthesizer.blocked = false; let behindHeld = behind.synthesizer.waiters; behind.synthesizer.waiters = []; behindHeld.forEach { $0.resume() }
            try await until { behind.events.targets.count == 2 }
            try expect(behind.events.targets.map(\.text) == ["translated: a", "translated: c"],
                       "A stale waiting segment must be skipped and newer speech must continue")
            behind.provider.cancel()
            passed += 1; print("PASS: Speech catches up by skipping stale waiting segments instead of failing")
            let overlap = Fixture(); overlap.synthesizer.blocked = true; try await overlap.start()
            await overlap.recognizer.emit(.init(id: "one", text: "one", isFinal: true))
            await overlap.recognizer.emit(.init(id: "two", text: "two", isFinal: true))
            await overlap.recognizer.emit(.init(id: "three", text: "three", isFinal: true))
            try await until { overlap.synthesizer.waiter != nil }
            try await until { overlap.translator.calls.count == 2 && overlap.synthesizer.calls.count == 2 }
            try expect(overlap.synthesizer.calls == ["translated: one", "translated: two"] && overlap.translator.calls == ["one", "two"],
                       "The next segment must translate and synthesize while the current one is spoken, one segment ahead only")
            overlap.synthesizer.blocked = false
            let held = overlap.synthesizer.waiters; overlap.synthesizer.waiters = []; held.forEach { $0.resume() }
            try await until { overlap.synthesizer.calls.count == 3 }
            try expect(overlap.synthesizer.calls == ["translated: one", "translated: two", "translated: three"], "Lookahead changed speech order")
            overlap.provider.cancel()
            let cancelled = Fixture(); cancelled.synthesizer.blocked = true; try await cancelled.start()
            await cancelled.recognizer.emit(.init(id: "one", text: "one", isFinal: true))
            try await until { cancelled.synthesizer.waiter != nil }
            cancelled.translator.blocked = true
            await cancelled.recognizer.emit(.init(id: "two", text: "two", isFinal: true))
            try await until { cancelled.translator.waiter != nil }
            cancelled.provider.cancel()
            cancelled.translator.release("translated: two")
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(cancelled.synthesizer.calls == ["translated: one"] && cancelled.translator.cancels >= 1,
                       "Cancel must stop the lookahead translation before it is spoken")
            passed += 1; print("PASS: Translation runs one segment ahead of speech, in order, and cancels with the session")
            let policy = CompositionPolicy()
            try expect(policy.speakingRate(lag: policy.targetLag) == 1 && abs(policy.speakingRate(lag: 3, previous: 1.15) - 1.18) < 0.001,
                       "Speaking rate must be normal at the target delay and rise above it")
            try expect(abs(policy.speakingRate(lag: 0) - policy.minimumRate) < 0.001 && policy.speakingRate(lag: 0, waiting: true) == 1,
                       "Speaking rate may slow slightly only when no segment waits")
            try expect(policy.speakingRate(lag: 30, previous: 1.25) == policy.maximumRate && abs(policy.speakingRate(lag: 30, previous: 1.2, step: 0.04) - 1.24) < 0.001,
                       "Speaking rate must stop at its ceiling and follow the per-chunk step while audio plays")
            try expect(abs(policy.speakingRate(lag: 30, previous: 1) - 1.1) < 0.001 && abs(policy.speakingRate(lag: 0, previous: 1.3) - 1.2) < 0.001,
                       "Speaking rate must change by at most one step per segment")
            let lagClock = Clock()
            let lagging = Fixture(clock: lagClock); lagging.translator.blocked = true; try await lagging.start()
            await lagging.recognizer.emit(.init(id: "late", text: "late", isFinal: true))
            try await until { lagging.translator.waiter != nil }
            lagClock.advance(10)
            lagging.translator.blocked = false; lagging.translator.release("translated: late")
            try await until { lagging.synthesizer.calls.count == 1 && !lagging.bytes.packets.isEmpty }
            try await Task.sleep(nanoseconds: 50_000_000)
            let delivered = lagging.bytes.packets.reduce(0, +)
            try expect(delivered > 0 && Double(delivered) < Double((3001 - 1) * 2) * 0.95,
                       "A lagging segment from a stage without native speed must be shortened (delivered \(delivered) bytes)")
            lagging.provider.cancel()
            passed += 1; print("PASS: Speech speeds up when output lags the source, natively or by time stretch")
            print("\(passed)/\(passed) composition checks passed")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
