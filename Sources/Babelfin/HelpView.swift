import AppKit
import SwiftUI

/// The guide is compiled into the app; How to use and the Help menu open this window.
@MainActor enum HelpWindow {
    private static var window: NSWindow?
    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let created = NSWindow(contentViewController: NSHostingController(rootView: HelpView()))
        created.title = "Babelfin Help"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.setContentSize(NSSize(width: 760, height: 680))
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor private final class HelpState: ObservableObject {
    enum Topic: String, CaseIterable { case start = "Getting started", routing = "Calls and routing", voices = "Voices, tools and privacy" }
    @Published var topic: Topic = .start
}

struct HelpView: View {
    @StateObject private var state = HelpState()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Babelfin Help").font(.title2.weight(.semibold))
            Picker("Help topic", selection: $state.topic) {
                ForEach(HelpState.Topic.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch state.topic {
                    case .start: start
                    case .routing: routing
                    case .voices: voices
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18).padding(.bottom, 24)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .padding(24).frame(minWidth: 620, minHeight: 520)
    }
    @ViewBuilder private var start: some View {
        section("Two directions", "Your voice translates what you say, for a call or for listening locally. Meeting audio translates what you hear. Each direction has its own service, languages and devices, and you can run both together. Choose a direction in the sidebar.")
        section("Add your API keys", "Babelfin uses your own accounts. Open Settings › Accounts and save a key for each service your translation uses. This Mac (recommended) stores keys in unencrypted files that only your macOS account can read; Keychain encrypts them but may ask for access again after an update. Changing storage does not move existing keys. Each service bills your account separately, and consumer subscriptions such as ChatGPT do not include API usage.")
        section("Allow the microphone", "Approve microphone access when macOS asks. If you denied it, turn Babelfin on in System Settings › Privacy & Security › Microphone.")
        section("Start and stop", "Translate starts a direction. Stop translating returns to your original audio. Mute silences the direction immediately and Unmute starts fresh. Off closes the direction. Review next lists anything missing before you can start. The Translation menu has the same commands: Shift-Command-T, M and O for Your voice, and Option-Shift-Command for Meeting audio.")
        section("Compact controls", "Choose Compact in a direction to keep both directions in a small window with their state and next action. Choose Expand to return to routes, languages, the transcript and tools. Closing the window keeps Babelfin running in the menu bar.")
    }
    @ViewBuilder private var routing: some View {
        section("Be heard in Teams", "Install BlackHole separately; Babelfin does not install drivers or change system defaults. In Your voice choose Virtual microphone, your physical microphone, and BlackHole 2ch under Send through. In Teams › Settings › Devices choose BlackHole 2ch as the microphone. Try a private test call first.")
        section("Hear the meeting translated", "Install a second, separate loopback such as BlackHole 16ch and choose it as the Teams speaker. In Meeting audio select that loopback as the source and your headphones as the output. Babelfin reads channels 1 and 2 of BlackHole 16ch. The same loopback or a mirror cannot keep the two directions apart.")
        section("Listen locally", "In Your voice choose Listen locally, a microphone and physical headphones. To translate a video, set the Mac’s output to BlackHole 2ch in Sound settings, choose BlackHole 2ch as the source, and play the video. Everything sent to BlackHole is captured, including notifications. Restore your usual output afterwards.")
        section("Keep your original voice available", "Start original audio, in a direction’s options menu, passes the source through without a translation service or API key. With Ready for calls, Babelfin passes your voice through when another app uses BlackHole; a microphone preview also counts. Translation still starts only when you choose it, and Mute or Off always wins. In Settings you can mix the original quietly under the translation; the two voices are not synchronized.")
        section("If you cannot hear anything", "Check the devices in each direction and choose Refresh devices. If a selected device disconnects, reconnect it and choose Resume; Babelfin never switches to another device. Watch the level meter while speaking. If a translation service fails, your original audio continues and Retry tries again. Settings › Troubleshooting checks the OpenAI direct connection with generated silence.")
    }
    @ViewBuilder private var voices: some View {
        section("Services and languages", "OpenAI direct translation receives your audio and returns translated speech, detecting the input language. The ElevenLabs and Fish Audio routes use ElevenLabs to recognize speech, OpenAI to translate the text, and ElevenLabs or Fish Audio to speak it. Available languages depend on the service.")
        section("Delay", "For the ElevenLabs and Fish Audio routes, Delay sets how much speech Babelfin collects before it translates. Fast stays close behind the speaker, More context waits for longer passages, which can translate better, and Balanced is in between. Babelfin adjusts the speed of the translated voice slightly to keep the delay steady.")
        section("Voices", "For ElevenLabs or Fish Audio, choose an account voice in Settings and preview it through physical headphones. To create a voice, choose Create a voice…, then record a sample in the app or choose an audio file. A recording stays in memory and is uploaded only when you confirm that you own the voice or have permission to clone it and choose Create voice. Meeting audio is never used as a sample.")
        section("Transcript", "Transcript in the sidebar shows original and translated text from both directions while translation is active, with gaps marked when it is off or muted. Copy it, optionally with a prompt for a chatbot, or save it as plain text or JSON. Babelfin never sends it anywhere by itself. Text stays in memory until you clear it or quit.")
        section("Tools", "Audio file transcribes a recording you choose and can translate the text; ElevenLabs can add anonymous speaker labels. Meeting notes summarizes your transcript or pasted text when you ask. Voice clip turns text into speech you can play through headphones or save as WAV.")
        section("Privacy", "The services you select process your audio or text under their own terms, retention policies and charges. Babelfin has no account or analytics and does not record your live audio. It contacts GitHub only when you choose Check for Updates. Keys are sent only to authenticate with their own services. Original-only audio uses no translation service, although a meeting app still sends your voice to its participants.")
        section("Updates", "Choose Babelfin › Check for Updates… to look for a newer published release. Babelfin shows the release notes, downloads the update, checks its size and SHA-256 checksum against the release, then quits, replaces itself and reopens. If anything fails, the previous version is restored. Keep Babelfin in a folder you can write to, such as Applications. macOS may ask for microphone or Keychain access again after an update.")
        section("Remove Babelfin", "Remove your keys in Settings › Accounts, then move Babelfin to the Trash. To remove local key files without the app, delete the Babelfin folder in your user Library › Application Support.")
    }
    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
