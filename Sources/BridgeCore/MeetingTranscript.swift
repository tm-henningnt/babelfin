import Foundation

public enum ConversationDirection: String, Codable, CaseIterable, Sendable {
    case outgoing, incoming
    public var label: String { self == .outgoing ? "You" : "Meeting" }
}

/// Full session text, distinct from the compact rolling view. No implicit disk persistence.
public struct MeetingTranscript: Codable, Sendable {
    public enum Provenance: String, Codable, Sendable { case segment, continuousDelta }
    public struct Entry: Codable, Identifiable, Sendable {
        public let id: String
        public let sessionID: UUID
        public let direction: ConversationDirection
        public let role: TranscriptRole
        public let firstReceivedAt: Date
        public let provenance: Provenance
        public var segment: TranscriptSegment
    }
    public struct Session: Codable, Sendable {
        public let sessionID: UUID
        public let direction: ConversationDirection
        public var startedAt: Date?
        public var endedAt: Date?
        public var endReason: String?
    }
    public private(set) var entries: [Entry] = []
    public private(set) var sessions: [Session] = []
    public private(set) var limitReached = false
    /// Names the user gave speaker labels, per session and direction. They stay on this Mac.
    public private(set) var speakerNames: [String: String] = [:]
    public private(set) var skippedInvalidSegments = 0
    public let characterLimit: Int
    private var indices: [String: Int] = [:]
    private var characterCount = 0
    private var rebuildIndices = true
    private enum CodingKeys: String, CodingKey { case entries, sessions, limitReached, skippedInvalidSegments, characterLimit, speakerNames }
    public init(characterLimit: Int = 2_000_000) { self.characterLimit = max(1, characterLimit) }
    public mutating func clear() {
        entries = []; sessions = []; limitReached = false; skippedInvalidSegments = 0; speakerNames = [:]
        indices = [:]; characterCount = 0; rebuildIndices = false
    }
    public mutating func begin(sessionID: UUID, direction: ConversationDirection, at time: Date = Date()) {
        guard time.timeIntervalSince1970.isFinite else { skippedInvalidSegments += 1; return }
        if let index = sessions.firstIndex(where: { $0.sessionID == sessionID && $0.direction == direction }) {
            if let end = sessions[index].endedAt, time > end { skippedInvalidSegments += 1; return }
            if sessions[index].startedAt == nil { sessions[index].startedAt = time }
        } else if sessions.count < 50_000 {
            sessions.append(Session(sessionID: sessionID, direction: direction, startedAt: time))
        } else { limitReached = true }
    }
    public mutating func end(sessionID: UUID, direction: ConversationDirection, at time: Date = Date(), reason: String? = nil) {
        guard time.timeIntervalSince1970.isFinite else { skippedInvalidSegments += 1; return }
        ensureSession(sessionID, direction)
        guard let index = sessions.firstIndex(where: { $0.sessionID == sessionID && $0.direction == direction }) else { return }
        if let start = sessions[index].startedAt, time < start { skippedInvalidSegments += 1; return }
        if sessions[index].endedAt == nil {
            sessions[index].endedAt = time
        }
        // Finalization can fail after capture has already stopped. Amend the outcome,
        // preserving the actual first capture-end time.
        if let reason { sessions[index].endReason = String(reason.prefix(256)) }
    }
    private mutating func ensureSession(_ id: UUID, _ direction: ConversationDirection) {
        guard !sessions.contains(where: { $0.sessionID == id && $0.direction == direction }) else { return }
        if sessions.count < 50_000 { sessions.append(Session(sessionID: id, direction: direction)) }
        else { limitReached = true }
    }
    public mutating func receive(_ event: TranslationEvent, sessionID: UUID, direction: ConversationDirection, at time: Date = Date()) {
        guard !limitReached else { return }
        guard time.timeIntervalSince1970.isFinite else { skippedInvalidSegments += 1; return }
        if rebuildIndices {
            indices = Dictionary(entries.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            characterCount = entries.reduce(0) { $0 + $1.segment.text.count }; rebuildIndices = false
        }
        let role: TranscriptRole
        let segment: TranscriptSegment
        let provenance: Provenance
        switch event {
        case .segment(let value, let valueRole):
            do { try value.validate() } catch { skippedInvalidSegments += 1; return }
            segment = value; role = valueRole; provenance = .segment
        case .sourceTranscript(let text):
            guard !text.isEmpty else { return }
            role = .source; provenance = .continuousDelta
            segment = appended(text, sessionID: sessionID, direction: direction, role: role)
        case .targetTranscript(let text):
            guard !text.isEmpty else { return }
            role = .target; provenance = .continuousDelta
            segment = appended(text, sessionID: sessionID, direction: direction, role: role)
        default: return
        }
        let key = Self.key(sessionID, direction, role, provenance, segment.id)
        let index = indices[key]
        if let index {
            let previous = entries[index].segment
            if segment.revision == previous.revision {
                if segment != previous { skippedInvalidSegments += 1 }
                return
            }
            guard segment.revision > previous.revision, !previous.isFinal || segment.isFinal else { return }
        }
        let previousCount = index.map { entries[$0].segment.text.count } ?? 0
        let nextCount = characterCount - previousCount + segment.text.count
        guard nextCount <= characterLimit,
              index != nil || entries.count < 50_000 else { limitReached = true; return }
        ensureSession(sessionID, direction)
        guard !limitReached else { return }
        if let index { entries[index].segment = segment }
        else {
            indices[key] = entries.count
            entries.append(Entry(id: key, sessionID: sessionID, direction: direction, role: role, firstReceivedAt: time, provenance: provenance, segment: segment))
        }
        characterCount = nextCount
    }
    private func appended(_ text: String, sessionID: UUID, direction: ConversationDirection, role: TranscriptRole) -> TranscriptSegment {
        let last = entries.last
        let previous = last?.sessionID == sessionID && last?.direction == direction && last?.role == role
            && last?.provenance == .continuousDelta && (last?.segment.text.count ?? 0) + text.count <= 16_000 ? last?.segment : nil
        return TranscriptSegment(id: previous?.id ?? "continuous-\(entries.count)", revision: (previous?.revision ?? -1) + 1,
                                 text: (previous?.text ?? "") + text, isFinal: false)
    }
    private static func key(_ session: UUID, _ direction: ConversationDirection, _ role: TranscriptRole, _ provenance: Provenance, _ id: String) -> String {
        "\(session.uuidString)/\(direction.rawValue)/\(role.rawValue)/\(provenance.rawValue)/\(id)"
    }
    private static func speakerKey(_ entry: Entry, _ speaker: String) -> String {
        "\(entry.sessionID.uuidString)/\(entry.direction.rawValue)/\(speaker)"
    }
    /// The entry's speaker as shown: the user's name for the label, or "Speaker N". Nil without a label.
    public func speakerLabel(_ entry: Entry) -> String? {
        entry.segment.speaker.map { speakerNames[Self.speakerKey(entry, $0)] ?? "Speaker \($0)" }
    }
    /// Names the entry's speaker for its session and direction. An empty name restores "Speaker N".
    public mutating func renameSpeaker(of entry: Entry, to name: String) {
        guard let speaker = entry.segment.speaker else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        speakerNames[Self.speakerKey(entry, speaker)] = trimmed.isEmpty ? nil : trimmed
    }
    public func plainText(selection: TranscriptExport.Selection = .both) -> String {
        let selected = entries.filter { selection == .both || (selection == .source ? $0.role == .source : $0.role == .target) }
        let content = selected.map { entry in
            let role = entry.role == .source ? "Original" : "Translation"
            let speaker = speakerLabel(entry).map { " · \($0)" } ?? ""
            return "\(entry.direction.label) · \(role)\(speaker)\n\(entry.segment.text)"
        }.joined(separator: "\n\n")
        let formatter = ISO8601DateFormatter()
        let coverage = sessions.map { session in
            let start = session.startedAt.map(formatter.string(from:)) ?? "unknown capture start"
            let end = session.endedAt.map(formatter.string(from:)) ?? "end not recorded"
            return "\(session.direction.label): \(start) → \(end)\(session.endReason.map { " (\($0))" } ?? "")"
        }.joined(separator: "\n")
        let limits = limitReached ? "[Transcript stopped at its memory limit; later speech is missing.]\n\n" : ""
        let invalid = skippedInvalidSegments > 0 ? "[\(skippedInvalidSegments) invalid or conflicting transcript updates were skipped.]\n\n" : ""
        return limits + invalid + (coverage.isEmpty ? "" : "Capture sessions\n\(coverage)\n\n") + content
    }
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// Validate the complete duplex graph before either new direction opens devices.
public enum DuplexRouting {
    public static func validate(outgoingInput: AudioEndpoint?, outgoingOutput: AudioEndpoint?,
                                incomingInput: AudioEndpoint?, incomingOutput: AudioEndpoint?) throws {
        if let incomingInput, incomingInput.kind != .blackHole && incomingInput.kind != .other {
            throw BridgeError.unavailable("Choose a separate loopback device for incoming meeting audio.")
        }
        if let outgoingInput, let incomingInput, outgoingInput.uid == incomingInput.uid, outgoingInput.kind != .physical {
            throw BridgeError.unavailable("The two directions need separate audio sources. Choose your microphone for outgoing speech.")
        }
        if let outgoingOutput, let incomingInput, outgoingOutput.uid == incomingInput.uid {
            throw BridgeError.unavailable("Incoming and outgoing meeting audio need separate loopback devices. Choose a different incoming source.")
        }
        if let outgoingInput, let incomingOutput, outgoingInput.uid == incomingOutput.uid, outgoingInput.kind != .physical {
            throw BridgeError.unavailable("The incoming output would feed the outgoing source. Choose physical headphones.")
        }
    }
}
