import Foundation
import AVFoundation
import BridgeCore

struct CheckFailure: Error { let message: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}
func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw CheckFailure(message: "Expected invalid input to be rejected")
}
func object(_ text: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw CheckFailure(message: "Expected JSON object") }
    return value
}
func event(_ text: String) throws -> TranslationEvent { try TranslationWire.decode(Data(text.utf8)) }

final class DelayedDeviceScheduler: AudioBufferScheduling {
    private(set) var starts = 0
    private(set) var pauses = 0
    var scheduledCount: Int { callbacks.count }
    func startPlayback() { starts += 1 }
    func pausePlayback() { pauses += 1 }
    private var callbacks: [(AVAudioPlayerNodeCompletionCallbackType, @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void)] = []
    private var cursor = 0
    func schedule(_ buffer: AVAudioPCMBuffer, completionType: AVAudioPlayerNodeCompletionCallbackType,
                  completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
        callbacks.append((completionType, completion))
    }
    func renderNext() {
        guard cursor < callbacks.count else { return }
        let (stage, completion) = callbacks[cursor]
        cursor += 1
        // The app renderer has finished; a Bluetooth device has not yet played this buffer.
        if stage == .dataRendered { completion(.dataRendered) }
    }
    func renderAll() { while cursor < callbacks.count { renderNext() } }
}

