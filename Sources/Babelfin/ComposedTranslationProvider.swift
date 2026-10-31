import Foundation
import BridgeCore

struct CompositionPolicy: Sendable {
    var maximumSegments = 8
    var maximumCharacters = 20_000
    /// A waiting segment older than this is skipped so that speech catches up with the speaker.
    /// A translation that is in progress for longer than this fails the session.
    var maximumAge: TimeInterval = 15
    var stageTimeout: TimeInterval = 20
    var startTimeout: TimeInterval = 15
    var finishTimeout: TimeInterval = 8
    /// Keeps spoken output a roughly constant distance behind the source. `lag` is the time
    /// from a segment's commit to the start of its speech. While a segment plays, the age of
    /// the oldest waiting segment counts as the lag, so speech speeds up before the next
    /// segment falls behind. The rate rises by `rateGain` per second above `targetLag`.
    /// It goes below 1 only when no segment waits. Each call changes it by at most `step`.
    var targetLag: TimeInterval = 1.5
    var rateGain = 0.12
    var minimumRate = 0.96
    var maximumRate = 1.35
    var maximumRateStep = 0.1
    func speakingRate(lag: TimeInterval, previous: Double = 1, waiting: Bool = false, step: Double? = nil) -> Double {
        guard lag.isFinite else { return 1 }
        let floor = waiting ? 1 : minimumRate
        let wanted = min(maximumRate, max(floor, 1 + rateGain * (lag - targetLag)))
        let limit = step ?? maximumRateStep
        return min(previous + limit, max(previous - limit, wanted))
    }
}

/// A generation gate shared by the serial capture sender and async synthesis sink.
/// It owns no audio queue: the sink is awaited in at most100ms pieces.
private final class CompositionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var token = UUID()
    private var inputOpen = false
    private var outputOpen = false
    private var handler: TranslationAudioHandler?
    private var hadHandler = false
    private var discardOutput = false
    private var playbackFailure = false
    func open(_ value: UUID) { lock.lock(); token = value; inputOpen = true; outputOpen = true; playbackFailure = false; lock.unlock() }
    func closeInput() { lock.lock(); inputOpen = false; discardOutput = true; lock.unlock() }
    func cancel() { lock.lock(); inputOpen = false; outputOpen = false; token = UUID(); lock.unlock() }
    func set(_ value: TranslationAudioHandler?) {
        lock.lock(); handler = value
        if value != nil { hadHandler = true; discardOutput = false }
        else if hadHandler { discardOutput = true }
        lock.unlock()
    }
    var acceptsInput: Bool { lock.lock(); defer { lock.unlock() }; return inputOpen }
    var outputDetached: Bool { lock.lock(); defer { lock.unlock() }; return discardOutput && handler == nil }
    var failedPlayback: Bool { lock.lock(); defer { lock.unlock() }; return playbackFailure }
    private func recordPlaybackFailure(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        if outputOpen, token == generation { playbackFailure = true }
    }
    private func sink(for generation: UUID) throws -> (TranslationAudioHandler?, Bool) {
        lock.lock(); defer { lock.unlock() }
        guard outputOpen, generation == token else { throw CancellationError() }
        return (handler, discardOutput)
    }
    func deliver(_ pcm: Data, generation: UUID) async throws {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 240_000 else { throw BridgeError.invalidPCM }
        var offset = 0
        while offset < pcm.count {
            try Task.checkCancellation()
            let (sink, discarding) = try sink(for: generation)
            guard let handler = sink else {
                if discarding { return }
                throw BridgeError.unavailable("No translated audio output is connected.")
            }
            let count = min(4800, pcm.count - offset)
            let first = pcm.index(pcm.startIndex, offsetBy: offset)
            let last = pcm.index(first, offsetBy: count)
            do { try await handler(Data(pcm[first..<last])) }
            catch {
                // Network adapters may sanitize errors from their stream consumer. Keep
                // the sink failure separately so device errors cannot become cloud fallback.
                if !(error is CancellationError), !Task.isCancelled { recordPlaybackFailure(generation) }
                throw error
            }
            offset += count
        }
    }
}

