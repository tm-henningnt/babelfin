import Foundation
import AVFoundation

public protocol AudioBufferScheduling {
    func startPlayback()
    func pausePlayback()
    func schedule(_ buffer: AVAudioPCMBuffer, completionType: AVAudioPlayerNodeCompletionCallbackType,
                  completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void)
}

public struct NativeAudioBufferScheduler: AudioBufferScheduling {
    private let player: AVAudioPlayerNode
    public init(player: AVAudioPlayerNode) { self.player = player }
    public func startPlayback() { player.play() }
    public func pausePlayback() { player.pause() }
    public func schedule(_ buffer: AVAudioPCMBuffer, completionType: AVAudioPlayerNodeCompletionCallbackType,
                         completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: completionType, completionHandler: completion)
    }
}

public struct PlaybackBufferReservation: Sendable {
    fileprivate let id: UUID
}

public struct PlaybackMetrics: Sendable {
    public let queuedFrames: Int
    public let admittedFrames: UInt64
    public let renderedFrames: UInt64
    public let discardedFrames: UInt64
    public let oldestAge: TimeInterval
    public let secondsSinceProgress: TimeInterval
    public let maximumQueuedFrames: Int
    /// Empty intervals between rendered data and the next arrival; includes natural silence.
    public let emptyIntervalSeconds: TimeInterval
}

/// Tracks only audio waiting for the app's renderer, not Bluetooth/device playback latency.
/// Scheduling is on the audio controller's thread; completion accounting is protected by the lock.
public final class PlaybackBufferQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumFrames: Int
    private var tickets: [UUID: Int] = [:]
    private var frames = 0
    private var submitted: Set<UUID> = []
    private var admitted: UInt64 = 0
    private var renderedCount: UInt64 = 0
    private var discarded: UInt64 = 0
    private var timestamps: [UUID: TimeInterval] = [:]
    private var lastProgress: TimeInterval = 0
    private var maximumQueued = 0
    private var drainedAt: TimeInterval?
    private var emptyIntervals: TimeInterval = 0
    public init(maximumFrames: Int = 48_000) { self.maximumFrames = maximumFrames }
    public var queuedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return frames
    }
    public var remainingFrames: Int { max(0, maximumFrames - queuedFrames) }
    public func reserve(_ buffer: AVAudioPCMBuffer) throws -> PlaybackBufferReservation {
        let count = Int(buffer.frameLength)
        guard count > 0, buffer.format.sampleRate == 24_000 else { throw BridgeError.invalidPCM }
        lock.lock(); defer { lock.unlock() }
        guard frames + count <= maximumFrames else { throw BridgeError.playbackBacklog(Double(frames + count) / 24_000) }
        let ticket = UUID()
        let now = ProcessInfo.processInfo.systemUptime
        if frames == 0 { lastProgress = now }
        if let drainedAt { emptyIntervals += max(0, now - drainedAt); self.drainedAt = nil }
        tickets[ticket] = count
        timestamps[ticket] = now
        admitted += UInt64(count)
        frames += count
        maximumQueued = max(maximumQueued, frames)
        return PlaybackBufferReservation(id: ticket)
    }
    public func submit(_ buffer: AVAudioPCMBuffer, reservation: PlaybackBufferReservation, on scheduler: any AudioBufferScheduling) {
        lock.lock()
        let valid = tickets[reservation.id] == Int(buffer.frameLength) && submitted.insert(reservation.id).inserted
        lock.unlock()
        guard valid else { return }
        scheduler.schedule(buffer, completionType: .dataRendered) { [weak self] _ in self?.rendered(reservation.id) }
    }
    public func schedule(_ buffer: AVAudioPCMBuffer, on scheduler: any AudioBufferScheduling) throws {
        let reservation = try reserve(buffer)
        submit(buffer, reservation: reservation, on: scheduler)
    }
    private func rendered(_ ticket: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let count = tickets.removeValue(forKey: ticket) else { return }
        submitted.remove(ticket)
        timestamps.removeValue(forKey: ticket)
        frames -= count
        renderedCount += UInt64(count)
        lastProgress = ProcessInfo.processInfo.systemUptime
        if frames == 0 { drainedAt = lastProgress }
    }
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        tickets.removeAll()
        submitted.removeAll()
        timestamps.removeAll()
        discarded += UInt64(frames)
        frames = 0
        drainedAt = nil
    }
    /// Time since the last queued audio finished rendering, or nil while audio is queued.
    public var secondsSinceDrained: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return drainedAt.map { max(0, ProcessInfo.processInfo.systemUptime - $0) }
    }
    public var snapshot: PlaybackMetrics {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return PlaybackMetrics(queuedFrames: frames, admittedFrames: admitted, renderedFrames: renderedCount,
            discardedFrames: discarded, oldestAge: timestamps.values.min().map { max(0, now - $0) } ?? 0,
            secondsSinceProgress: frames == 0 ? 0 : max(0, now - lastProgress),
            maximumQueuedFrames: maximumQueued, emptyIntervalSeconds: emptyIntervals)
    }
}
