import AppKit
import SwiftUI

@MainActor final class AudioDriverSettingsState: ObservableObject {
    @Published private(set) var status: AudioDriverStatus?
    @Published private(set) var bundled = false
    @Published private(set) var working = false
    @Published var notice = ""
    private var generation = 0

    /// Reads the bundles and device list off the main thread, then publishes one status.
    func refresh() async {
        generation += 1
        let token = generation
        let source = AudioDriverInstaller.bundledDirectory()
        let loaded = Set(AudioDevices.cached().map(\.uid))
        let (observations, hasBundles) = await Task.detached(priority: .userInitiated) {
            let observations = AudioDriverInstaller.observe(bundled: source, loadedUIDs: loaded)
            return (observations, observations.allSatisfy { $0.bundledDigest != nil })
        }.value
        guard token == generation else { return }
        bundled = hasBundles
        status = AudioDriverStatus.evaluate(observations)
    }

    func install(conversation: ConversationModel) async {
        guard let source = AudioDriverInstaller.bundledDirectory(), bundled else {
            notice = AudioDriverInstallerError.missingBundles.localizedDescription; return
        }
        await run(conversation: conversation, prompt: "Babelfin wants to install Babelfin Microphone and Babelfin Speaker.",
                  expected: .installed) { try AudioDriverInstaller.installCommand(sourceDirectory: source.path) }
    }

    func remove(conversation: ConversationModel) async {
        await run(conversation: conversation, prompt: "Babelfin wants to remove Babelfin Microphone and Babelfin Speaker.",
                  expected: .notInstalled) { AudioDriverInstaller.removeCommand() }
    }

    private func run(conversation: ConversationModel, prompt: String, expected: AudioDriverStatus,
                     command: () throws -> String) async {
        guard !working, !conversation.locked else { return }
        working = true; notice = "Waiting for the administrator password…"
        defer { working = false }
        // Let SwiftUI draw the waiting state before the AppleScript call blocks the main thread.
        try? await Task.sleep(nanoseconds: 50_000_000)
        do {
            try AudioDriverInstaller.runPrivileged(try command(), prompt: prompt)
        } catch {
            notice = error.localizedDescription
            await refresh(); return
        }
        notice = "Core Audio is restarting. Mac audio returns in a few seconds."
        // Core Audio restarts in the background. Poll until the devices appear or disappear.
        for _ in 0..<20 {
            AudioDeviceInventory.shared.refresh()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            conversation.outgoing.refresh(); conversation.incoming.refresh()
            await refresh()
            if status == expected { break }
        }
        notice = status == expected ? "" : "Core Audio has not finished. Choose Refresh devices in a moment, or restart the Mac."
    }
}

struct AudioDriverSettingsView: View {
    @ObservedObject var conversation: ConversationModel
    @StateObject private var state = AudioDriverSettingsState()
    private var editsAllowed: Bool { !conversation.locked && !state.working }

    /// Form sections for Settings › Audio devices.
    var body: some View {
        Section {
            LabeledContent("Babelfin Microphone and Babelfin Speaker") {
                if let status = state.status { Text(status.text).foregroundStyle(.secondary) } else { ProgressView().controlSize(.small) }
            }
            HStack {
                if state.working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Remove", role: .destructive) { Task { await state.remove(conversation: conversation) } }
                    .disabled(!editsAllowed || state.status == nil || state.status == .notInstalled)
                Button("Install") { Task { await state.install(conversation: conversation) } }
                    .disabled(!editsAllowed || !state.bundled || state.status == .installed)
            }
            if conversation.locked {
                Text("Stop translation and turn off Ready for calls first.").foregroundStyle(.secondary)
            }
            if state.status != nil && !state.bundled {
                Text(AudioDriverInstallerError.missingBundles.localizedDescription).foregroundStyle(.secondary)
            }
            if !state.notice.isEmpty {
                Text(state.notice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: { Text("Babelfin audio drivers") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Installing asks for an administrator password and stops Mac audio for a few seconds. BlackHole 2ch and 16ch work instead.")
                HStack(spacing: 16) {
                    Text("Built from BlackHole by Existential Audio.")
                    Button("GPL-3.0 License") { AppLinks.openDriverLicense() }.buttonStyle(.link)
                    Link("Source", destination: AppLinks.driverSource)
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await state.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .babelfinAudioDevicesChanged)) { _ in
            guard !state.working else { return }
            Task { await state.refresh() }
        }
    }
}
