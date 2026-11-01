<p align="center"><img src="Assets/Brand/Web/readme-banner.png" alt="Babelfin — a fish microphone carrying translated speech" width="960"></p>

# Babelfin

Live speech translation for macOS. Speak into a Teams call and listen to the meeting in your language, or translate audio locally through your headphones.

[**Download for Mac**](https://github.com/tm-henningnt/babelfin/releases/latest) · [Website](https://tm-henningnt.github.io/babelfin/)

Apple Silicon (arm64), macOS 13 or later. Made by **Henning Naarlien-Tolpinrud**.

<p align="center"><img src="Assets/Brand/Web/screenshot-main.png" alt="Babelfin main window with the sidebar and the Speak page" width="900"></p>

## How it works

**Speak** and **Listen** have independent language, service and voice settings. Start either direction or run both together. OpenAI direct translation detects the input language automatically. The other routes use ElevenLabs speech recognition, OpenAI text translation and an ElevenLabs or Fish Audio voice; you can use automatic input detection or select an input language. Available translation languages depend on the service.

**Azure Live Interpreter** is a third direct service. It needs your Azure Speech resource's key and endpoint (Settings › Accounts) in a region that offers Live Interpreter, such as West Europe. Babelfin uses Microsoft's Speech SDK for it; the SDK is Microsoft's software under Microsoft's licence terms, which are included in the app (`Contents/Resources/Microsoft Speech SDK`). By using the Azure route you also accept those terms.

**Palabra** and **Gemini Live Translate** are also direct services: each recognizes, translates and speaks in one step with its own API key. Palabra lets you choose the input language; Gemini detects it. Gemini keys need a billing-enabled Google project for use in the EEA.

**Which service for which direction.** For **Listen**, use a direct service. OpenAI direct translation follows the voice of each speaker, so you can tell the people in a meeting apart. For **Speak**, use ElevenLabs or Fish Audio when you want to choose the voice that speaks for you, for example a voice you create from your own. These routes also let you set your input language. **Settings › Language setup** suggests services in this order.

For the ElevenLabs and Fish Audio routes, **Delay** sets how much speech Babelfin collects before it translates. **Fast** stays close behind the speaker, **More context** waits for longer passages, which can translate better, and **Balanced** is in between. Babelfin adjusts the speed of the translated voice slightly to keep the delay steady.

For ElevenLabs or Fish Audio output, select an account voice and preview it through a physical output. Audio from Listen is never used as a voice sample.

Ready for calls can pass your original voice through when another app uses BlackHole. Choose when to turn translation on; Mute and Off take priority. Original and translated speech are not synchronized.

When a direction's input is BlackHole, Babelfin plays the original audio as soon as the app opens, so you hear the meeting or Mac audio before you translate. This starts only after you have allowed microphone access. **Off** stops it until you choose **Translate** again. A physical microphone never starts by itself. When you choose **Translate**, the original keeps its full volume until the first translated speech plays. While a direction plays only original audio, you can change its settings.

**Hear** chooses what you hear, also while translating: **Translation**, **Both** (the original under the translation, at the level and with the ducking set in Settings) or **Original**. With Original, translation keeps running, so the transcript continues, and the original fades up to full volume. **Stop translating** returns to the original audio and ends the translation connection. **Mute** silences the direction at once. **Off** stops all audio in the direction and turns off automatic activation.

Each direction has its own output volume: the slider in the main window and in Compact controls, or **Volume** in the menu bar menu. It changes only Babelfin's output for that direction, not the system volume, so it also works when macOS output goes to BlackHole and the Mac's own volume keys no longer control the speakers.

Open **Timing** under a direction's controls, or choose **Show timing** in Compact controls, to see how long each stage takes for ElevenLabs and Fish Audio: translation, the voice's first audio, waiting for the previous passage, and the total from the speaker's pause to translated speech. It shows the last passage and the median of the last 20. OpenAI does all stages in one step, so Babelfin cannot time them separately.

Choose **Compact** to keep both directions in a small window with the same controls. Expand the window to change the setup.

## Setup

Download the DMG, drag Babelfin to Applications, and open it. This download is **not notarized by Apple**. If macOS blocks it, follow [Apple’s instructions](https://support.apple.com/102445) using **System Settings → Privacy & Security → Open Anyway**. Your organization may restrict this option.

1. Choose a translation service in Settings and enter your own API keys for the services it uses. Direct services need only their own key. The ElevenLabs and Fish Audio routes need ElevenLabs and OpenAI keys; the Fish Audio route also needs a Fish Audio key. Choose local storage (recommended) or macOS Keychain for your keys in Settings → Accounts. Each service bills your account separately; a ChatGPT subscription does not include OpenAI API usage.
2. Install [BlackHole](https://github.com/ExistentialAudio/BlackHole#installation-instructions) separately for virtual microphone or system-audio routes. Follow its installer’s restart instructions. Babelfin does not install drivers or change system audio defaults.
3. To be heard in Teams, select **Speak**, **Virtual microphone**, your physical microphone and BlackHole 2ch as output. In Teams, select BlackHole 2ch as the microphone.
4. To translate meeting audio at the same time, use a genuinely separate loopback device, such as BlackHole 16ch, for the incoming route. Select it as the Teams speaker and as **Listen** input in Babelfin; choose your headphones as Babelfin’s output. BlackHole 16ch uses channels 1 and 2. The same device or a mirror cannot isolate the two streams. If translating only your voice, keep Teams’ speaker on headphones.
5. Choose the language and service in each direction, choose **Translate**, and approve microphone access if requested. Each direction can be stopped independently.

**Settings › Accounts › Usage** counts, per service, the audio sent, the translated speech received and the characters translated and spoken since you last reset it. The counts stay on this Mac. Each service bills your account by its own measures; the Pricing links open each service's price page.

### What translation costs

Each service bills your own account. The table shows estimates for one direction and one hour of meeting audio with about 30 minutes of speech. The estimates are calculated from the published pay-as-you-go prices on 2026-10-31, in US dollars before tax. They are not measured bills. Prices change; check each service's price page.

| Service in Babelfin | Estimate per hour | What decides the cost |
|---|---|---|
| Fish Audio voice (ElevenLabs recognition, OpenAI text translation) | about $0.50–1.60 | Characters spoken |
| ElevenLabs voice (ElevenLabs recognition, OpenAI text translation) | about $1.00–1.80 | Characters spoken |
| Gemini | about $1.25–2.20 | Minutes of translated speech |
| Azure Live Interpreter | about $1.75–2.50 | Hours of audio in and out |
| OpenAI direct | about $2.00 | Minutes of audio |
| Palabra | about $2.40 | Minutes of audio |

Running both directions doubles the cost. Text translation by OpenAI costs about $0.02 per hour. Languages that use more than one byte per character, such as Japanese, cost more on Fish Audio. Settings › Accounts › Usage shows what you used.

Keychain encrypts saved keys. **This Mac (local file)** avoids Keychain access prompts after app updates, but stores keys unencrypted in files restricted to your macOS account. Changing storage does not move or delete saved keys; enter them separately in the location you choose.

To translate other audio, use **Listen** with your headphones as output. To hear your own translation in **Speak**, choose **My headphones**. To translate system audio, route macOS output to BlackHole and select that device as input; all audio sent there is captured. Restore your normal output afterward. Do not select the same loopback for input and output.

## Key permissions

OpenAI and ElevenLabs keys can be restricted to some features. When you save a key in **Settings › Accounts**, Babelfin checks which permissions the key has. Choose **Check again** to repeat the check. The check sends requests that produce no output and cost no credits. A missing permission shows in orange with the features that need it, and **Settings › Language setup** marks the services that cannot work with the key. If translation stops because the service rejects a key, Babelfin checks the key and names the missing permission.

Babelfin uses these permissions:

- **OpenAI:** Realtime (OpenAI direct translation), Responses API (text translation for the ElevenLabs and Fish Audio routes, and meeting notes), and audio transcription (audio tools).
- **ElevenLabs:** Speech to Text (speech recognition), Text to Speech and Voices read (ElevenLabs voices), and Voices write (voice creation only).
- **Fish Audio:** keys have no permission settings. Babelfin checks only that the key works.

## Subtitles and text-only translation

Choose **Translation › Show Subtitles** (Option-Command-U) to show translated speech in a floating window above other apps, also in full-screen meetings. **Captions** show the latest lines in large text; **Transcript** shows the running translation. Use the window's options button to choose the style, the direction and the text size. Drag the window to move it and drag its edges to resize it.

To read a translation instead of hearing it, turn off **Speak the translation** in a direction's settings. You then hear the original audio at full volume and read the translation in the subtitles or the transcript. The ElevenLabs and Fish Audio routes then use no speech service.

## Language setup and your own translation server

**Settings › Language setup** asks which language you speak and which language the meeting uses, and suggests a service for each direction. It shows which accounts each service needs.

In **Settings › Accounts › Translation server**, you can enter an OpenAI-compatible server, for example Ollama or LM Studio, with a base URL and a model name. The ElevenLabs and Fish Audio routes can then use it for text translation instead of OpenAI. Babelfin sends the recognized text to that server. Plain HTTP is allowed only for this Mac and .local hosts.

## Uninstall

1. In Settings → Accounts, choose **Remove all saved keys**.
2. Quit Babelfin and move it to the Trash.
3. To remove BlackHole as well, follow the [BlackHole uninstall instructions](https://github.com/ExistentialAudio/BlackHole#uninstallation-instructions).

## Tools

The **Tools** section of the sidebar works with a recording, meeting text or a short voice clip:

- **Audio file:** transcribe a local recording, or record from a microphone, with OpenAI or ElevenLabs. Add speaker labels with ElevenLabs, and translate the resulting text with OpenAI. Copy or save the original and translation.
- **Dub:** after you translate an ElevenLabs transcript, **Create dub** speaks each translated passage at its original time with the voice and delivery from Voice clip. A passage that is longer than its slot plays up to 1.3 times faster. Turn on **Keep the original under the dub** to hear the original quietly underneath. A dub covers up to 15 minutes; save it as a WAV file.
- **Meeting notes:** use text from your meeting or paste a transcript, then make concise notes with OpenAI. Review, copy or save the result.
- **Voice clip:** type a short passage, choose an ElevenLabs or Fish Audio voice, then play or save a WAV file. **Delivery** sets a steady, natural or expressive read, and **Speed** sets the rate. Buttons add tags such as [whispers]; Expressive performs them best. Each generation is a take, and up to five takes stay for comparison until you change the text or voice.
- **A new voice for your recording:** choose **Speak › My recording** in Voice clip. ElevenLabs speaks your microphone recording again with the chosen voice and keeps your timing and intonation. It takes up to 90 seconds.

The microphone recording is shared: record it once, then transcribe it in Audio file or give it a new voice in Voice clip. It stays in memory until you discard it or quit.

Each action shows which service it uses. Files and recordings are uploaded only when you choose an action.

<p align="center"><img src="Assets/Brand/Web/screenshot-compact.png" alt="Compact controls for both directions" width="440"></p>

## Meeting text and privacy

**Transcript** in the sidebar brings together original and translated text from both directions. Copy it with an optional prompt for another chatbot, or explicitly save it as plain text or JSON. It covers periods when translation is active, with gaps while translation is off or muted. Original-only audio is not transcribed. Text can be incomplete and is not necessarily attributed to individual speakers.

Babelfin tells you when the transcript is full; save and clear it to continue. Text stays in memory until cleared or you quit, unless you choose to copy or save it. Babelfin does not record your live audio. Selected services process audio or text, and their terms, retention policies and charges apply.

To update, choose **Babelfin → Check for Updates…**. Babelfin contacts GitHub only when you choose this, verifies the download against the release checksum, and restores the previous version if the update fails.

## Build from source

Install a recent macOS Swift toolchain (this project has been checked with Swift 6.4). No third-party Swift packages are required.

```sh
zsh scripts/test.sh
zsh scripts/build-app.sh
open dist/Babelfin.app
```

The default build is **ad-hoc signed for local review and not notarized**. Rebuilds can trigger microphone or Keychain permission prompts.

To rebuild the icons, run `zsh scripts/build-icons.sh`. To build the static site, run `python3 scripts/build_site.py --output .build/site` with a fresh output folder.

## License

Copyright © 2026 Henning Naarlien-Tolpinrud. **Source-available** under the [Sustainable Use License 1.0](LICENSE), with conditions on redistribution and commercial use. This is not an OSI open-source license. Instrument Serif is bundled under the SIL Open Font License in `site/fonts/OFL.txt`.