/// Commit time of the oldest segment waiting behind the one being spoken. Delivery reads it on
/// any thread to adjust the speaking rate while audio plays.
private final class WaitingSegment: @unchecked Sendable {
    private let lock = NSLock(); private var arrived: TimeInterval?
    func set(_ value: TimeInterval?) { lock.withLock { arrived = value } }
    var oldest: TimeInterval? { lock.withLock { arrived } }
}

/// The speaking rate of the segment being delivered. `native` is the part of the rate that the
/// synthesis service applied itself; the time stretcher applies the rest.
private final class LiveRate: @unchecked Sendable {
    private let lock = NSLock(); private var rate: Double; private var nativeRate = 1.0
    init(_ value: Double) { rate = value }
    var value: Double { get { lock.withLock { rate } } set { lock.withLock { rate = newValue } } }
    var native: Double { get { lock.withLock { nativeRate } } set { lock.withLock { nativeRate = newValue } } }
}

private final class DeliveredBytes: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func add(_ value: Int) { lock.withLock { count += value } }
    var total: Int { lock.withLock { count } }
}

/// Audio of one segment, synthesized while an earlier segment is still speaking. Synthesis
/// appends chunks; the consumer reads them in order and can start before synthesis ends.
/// Stage timestamps for one passage, written from the stage tasks and the audio callbacks.
private final class StageStamps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: TimeInterval] = [:]
    /// Records the first time only.
    func mark(_ key: String, _ time: TimeInterval) { lock.withLock { if values[key] == nil { values[key] = time } } }
    func span(_ from: String, _ to: String) -> Double? {
        lock.withLock { values[from].flatMap { start in values[to].map { $0 - start } } }
    }
    func value(_ key: String) -> TimeInterval? { lock.withLock { values[key] } }
}

private final class PreparedSpeech: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var finished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    func append(_ pcm: Data) {
        lock.lock(); chunks.append(pcm); let waiting = waiter; waiter = nil; lock.unlock()
        waiting?.resume()
    }
    func finish(_ error: Error? = nil) {
        lock.lock()
        if !finished { finished = true; failure = error }
        let waiting = waiter; waiter = nil; lock.unlock()
        waiting?.resume()
    }
    /// The next chunk, or nil when synthesis has ended. Throws the synthesis error.
    func next() async throws -> Data? {
        while true {
            try Task.checkCancellation()
            let ready: Bool = lock.withLock {
                if !chunks.isEmpty || finished { return true }
                return false
            }
            if ready {
                return try lock.withLock {
                    if !chunks.isEmpty { return chunks.removeFirst() }
                    if let failure { throw failure }
                    return nil
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if !chunks.isEmpty || finished { lock.unlock(); continuation.resume() }
                else { waiter = continuation; lock.unlock() }
            }
        }
    }
}

/// Unstructured race so a misbehaving stage cannot keep finish waiting after its deadline.
/// Stage.cancel must still close its transport; late results are ignored by the resolved race.
@MainActor private final class CompositionDeadline<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var completed = false
    func cancel() { resolve(.failure(CancellationError())) }
    func run(seconds: TimeInterval, action: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled { resolve(.failure(CancellationError())); return }
                operation = Task { @MainActor in
                    do { self.resolve(.success(try await action())) }
                    catch { self.resolve(.failure(error)) }
                }
                timer = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.001, min(3600, seconds)) * 1_000_000_000)) }
                    catch { return }
                    self.resolve(.failure(BridgeError.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(.failure(CancellationError())) }
        }
    }
    private func resolve(_ result: Result<Value, Error>) {
        guard !completed else { return }
        completed = true
        let continuation = self.continuation; self.continuation = nil
        operation?.cancel(); operation = nil
        timer?.cancel(); timer = nil
        continuation?.resume(with: result)
    }
}

