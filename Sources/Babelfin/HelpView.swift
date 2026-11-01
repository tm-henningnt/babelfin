import AppKit
import SwiftUI

/// The guide is compiled into the app; How to use and the Help menu open this window.
@MainActor enum HelpWindow {
    private static var window: NSWindow?
    /// Opens Help, at a topic when one is given.
    static func show(topic: String? = nil) {
        if let topic { HelpState.shared.query = ""; HelpState.shared.selection = topic }
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let created = NSWindow(contentViewController: NSHostingController(rootView: HelpView()))
        created.title = "Babelfin Help"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.setContentSize(NSSize(width: 860, height: 600))
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        created.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

/// One help topic. Groups follow the order a new user needs them.
struct HelpTopic: Identifiable, Hashable {
    let group: String
    let title: String
    let text: String
    var id: String { title }
    static let groups = ["Start", "Use", "Problems and privacy"]
    static let all: [HelpTopic] = [
        HelpTopic(group: "Start", title: "Two directions", text: "Speak translates what you say, for a call. Listen translates what you hear: a meeting, a video, the news or a room. Each direction has its own service, languages and devices, and you can run both together. Home shows both directions side by side."),
        HelpTopic(group: "Start", title: "Add your API keys", text: "Babelfin uses your own accounts. Open Settings › Accounts and save a key for each service your translation uses. This Mac (recommended) stores keys in unencrypted files that only your macOS account can read; Keychain encrypts them but may ask for access again after an update. Changing storage does not move existing keys. Each service bills your account separately, and consumer subscriptions such as ChatGPT do not include API usage."),
        HelpTopic(group: "Start", title: "Allow the microphone", text: "Approve microphone access when macOS asks. If you denied it, turn Babelfin on in System Settings › Privacy & Security › Microphone."),
        HelpTopic(group: "Start", title: "Be heard in a call", text: "Install BlackHole 2ch, or the Babelfin audio drivers in Settings › Audio devices. Babelfin never changes your system audio defaults. In Settings › Audio devices, under Speak, choose The call, your microphone, and BlackHole 2ch under Send through. In your meeting app, such as Zoom, Teams, Slack or Discord, choose BlackHole 2ch as the microphone. Try a private test call first."),
        HelpTopic(group: "Start", title: "Hear the meeting translated", text: "Install a second, separate loopback such as BlackHole 16ch and choose it as the speaker in your meeting app. In Listen select that loopback as the source and your headphones as the output. Babelfin reads channels 1 and 2 of BlackHole 16ch. The same loopback or a mirror cannot keep the two directions apart."),
        HelpTopic(group: "Start", title: "Translate a video or the room", text: "In Listen choose your headphones as the output. To translate a video, set the Mac’s output to BlackHole 2ch in Sound settings, choose BlackHole 2ch as the source, and play the video. To translate a TV or radio in the room, choose a microphone as the source. To hear your own translation in Speak, choose My headphones under Use for. Everything sent to BlackHole is captured, including notifications. Restore your usual output afterwards."),
        HelpTopic(group: "Use", title: "Start and stop", text: "Translate starts a direction. Stop translating returns to your original audio. Mute silences the direction immediately and Unmute starts fresh. Off closes the direction. A direction lists anything missing before you can start, with a button that opens the right place. The Translation menu has the same commands: Shift-Command-T, M and O for Speak, and Option-Shift-Command for Listen."),
        HelpTopic(group: "Use", title: "Route and audio", text: "Each direction on Home shows its route and its audio devices on one line. Choose Change… to edit the service, voice, languages and Delay, or the source and output. Voice, output language and Delay apply from the next passage. A new service, input language or device applies when you choose Restart. Settings › Audio devices shows the devices of both directions together."),
        HelpTopic(group: "Use", title: "Compact controls and the menu bar", text: "Choose Compact in the toolbar, or Window › Compact Controls (Command-0), to keep both directions in a small window without a title bar. The pin keeps it above other windows, also over a full-screen meeting. Choose Expand to return to Home. The Babelfin icon in the menu bar opens a panel with each direction's actions, what you hear and a volume slider. Closing the window keeps Babelfin running in the menu bar."),
        HelpTopic(group: "Use", title: "Keep your original voice available", text: "Start original audio, in the Options menu of compact controls, passes the source through without a translation service or API key. With Ready for calls, Babelfin passes your voice through when another app uses BlackHole; a microphone preview also counts. Translation still starts only when you choose it, and Mute or Off always wins. Hear › Both mixes the original quietly under the translation; the two voices are not synchronized."),
        HelpTopic(group: "Use", title: "Services and languages", text: "OpenAI, Palabra, Gemini and Azure Live Interpreter translate directly: they receive your audio and return translated speech. Palabra accepts an input language; the others detect it. Azure also needs your Speech resource endpoint in Settings › Advanced. The ElevenLabs and Fish Audio routes use ElevenLabs to recognize speech, OpenAI to translate the text, and ElevenLabs or Fish Audio to speak it. The routes with OpenAI recognition use OpenAI to recognize speech instead. Fish Audio with Fish recognition uses Fish Audio to recognize the languages Fish documents. For Listen, use a direct service: OpenAI follows the voice of each speaker. For Speak, use ElevenLabs or Fish Audio to choose the voice that speaks for you. On this Mac uses the speech recognition, translation and voices built into macOS 26 or later. It needs no account and sends nothing, at a lower quality. Available languages depend on the service."),
        HelpTopic(group: "Use", title: "Delay", text: "For the ElevenLabs and Fish Audio routes, Delay sets how much speech Babelfin collects before it translates. Fast stays close behind the speaker, More context waits for longer passages, which can translate better, and Balanced is in between. Babelfin adjusts the speed of the translated voice slightly to keep the delay steady."),
        HelpTopic(group: "Use", title: "Suggestions and translation server", text: "Settings › Languages and services suggests a service for each direction from your language and the meeting language. In Settings › Advanced, an OpenAI-compatible translation server such as Ollama or LM Studio can translate the text for the ElevenLabs and Fish Audio routes."),
        HelpTopic(group: "Use", title: "Voices", text: "For ElevenLabs or Fish Audio, choose an account voice on Home or in Settings › Languages and services, and preview it through physical headphones. To create a voice, choose Create a voice…, then record a sample in the app or choose an audio file. A recording stays in memory and is uploaded only when you confirm that you own the voice or have permission to clone it and choose Create voice. Audio from Listen is never used as a sample."),
        HelpTopic(group: "Use", title: "A voice for each speaker", text: "With Fish Audio with Fish recognition, Babelfin can tell speakers apart and give each one a voice. Choose up to eight voices under Voices for speakers in Settings › Languages and services. The transcript shows Speaker 1, Speaker 2 and so on; choose a label to give it a name. The names stay on this Mac."),
        HelpTopic(group: "Use", title: "Subtitles", text: "Translation › Show Subtitles (Option-Command-U) shows translated speech in a floating window above other apps. Captions show the latest lines; Transcript shows the running translation. The options button sets the style, the direction and the text size. To read instead of hear, turn off Speak the translation in Settings › Languages and services; you then hear the original audio."),
        HelpTopic(group: "Use", title: "Transcript", text: "Transcript shows original and translated text from both directions while translation is active, with gaps marked when it is off or muted. Copy it, optionally with a prompt for a chatbot, or save it as plain text or JSON. Babelfin never sends it anywhere by itself. Text stays in memory until you clear it or quit."),
        HelpTopic(group: "Use", title: "Tools", text: "Audio file transcribes a recording you choose or record and can translate the text; ElevenLabs can add anonymous speaker labels. After translation, Create dub speaks the translation at the original times, optionally over the original. Meeting notes summarizes your transcript or pasted text when you ask. Voice clip turns text into speech with ElevenLabs, Fish Audio, Gemini or the system voices on this Mac, with the delivery and speed you choose, and keeps up to five takes to compare. The system voices need no key and send nothing. With Speak › My recording, ElevenLabs gives your microphone recording a new voice. Recordings stay in memory until you discard them or quit."),
        HelpTopic(group: "Problems and privacy", title: "If you cannot hear anything", text: "Check the devices in each direction and choose Refresh devices. If a selected device disconnects, reconnect it and choose Resume; Babelfin never switches to another device. Watch the level meter while speaking. If a translation service fails, your original audio continues and Retry tries again. Settings › Advanced checks a direction's service with generated silence."),
        HelpTopic(group: "Problems and privacy", title: "What translation costs", text: "Each service bills your own account for what you use. One direction for one hour of a meeting costs about $0.50 to $2.50, depending on the service. Fish Audio is usually the lowest, and OpenAI direct and Palabra are near the top. Running both directions doubles the cost. These are estimates from published prices; check each service’s price page. Settings › Accounts › Usage shows what you used."),
        HelpTopic(group: "Problems and privacy", title: "Privacy", text: "The services you select process your audio or text under their own terms, retention policies and charges. Babelfin has no account or analytics and does not record your live audio. It contacts GitHub only when you choose Check for Updates. Keys are sent only to authenticate with their own services. Original-only audio uses no translation service, although a meeting app still sends your voice to its participants."),
        HelpTopic(group: "Problems and privacy", title: "Updates", text: "Choose Babelfin › Check for Updates… to look for a newer published release. Babelfin shows the release notes, downloads the update, checks its size and SHA-256 checksum against the release, then quits, replaces itself and reopens. If anything fails, the previous version is restored. Keep Babelfin in a folder you can write to, such as Applications. macOS may ask for microphone or Keychain access again after an update."),
        HelpTopic(group: "Problems and privacy", title: "Remove Babelfin", text: "Remove your keys in Settings › Accounts, then move Babelfin to the Trash. To remove local key files without the app, delete the Babelfin folder in your user Library › Application Support."),
    ]
}

@MainActor final class HelpState: ObservableObject {
    static let shared = HelpState()
    @Published var selection: String? = HelpTopic.all.first?.id
    @Published var query = ""
}

/// Help: topics in a sidebar with search, and the chosen topic on the right.
struct HelpView: View {
    @ObservedObject private var state = HelpState.shared
    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return HelpTopic.all }
        return HelpTopic.all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search Help", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10).padding(.top, 10)
                List(selection: $state.selection) {
                    ForEach(HelpTopic.groups, id: \.self) { group in
                        let topics = matches.filter { $0.group == group }
                        if !topics.isEmpty {
                            Section(group) { ForEach(topics) { Text($0.title).tag($0.id) } }
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Help topics")
            }
            .frame(width: 270)
            Divider()
            ScrollView {
                if let topic = HelpTopic.all.first(where: { $0.id == state.selection }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(topic.title).font(.title2.weight(.semibold))
                        Text(topic.text).font(.body).lineSpacing(3).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: state.query) { _ in
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}
