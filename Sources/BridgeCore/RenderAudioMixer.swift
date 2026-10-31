import AVFoundation
import Foundation
import CAtomicMixer
#if BABELFIN_AUDIO_TRACE
import Darwin

public struct MixerAppendTrace: Codable, Sendable {
    public var tick: UInt64 = 0
    public var frames: Int = 0
    public var before: Int = 0
    public var after: Int = 0
    public var discarded: UInt64 = 0
}
public struct MixerRenderTrace: Codable, Sendable {
    public var tick: UInt64 = 0
    public var framePosition: UInt64 = 0
    public var requested: Int = 0
    public var originalConsumed: Int = 0
    public var originalEmpty: Int = 0
    public var originalStartupHold: Int? = nil
    public var translatedConsumed: UInt64 = 0
    public var lockMiss = false
    public var enabled = false
}
public struct AudioMixerTrace: Codable, Sendable {
    public let tickNumerator: UInt32
    public let tickDenominator: UInt32
    public let appends: [MixerAppendTrace]
    public let renders: [MixerRenderTrace]
    public let appendOverflow: Int
    public let renderOverflow: Int
}
/// Each lane has exactly one serialized writer. Snapshots are legal ONLY after all
/// writer callbacks stop; they are deliberately excluded from live mixer snapshots.
private final class MixerTraceLane<Record> {
    private let storage: UnsafeMutablePointer<Record>
    private let capacity: Int
    private var count = 0
    private(set) var overflow = 0
    init(capacity: Int, empty: Record) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: empty, count: capacity)
    }
    deinit { storage.deinitialize(count: capacity); storage.deallocate() }
    @inline(__always) func record(_ value: Record) {
        guard count < capacity else { overflow += 1; return }
        storage[count] = value
        count += 1
    }
    func afterStop() -> [Record] { Array(UnsafeBufferPointer(start: storage, count: count)) }
}

private enum MixerTraceCapacity {
    #if BABELFIN_AUDIO_SOAK
    // 310s budget with margin for the measured ~94/s source appends and faster renders.
    static let appends = 262_144
    static let renders = 262_144
    #else
    static let appends = 2_048
    static let renders = 4_096
    #endif
}
#endif

