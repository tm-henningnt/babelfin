import Foundation

/// When translated audio becomes audible, for the delay measurement. Each admitted piece of
/// audio gets the time its first sample reaches the renderer: at once plus the audio queued
/// ahead of it, or, while the playback buffer fills, the time the buffer starts playing.
/// It excludes the output device's own latency. Times use one clock, the system uptime.
public final class AudibleStartLog: @unchecked Sendable {
    private struct Entry { let admitted: TimeInterval; var audible: TimeInterval? }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int
    public init(capacity: Int = 512) { self.capacity = capacity }

    /// A piece admitted at `time`. `queuedAhead` is the audio before it in seconds, or nil while
    /// the buffer holds it until playback starts.
    public func admitted(at time: TimeInterval, queuedAhead: TimeInterval?) {
        lock.withLock {
            entries.append(Entry(admitted: time, audible: queuedAhead.map { time + $0 }))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
    }
    /// The buffer started playing at `time`: every held piece starts then.
    public func started(at time: TimeInterval) {
        lock.withLock { for index in entries.indices where entries[index].audible == nil { entries[index].audible = time } }
    }
    /// The audible time of the first piece admitted at or after `time`, once it is known.
    public func audible(after time: TimeInterval) -> TimeInterval? {
        lock.withLock { entries.first { $0.admitted >= time }?.audible }
    }
    public func reset() { lock.withLock { entries.removeAll() } }
}
