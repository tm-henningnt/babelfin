import Foundation

/// Bounded UI/control handoff, including the event currently being handled.
/// Audio has its own duration budget and must never enter this channel.
public final class TranslationControlChannel: @unchecked Sendable {
    public struct Entry: Sendable {
        public let id: UUID
        public let envelope: TranslationEnvelope
    }
    public let stream: AsyncStream<Entry>
    private let continuation: AsyncStream<Entry>.Continuation
    private let lock = NSLock()
    private var sizes: [UUID: Int] = [:]
    private var bytes = 0
    private var accepting = true
    public init() {
        var captured: AsyncStream<Entry>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingOldest(64)) { captured = $0 }
        continuation = captured
    }
    public func append(_ envelope: TranslationEnvelope) throws {
        // Include fixed metadata overhead in addition to any text payload.
        let size: Int
        switch envelope.event {
        case .sourceTranscript(let text), .targetTranscript(let text), .failure(let text), .notice(let text):
            size = text.utf8.count + 128
        case .audio: throw BridgeError.invalidEvent
        default: size = 128
        }
        lock.lock(); defer { lock.unlock() }
        guard accepting, sizes.count < 64, size <= 65_536 - bytes else {
            throw BridgeError.unavailable("Translation control delivery fell behind.")
        }
        let entry = Entry(id: UUID(), envelope: envelope)
        sizes[entry.id] = size; bytes += size
        switch continuation.yield(entry) {
        case .enqueued: break
        case .dropped, .terminated:
            sizes.removeValue(forKey: entry.id); bytes -= size
            throw BridgeError.unavailable("Translation control delivery stopped.")
        @unknown default:
            sizes.removeValue(forKey: entry.id); bytes -= size
            throw BridgeError.invalidEvent
        }
    }
    public func complete(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        if let size = sizes.removeValue(forKey: entry.id) { bytes -= size }
    }
    public func finish() {
        lock.lock(); accepting = false; lock.unlock()
        continuation.finish()
    }
    public func cancel() {
        lock.lock(); accepting = false; sizes.removeAll(); bytes = 0; lock.unlock()
        continuation.finish()
    }
}