/// A bounded, mono 24 kHz render source. The control/producer lane is serialized
/// by `lock`; the callback uses only lock-free C11 publication and render-owned DSP.
/// Atomic tagged slots make live drop-oldest overwrites safe without plain-Float races.
/// Completions and all allocation remain on the control lane.
public final class RenderAudioMixer: AudioBufferScheduling, @unchecked Sendable {
    public static let liveOriginalLeadFrames = 240
    private struct Completion {
        let end: UInt64
        let callback: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    }
    private let lock = NSLock()
    private let state: OpaquePointer
    private var completions: [Completion] = []
    private var schedulingFailed = false
    #if BABELFIN_MIXER_CHECKS
    /// Offline checkpoint after the actual production control lock acquisition.
    public var controlCheckpoint: (@Sendable (String) -> Void)?
    /// Empty, quiescent test seam for 32-bit sample-stamp rollover coverage.
    public func seedEmptyCursors(original: UInt64, translated: UInt64) {
        lock.lock(); defer { lock.unlock() }
        bf_mixer_seed_empty_cursors(state, original, translated)
    }
    #endif
    #if BABELFIN_AUDIO_TRACE
    public static let traceAppendCapacity = MixerTraceCapacity.appends
    public static let traceRenderCapacity = MixerTraceCapacity.renders
    private let appendTrace = MixerTraceLane(capacity: MixerTraceCapacity.appends, empty: MixerAppendTrace())
    private let renderTrace = MixerTraceLane(capacity: MixerTraceCapacity.renders, empty: MixerRenderTrace())
    private var tracedRenderPosition: UInt64 = 0
    /// Stop the engine and quiesce producers before taking this snapshot.
    public func traceAfterStop() -> AudioMixerTrace {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return AudioMixerTrace(tickNumerator: timebase.numer, tickDenominator: timebase.denom,
                               appends: appendTrace.afterStop(), renders: renderTrace.afterStop(),
                               appendOverflow: appendTrace.overflow, renderOverflow: renderTrace.overflow)
    }
    #endif
    public init(originalLevel: Float, ducking: Bool, mixesTranslation: Bool = true, initialOriginalLeadFrames: Int = 0) {
        precondition((0...480).contains(initialOriginalLeadFrames))
        let level = originalLevel.isFinite ? min(1, max(0, originalLevel)) : 0
        guard let allocated = bf_mixer_create(level, ducking, mixesTranslation, initialOriginalLeadFrames) else {
            preconditionFailure("Unable to allocate bounded audio mixer")
        }
        state = allocated
    }
    deinit { bf_mixer_destroy(state) }
    public func appendOriginal(_ pcm: Data) throws {
        let values = try PCM16.decode(pcm)
        lock.lock(); defer { lock.unlock() }
        #if BABELFIN_MIXER_CHECKS
        controlCheckpoint?("append")
        #endif
        guard bf_mixer_enabled(state) else { return }
        #if BABELFIN_AUDIO_TRACE
        let arrival = mach_absolute_time()
        let before = bf_mixer_snapshot(state)
        defer {
            let after = bf_mixer_snapshot(state)
            appendTrace.record(MixerAppendTrace(tick: arrival, frames: values.count,
                               before: Int(before.original_frames), after: Int(after.original_frames),
                               discarded: after.discarded_original_frames > before.discarded_original_frames
                                ? after.discarded_original_frames - before.discarded_original_frames : 0))
        }
        #endif
        values.withUnsafeBufferPointer { bf_mixer_append_original(state, $0.baseAddress, $0.count) }
    }
    public func schedule(_ buffer: AVAudioPCMBuffer, completionType: AVAudioPlayerNodeCompletionCallbackType,
                         completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard bf_mixer_enabled(state) else { return }
        var end: UInt64 = 0
        guard buffer.format.sampleRate == 24_000, let samples = buffer.floatChannelData?[0],
              bf_mixer_schedule(state, samples, Int(buffer.frameLength), &end) else {
            schedulingFailed = true; return
        }
        completions.append(Completion(end: end, callback: completion))
    }
    public func switchToTranslation(originalLevel: Float, ducking: Bool) {
        lock.lock(); defer { lock.unlock() }
        let level = originalLevel.isFinite ? min(1, max(0, originalLevel)) : 0
        bf_mixer_translation(state, level, ducking)
    }
    public func switchToOriginal() {
        lock.lock(); defer { lock.unlock() }
        bf_mixer_original(state); completions.removeAll()
    }
    /// Silences translated speech while it keeps playing out, so the original plays at full level.
    public func setSpeechMuted(_ muted: Bool) { lock.lock(); bf_mixer_speech_muted(state, muted); lock.unlock() }
    public func startPlayback() { lock.lock(); bf_mixer_playing(state, true); lock.unlock() }
    public func pausePlayback() { lock.lock(); bf_mixer_playing(state, false); lock.unlock() }
    public func render(into output: UnsafeMutableBufferPointer<Float>) {
        #if BABELFIN_AUDIO_TRACE
        var event = MixerRenderTrace(tick: mach_absolute_time(), framePosition: tracedRenderPosition,
                                     requested: output.count)
        tracedRenderPosition += UInt64(output.count)
        #endif
        let rendered = bf_mixer_render(state, output.baseAddress, output.count)
        #if BABELFIN_AUDIO_TRACE
        event.enabled = rendered.enabled
        event.originalStartupHold = rendered.original_startup_hold
        event.originalConsumed = rendered.original_consumed
        event.originalEmpty = rendered.original_empty
        event.translatedConsumed = rendered.translated_consumed
        // Retained trace field for comparisons with historical zero-on-lock-miss trials.
        // This renderer does not attempt or acquire the control lock.
        event.lockMiss = false
        renderTrace.record(event)
        #else
        _ = rendered
        #endif
    }
    public func retireRenderedCompletions() {
        lock.lock()
        #if BABELFIN_MIXER_CHECKS
        controlCheckpoint?("retire")
        #endif
        let consumed = bf_mixer_snapshot(state).translated_read
        let callbacks = completions.prefix { $0.end <= consumed }.map(\.callback)
        completions.removeFirst(callbacks.count)
        lock.unlock()
        for callback in callbacks { callback(.dataRendered) }
    }
    public func clearOriginal() {
        lock.lock(); defer { lock.unlock() }
        bf_mixer_clear_original(state)
    }
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        bf_mixer_reset(state); completions.removeAll(); schedulingFailed = false
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        bf_mixer_stop(state); completions.removeAll()
    }
    public var snapshot: (originalFrames: Int, translatedFrames: Int, discardedOriginalFrames: UInt64, outputFrames: UInt64, schedulingFailed: Bool) {
        lock.lock(); defer { lock.unlock() }
        #if BABELFIN_MIXER_CHECKS
        controlCheckpoint?("snapshot")
        #endif
        let value = bf_mixer_snapshot(state)
        return (Int(value.original_frames), Int(value.translated_frames), value.discarded_original_frames, value.output_frames, schedulingFailed)
    }
}