/// Stable source segments -> translation -> synthesis, with ordered bounded admission.
/// Revisions remain visible, but a committed segment is spoken only once.
@MainActor final class ComposedTranslationProvider: TranslationProvider {
    var onEvent: TranslationEventHandler?
    var onAudio: TranslationAudioHandler? { didSet { gate.set(onAudio) } }
    nonisolated private let recognizer: any StreamingSpeechRecognizer
    private let translator: any TextTranslationStage
    private let synthesizer: any SpeechSynthesisStage
    private var synthesisDeadline: CompositionDeadline<Void>?
    nonisolated private let gate = CompositionGate()
    private var policy: CompositionPolicy
    private let now: @Sendable () -> TimeInterval
    private enum State { case fresh, starting, running, finishing, closed, cancelled, failed }
    private var state = State.fresh
    private var generation = UUID()
    private var configuration = TranslationConfiguration()
    private var credentials = ProviderCredentials()
    private var ledger = TranscriptRevisionLedger()
    private struct Job { let segment: TranscriptSegment; let arrived: TimeInterval; let stamps = StageStamps() }
    private var jobs: [Job] = []
    private var inFlight: Job?
    /// The next segment is translated and synthesized while the current segment is spoken, so
    /// translation and synthesis latency overlap playback instead of adding a gap per segment.
    private var lookahead: (job: Job, translation: Task<String, Error>, speech: PreparedSpeech, preparation: Task<Void, Never>)?
    private var lastRate = 1.0
    nonisolated private let waiting = WaitingSegment()
    private func updateWaiting() { waiting.set(lookahead?.job.arrived ?? jobs.first?.arrived) }
    private var speaking = false
    private var queuedCharacters = 0
    private var consumer: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    init(recognizer: any StreamingSpeechRecognizer, translator: any TextTranslationStage,
         synthesizer: any SpeechSynthesisStage, policy: CompositionPolicy = CompositionPolicy(),
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.recognizer = recognizer; self.translator = translator; self.synthesizer = synthesizer
        self.policy = policy; self.now = clock
    }
    func start(configuration: TranslationConfiguration, apiKey: String) async throws {
        throw BridgeError.unavailable("This composed route needs separate service credentials from Settings.")
    }
    func start(configuration: TranslationConfiguration, credentials: ProviderCredentials) async throws {
        guard state == .fresh else { throw BridgeError.unavailable("Create a fresh translation session before starting again.") }
        guard configuration.route != .openAI else { throw BridgeError.unavailable("Use the direct OpenAI adapter for this route.") }
        try ProviderCapabilities.forRoute(configuration.route).validate(configuration)
        try credentials.validate(for: configuration.route)
        self.configuration = configuration; self.credentials = credentials
        policy.targetLag = configuration.pacing.targetLagSeconds
        state = .starting
        let token = generation
        recognizer.onEvent = { [weak self] event in
            guard let self, self.generation == token else { return }
            await self.recognized(event, token: token)
        }
        do {
            try await CompositionDeadline<Void>().run(seconds: policy.startTimeout) { [recognizer] in
                try await recognizer.start(configuration: configuration, credentials: credentials)
            }
            guard generation == token, state == .starting, !Task.isCancelled else { throw CancellationError() }
            state = .running; gate.open(token)
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                    guard let self, self.generation == token else { return }
                    if !self.speaking, let stuck = self.inFlight?.arrived, self.now() - stuck > self.policy.maximumAge {
                        await self.fail("translation_backlog_stale", token: token)
                        return
                    }
                    await self.catchUp(token: token)
                }
            }
            await onEvent?(.created)
            guard generation == token else { throw CancellationError() }
            await onEvent?(.updated)
        } catch {
            if generation == token { cancel() }
            if error is CancellationError { throw error }
            throw BridgeError.unavailable("Speech recognition could not start. Check the selected services and credentials.")
        }
    }
    nonisolated func append(_ pcm: Data) throws {
        guard gate.acceptsInput else { throw BridgeError.unavailable("The recognition input is closed.") }
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { throw BridgeError.invalidPCM }
        try recognizer.append(pcm)
    }
    private func recognized(_ event: RecognitionEvent, token: UUID) async {
        guard generation == token, state == .running || state == .finishing else { return }
        switch event {
        case .failure(let message):
            let transient = ["Speech recognition connection failed.", "Speech recognition upload failed.", "Speech recognition upload stalled."].contains(message)
            await fail(transient ? "recognition_transport" : "recognition_failed", token: token)
        case .closed:
            if state != .finishing { await fail("recognition_closed", token: token) }
        case .segment(let segment):
            do {
                let change = try ledger.accept(segment)
                guard change != .ignored else { return }
                await onEvent?(.segment(segment, role: .source))
                guard generation == token, change == .committed,
                      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                while !jobs.isEmpty, jobs.count + (inFlight == nil ? 0 : 1) + (lookahead == nil ? 0 : 1) >= policy.maximumSegments
                        || queuedCharacters + segment.text.count > policy.maximumCharacters {
                    skip(jobs.removeFirst())
                }
                guard jobs.count + (inFlight == nil ? 0 : 1) + (lookahead == nil ? 0 : 1) < policy.maximumSegments,
                      queuedCharacters + segment.text.count <= policy.maximumCharacters else {
                    await fail("translation_segment_backlog", token: token); return
                }
                await reportSkipped(token: token)
                queuedCharacters += segment.text.count
                jobs.append(Job(segment: segment, arrived: now())); updateWaiting()
                if consumer == nil { consumer = Task { [weak self] in await self?.consume(token: token) } }
                else { startLookahead() }
            } catch { await fail("recognition_segment_invalid", token: token) }
        }
    }
    /// Starts the next segment's translation and synthesis while the current segment is spoken.
    private func startLookahead() {
        guard speaking, lookahead == nil, !jobs.isEmpty else { return }
        let next = jobs.removeFirst()
        let pending = translation(for: next), speech = PreparedSpeech()
        let request = configuration, keys = credentials, stamps = next.stamps
        // Cancelling this task cancels the synthesis request, so a skipped segment frees its slot.
        let preparation = Task { @MainActor [synthesizer, gate, policy, now] in
            do {
                let text = try await pending.value
                guard !gate.outputDetached, !Task.isCancelled else { speech.finish(CancellationError()); return }
                stamps.mark("voice", now())
                try await CompositionDeadline<Void>().run(seconds: policy.stageTimeout) {
                    try await synthesizer.synthesize(text: text, language: request.targetLanguage, voiceID: request.voiceID,
                                                    credentials: keys, onAudio: { pcm in stamps.mark("voiced", now()); speech.append(pcm) })
                }
                speech.finish()
            } catch { speech.finish(error) }
        }
        lookahead = (next, pending, speech, preparation)
        updateWaiting()
    }
    private func translation(for job: Job) -> Task<String, Error> {
        let source = job.segment, request = configuration, keys = credentials, stamps = job.stamps
        return Task { @MainActor [translator, policy, now] in
            stamps.mark("translate", now())
            let text = try await CompositionDeadline<String>().run(seconds: policy.stageTimeout) {
                try await translator.translate(text: source.text, sourceLanguage: source.language ?? request.sourceLanguage,
                                               targetLanguage: request.targetLanguage, credentials: keys)
            }
            stamps.mark("translated", now())
            return text
        }
    }
    private func consume(token: UUID) async {
        while generation == token, !Task.isCancelled, lookahead != nil || !jobs.isEmpty {
            let job: Job, pending: Task<String, Error>, prepared: PreparedSpeech?
            await catchUp(token: token)
            guard generation == token else { return }
            if let ahead = lookahead { job = ahead.job; pending = ahead.translation; prepared = ahead.speech; lookahead = nil }
            else {
                guard !jobs.isEmpty else { break }
                job = jobs.removeFirst()
                pending = translation(for: job); prepared = nil
            }
            updateWaiting()
            inFlight = job
            let source = job.segment
            let request = configuration
            let keys = credentials
            var synthesizing = false
            do {
                let text = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 80_000 else { throw BridgeError.invalidEvent }
                let target = TranscriptSegment(id: source.id, revision: source.revision, text: text, isFinal: true,
                    language: request.targetLanguage, startSeconds: source.startSeconds, endSeconds: source.endSeconds,
                    speaker: source.speaker, timingReference: source.timingReference)
                await onEvent?(.segment(target, role: .target))
                guard generation == token, !Task.isCancelled else { return }
                speaking = true
                startLookahead()
                defer { speaking = false }
                if !gate.outputDetached {
                    synthesizing = true
                    let lag = now() - job.arrived
                    let rate = policy.speakingRate(lag: lag, previous: lastRate, waiting: waiting.oldest != nil)
                    let stretcher = SpeechRateStretcher()
                    let delivered = DeliveredBytes()
                    let pace = LiveRate(rate)
                    // While audio plays, a waiting segment's age drives the rate in small steps.
                    let adjust: @Sendable () -> Void = { [waiting, policy, now] in
                        let oldest = waiting.oldest
                        let current = pace.value
                        let target = oldest.map { policy.speakingRate(lag: max(lag, now() - $0), previous: current, waiting: true, step: 0.04) }
                            ?? policy.speakingRate(lag: lag, previous: current, step: 0.04)
                        pace.value = target
                        stretcher.setRate(target / pace.native)
                    }
                    let stamps = job.stamps, now = self.now
                    if let prepared {
                        // Synthesized ahead at normal speed; the rate applies now, at the measured delay.
                        stretcher.setRate(rate)
                        while let pcm = try await prepared.next() {
                            adjust()
                            let stretched = try stretcher.process(pcm)
                            if !stretched.isEmpty { stamps.mark("played", now()); delivered.add(stretched.count); try await gate.deliver(stretched, generation: token) }
                        }
                    } else {
                        if synthesizer.prepareSpeakingRate(rate) { pace.native = rate }
                        stretcher.setRate(rate / pace.native)
                        let deadline = CompositionDeadline<Void>()
                        synthesisDeadline = deadline
                        stamps.mark("voice", now())
                        try await deadline.run(seconds: policy.stageTimeout) { [synthesizer, gate] in
                            try await synthesizer.synthesize(text: text, language: request.targetLanguage, voiceID: request.voiceID,
                                                            credentials: keys, onAudio: { pcm in
                                stamps.mark("voiced", now())
                                adjust()
                                let stretched = try stretcher.process(pcm)
                                if !stretched.isEmpty { stamps.mark("played", now()); delivered.add(stretched.count); try await gate.deliver(stretched, generation: token) }
                            })
                        }
                        synthesisDeadline = nil
                    }
                    lastRate = pace.value
                    let rest = stretcher.finish()
                    if !rest.isEmpty { delivered.add(rest.count); try await gate.deliver(rest, generation: token) }
                    await onEvent?(.notice(String(format: "Segment timing: speech started %.1f s after commit, %.1f s of speech at %.2fx%@.",
                                                  lag, Double(delivered.total) / 48_000, pace.value, prepared == nil ? "" : ", prepared ahead")))
                    if let played = stamps.value("played") {
                        let passage = source.startSeconds.flatMap { start in source.endSeconds.map { $0 - start } }.flatMap { $0 > 0 ? $0 : nil }
                        await onEvent?(.passage(PassageTiming(passageSeconds: passage, translateSeconds: stamps.span("translate", "translated"),
                            voiceSeconds: stamps.span("voice", "voiced"), preparedAhead: prepared != nil, totalSeconds: played - job.arrived,
                            speechSeconds: Double(delivered.total) / 48_000, rate: pace.value)))
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                queuedCharacters -= source.text.count; inFlight = nil
            } catch {
                synthesisDeadline = nil
                guard generation == token else { return }
                if synthesizing, gate.outputDetached, !gate.failedPlayback {
                    // Deliberate text-only completion cancels speech, not queued translation jobs.
                    queuedCharacters -= source.text.count; inFlight = nil
                    continue
                }
                if gate.failedPlayback {
                    await fail("audio_playback_failed", token: token)
                } else {
                    // All currently composed routes use OpenAI text translation; the selected
                    // route names its speech backend. Only closed diagnostic values are logged.
                    let stage = synthesizing ? "\(request.route.displayName) speech synthesis" : "OpenAI text translation"
                    await onEvent?(.notice("\(stage) failed. \(TranslationFailureReason(error: error).safeSummary)"))
                    let base = synthesizing ? "speech_synthesis_failed" : "text_translation_failed"
                    await fail(base + (TranslationFailureReason(error: error).isTransient ? "_transient" : ""), token: token)
                }
                return
            }
        }
        if generation == token { consumer = nil }
    }
    /// Drops waiting segments that are older than `maximumAge`, oldest first. The source
    /// transcript keeps their text; only their translation and speech are skipped.
    private func catchUp(token: UUID) async {
        guard generation == token else { return }
        if let ahead = lookahead, now() - ahead.job.arrived > policy.maximumAge {
            ahead.translation.cancel(); ahead.preparation.cancel(); ahead.speech.finish(CancellationError()); lookahead = nil; skip(ahead.job)
        }
        while let first = jobs.first, now() - first.arrived > policy.maximumAge { skip(jobs.removeFirst()) }
        updateWaiting()
        await reportSkipped(token: token)
    }
    private var skippedSegments = 0
    private func skip(_ job: Job) { queuedCharacters -= job.segment.text.count; skippedSegments += 1 }
    private func reportSkipped(token: UUID) async {
        guard skippedSegments > 0, generation == token else { return }
        let count = skippedSegments; skippedSegments = 0
        await onEvent?(.notice("Skipped \(count) recognized segment\(count == 1 ? "" : "s") to catch up with the speaker."))
    }
    func stopInput() {
        gate.closeInput()
        onAudio = nil
        recognizer.stopInput()
        if synthesisDeadline != nil || lookahead != nil {
            synthesisDeadline?.cancel()
            lookahead?.preparation.cancel(); lookahead?.speech.finish(CancellationError())
            synthesizer.cancel()
        }
    }
    func finish() async {
        guard state == .running else { return }
        state = .finishing; gate.closeInput()
        let token = generation
        do {
            try await CompositionDeadline<Void>().run(seconds: policy.finishTimeout) { [self] in
                try await recognizer.finish()
                while generation == token, consumer != nil {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard generation == token else { throw CancellationError() }
            }
            guard generation == token else { return }
            state = .closed
            gate.cancel(); monitor?.cancel(); monitor = nil
            recognizer.onEvent = nil
            credentials = ProviderCredentials()
            await onEvent?(.closed)
        } catch {
            guard generation == token else { return }
            await fail("finalization_timed_out", token: token)
        }
    }
    func cancel() {
        generation = UUID(); gate.cancel()
        synthesisDeadline?.cancel(); synthesisDeadline = nil
        recognizer.onEvent = nil
        recognizer.cancel(); translator.cancel(); synthesizer.cancel()
        consumer?.cancel(); consumer = nil; monitor?.cancel(); monitor = nil
        lookahead?.translation.cancel(); lookahead?.preparation.cancel(); lookahead?.speech.finish(CancellationError()); lookahead = nil
        jobs.removeAll(); inFlight = nil; queuedCharacters = 0; waiting.set(nil)
        credentials = ProviderCredentials(); state = .cancelled
    }
    private func fail(_ code: String, token: UUID) async {
        guard generation == token else { return }
        cancel(); state = .failed
        await onEvent?(.failure(code))
    }
}
