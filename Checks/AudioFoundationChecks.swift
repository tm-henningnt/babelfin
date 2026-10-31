import Foundation
import AVFoundation
import BridgeCore

private final class CaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var failures: [String] = []
    func append(_ data: Data) { lock.lock(); chunks.append(data); lock.unlock() }
    func fail(_ value: String) { lock.lock(); failures.append(value); lock.unlock() }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return chunks.reduce(into: Data()) { $0.append($1) } }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures.count }
}

private final class AdmissionProbe: @unchecked Sendable {
    enum Progress { case render, invalidate, stall }
    private let lock = NSLock()
    private let queue = PlaybackBufferQueue()
    private let scheduler = DelayedDeviceScheduler()
    private var valid = true
    private var clock: TimeInterval = 0
    private var received = Data()
    private var peak = 0
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
    func admit(_ pcm: Data) throws -> PlaybackAdmissionDecision {
        lock.lock(); defer { lock.unlock() }
        guard valid else { return .invalidated }
        let frames = pcm.count / 2
        guard queue.remainingFrames >= frames else { return .wait }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        try queue.schedule(buffer, on: scheduler)
        received.append(pcm)
        peak = max(peak, queue.queuedFrames)
        return .admitted
    }
    func advance() {
        lock.lock(); defer { lock.unlock() }
        clock += 0.1
        switch progress {
        case .render: scheduler.renderNext()
        case .invalidate: valid = false; queue.reset()
        case .stall: break
        }
    }
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return clock }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return received }
    var maximumFrames: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