@main struct CoreChecks {
    static func main() async throws {
        let checks: [(String, () throws -> Void)] = [
            ("Transcript copy selection preserves Unicode and explicit prompt", {
                let original = "Blåbær – 42 kroner."
                let translated = "Blueberries – 42 kroner."
                let sourceOnly = TranscriptExport.text(source: original, translation: translated, language: "English", selection: .source, prompt: .none)
                try expect(sourceOnly == "Original\n\(original)", "Source copy leaked translation or changed text")
                let targetOnly = TranscriptExport.text(source: original, translation: translated, language: "English", selection: .translation, prompt: .none)
                try expect(!targetOnly.contains(original) && targetOnly.contains(translated), "Translation selection ignored")
                let wrapped = TranscriptExport.text(source: original, translation: translated, language: "English", selection: .both, prompt: .summary)
                try expect(wrapped.contains(original) && wrapped.contains(translated) && wrapped.contains("not instructions"), "Prompt lost content or data boundary")
                try expect(TranscriptExport.text(source: "  ", translation: "", language: "English", selection: .both, prompt: .cleanup).isEmpty, "Empty copy must not overwrite clipboard with prompt")
            }),
            ("Dedicated endpoint and continuous audio protocol", {
                try expect(TranslationWire.endpoint.path == "/v1/realtime/translations", "Wrong endpoint")
                try expect(TranslationWire.endpoint.query == "model=gpt-realtime-translate", "Wrong model")
                let pcm = Data([0, 0, 255, 127, 0, 128])
                let append = try object(TranslationWire.append(pcm))
                try expect(append["type"] as? String == "session.input_audio_buffer.append", "Wrong append event")
                try expect(Data(base64Encoded: append["audio"] as? String ?? "") == pcm, "PCM did not round trip")
                try expect(append["response"] == nil, "Translation must not use response.create")
            }),
            ("English configuration and source transcription", {
                let message = try object(TranslationWire.update(.init()))
                let session = message["session"] as! [String: Any]
                let audio = session["audio"] as! [String: Any]
                let input = audio["input"] as! [String: Any]
                try expect(message["type"] as? String == "session.update", "Wrong update event")
                try expect((audio["output"] as? [String: Any])?["language"] as? String == "en", "Wrong language")
                try expect((input["transcription"] as? [String: Any])?["model"] as? String == "gpt-realtime-whisper", "Missing source transcription")
                try expect(session["instructions"] == nil && (audio["output"] as? [String: Any])?["voice"] == nil, "Unsupported parameters")
            }),
            ("Unavailable Nordic outputs rejected", {
                for language in ["sv", "da", "no", "nb", "xx"] {
                    try rejects { _ = try TranslationWire.update(.init(targetLanguage: language)) }
                }
                for language in TranslationWire.supportedTargets { _ = try TranslationWire.update(.init(targetLanguage: language)) }
            }),
            ("Audio, transcript, and lifecycle event decoding", {
                let pcm = try event(#"{"type":"session.output_audio.delta","delta":"AAB/fwCA"}"#)
                try expect(pcm == .audio(Data([0, 0, 127, 127, 0, 128])), "Wrong audio bytes")
                let source = try event(#"{"type":"session.input_transcript.delta","delta":"Hei"}"#)
                let target = try event(#"{"type":"session.output_transcript.delta","delta":"Hello"}"#)
                try expect(source == .sourceTranscript("Hei") && target == .targetTranscript("Hello"), "Wrong transcript")
                for (type, expected) in [("session.created", TranslationEvent.created), ("session.updated", .updated), ("session.closed", .closed), ("future.event", .other)] {
                    let value = try event("{\"type\":\"\(type)\"}")
                    try expect(value == expected, "Wrong lifecycle event")
                }
            }),
            ("Malformed PCM and events rejected", {
                for delta in ["!", "AA==", ""] {
                    try rejects { _ = try event("{\"type\":\"session.output_audio.delta\",\"delta\":\"\(delta)\"}") }
                }
                try rejects { _ = try event("{}") }
                try rejects { _ = try event("not json") }
                try rejects { _ = try TranslationWire.append(Data()) }
                try rejects { _ = try TranslationWire.append(Data([0])) }
                try rejects { _ = try PCM16.decode(Data([0])) }
            }),
            ("Server errors cannot echo secret messages", {
                let normal = try event(#"{"type":"error","error":{"code":"invalid_api_key","message":"SECRET"}}"#)
                let unsafe = try event(#"{"type":"error","error":{"code":"Bearer secret value"}}"#)
                try expect(normal == .failure("invalid_api_key"), "Unsafe error message")
                try expect(unsafe == .failure("api_error"), "Unsafe error code")
            }),
            ("PCM clipping, endianness, and nonfinite samples", {
                let data = PCM16.encode([-2, -1, 0, 1, 2, .nan, .infinity])
                let values = try PCM16.decode(data)
                try expect(values.count == 7, "Wrong sample count")
                try expect(abs(values[0] + Float(32767) / 32768) < 0.00001, "Negative clipping failed")
                try expect(abs(values[3] - Float(32767) / 32768) < 0.00001, "Positive clipping failed")
                try expect(values[2] == 0 && values[5] == 0 && values[6] == 0, "Invalid finite handling")
                let minimum = try PCM16.decode(Data([0, 128]))
                try expect(minimum == [-1], "Expected little endian signed PCM")
            }),
            ("Safe Teams and loopback-to-headphones routing", {
                let mic = AudioEndpoint(uid: "mic", inputChannels: 1, outputChannels: 0, kind: .physical)
                let blackHole = AudioEndpoint(uid: "blackhole", inputChannels: 2, outputChannels: 2, kind: .blackHole)
                let headphones = AudioEndpoint(uid: "headset", inputChannels: 1, outputChannels: 2, kind: .physical)
                let virtual = AudioEndpoint(uid: "other-loopback", inputChannels: 2, outputChannels: 2, kind: .other)
                try AudioRouting.validate(input: mic, output: blackHole, destination: .teams)
                try AudioRouting.validate(input: blackHole, output: headphones, destination: .listen)
                try AudioRouting.validate(input: virtual, output: headphones, destination: .listen)
                try AudioRouting.validate(input: headphones, output: headphones, destination: .listen)
                try rejects { try AudioRouting.validate(input: blackHole, output: blackHole, destination: .teams) }
                try rejects { try AudioRouting.validate(input: mic, output: headphones, destination: .teams) }
                try rejects { try AudioRouting.validate(input: mic, output: blackHole, destination: .listen) }
                try rejects { try AudioRouting.validate(input: mic, output: virtual, destination: .listen) }
                try rejects { try AudioRouting.validate(input: headphones, output: mic, destination: .listen) }
            }),
            ("Stopped Bluetooth playback recovers without changing the selected route", {
                var recovery = AudioConfigurationRecovery()
                var health = AudioGraphHealth()
                health.playbackRunning = false
                health.outputFormatChanged = true
                let action = recovery.evaluate(health, at: 10)
                try expect(action == .recover(capture: false, playback: true), "A same-device format transition must rebuild playback rather than stop the session")
                health.playbackRunning = true
                health.outputFormatChanged = false
                try expect(recovery.evaluate(health, at: 11) == .unchanged, "A delayed healthy configuration notification must not stop audio")
                health.routeIntact = false
                try expect(recovery.evaluate(health, at: 12) == .stopRouteChanged, "Recovery must never silently switch audio devices")
            }),
            ("Configuration recovery validates capture formats and bounds repeated failures", {
                var recovery = AudioConfigurationRecovery()
                var health = AudioGraphHealth()
                health.captureRunning = false
                health.inputFormatChanged = true
                try expect(recovery.evaluate(health, at: 20) == .recover(capture: true, playback: false), "Capture-only recovery must preserve healthy playback")
                health.inputFormatValid = false
                try expect(recovery.evaluate(health, at: 21) == .stopFormatUnavailable, "Invalid hardware format must stop safely")
                health.inputFormatValid = true
                _ = recovery.evaluate(health, at: 21)
                _ = recovery.evaluate(health, at: 22)
                try expect(recovery.evaluate(health, at: 23) == .stopUnstable, "Repeated configuration churn must remain bounded")
                try expect(recovery.evaluate(health, at: 30) == .recover(capture: true, playback: false), "A later isolated capture transition can recover without resetting playback")
            }),
            ("Playback budget follows render completion despite delayed Bluetooth playback", {
                let queue = PlaybackBufferQueue()
                let scheduler = DelayedDeviceScheduler()
                let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
                buffer.frameLength = 2400
                for _ in 0..<20 { try queue.schedule(buffer, on: scheduler) }
                try expect(queue.queuedFrames == 48_000, "Exactly two seconds must fit")
                try rejects { try queue.schedule(buffer, on: scheduler) }
                scheduler.renderNext()
                try expect(queue.queuedFrames == 45_600, "Rendering must release capacity before a delayed physical playback callback")
                try queue.schedule(buffer, on: scheduler)
                queue.reset()
                try queue.schedule(buffer, on: scheduler)
                scheduler.renderNext()
                try expect(queue.queuedFrames == 2400, "A completion from before recovery must not drain the new generation")
                scheduler.renderAll()
                try expect(queue.queuedFrames == 0, "All newly rendered audio must release its capacity")
            }),
            ("Jitter buffering primes and reprimes before playback", {
                let playback = BufferedAudioPlayback(prebufferFrames: 7200)
                let scheduler = DelayedDeviceScheduler()
                let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
                buffer.frameLength = 2400
                try playback.append(buffer, on: scheduler)
                try playback.append(buffer, on: scheduler)
                try expect(scheduler.starts == 0 && scheduler.scheduledCount == 0, "Playback must wait for a reserve instead of draining the first arriving chunk")
                try expect(playback.queuedFrames == 4800, "Held audio must count toward the same bounded queue")
                try playback.append(buffer, on: scheduler)
                try expect(scheduler.starts == 1 && scheduler.scheduledCount == 3, "A complete prebuffer starts once and preserves chunk order")
                scheduler.renderAll()
                try playback.append(buffer, on: scheduler)
                try expect(scheduler.pauses == 1 && scheduler.starts == 1, "An underrun must re-prime, not repeatedly play isolated chunks")
                playback.flush(on: scheduler)
                try expect(scheduler.starts == 2, "The timeout path must also play short utterances")
            }),
            ("Adaptive jitter buffer grows on mid-speech gaps, ignores natural pauses and decays", {
                let playback = BufferedAudioPlayback(prebufferFrames: 7200)
                let scheduler = DelayedDeviceScheduler()
                let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
                buffer.frameLength = 2400
                func prime() throws { while !playbackStarted() { try playback.append(buffer, on: scheduler) } }
                var starts = 0
                func playbackStarted() -> Bool { defer { starts = scheduler.starts }; return scheduler.starts > starts }
                try prime(); scheduler.renderAll()
                try playback.append(buffer, on: scheduler)
                try expect(playback.prebufferFrames == 7200 + BufferedAudioPlayback.jitterStepFrames, "A gap that resumes immediately must raise the target")
                try prime(); scheduler.renderAll()
                Thread.sleep(forTimeInterval: 1.1)
                try playback.append(buffer, on: scheduler)
                try expect(playback.prebufferFrames == 7200 + BufferedAudioPlayback.jitterStepFrames, "A natural pause must not raise the target")
                try prime()
                for _ in 0..<200 { try playback.append(buffer, on: scheduler); scheduler.renderNext() }
                try expect(playback.prebufferFrames == 7200, "Steady playback must lower the target back to its start value")
                let grown = BufferedAudioPlayback(prebufferFrames: 7200)
                for _ in 0..<12 {
                    while true { try grown.append(buffer, on: scheduler); if !grown.isBuffering { break } }
                    scheduler.renderAll()
                }
                try expect(grown.prebufferFrames == BufferedAudioPlayback.maximumPrebufferFrames, "The target must stop at its ceiling")
                let original = BufferedAudioPlayback(prebufferFrames: 0)
                try original.append(buffer, on: scheduler); scheduler.renderAll(); try original.append(buffer, on: scheduler)
                try expect(original.prebufferFrames == 0, "Original passthrough must never buffer")
            }),
            ("Jitter buffering preserves the two-second cap across reset", {
                let playback = BufferedAudioPlayback(prebufferFrames: 48_000)
                let scheduler = DelayedDeviceScheduler()
                let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
                buffer.frameLength = 2400
                for _ in 0..<20 { try playback.append(buffer, on: scheduler) }
                try rejects { try playback.append(buffer, on: scheduler) }
                playback.reset()
                try playback.append(buffer, on: scheduler)
                scheduler.renderAll()
                try expect(playback.queuedFrames == 2400, "Old rendering callbacks cannot free a new held buffer")
                playback.flush(on: scheduler)
                scheduler.renderAll()
                try expect(playback.queuedFrames == 0, "Newly rendered buffers must still drain normally")
            }),
            ("Capture copies valid frames rather than padded source capacity", {
                let bytes = try AudioFrameCopy.byteCount(frames: 2400, bytesPerFrame: 4, sourceBytes: 16_384, destinationBytes: 9600)
                try expect(bytes == 9600, "A padded capture buffer must never overrun the exact-sized destination")
                try rejects { _ = try AudioFrameCopy.byteCount(frames: 2400, bytesPerFrame: 4, sourceBytes: 9599, destinationBytes: 9600) }
                try rejects { _ = try AudioFrameCopy.byteCount(frames: 2400, bytesPerFrame: 4, sourceBytes: 9600, destinationBytes: 9599) }
                try rejects { _ = try AudioFrameCopy.byteCount(frames: Int.max, bytesPerFrame: 8, sourceBytes: Int.max, destinationBytes: Int.max) }
                let stereo = try AudioFrameCopy.byteCount(frames: 100, bytesPerFrame: 8, sourceBytes: 800, destinationBytes: 800)
                try expect(stereo == 800, "Interleaved frames retain all channel bytes")
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                source.frameLength = 2400
                for channel in 0..<2 { for sample in 0..<4096 { source.floatChannelData![channel][sample] = channel == 0 ? 0.25 : -0.5 } }
                let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
                for index in 0..<sourceBuffers.count { sourceBuffers[index].mDataByteSize = 16_384 }
                let copied = try AudioFrameCopy.copy(source)
                try expect(copied.frameLength == 2400 && copied.frameCapacity == 2400, "Only valid frames belong in the copied buffer")
                try expect(copied.floatChannelData![0][2399] == 0.25 && copied.floatChannelData![1][2399] == -0.5, "Capture copying must preserve both channels")
            }),
            ("Actual stereo 48 kHz capture conversion to mono 24 kHz packets", {
                let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                let target = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
                let converter = CaptureConversion(converter: AVAudioConverter(from: source, to: target)!, target: target)
                var result = Data()
                for _ in 0..<100 {
                    let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 960)!
                    buffer.frameLength = 960
                    for c in 0..<2 { for i in 0..<960 { buffer.floatChannelData![c][i] = 0.25 } }
                    let (chunks, level) = try converter.convert(buffer)
                    try expect(level.isFinite && level >= 0 && level <= 1, "Invalid level")
                    for chunk in chunks {
                        try expect(chunk.count == 4800, "Expected exactly 100 ms packets")
                        result.append(chunk)
                    }
                }
                try expect(result.count >= 90_000 && result.count <= 96_000, "Resampling duration drift")
                let values = try PCM16.decode(result)
                try expect(values.dropFirst(500).allSatisfy { abs($0 - 0.25) < 0.01 }, "Unexpected downmix or PCM corruption")
            }),
            ("Provider registry derives the current routes' languages and accounts unchanged", {
                let openAI = ProviderRegistry.route(.openAI), eleven = ProviderRegistry.route(.elevenLabs), fish = ProviderRegistry.route(.fish)
                try expect(openAI.outputLanguages.map(\.code) == SupportedTargetLanguage.allCases.map(\.rawValue) && openAI.inputLanguages.isEmpty,
                           "OpenAI languages changed")
                try expect(eleven.outputLanguages == TranslationLanguage.elevenLabsOutputs && eleven.inputLanguages == TranslationLanguage.elevenLabsOutputs,
                           "ElevenLabs route languages changed")
                try expect(fish.outputLanguages == TranslationLanguage.composedOutputs && fish.inputLanguages == TranslationLanguage.elevenLabsOutputs,
                           "Fish route languages changed")
                try expect(TranslationRoute.openAI.requiredServices == [.openAI] && TranslationRoute.elevenLabs.requiredServices == [.openAI, .elevenLabs]
                           && TranslationRoute.fish.requiredServices == [.openAI, .elevenLabs, .fish], "Required accounts changed")
                try expect(fish.nativeSpeakingRate && !eleven.nativeSpeakingRate && eleven.acceptsLanguageHint && !openAI.acceptsLanguageHint,
                           "Stage properties changed")
                for route in TranslationRoute.allCases {
                    let capabilities = ProviderCapabilities.forRoute(route), registered = ProviderRegistry.route(route)
                    try expect(capabilities.outputLanguages == registered.outputLanguages && capabilities.inputLanguages == registered.inputLanguages,
                               "Capabilities and registry disagree for \(route)")
                }
                do { _ = try RouteDescriptor(id: "x", displayName: "x", stages: [ProviderRegistry.openAIText]); throw CheckFailure(message: "Invalid chain accepted") }
                catch is CheckFailure { throw CheckFailure(message: "Invalid chain accepted") } catch {}
            }),
            ("Route advisor fixes the user's language, detects the meeting's, and ranks available routes first", {
                // Norwegian speaker in an English meeting.
                let voice = RouteAdvisor.suggestions(direction: .yourVoice, userLanguage: "no", meetingLanguage: "en", savedServices: [.openAI])
                try expect(voice.map(\.route.id) == ["openai", "palabra", "elevenlabs", "fish", "gemini"], "An available route must come first: \(voice.map(\.route.id))")
                let eleven = voice.first { $0.route.id == "elevenlabs" }
                try expect(voice[0].sourceLanguage == nil && eleven?.sourceLanguage == "no" && eleven?.missingServices == [.elevenLabs]
                           && voice.first { $0.route.id == "gemini" }?.sourceLanguage == nil,
                           "Detection-only routes get no lock; locking routes list missing accounts")
                let ready = RouteAdvisor.suggestions(direction: .yourVoice, userLanguage: "no", meetingLanguage: "en", savedServices: [.openAI, .elevenLabs])
                try expect(ready.first?.route.id == "elevenlabs" && ready.first?.sourceLanguage == "no",
                           "With the accounts available, a route that locks the user's language must come first")
                let meeting = RouteAdvisor.suggestions(direction: .meetingAudio, userLanguage: "en", meetingLanguage: nil, savedServices: [.openAI])
                try expect(meeting.first?.route.id == "openai" && meeting.first?.missingServices.isEmpty == true && meeting.allSatisfy { $0.sourceLanguage == nil },
                           "Meeting audio must detect the input and prefer a route the user can already use")
                let norwegianOut = RouteAdvisor.suggestions(direction: .meetingAudio, userLanguage: "no", meetingLanguage: nil, savedServices: [.openAI, .elevenLabs])
                try expect(!norwegianOut.contains { $0.route.id == "openai" } && norwegianOut.first?.route.id == "elevenlabs",
                           "Routes that cannot speak the target must not be offered")
                try expect(RouteAdvisor.suggestions(direction: .yourVoice, userLanguage: "en", meetingLanguage: "en", savedServices: []).isEmpty,
                           "Same input and output language needs no translation")
            }),
            ("Key check classifies provider answers without trusting pre-auth validation", {
                func body(_ text: String) -> Data { Data(text.utf8) }
                let el = #"{"detail":{"type":"authentication_error","code":"unauthorized","message":"The API key you used is missing the permission user_read to execute this operation.","status":"missing_permissions"}}"#
                try expect(KeyProbeClassifier.classify(service: .elevenLabs, status: 401, body: body(el)) == .missing(scope: "user_read"), "ElevenLabs scope")
                try expect(KeyProbeClassifier.classify(service: .elevenLabs, status: 401, body: body(#"{"detail":{"status":"invalid_api_key"}}"#)) == .invalidKey, "ElevenLabs rejected key")
                try expect(KeyProbeClassifier.classify(service: .elevenLabs, status: 404, body: body(#"{"detail":{"status":"voice_not_found"}}"#)) == .granted, "Absent voice proves access")
                // ElevenLabs validates the body before the key, so 422 proves nothing.
                if case .unknown = KeyProbeClassifier.classify(service: .elevenLabs, status: 422, body: body(#"{"detail":[]}"#)) {} else { throw CheckFailure(message: "422 must be unknown") }
                let oa = #"{"error":{"message":"You have insufficient permissions for this operation. Missing scopes: api.responses.write. Check that you have the correct role.","type":"invalid_request_error"}}"#
                try expect(KeyProbeClassifier.classify(service: .openAI, status: 401, body: body(oa)) == .missing(scope: "api.responses.write"), "OpenAI scope")
                try expect(KeyProbeClassifier.classify(service: .openAI, status: 401, body: body(#"{"error":{"code":"invalid_api_key","message":"Incorrect API key"}}"#)) == .invalidKey, "OpenAI rejected key")
                try expect(KeyProbeClassifier.classify(service: .openAI, status: 400, body: body(#"{"error":{"code":"missing_required_parameter"}}"#)) == .granted, "Validation after auth proves access")
                try expect(KeyProbeClassifier.classify(service: .fish, status: 401, body: body("No permission")) == .invalidKey, "Fish rejected key")
                let hostile = #"{"error":{"message":"Missing scopes: <script>alert(1)</script>"}}"#
                try expect(KeyProbeClassifier.classify(service: .openAI, status: 401, body: body(hostile)) == .missing(scope: nil), "Unsafe scope text must not pass through")
                if case .unknown = KeyProbeClassifier.classify(service: .openAI, status: 503, body: Data()) {} else { throw CheckFailure(message: "5xx must be unknown") }
                try expect(KeyPermissions.all.allSatisfy { $0.probe.url.scheme == "https" }, "Probes use HTTPS only")
                try expect(Set(KeyPermissions.all.map(\.id)).count == KeyPermissions.all.count, "Permission IDs are unique")
            }),
            ("Route advisor ranks routes with a missing key permission after ready routes", {
                let plain = RouteAdvisor.suggestions(direction: .yourVoice, userLanguage: "no", meetingLanguage: "en", savedServices: [.openAI, .elevenLabs])
                try expect(plain.first?.route.id == "elevenlabs", "Baseline: ElevenLabs first")
                let lacking = RouteAdvisor.suggestions(direction: .yourVoice, userLanguage: "no", meetingLanguage: "en", savedServices: [.openAI, .elevenLabs],
                                                      missingPermissions: ["elevenlabs.text-to-speech"])
                try expect(lacking.first?.route.id == "openai", "A ready route must rank above one whose key lacks a permission: \(lacking.map(\.route.id))")
                let el = lacking.first { $0.route.id == "elevenlabs" }
                try expect(el?.missingPermissions.map(\.id) == ["elevenlabs.text-to-speech"] && el?.ready == false, "The suggestion names the missing permission")
                let fish = lacking.first { $0.route.id == "fish" }
                try expect(fish?.missingPermissions.isEmpty == true, "Fish speech does not need ElevenLabs Text to Speech")
                let voiceOnly = RouteAdvisor.suggestions(direction: .yourVoice, userLanguage: "no", meetingLanguage: "en", savedServices: [.openAI, .elevenLabs],
                                                        missingPermissions: ["elevenlabs.voices-write"])
                try expect(voiceOnly.allSatisfy { $0.missingPermissions.isEmpty }, "Voice creation is not needed by any route")
            }),
            ("Usage goes to the service of each stage, never to a translation server", {
                var ledger = UsageLedger(since: Date(timeIntervalSince1970: 0))
                ledger.addAudio(route: TranslationRoute.fish.descriptor, secondsSent: 60, secondsReceived: 30)
                ledger.addText(route: TranslationRoute.fish.descriptor, recognized: 100, translated: 120, spoken: true)
                try expect(ledger.services[.elevenLabs]?.audioSecondsSent == 60 && ledger.services[.fish]?.audioSecondsReceived == 30,
                           "Composed audio: sent to the recognizer, received from the voice")
                try expect(ledger.services[.openAI]?.charactersTranslated == 100 && ledger.services[.fish]?.charactersSpoken == 120,
                           "Composed text: recognized text to the translator, translated text to the voice")
                ledger.addAudio(route: TranslationRoute.openAI.descriptor, secondsSent: 10, secondsReceived: 8)
                ledger.addText(route: TranslationRoute.elevenLabs.descriptor, recognized: 5, translated: 7, spoken: false)
                try expect(ledger.services[.openAI]?.audioSecondsSent == 10 && ledger.services[.openAI]?.audioSecondsReceived == 8
                           && ledger.services[.elevenLabs]?.charactersSpoken == 0, "Direct audio and text-only speech")
                let decoded = try JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(ledger))
                try expect(decoded == ledger, "The ledger survives storage")
                ledger.reset(at: Date(timeIntervalSince1970: 5))
                try expect(ledger.services.isEmpty && ledger.since == Date(timeIntervalSince1970: 5), "Reset clears all counts")
            }),
            ("Speech rate stretcher passes through at 1x, shortens and lengthens without changing pitch", {
                let tone = PCM16.encode((0..<48_000).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 24_000)) })
                let plain = SpeechRateStretcher()
                let passed = try plain.process(tone)
                try expect(passed == tone, "Rate 1 must pass audio through unchanged")
                let fast = SpeechRateStretcher(); fast.setRate(1.25)
                var out = Data()
                for start in stride(from: 0, to: tone.count, by: 4_800) { out.append(try fast.process(tone.subdata(in: start..<min(tone.count, start + 4_800)))) }
                out.append(fast.finish())
                let samples = try PCM16.decode(out)
                let expected = 48_000.0 / 1.25
                try expect(abs(Double(samples.count) - expected) < 1_200, "1.25x output length \(samples.count) differs from \(expected)")
                let core = Array(samples[2_400..<(samples.count - 2_400)])
                var crossings = 0
                for i in 1..<core.count where (core[i - 1] < 0) != (core[i] < 0) { crossings += 1 }
                let frequency = Double(crossings) / 2 / (Double(core.count) / 24_000)
                try expect(abs(frequency - 440) < 15, "Pitch changed to \(frequency) Hz")
                try expect(core.map { abs($0) }.max()! < 0.4, "Overlap-add exceeded the source amplitude")
                let clamped = SpeechRateStretcher(); clamped.setRate(9); try expect(clamped.rate == SpeechRateStretcher.maximumRate, "Rate must be clamped")
                try expect([1.0, 3.5, 7].map { CatchUpRate.forBacklog(seconds: $0) } == [1, 1.15, 1.3],
                           "A direct route speeds up waiting translated speech in steps")
                let slow = SpeechRateStretcher(); slow.setRate(0.95)
                var slowed = Data()
                for start in stride(from: 0, to: tone.count, by: 4_800) { slowed.append(try slow.process(tone.subdata(in: start..<min(tone.count, start + 4_800)))) }
                slowed.append(slow.finish())
                let lengthened = try PCM16.decode(slowed).count
                try expect(abs(Double(lengthened) - 48_000 / 0.95) < 1_200, "0.95x output length \(lengthened) differs from \(48_000 / 0.95)")
                let floored = SpeechRateStretcher(); floored.setRate(0.1); try expect(floored.rate == SpeechRateStretcher.minimumRate, "Rate must have a floor")
            }),
            ("Recorded voice sample stays bounded, refuses short clips and encodes canonical WAV", {
                var sample = VoiceSampleBuffer()
                try rejects { try sample.append(Data([0])) }
                let second = Data(count: VoiceSampleBuffer.sampleRate * 2)
                for _ in 0..<9 { let kept = try sample.append(second); try expect(kept, "Append below limit dropped audio") }
                try expect(!sample.meetsMinimum && abs(sample.seconds - 9) < 0.0001, "Nine seconds met the minimum")
                try rejects { _ = try sample.wav() }
                for _ in 9..<VoiceSampleBuffer.maximumSeconds { try sample.append(second) }
                try expect(sample.isFull && sample.pcm.count == VoiceSampleBuffer.maximumBytes, "Ninety seconds did not fill the buffer")
                let overflowKept = try sample.append(second)
                try expect(!overflowKept && sample.pcm.count == VoiceSampleBuffer.maximumBytes, "Buffer grew past its limit")
                let wav = try sample.wav(), decoded = try SpeechToolsWAV.decode(wav)
                try expect(wav.count == 44 + VoiceSampleBuffer.maximumBytes && wav.prefix(4) == Data("RIFF".utf8)
                           && decoded == sample.pcm, "Recorded sample WAV is not canonical")
                var partial = VoiceSampleBuffer()
                for _ in 0..<(VoiceSampleBuffer.maximumSeconds - 1) { try partial.append(second) }
                let partialKept = try partial.append(Data(count: 3 * VoiceSampleBuffer.sampleRate))
                try expect(!partialKept && partial.isFull, "Partial final chunk was not truncated at the limit")
                sample.discard()
                try expect(sample.pcm.isEmpty && !sample.meetsMinimum, "Discard kept recorded audio")
            })
        ]
        var failures = 0
        for (name, check) in checks {
            do { try check(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        do {
            let count = try await AudioFoundationChecks.run()
            print("\(count)/\(count) audio foundation checks passed")
        } catch {
            failures += 1
            print("FAIL: Audio foundation checks: \(error)")
        }
        if failures > 0 { exit(1) }
    }
}
