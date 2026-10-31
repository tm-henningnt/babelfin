import Foundation
import AVFoundation
import CAtomicMixer

public struct CaptureMetrics: Sendable {
    public init() {}
    public var queuedBuffers = 0
    public var maximumQueuedBuffers = 0
    public var capturedFrames: UInt64 = 0
    public var callbacks: UInt64 = 0
    public var zeroFrameCallbacks: UInt64 = 0
    public var deliveredFrames: UInt64 = 0
    public var oldestAge: TimeInterval = 0
    public var level: Float = 0
    public var signal = AudioSignalMetrics()
}

#if BABELFIN_AUDIO_TRACE
/// Fixed-size off-real-time diagnostics. All times use systemUptime seconds;
/// failure time is when the consumer observed the error, not the RT error instant.
public enum CaptureDiagnosticStage: Sendable {
    case pushToDrain, conversion, originalControlWait, originalControlExecution, delivery
}
public struct CaptureDiagnosticSpan: Sendable {
    public let begin: TimeInterval
    public let end: TimeInterval
    public var seconds: TimeInterval { max(0, end - begin) }
}
public struct CaptureDiagnosticHistory: Sendable {
    public fileprivate(set) var count: UInt64 = 0
    public fileprivate(set) var last: CaptureDiagnosticSpan?
    public fileprivate(set) var maximum: CaptureDiagnosticSpan?
    fileprivate mutating func record(_ span: CaptureDiagnosticSpan) {
        count += 1
        last = span
        if maximum == nil || span.seconds > maximum!.seconds { maximum = span }
    }
}
public struct CaptureFailureObservation: Sendable {
    public let observedUptime: TimeInterval
    public let rawError: UInt32
    public let metrics: CaptureMetrics
}
public struct CaptureDiagnosticSnapshot: Sendable {
    /// Real-time push of a slot to the start of its conversion; includes consumer wake latency.
    public fileprivate(set) var pushToDrain = CaptureDiagnosticHistory()
    public fileprivate(set) var conversion = CaptureDiagnosticHistory()
    public fileprivate(set) var originalControlWait = CaptureDiagnosticHistory()
    public fileprivate(set) var originalControlExecution = CaptureDiagnosticHistory()
    public fileprivate(set) var delivery = CaptureDiagnosticHistory()
    public fileprivate(set) var firstFailure: CaptureFailureObservation?
}
public final class CaptureDeliveryDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var state = CaptureDiagnosticSnapshot()
    public init() {}
    /// Caller is the conversion or control lane, never the sink receiver.
    public func record(_ stage: CaptureDiagnosticStage, begin: TimeInterval, end: TimeInterval) {
        let span = CaptureDiagnosticSpan(begin: begin, end: end)
        lock.lock(); defer { lock.unlock() }
        switch stage {
        case .pushToDrain: state.pushToDrain.record(span)
        case .conversion: state.conversion.record(span)
        case .originalControlWait: state.originalControlWait.record(span)
        case .originalControlExecution: state.originalControlExecution.record(span)
        case .delivery: state.delivery.record(span)
        }
    }
    fileprivate func observeFailure(rawError: UInt32, at uptime: TimeInterval, metrics: CaptureMetrics) {
        lock.lock(); defer { lock.unlock() }
        if state.firstFailure == nil {
            state.firstFailure = CaptureFailureObservation(observedUptime: uptime, rawError: rawError, metrics: metrics)
        }
    }
    public var snapshot: CaptureDiagnosticSnapshot { lock.lock(); defer { lock.unlock() }; return state }
    public var summary: String {
        let value = snapshot
        func span(_ value: CaptureDiagnosticSpan?) -> String {
            guard let value else { return "none" }
            return String(format: "[%.9f,%.9f;%.6fs]", value.begin, value.end, value.seconds)
        }
        func history(_ name: String, _ value: CaptureDiagnosticHistory) -> String {
            " \(name){count=\(value.count),last=\(span(value.last)),max=\(span(value.maximum))};"
        }
        let failure: String
        if let f = value.firstFailure {
            failure = String(format: "observedError{uptime=%.9f,raw=%u,queued=%d,peak=%d,oldest=%.6fs,callbacks=%llu,captured=%llu,delivered=%llu};",
                f.observedUptime, f.rawError, f.metrics.queuedBuffers, f.metrics.maximumQueuedBuffers,
                f.metrics.oldestAge, f.metrics.callbacks, f.metrics.capturedFrames, f.metrics.deliveredFrames)
        } else { failure = "observedError=none;" }
        return " Capture diagnostics (offRT observation; uptime seconds): " + failure +
            history("pushToDrain", value.pushToDrain) + history("conversion", value.conversion) + history("originalControlWait", value.originalControlWait) +
            history("originalControlExecution", value.originalControlExecution) + history("delivery", value.delivery)
    }
}
#endif

