import Foundation
import AVFoundation
import BridgeCore

private struct Failure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure(message: "Unsafe route accepted")
}
@main struct MeetingCoreChecks {
    static func main() {
        let session = UUID()
        let checks: [(String, () throws -> Void)] = [
            ("Legacy deltas preserve cross-direction conversation order", {
                var journal = MeetingTranscript()
                journal.receive(.sourceTranscript("hello"), sessionID: session, direction: .outgoing)
                journal.receive(.sourceTranscript("reply"), sessionID: session, direction: .incoming)
                journal.receive(.sourceTranscript("bye"), sessionID: session, direction: .outgoing)
                try expect(journal.entries.map(\.segment.text) == ["hello", "reply", "bye"], "Interleaved turns were merged out of chronological order")
                journal.receive(.sourceTranscript(" again"), sessionID: session, direction: .outgoing)
                try expect(journal.entries.last?.segment.text == "bye again" && journal.entries.count == 3, "Contiguous fragments should coalesce without creating artificial turns")
            }),
            ("Segment revisions are idempotent and allow explicit empty retractions", {
                var journal = MeetingTranscript()
                journal.receive(.segment(.init(id: "a", revision: 1, text: "original", isFinal: true), role: .source), sessionID: session, direction: .outgoing)
                journal.receive(.segment(.init(id: "a", revision: 1, text: "conflict", isFinal: true), role: .source), sessionID: session, direction: .outgoing)
                try expect(journal.entries.first?.segment.text == "original", "Same revision changed committed text")
                journal.receive(.segment(.init(id: "a", revision: 0, text: "older", isFinal: true), role: .source), sessionID: session, direction: .outgoing)
                journal.receive(.segment(.init(id: "a", revision: 2, text: "draft"), role: .source), sessionID: session, direction: .outgoing)
                try expect(journal.entries.first?.segment.text == "original", "Old revision or draft replaced final text")
                journal.receive(.segment(.init(id: "a", revision: 3, text: "", isFinal: true), role: .source), sessionID: session, direction: .outgoing)
                try expect(journal.entries.first?.segment.text == "", "Explicit final retraction was ignored")
            }),
            ("Invalid timing cannot poison meeting JSON export", {
                var journal = MeetingTranscript()
                journal.receive(.segment(.init(id: "bad", text: "bad", startSeconds: .nan), role: .source), sessionID: session, direction: .outgoing)
                try expect(journal.entries.isEmpty, "Invalid nonfinite timing entered the journal")
                _ = try journal.jsonData()
            }),
            ("Sessions and roles do not overwrite one another and limits remain explicit", {
                var journal = MeetingTranscript(characterLimit: 12)
                let fragment = TranscriptSegment(id: "same", text: "abc", isFinal: true)
                for direction in ConversationDirection.allCases {
                    for role in [TranscriptRole.source, .target] {
                        journal.receive(.segment(fragment, role: role), sessionID: session, direction: direction)
                    }
                }
                try expect(journal.entries.count == 4 && !journal.limitReached, "Direction/role identities collided or exact limit failed")
                journal.receive(.sourceTranscript("extra"), sessionID: UUID(), direction: .outgoing)
                try expect(journal.limitReached && journal.entries.count == 4 && journal.plainText().contains("missing"), "Limit silently discarded transcript")
                journal.clear()
                try expect(journal.entries.isEmpty && !journal.limitReached, "Clear did not reset transcript bounds")
            }),
            ("Capture coverage and finalization outcomes survive export without invented timing", {
                var journal = MeetingTranscript()
                let start = Date(timeIntervalSince1970: 100), end = Date(timeIntervalSince1970: 110)
                journal.begin(sessionID: session, direction: .outgoing, at: start)
                journal.begin(sessionID: session, direction: .outgoing, at: Date(timeIntervalSince1970: 102))
                journal.receive(.sourceTranscript("one"), sessionID: session, direction: .outgoing)
                journal.end(sessionID: session, direction: .outgoing, at: end, reason: "Stopped")
                journal.end(sessionID: session, direction: .outgoing, at: Date(timeIntervalSince1970: 115), reason: "Final text missing")
                let coverage = journal.sessions.first!
                try expect(coverage.startedAt == start && coverage.endedAt == end && coverage.endReason == "Final text missing",
                           "Finalization correction changed capture timing or lost outcome")
                journal.receive(.targetTranscript("translated"), sessionID: UUID(), direction: .incoming)
                try expect(journal.sessions.last?.startedAt == nil && journal.entries.last?.segment.speaker == nil,
                           "Legacy text fabricated a capture start or speaker")
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var roundtrip = try decoder.decode(MeetingTranscript.self, from: journal.jsonData())
                roundtrip.receive(.sourceTranscript("two"), sessionID: session, direction: .outgoing)
                try expect(roundtrip.entries.count == 3 && roundtrip.plainText().contains("Final text missing"), "Export/reload lost chronological identity or coverage")
            }),
            ("Provider language sets stay model-specific after expansion", {
                let eleven = ProviderCapabilities.elevenLabsTranslation.outputLanguages
                try expect(eleven.count == 84 && Set(eleven.map(\.code)).count == 84 && eleven.contains { $0.code == "th" }, "Enumerated v4Turbo coverage missing or duplicated")
                try expect(ProviderCapabilities.openAITranslation.outputLanguages.count == 13 && ProviderCapabilities.fishTranslation.outputLanguages.count == 32,
                           "An alternate model's language list leaked into another route")
            }),
            ("Duplex rejects digital feedback while allowing a physical headset", {
                let mic = AudioEndpoint(uid: "headset", inputChannels: 1, outputChannels: 2, kind: .physical)
                let first = AudioEndpoint(uid: "outgoing", inputChannels: 2, outputChannels: 2, kind: .blackHole)
                let second = AudioEndpoint(uid: "incoming", inputChannels: 16, outputChannels: 16, kind: .blackHole)
                try DuplexRouting.validate(outgoingInput: mic, outgoingOutput: first, incomingInput: second, incomingOutput: mic)
                try rejects { try DuplexRouting.validate(outgoingInput: second, outgoingOutput: first, incomingInput: second, incomingOutput: mic) }
                try rejects { try DuplexRouting.validate(outgoingInput: mic, outgoingOutput: first, incomingInput: first, incomingOutput: mic) }
                try rejects { try DuplexRouting.validate(outgoingInput: first, outgoingOutput: second, incomingInput: nil, incomingOutput: first) }
                try rejects { try DuplexRouting.validate(outgoingInput: nil, outgoingOutput: nil, incomingInput: mic, incomingOutput: mic) }
            }),
            ("Actual16-channel converter preserves stereo signal amplitude", {
                func rms(channels: UInt32, loopback: Bool = true, rightOnly: Bool = false) throws -> Double {
                    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
                    let format = channels == 2 ? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)! : AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
                    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
                    input.frameLength = 4800
                    for channel in 0..<Int(channels) {
                        for frame in 0..<4800 {
                            input.floatChannelData![channel][frame] = rightOnly ? (channel == 1 ? 0.5 : 0) : (channel < 2 ? 0.25 : 0)
                        }
                    }
                    let target = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
                    let conversion = try CaptureConversion(sourceFormat: format, target: target, loopback: loopback)
                    let (initial, _) = try conversion.convert(input)
                    let data = (initial + (try conversion.finish())).reduce(into: Data()) { $0.append($1) }
                    var signal = AudioSignalMetrics(); try signal.recordPCM16(data)
                    return signal.rms
                }
                let stereo = try rms(channels: 2), multichannel = try rms(channels: 16)
                let oldMapping = try rms(channels: 16, loopback: false)
                let right = try rms(channels: 16, rightOnly: true)
                print(String(format: "Synthetic converter RMS: stereo=%.6f,16channel=%.6f,rightOnly=%.6f,oldDiscrete=%.6f", stereo, multichannel, right, oldMapping))
                try expect(abs(stereo - multichannel) < 0.01 && multichannel > 0.20, "16-channel conversion attenuated the stereo pair")
                try expect(abs(right - 0.25) < 0.01, "Right-channel-only speech was lost")
            })
        ]
        var passed = 0
        for (name, check) in checks {
            do { try check(); passed += 1; print("PASS: \(name)") }
            catch { print("FAIL: \(name): \(error)") }
        }
        print("\(passed)/\(checks.count) meeting core checks passed")
        if passed != checks.count { exit(1) }
    }
}