enum AudioFoundationChecks {
    private static func source(frames: UInt32, rate: Double = 48_000, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
        return buffer
    }
    private static func conversion(from source: AVAudioFormat) -> CaptureConversion {
        let target = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        return CaptureConversion(converter: AVAudioConverter(from: source, to: target)!, target: target)
    }
    static func run() async throws -> Int {
        var count = 0
        // Actual converter drain retains a short utterance that packetization alone emits as zero packets.
        let short = source(frames: 960)
        let converter = conversion(from: short.format)
        let (before, _) = try converter.convert(short)
        try expect(before.isEmpty, "Short capture should still be pending before finalization")
        let tail = try converter.finish().reduce(into: Data()) { $0.append($1) }
        try expect(!tail.isEmpty && tail.count < 4800, "Finalization must deliver the last partial PCM packet")
        let repeatedTail = try converter.finish()
        try expect(repeatedTail.isEmpty, "Converter finalization must be idempotent")
        try rejects { _ = try converter.convert(short) }
        count += 1
        print("PASS: Short input tail drains the real converter exactly once")

        let probe = CaptureProbe()
        let delivery = CaptureDelivery(conversion: conversion(from: short.format), deliver: { probe.append($0) }, failure: { probe.fail($0) })
        delivery.capture(short)
        try await delivery.finish()
        try expect(probe.bytes == tail, "Capture finish must follow queued conversion and preserve its tail")
        delivery.capture(short)
        try await delivery.finish()
        try expect(probe.bytes == tail, "Closed capture must reject later buffers and not resend its tail")
        count += 1
        print("PASS: Capture close orders queued conversion before its final tail")

        // Block the actual consumer, not the converter: its in-flight slot must stay reserved.
        let big = source(frames: 9600)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blockedProbe = CaptureProbe()
        let bounded = CaptureDelivery(conversion: conversion(from: big.format), capacity: 4, deliver: { data in
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            blockedProbe.append(data)
        }, failure: { blockedProbe.fail($0) })
        bounded.capture(big)
        try expect(entered.wait(timeout: .now() + 2) == .success, "Test consumer did not receive a packet")
        for _ in 0..<3 { bounded.capture(big) }
        let full = bounded.snapshot
        try expect(full.queuedBuffers == 4 && full.maximumQueuedBuffers == 4, "Bound must include the blocked consumer")
        bounded.capture(big)
        try expect(blockedProbe.failureCount == 1, "Fifth buffer must fail explicitly instead of escaping to another queue")
        release.signal()
        var overflowPropagated = false
        do { try await bounded.finish() } catch { overflowPropagated = true }
        try expect(overflowPropagated, "A capture failure before finish must not finalize successfully")
        try expect(bounded.snapshot.maximumQueuedBuffers == 4, "Consumer stall must never enlarge capture budget")
        count += 1
        print("PASS: Capture bound includes slow delivery and propagates failure through finalization")

        let failing = CaptureDelivery(conversion: conversion(from: short.format), deliver: { _ in throw BridgeError.uploadBacklog }, failure: { _ in })
        failing.capture(short)
        var deliveryFailed = false
        do { try await failing.finish() } catch BridgeError.uploadBacklog { deliveryFailed = true }
        try expect(deliveryFailed, "Failure while sending final tail must propagate its safe provider error")
        count += 1
        print("PASS: Final-tail delivery failure is not reported as successful shutdown")

        let cancelledProbe = CaptureProbe()
        let cancelled = CaptureDelivery(conversion: conversion(from: short.format), deliver: { cancelledProbe.append($0) }, failure: { cancelledProbe.fail($0) })
        cancelled.capture(short)
        cancelled.cancel()
        try await cancelled.finish()
        try expect(cancelledProbe.bytes.isEmpty, "Abort must discard a partial capture tail")
        count += 1
        print("PASS: Abort discards pending capture tail")

        let queue = PlaybackBufferQueue()
        let scheduler = DelayedDeviceScheduler()
        let buffer = source(frames: 2400, rate: 24_000)
        try queue.schedule(buffer, on: scheduler)
        try queue.schedule(buffer, on: scheduler)
        scheduler.renderNext()
        let rendered = queue.snapshot
        try expect(rendered.admittedFrames == 4800 && rendered.renderedFrames == 2400 && rendered.queuedFrames == 2400, "Render telemetry must reconcile admitted frames")
        queue.reset()
        let reset = queue.snapshot
        try expect(reset.discardedFrames == 2400 && reset.queuedFrames == 0, "Reset must account for lost queued speech")
        scheduler.renderAll()
        try expect(queue.snapshot.renderedFrames == 2400, "Stale render completion must not inflate telemetry")
        count += 1
        print("PASS: Playback counters distinguish rendered and discarded frames")

        let burst = Data((0..<144_000).map { UInt8(truncatingIfNeeded: $0) })
        let draining = AdmissionProbe(.render)
        let remainder = try await PlaybackAdmission().play(burst, admit: { try draining.admit($0) },
            now: { draining.now }, sleep: { draining.advance(); await Task.yield() })
        try expect(remainder == 0 && draining.bytes == burst, "Large output event must retain complete byte order through admission waits")
        try expect(draining.maximumFrames == 48_000, "Large burst must never expand the two-second renderer cap")
        count += 1
        print("PASS: Three-second event drains in order through the real two-second admission budget")

        let resetDuringWait = AdmissionProbe(.invalidate)
        let dropped = try await PlaybackAdmission().play(burst, admit: { try resetDuringWait.admit($0) },
            now: { resetDuringWait.now }, sleep: { resetDuringWait.advance(); await Task.yield() })
        try expect(dropped == 24_000 && resetDuringWait.bytes.count == 96_000, "Stop or recovery must invalidate a waiting generation and report its abandoned remainder")
        count += 1
        print("PASS: Stop or graph recovery invalidates admission waiting on a full renderer")

        let stalled = AdmissionProbe(.stall)
        var timedOut = false
        do {
            _ = try await PlaybackAdmission(timeout: 0.5).play(burst, admit: { try stalled.admit($0) },
                now: { stalled.now }, sleep: { stalled.advance(); await Task.yield() })
        } catch BridgeError.unavailable { timedOut = true }
        try expect(timedOut && stalled.bytes.count == 96_000, "A stalled renderer must fail within its deadline without scheduling extra audio")
        count += 1
        print("PASS: Stalled renderer has a deterministic admission deadline")

        let cancelProbe = AdmissionProbe(.stall)
        let sleeping = DispatchSemaphore(value: 0)
        let task = Task {
            try await PlaybackAdmission().play(burst, admit: { try cancelProbe.admit($0) }, sleep: {
                sleeping.signal()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            })
        }
        let didWait = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: sleeping.wait(timeout: .now() + 2) == .success) }
        }
        task.cancel()
        var cancelledWait = false
        do { _ = try await task.value } catch is CancellationError { cancelledWait = true }
        try expect(didWait && cancelledWait && cancelProbe.bytes.count == 96_000, "Cancellation must interrupt an admission wait without appending more PCM")
        count += 1
        print("PASS: Task cancellation interrupts a pending playback admission")

        var silentSignal = AudioSignalMetrics()
        try silentSignal.recordPCM16(Data(repeating: 0, count: 4800))
        try expect(silentSignal.samples == 2400 && silentSignal.nonzeroSamples == 0 && silentSignal.rms == 0 && silentSignal.peak == 0,
                   "Valid silent PCM must be distinguishable from no samples")
        var signal = AudioSignalMetrics()
        try signal.recordPCM16(Data([0, 0, 0, 32, 0, 192])) // 0, +0.25, -0.5 exactly.
        try expect(signal.samples == 3 && signal.nonzeroSamples == 2 && signal.peak == 0.5,
                   "PCM signal counts/peak must preserve signed little-endian amplitudes")
        try expect(abs(signal.rms - sqrt((0.25 * 0.25 + 0.5 * 0.5) / 3)) < 0.000001,
                   "Signal RMS must include zero samples")
        try rejects { try signal.recordPCM16(Data([0])) }
        count += 1
        print("PASS: Numeric PCM diagnostics distinguish silence from nonzero signal")

        let silentBuffer = source(frames: 2400, rate: 24_000, value: 0)
        let emptyBuffer = source(frames: 16, rate: 24_000, value: 0)
        emptyBuffer.frameLength = 0
        let silentCapture = CaptureDelivery(conversion: conversion(from: silentBuffer.format), deliver: { _ in }, failure: { _ in })
        silentCapture.capture(emptyBuffer)
        silentCapture.capture(silentBuffer)
        try await silentCapture.finish()
        let silentSnapshot = silentCapture.snapshot
        try expect(silentSnapshot.callbacks == 2 && silentSnapshot.zeroFrameCallbacks == 1 && silentSnapshot.capturedFrames == 2400,
                   "Tap counters must distinguish an empty callback from a valid silent buffer")
        try expect(silentSnapshot.signal.samples > 0 && silentSnapshot.signal.nonzeroSamples == 0 && silentSnapshot.signal.rms == 0,
                   "Real conversion of silence must report valid zero-energy PCM")
        let signalBuffer = source(frames: 2400, rate: 24_000, value: 0.25)
        let signalCapture = CaptureDelivery(conversion: conversion(from: signalBuffer.format), deliver: { _ in }, failure: { _ in })
        signalCapture.capture(signalBuffer)
        try await signalCapture.finish()
        try expect(signalCapture.snapshot.signal.nonzeroSamples > 0 && signalCapture.snapshot.signal.peak > 0.2,
                   "Actual capture delivery must populate nonzero PCM telemetry")
        count += 1
        print("PASS: Tap diagnostics separate absent frames, silent PCM and nonzero PCM")

        var progress = CaptureProgressWatchdog()
        progress.reset(at: 10)
        try expect(!progress.isStalled(frames: 0, at: 14.9) && progress.isStalled(frames: 0, at: 15),
                   "No-frame startup must fail at the five-second deadline")
        progress.reset(at: 20)
        try expect(!progress.isStalled(frames: 2400, at: 21), "Valid silent frames count as capture progress")
        try expect(!progress.isStalled(frames: 4800, at: 25) && !progress.isStalled(frames: 4800, at: 29.9),
                   "New frames must reset the no-progress deadline regardless of signal level")
        try expect(progress.isStalled(frames: 4800, at: 30), "A running engine with stalled valid frames must fail explicitly")
        progress.reset(at: 40)
        try expect(!progress.isStalled(frames: 0, at: 44.9), "A recovered generation must get its own startup grace period")
        count += 1
        print("PASS: Capture watchdog detects missing frames without treating acoustic silence as failure")

        let bluetoothHardware = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let staleClient = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let selection = try CaptureFormatPolicy.select(hardware: bluetoothHardware, client: staleClient, installed: staleClient)
        try expect(selection.format.sampleRate == 24_000 && selection.requiresRebuild,
                   "AirPods hardware24k/client48k must select hardware24k and rebuild capture")
        var changedHealth = AudioGraphHealth()
        changedHealth.inputFormatChanged = selection.requiresRebuild
        var formatRecovery = AudioConfigurationRecovery()
        try expect(formatRecovery.evaluate(changedHealth, at: 1) == .recover(capture: true, playback: false),
                   "Hardware/client capture mismatch must recover only capture even when both engines report running")
        let settled = try CaptureFormatPolicy.select(hardware: bluetoothHardware, client: bluetoothHardware, installed: bluetoothHardware)
        try expect(!settled.requiresRebuild, "Settled hardware/client24k must not cause repeated recovery")
        for (rate, channels) in [(0.0, UInt32(1)), (Double.nan, UInt32(1)), (Double.infinity, UInt32(1)), (24_000.0, UInt32(0))] {
            try rejects { try CaptureFormatPolicy.validateHardware(sampleRate: rate, channels: channels) }
        }
        let selectedConverter = conversion(from: selection.format)
        let hardwareFrames = source(frames: 2400, rate: 24_000, value: 0.25)
        let (selectedPackets, _) = try selectedConverter.convert(hardwareFrames)
        let selectedTail = try selectedConverter.finish()
        let selectedBytes = (selectedPackets + selectedTail).reduce(into: Data()) { $0.append($1) }
        try expect(selectedBytes.count == 4800, "Hardware24k selection must preserve100ms through the actual converter, not halve its duration")
        count += 1
        print("PASS: Capture hardware format drives tap conversion and mismatch recovery")
        try expect(!ConsumerObservation.matches(processID: 10, ownProcessID: 10, runningInput: true, inputDevices: [2], selectedDevice: 2),
                   "Our own audio IO must not trigger consumer detection")
        try expect(!ConsumerObservation.matches(processID: 11, ownProcessID: 10, runningInput: false, inputDevices: [2], selectedDevice: 2),
                   "Selected but inactive input must not trigger consumer detection")
        try expect(!ConsumerObservation.matches(processID: 11, ownProcessID: 10, runningInput: true, inputDevices: [3], selectedDevice: 2),
                   "Other input devices must not count as virtual microphone consumers")
        try expect(ConsumerObservation.matches(processID: 11, ownProcessID: 10, runningInput: true, inputDevices: [2], selectedDevice: 2),
                   "External active input consumer must match")
        var debounce = ConsumerDebouncer()
        try expect(debounce.update(.active, at: 0) == .unknown && debounce.update(.active, at: 0.49) == .unknown,
                   "Brief consumer changes must not start automatic capture")
        try expect(debounce.update(.active, at: 0.5) == .active, "Stable consumer must become active")
        try expect(debounce.update(.unknown, at: 0.6) == .unknown, "Read failure must remain unknown, not idle or active")
        try expect(debounce.update(.unsupported, at: 1) == .unsupported, "Missing runtime support must be explicit")
        count += 1
        print("PASS: Consumer metadata matching excludes self and debounces active input")

        let liveOriginal = CaptureProbe()
        let streaming = CaptureConversion(converter: AVAudioConverter(from: short.format, to: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)!,
            target: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!, convertedPCM: { liveOriginal.append($0) })
        let (networkPending, _) = try streaming.convert(short)
        try expect(networkPending.isEmpty && !liveOriginal.bytes.isEmpty,
                   "Original speech must become available before the100ms network packet fills")
        let lowLatency = CaptureConversion(converter: AVAudioConverter(from: short.format, to: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)!,
            target: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!, packetFrames: 480)
        // The real resampler has an initial priming delay; two20ms input blocks allow
        // its first packet without pretending the hardware-to-output latency is20ms.
        let (localPackets, _) = try lowLatency.convert(source(frames: 1920))
        try expect(!localPackets.isEmpty && localPackets.allSatisfy { $0.count == 960 }, "Original-only packetization must emit20ms packets")
        count += 1
        print("PASS: Original capture bypasses network packetization without altering default packets")

        let mixed = RenderAudioMixer(originalLevel: 0.5, ducking: true)
        try mixed.appendOriginal(PCM16.encode([Float](repeating: 0.4, count: 1000)))
        let speechBuffer = source(frames: 480, rate: 24_000, value: 0.2)
        let mixedQueue = PlaybackBufferQueue()
        try mixedQueue.schedule(speechBuffer, on: mixed)
        var renderedMix = [Float](repeating: 0, count: 240)
        renderedMix.withUnsafeMutableBufferPointer { mixed.render(into: $0) }
        try expect(abs(renderedMix[239] - 0.4) < 0.001,
                   "The original must keep full level until translated speech plays")
        mixed.startPlayback()
        renderedMix.withUnsafeMutableBufferPointer { mixed.render(into: $0) }
        try expect(renderedMix[0] > 0.39 / 1.5 && abs(renderedMix[239] - 0.23 / 1.5) < 0.002,
                   "Duck attack must follow actually rendered translated samples")
        mixed.retireRenderedCompletions()
        try expect(mixedQueue.queuedFrames == 480, "Partial render must not retire an entire buffer")
        renderedMix.withUnsafeMutableBufferPointer { mixed.render(into: $0) }
        mixed.retireRenderedCompletions()
        try expect(mixedQueue.queuedFrames == 0, "Actual full render must release translated reservation")
        // Drive the actual source through its hold+release instead of advancing wall time.
        var releaseOutput = [Float](repeating: 0, count: 240)
        for _ in 0..<36 {
            try mixed.appendOriginal(PCM16.encode([Float](repeating: 0.4, count: 240)))
            releaseOutput.withUnsafeMutableBufferPointer { mixed.render(into: $0) }
        }
        try expect(abs(releaseOutput[239] - 0.2 / 1.5) < 0.002, "Original gain must recover after rendered speech hold and release")
        mixed.stop()
        renderedMix.withUnsafeMutableBufferPointer { mixed.render(into: $0) }
        try expect(renderedMix.allSatisfy { $0 == 0 }, "Stop must silence both branches immediately")
        count += 1
        print("PASS: Ducking and translated completions follow the actual render clock")

        let boundedMix = RenderAudioMixer(originalLevel: 1, ducking: true, mixesTranslation: false)
        try boundedMix.appendOriginal(PCM16.encode([Float](repeating: 0.25, count: 4000)))
        try expect(boundedMix.snapshot.originalFrames == 2880 && boundedMix.snapshot.discardedOriginalFrames == 1120,
                   "Original queue must keep only the newest120ms")
        let boundedQueue = PlaybackBufferQueue()
        let fullSpeech = source(frames: 48_000, rate: 24_000, value: 0)
        try boundedQueue.schedule(fullSpeech, on: boundedMix)
        try rejects { try boundedQueue.schedule(speechBuffer, on: boundedMix) }
        boundedMix.startPlayback()
        renderedMix.withUnsafeMutableBufferPointer { boundedMix.render(into: $0) }
        try expect(abs(renderedMix[239] - 0.25) < 0.001, "Translated digital silence must not duck original speech")
        boundedQueue.reset(); boundedMix.reset()
        renderedMix.withUnsafeMutableBufferPointer { boundedMix.render(into: $0) }
        try expect(renderedMix.allSatisfy { $0 == 0 } && boundedMix.snapshot.translatedFrames == 0,
                   "Recovery reset must discard stale render data and completion state")
        count += 1
        print("PASS: Mixed output preserves two-second translation and120ms original bounds")
        let muteMix = RenderAudioMixer(originalLevel: 0, ducking: true)
        try muteMix.appendOriginal(PCM16.encode([Float](repeating: 0.4, count: 2880)))
        let muteQueue = PlaybackBufferQueue()
        try muteQueue.schedule(source(frames: 2400, rate: 24_000, value: 0.3), on: muteMix)
        muteMix.startPlayback()
        var muteOutput = [Float](repeating: 0, count: 240)
        muteOutput.withUnsafeMutableBufferPointer { muteMix.render(into: $0) }
        try expect(abs(muteOutput[239] - 0.3) < 0.002, "Translation fixture must play speech with the original off")
        muteMix.setSpeechMuted(true)
        var faded = [Float](repeating: 0, count: 1920)
        faded.withUnsafeMutableBufferPointer { muteMix.render(into: $0) }
        try expect(faded.allSatisfy { $0 <= 0.4 + 0.0001 } && faded[0] < 0.01 && abs(faded[1919] - 0.4) < 0.002
                   && muteMix.snapshot.translatedFrames < 2400 - 240,
                   "Hear Original must silence speech, fade the original up to full level in 80 ms and keep consuming speech")
        muteMix.setSpeechMuted(false)
        muteOutput.withUnsafeMutableBufferPointer { muteMix.render(into: $0) }
        try expect(abs(muteOutput[0] - 0.3) < 0.002, "Unmuting speech must drop the original at once under the speech")
        count += 1
        print("PASS: Hear Original silences translated speech and fades the original to full level")
        let headroomMix = RenderAudioMixer(originalLevel: 1, ducking: false)
        try headroomMix.appendOriginal(PCM16.encode([Float](repeating: 0.8, count: 240)))
        headroomMix.schedule(source(frames: 240, rate: 24_000, value: 0.8), completionType: .dataRendered, completion: { _ in })
        headroomMix.startPlayback()
        renderedMix.withUnsafeMutableBufferPointer { headroomMix.render(into: $0) }
        try expect(abs(renderedMix[239] - 0.8) < 0.002,
                   "Two hot0.8 signals must preserve headroom rather than hard-clip to1")
        headroomMix.schedule(source(frames: 48001, rate: 24_000), completionType: .dataRendered, completion: { _ in })
        try expect(headroomMix.snapshot.schedulingFailed, "Unexpected scheduling rejection must latch an explicit failure")
        headroomMix.reset()
        try expect(!headroomMix.snapshot.schedulingFailed, "Recovery resets scheduling fault state")
        count += 1
        print("PASS: Mixed speech reserves headroom and reports unexpected scheduling rejection")
        count += try CaptureTimingChecks.run()
        count += try await RawCaptureChecks.run()
        return count
    }
}