/// One dedicated consumer thread with a time-constraint scheduling policy. Between the
/// two real-time IO threads, a non-real-time consumer was preempted for 20–40ms, which
/// exceeds the 10ms original lead. The thread runs drains and queued jobs serially.
final class CaptureConsumerThread: @unchecked Sendable {
    let semaphore: semaphore_t
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    private var stopped = false
    private var drain: (() -> Void)?
    /// KERN_SUCCESS when the time-constraint policy was applied; nil before the thread runs.
    private(set) var policyResult: kern_return_t? {
        get { lock.lock(); defer { lock.unlock() }; return storedPolicyResult }
        set { lock.lock(); storedPolicyResult = newValue; lock.unlock() }
    }
    private var storedPolicyResult: kern_return_t?
    init() throws {
        var created = semaphore_t()
        guard semaphore_create(mach_task_self_, &created, SYNC_POLICY_FIFO, 0) == KERN_SUCCESS else {
            throw BridgeError.unavailable("Audio capture could not create its consumer.")
        }
        semaphore = created
    }
    deinit { semaphore_destroy(mach_task_self_, semaphore) }
    func start(drain: @escaping () -> Void) {
        lock.lock(); self.drain = drain; lock.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "Babelfin.capture-conversion"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func async(_ job: @escaping () -> Void) {
        lock.lock(); jobs.append(job); lock.unlock()
        semaphore_signal(semaphore)
    }
    func stop() {
        lock.lock(); stopped = true; drain = nil; lock.unlock()
        semaphore_signal(semaphore)
    }
    private func run() {
        policyResult = Self.applyTimeConstraintPolicy()
        while true {
            semaphore_wait(semaphore)
            lock.lock()
            let stop = stopped, pending = jobs, drain = self.drain
            jobs = []
            lock.unlock()
            if stop { return }
            drain?()
            pending.forEach { $0() }
        }
    }
    /// Period is one 512-frame quantum at 48kHz; typical drains measure under 1ms.
    private static func applyTimeConstraintPolicy() -> kern_return_t {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func ticks(_ nanoseconds: Double) -> UInt32 { UInt32(nanoseconds * Double(timebase.denom) / Double(timebase.numer)) }
        var policy = thread_time_constraint_policy_data_t(period: ticks(10_666_667), computation: ticks(3_000_000),
                                                          constraint: ticks(10_000_000), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        return withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }
}

/// Four owned raw slots shared by one non-reentrant sink receiver and one serial
/// conversion consumer. A slot remains reserved through synchronous delivery.
/// Only setup/consumer/control paths touch AVFoundation, locks and Swift metrics.
public final class CaptureDelivery: @unchecked Sendable {
    private let consumer: CaptureConsumerThread
    private let lock = NSLock()
    private let conversion: CaptureConversion
    private let deliver: @Sendable (Data) throws -> Void
    private let failure: @Sendable (String) -> Void
    private let ring: OpaquePointer
    private let buffer: AVAudioPCMBuffer
    private var failed = false
    private var firstFailure: BridgeError?
    private var metrics = CaptureMetrics()
    #if BABELFIN_AUDIO_TRACE
    private var diagnostics: CaptureDeliveryDiagnostics?
    /// Bind during graph setup before opening ingress; no trace work runs on RT.
    public func configureDiagnostics(_ diagnostics: CaptureDeliveryDiagnostics) {
        lock.lock(); self.diagnostics = diagnostics; lock.unlock()
    }
    private var diagnosticTrace: CaptureDeliveryDiagnostics? {
        lock.lock(); defer { lock.unlock() }; return diagnostics
    }
    public var diagnosticSummary: String {
        let realtime = consumerRealtime.map { $0 ? "true" : "false" } ?? "pending"
        return (diagnosticTrace?.summary ?? "") + " consumerRealtime=\(realtime);"
    }
    #endif

    /// Compatibility fixture seam; production supplies the audio unit's maximum slice.
    public convenience init(conversion: CaptureConversion, capacity: Int = 4,
                deliver: @escaping @Sendable (Data) throws -> Void,
                failure: @escaping @Sendable (String) -> Void) {
        try! self.init(conversion: conversion, maximumFrames: 16_384, capacity: capacity,
                       deliver: deliver, failure: failure)
    }
    public init(conversion: CaptureConversion, maximumFrames: AVAudioFrameCount, capacity: Int = 4, initiallyAccepting: Bool = true,
                deliver: @escaping @Sendable (Data) throws -> Void,
                failure: @escaping @Sendable (String) -> Void) throws {
        let format = conversion.sourceFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0, maximumFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames),
              let ring = bf_capture_create(capacity, maximumFrames, format.channelCount,
                  format.streamDescription.pointee.mBytesPerFrame, format.isInterleaved, initiallyAccepting) else {
            throw BridgeError.invalidPCM
        }
        let consumer: CaptureConsumerThread
        do { consumer = try CaptureConsumerThread() } catch { bf_capture_destroy(ring); throw error }
        self.conversion = conversion; self.deliver = deliver; self.failure = failure
        self.ring = ring; self.buffer = buffer; self.consumer = consumer
        // One semaphore signal per push or failure. No per-callback work item, Task or
        // unbounded secondary queue; payload storage is solely the four C slots.
        bf_capture_set_wake_semaphore(ring, consumer.semaphore)
        consumer.start { [weak self] in self?.drainRaw() }
    }
    deinit {
        bf_capture_destroy(ring)
        consumer.stop()
    }
    /// Whether the consumer thread runs with the time-constraint policy (nil until it starts).
    public var consumerRealtime: Bool? { consumer.policyResult.map { $0 == KERN_SUCCESS } }

    /// Real-time production seam. Copies bytes before returning; C uses only
    /// preallocated storage, lock-free atomics and a coalesced dispatch wake.
    @discardableResult
    public func captureRaw(frames: AVAudioFrameCount, buffers: UnsafePointer<AudioBufferList>) -> Bool {
        bf_capture_push(ring, frames, buffers)
    }
    public func capture(_ source: AVAudioPCMBuffer) {
        guard source.format.isEqual(conversion.sourceFormat), source.frameLength <= source.frameCapacity else {
            bf_capture_fail(ring, 1); return
        }
        captureRaw(frames: source.frameLength, buffers: source.audioBufferList)
        observeRawFailure() // compatibility seam runs off the real-time lane
    }
    private func observeRawFailure() {
        switch bf_capture_snapshot(ring).error {
        case 1: reportFailure(.unavailable("Invalid capture buffer size or format. Choose another source and start again."))
        case 2: reportFailure(.unavailable("Audio source processing or delivery fell behind. Start again."))
        default: break
        }
    }
    private func drainRaw() {
        observeRawFailure()
        while case let frames = bf_capture_front_frames(ring), frames > 0 {
            // Slot is intentionally not free while conversion or delivery blocks.
            defer { bf_capture_release_front(ring) }
            #if BABELFIN_AUDIO_TRACE
            let pushed = bf_capture_front_host_time(ring)
            if pushed != 0 {
                diagnosticTrace?.record(.pushToDrain, begin: AVAudioTime.seconds(forHostTime: pushed),
                                        end: ProcessInfo.processInfo.systemUptime)
            }
            #endif
            guard canDeliver else { continue }
            buffer.frameLength = frames
            guard bf_capture_copy_front(ring, buffer.mutableAudioBufferList) else {
                reportFailure(.invalidPCM); continue
            }
            do {
                let (chunks, level) = try convertMeasured(buffer)
                lock.lock(); metrics.level = level; lock.unlock()
                for chunk in chunks {
                    guard canDeliver else { break }
                    recordSignal(chunk)
                    try deliverMeasured(chunk)
                    lock.lock(); metrics.deliveredFrames += UInt64(chunk.count / 2); lock.unlock()
                }
            } catch { reportFailure(error as? BridgeError ?? .unavailable("Audio source conversion or delivery failed. Start again.")) }
            observeRawFailure()
        }
        observeRawFailure()
    }
    private func convertMeasured(_ buffer: AVAudioPCMBuffer) throws -> ([Data], Float) {
        #if BABELFIN_AUDIO_TRACE
        let trace = diagnosticTrace
        let begin = ProcessInfo.processInfo.systemUptime
        defer { trace?.record(.conversion, begin: begin, end: ProcessInfo.processInfo.systemUptime) }
        #endif
        return try conversion.convert(buffer)
    }
    private func deliverMeasured(_ pcm: Data) throws {
        #if BABELFIN_AUDIO_TRACE
        let trace = diagnosticTrace
        let begin = ProcessInfo.processInfo.systemUptime
        defer { trace?.record(.delivery, begin: begin, end: ProcessInfo.processInfo.systemUptime) }
        #endif
        try deliver(pcm)
    }
    private var canDeliver: Bool {
        let raw = bf_capture_snapshot(ring)
        guard !raw.cancelled, raw.error == 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        return !failed
    }
    private func reportFailure(_ error: BridgeError) {
        bf_capture_fail(ring, 3) // converter/downstream failures also close real-time admission
        lock.lock()
        let notify = !failed && !bf_capture_snapshot(ring).cancelled
        failed = true
        if firstFailure == nil { firstFailure = error }
        lock.unlock()
        if notify {
            #if BABELFIN_AUDIO_TRACE
            let observedUptime = ProcessInfo.processInfo.systemUptime
            diagnosticTrace?.observeFailure(rawError: bf_capture_snapshot(ring).error,
                at: observedUptime, metrics: snapshot)
            #endif
            failure(error.localizedDescription)
        }
    }
    private func recordSignal(_ pcm: Data) {
        lock.lock(); var signal = metrics.signal; lock.unlock()
        try? signal.recordPCM16(pcm)
        lock.lock(); metrics.signal = signal; lock.unlock()
    }
    /// Admission stays closed while the control lane starts/reconfigures engines.
    /// These barriers wait only for a real-time copy, never the conversion queue.
    public func begin() { bf_capture_begin(ring) }
    public func pause() { bf_capture_pause(ring) }
    public func cancel() { bf_capture_close(ring, true) }
    public func finish() async throws {
        // Gate and wait off RT before enqueuing the finish barrier: a copy already
        // admitted cannot publish after the final drain, even if its wake was late.
        bf_capture_close(ring, false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            consumer.async { [self] in
                drainRaw()
                do {
                    if let error = failureBeforeDrain { throw error }
                    guard canDeliver else { continuation.resume(); return }
                    for chunk in try conversion.finish() {
                        if let error = failureBeforeDrain { throw error }
                        guard canDeliver else { continuation.resume(); return }
                        recordSignal(chunk)
                        try deliverMeasured(chunk)
                        lock.lock(); metrics.deliveredFrames += UInt64(chunk.count / 2); lock.unlock()
                    }
                    continuation.resume()
                } catch {
                    reportFailure(error as? BridgeError ?? .unavailable("Audio source finalization failed."))
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private var failureBeforeDrain: BridgeError? {
        guard !bf_capture_snapshot(ring).cancelled else { return nil }
        lock.lock(); defer { lock.unlock() }
        return firstFailure
    }
    public var snapshot: CaptureMetrics {
        let raw = bf_capture_snapshot(ring)
        lock.lock(); var result = metrics; lock.unlock()
        result.callbacks = raw.callbacks; result.zeroFrameCallbacks = raw.empty_callbacks
        result.capturedFrames = raw.captured_frames
        result.queuedBuffers = Int(raw.queued); result.maximumQueuedBuffers = Int(raw.peak)
        result.oldestAge = raw.oldest_host_time == 0 ? 0 : max(0,
            ProcessInfo.processInfo.systemUptime - AVAudioTime.seconds(forHostTime: raw.oldest_host_time))
        return result
    }
}
