import Foundation

/// Server-sent events from a byte stream: returns the `data` payload of each complete event.
/// Lines may split across chunks; comments, `event:` names and empty payloads are skipped.
public struct ServerSentEvents: Sendable {
    private var pending = Data()
    private var data: [String] = []
    public init() {}
    public mutating func consume(_ bytes: Data) -> [String] {
        pending.append(bytes)
        var events: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if line.last == 0x0D { line = line.dropLast() }
            let text = String(decoding: line, as: UTF8.self)
            if text.isEmpty {
                if !data.isEmpty { events.append(data.joined(separator: "\n")); data.removeAll() }
            } else if text.hasPrefix("data:") {
                data.append(String(text.dropFirst(5).drop(while: { $0 == " " })))
            }
        }
        return events
    }
}

/// Where a translation can be split so that its first clause is spoken while the rest is translated.
public enum ClauseSplit {
    /// The first clause must have at least this many characters, so it is not spoken as a fragment.
    public static let minimumHeadCharacters = 24
    /// The end index of the first clause in `text`: after sentence or clause punctuation followed by
    /// a space, or after full-width punctuation. A period after a digit ("3. mai") is not a boundary.
    public static func head(in text: String) -> String.Index? {
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            count += 1
            if count >= minimumHeadCharacters {
                if "。！？；、，".contains(character) { return next }
                if ".!?;:,".contains(character), next < text.endIndex, text[next].isWhitespace {
                    let previous = index > text.startIndex ? text[text.index(before: index)] : " "
                    if !(character == "." && previous.isNumber) { return next }
                }
            }
            index = next
        }
        return nil
    }
}

/// The text of one translation as it streams in. The translation task appends deltas and then
/// finishes; the speaking side waits for the first clause, then for the rest.
public final class StreamingTranslation: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var finished = false
    private var failure: Error?
    /// Characters in the first clause, once `head()` has split it off.
    private var cut: Int?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}

    public func append(_ delta: String) { update { text += delta } }
    public func finish() { update { finished = true } }
    public func fail(_ error: Error) { update { failure = error; finished = true } }

    /// The first clause, once it is complete, or the whole translation when it ends first.
    /// `complete` is true when the text is the whole translation.
    public func head() async throws -> (text: String, complete: Bool) {
        while true {
            try Task.checkCancellation()
            let result: (String, Bool)? = try lock.withLock {
                if let failure { throw failure }
                if finished { return (text.trimmingCharacters(in: .whitespacesAndNewlines), true) }
                if let end = ClauseSplit.head(in: text) {
                    cut = text.distance(from: text.startIndex, to: end)
                    return (String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines), false)
                }
                return nil
            }
            if let result { return result }
            await wait()
        }
    }
    /// After `head()` returned an incomplete clause: the rest of the translation, once it ends.
    public func tail() async throws -> String {
        while true {
            try Task.checkCancellation()
            let result: String? = try lock.withLock {
                if let failure { throw failure }
                guard finished else { return nil }
                guard let cut, cut <= text.count else { return "" }
                return String(text.dropFirst(cut)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let result { return result }
            await wait()
        }
    }
    private func update(_ change: () -> Void) {
        lock.lock(); change(); let ready = waiters; waiters.removeAll(); lock.unlock()
        ready.forEach { $0.resume() }
    }
    private func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished || ClauseSplit.head(in: text) != nil && cut == nil || Task.isCancelled { lock.unlock(); continuation.resume() }
                else { waiters.append(continuation); lock.unlock() }
            }
        } onCancel: {
            lock.lock(); let ready = waiters; waiters.removeAll(); lock.unlock()
            ready.forEach { $0.resume() }
        }
    }
}