/// Exercise the exact raw AudioBufferList seam installed in AVAudioSinkNode;
/// fixture AVAudioPCMBuffer is only the producer's reusable borrowed storage.
private enum RawCaptureChecks {
    private final class Hold: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Confined to the single conversion queue.
        private var first = true
        func once() {
            if first { first = false; entered.signal(); _ = release.wait(timeout: .now() + 5) }
        }
    }
    private static func buffer(_ format: AVAudioFormat, frames: UInt32, value: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        fill(b, value: value)
        return b
    }
    private static func fill(_ b: AVAudioPCMBuffer, value: Float) {
        let list = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
        for item in list {
            let count = Int(item.mDataByteSize) / MemoryLayout<Float>.size
            let p = item.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<count { p[i] = value }
        }
    }
    private static func conversion(_ format: AVAudioFormat, loopback: Bool = false,
                                   original: (@Sendable (Data) throws -> Void)? = nil) throws -> CaptureConversion {
        try CaptureConversion(sourceFormat: format,
            target: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!,
            loopback: loopback, convertedPCM: original)
    }
    private static func raw(_ delivery: CaptureDelivery, _ b: AVAudioPCMBuffer) -> Bool {
        delivery.captureRaw(frames: b.frameLength, buffers: b.audioBufferList)
    }
    private static func expectFailedFinish(_ delivery: CaptureDelivery) async throws {
        var failed = false
        do { try await delivery.finish() } catch { failed = true }
        try expect(failed, "Malformed/overflow raw capture must fail finalization")
    }
    static func run() async throws -> Int {
        var count = 0
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let hold = Hold(), probe = CaptureProbe()
        let owned = try CaptureDelivery(conversion: conversion(mono, original: { _ in hold.once() }), maximumFrames: 512,
            deliver: { probe.append($0) }, failure: { probe.fail($0) })
        let borrowed = buffer(mono, frames: 512, value: 0.25)
        try expect(raw(owned, borrowed), "First raw quantum must be accepted")
        try expect(hold.entered.wait(timeout: .now() + 2) == .success, "Real converter hook did not block")
        fill(borrowed, value: 0.5)
        try expect(raw(owned, borrowed), "Second quantum must be accepted while converter is held")
        fill(borrowed, value: -0.75) // overwrite before the consumer can touch slot two
        hold.release.signal()
        try await owned.finish()
        let reference = try conversion(mono)
        var expected = Data()
        for value: Float in [0.25, 0.5] {
            for part in try reference.convert(buffer(mono, frames: 512, value: value)).0 { expected.append(part) }
        }
        for part in try reference.finish() { expected.append(part) }
        try expect(probe.bytes == expected && probe.failureCount == 0, "Raw slots must own copied bytes through producer reuse and converter tail")
        try expect(owned.snapshot.capturedFrames == 1024 && owned.snapshot.queuedBuffers == 0,
                   "Raw acceptance and drain metrics must reconcile")
        count += 1
        print("PASS: Raw sink owns bytes before producer reuse and finish drains exact converter tail")

        let boundHold = Hold(), boundedProbe = CaptureProbe()
        let bounded = try CaptureDelivery(conversion: conversion(mono, original: { _ in boundHold.once() }), maximumFrames: 512,
            deliver: { boundedProbe.append($0) }, failure: { boundedProbe.fail($0) })
        try expect(raw(bounded, borrowed), "Initial bounded raw capture failed")
        try expect(boundHold.entered.wait(timeout: .now() + 2) == .success, "Bounded converter did not hold")
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<3 { try expect(raw(bounded, borrowed), "Four TOTAL slots must include conversion in flight") }
        try expect(ProcessInfo.processInfo.systemUptime - start < 0.2, "Raw capture must not wait for held conversion")
        try expect(bounded.snapshot.queuedBuffers == 4 && bounded.snapshot.maximumQueuedBuffers == 4,
                   "Raw ring must retain in-flight slot without a second four-slot queue")
        try expect(!raw(bounded, borrowed) && !raw(bounded, borrowed), "Fifth raw quantum must latch overload and reject later input")
        try expect(boundedProbe.failureCount == 0, "Raw receiver must defer failure notification off the real-time lane")
        boundHold.release.signal()
        try await expectFailedFinish(bounded)
        try expect(boundedProbe.failureCount == 1 && bounded.snapshot.capturedFrames == 2048 && bounded.snapshot.queuedBuffers == 0,
                   "Raw overload must notify once, retain exact accepted accounting and clear reservations")
        count += 1
        print("PASS: Held raw converter stays nonblocking with exactly four outstanding slots and one deferred overload")

        let deliveryHold = Hold(), deliveryProbe = CaptureProbe()
        let deliveryBound = try CaptureDelivery(conversion: conversion(mono), maximumFrames: 8192,
            deliver: { data in deliveryHold.once(); deliveryProbe.append(data) }, failure: { deliveryProbe.fail($0) })
        let packetInput = buffer(mono, frames: 8192, value: 0.25)
        try expect(raw(deliveryBound, packetInput), "Raw synchronous delivery input rejected")
        try expect(deliveryHold.entered.wait(timeout: .now() + 2) == .success, "Raw synchronous consumer did not hold")
        for _ in 0..<3 { try expect(raw(deliveryBound, packetInput), "Blocked synchronous consumer must retain one of four slots") }
        try expect(deliveryBound.snapshot.queuedBuffers == 4 && !raw(deliveryBound, packetInput),
                   "Raw delivery must remain in the same four-slot capacity budget")
        deliveryHold.release.signal()
        try await expectFailedFinish(deliveryBound)
        try expect(deliveryProbe.failureCount == 1 && deliveryBound.snapshot.maximumQueuedBuffers == 4,
                   "Raw slow delivery overflow must notify once without increasing capacity")
        count += 1
        print("PASS: Raw synchronous delivery retains its slot in the same four-slot budget")

        let pausedProbe = CaptureProbe()
        let paused = try CaptureDelivery(conversion: conversion(mono), maximumFrames: 512, initiallyAccepting: false,
            deliver: { pausedProbe.append($0) }, failure: { pausedProbe.fail($0) })
        for _ in 0..<20 { try expect(!raw(paused, borrowed), "Start must reject ingress while control starts engines") }
        try expect(paused.snapshot.capturedFrames == 0 && paused.snapshot.maximumQueuedBuffers == 0,
                   "Held Start must neither replay early audio nor overflow")
        paused.begin()
        try expect(raw(paused, borrowed), "Completed Start must open raw admission")
        paused.pause()
        for _ in 0..<20 { try expect(!raw(paused, borrowed), "Recovery pause must reject ingress without blocking on consumer") }
        paused.begin()
        try expect(raw(paused, borrowed), "Completed recovery must reopen existing admission")
        try await paused.finish()
        paused.begin()
        try expect(!raw(paused, borrowed) && pausedProbe.failureCount == 0 && paused.snapshot.capturedFrames == 1024,
                   "Finish must permanently fence admission after accepted slots drain")
        count += 1
        print("PASS: Start/recovery admission holds native cadence without overflow or replay; finish cannot reopen")

        let cancelHold = Hold(), oldProbe = CaptureProbe(), freshProbe = CaptureProbe()
        let old = try CaptureDelivery(conversion: conversion(mono, original: { _ in cancelHold.once() }), maximumFrames: 512,
            deliver: { oldProbe.append($0) }, failure: { oldProbe.fail($0) })
        try expect(raw(old, borrowed), "Old generation capture failed")
        try expect(cancelHold.entered.wait(timeout: .now() + 2) == .success, "Old conversion did not hold")
        try expect(raw(old, borrowed), "Old second slot failed")
        old.cancel() // must not wait for work that could be waiting on AudioWorker.control
        old.begin()
        try expect(!raw(old, borrowed), "Cancelled generation must never reopen")
        let fresh = try CaptureDelivery(conversion: conversion(mono), maximumFrames: 512,
            deliver: { freshProbe.append($0) }, failure: { freshProbe.fail($0) })
        try expect(raw(fresh, borrowed), "Fresh generation needs its own pool")
        try await fresh.finish()
        cancelHold.release.signal()
        try await old.finish()
        try expect(oldProbe.bytes.isEmpty && !freshProbe.bytes.isEmpty && old.snapshot.queuedBuffers == 0,
                   "Cancel must discard queued/tail audio while a fresh generation drains independently")
        count += 1
        print("PASS: Cancel fences held-consumer output without waiting; new generation owns an independent pool")

        for rate in [16_000.0, 24_000.0, 44_100.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let p = CaptureProbe()
            let d = try CaptureDelivery(conversion: conversion(format), maximumFrames: 512,
                deliver: { p.append($0) }, failure: { p.fail($0) })
            try expect(raw(d, buffer(format, frames: 512, value: 0.25)), "Physical-rate raw quantum rejected")
            try await d.finish()
            try expect(abs(Double(p.bytes.count / 2) - 512 * 24_000 / rate) <= 2 && p.failureCount == 0,
                       "Raw physical-rate conversion must preserve duration")
        }
        for interleaved in [false, true] {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 16)!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                interleaved: interleaved, channelLayout: layout)
            let p = CaptureProbe(), b = buffer(format, frames: 512, value: 0)
            let list = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
            let right = list[interleaved ? 0 : 1].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<512 { right[interleaved ? i * 16 + 1 : i] = 0.5 }
            let d = try CaptureDelivery(conversion: conversion(format, loopback: true), maximumFrames: 512,
                deliver: { p.append($0) }, failure: { p.fail($0) })
            try expect(raw(d, b), "Multichannel raw layout rejected")
            try await d.finish()
            let samples = try PCM16.decode(p.bytes)
            try expect(samples.count == 256 && samples.suffix(100).allSatisfy { $0 > 0.1 } && p.failureCount == 0,
                       "BlackHole16 raw planar/interleaved must preserve right channel of first stereo pair")
        }
        count += 1
        print("PASS: Native raw layouts preserve mono physical rates and planar/interleaved BlackHole stereo right channel")

        for invalid in 0..<5 {
            let p = CaptureProbe(), b = buffer(mono, frames: 512, value: 0.25)
            let d = try CaptureDelivery(conversion: conversion(mono), maximumFrames: 512,
                deliver: { p.append($0) }, failure: { p.fail($0) })
            let list = b.mutableAudioBufferList
            let saved = list.pointee.mBuffers
            switch invalid {
            case 0: _ = d.captureRaw(frames: 513, buffers: b.audioBufferList)
            case 1: list.pointee.mBuffers.mDataByteSize = 2047; _ = d.captureRaw(frames: 512, buffers: UnsafePointer(list))
            case 2: list.pointee.mBuffers.mData = nil; _ = d.captureRaw(frames: 512, buffers: UnsafePointer(list))
            case 3: list.pointee.mBuffers.mNumberChannels = 2; _ = d.captureRaw(frames: 512, buffers: UnsafePointer(list))
            default: list.pointee.mNumberBuffers = 0; _ = d.captureRaw(frames: 512, buffers: UnsafePointer(list))
            }
            list.pointee.mBuffers = saved; list.pointee.mNumberBuffers = 1
            try expect(!raw(d, b), "Malformed raw input case \(invalid) must latch its gate")
            try await expectFailedFinish(d)
            try expect(p.failureCount == 1 && p.bytes.isEmpty && d.snapshot.capturedFrames == 0,
                       "Frame/byte/pointer/layout invalidity must report once without audio")
        }
        let emptyProbe = CaptureProbe()
        let empty = try CaptureDelivery(conversion: conversion(mono), maximumFrames: 512,
            deliver: { emptyProbe.append($0) }, failure: { emptyProbe.fail($0) })
        try expect(empty.captureRaw(frames: 0, buffers: borrowed.audioBufferList), "Empty callback should be counted, not failed")
        try await empty.finish()
        try expect(empty.snapshot.callbacks == 1 && empty.snapshot.zeroFrameCallbacks == 1 && emptyProbe.bytes.isEmpty && emptyProbe.failureCount == 0,
                   "Raw empty callback must not prime conversion or fabricate frames")
        count += 1
        print("PASS: Raw frame/byte/layout/pointer invalidity latches once; empty callbacks remain explicit")
        return count
    }
}
