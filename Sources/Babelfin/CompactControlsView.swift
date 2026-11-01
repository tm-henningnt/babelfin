import AppKit
import CoreFoundation
import SwiftUI

/// The same transport controls are used in both window sizes. A translation
/// pause deliberately keeps the existing original-audio route alive.
struct TranslationControls: View {
    @ObservedObject var model: AppModel
    var incoming = false
    var spaced = true
    private var actions: TranslationControlActions { TranslationControlActions(model: model) }
    var body: some View {
        HStack(spacing: 10) {
            Button(actions.primaryTitle) { Task { await actions.performPrimary() } }
                .buttonStyle(.borderedProminent)
                .disabled(actions.primaryDisabled)
                .help(actions.primaryHelp)
                .accessibilityLabel("\(incoming ? "Listen" : "Speak"): \(actions.primaryTitle)")
            if spaced { Spacer(minLength: 8) }
            Button { Task { await actions.toggleMute() } } label: {
                Label(model.muted ? "Unmute" : "Mute", systemImage: incoming ? (model.muted ? "speaker.wave.2" : "speaker.slash") : (model.muted ? "mic" : "mic.slash"))
            }
            .labelStyle(.iconOnly)
            .disabled(actions.muteDisabled)
            .accessibilityLabel("\(model.muted ? "Unmute" : "Mute") \(incoming ? "Listen" : "Speak")")
            .help(model.muted ? "Unmute this direction" : "Silence this direction")
            Button("Off") { Task { await actions.turnOff() } }
                .disabled(actions.offDisabled)
                .accessibilityLabel("Turn \(incoming ? "Listen" : "Speak") off")
                .help("Stop all audio in this direction and turn off call readiness")
        }
    }
}

/// Settings changed during translation that wait for Restart, with the Restart button. The first
/// time it appears, an alert explains it; the user can turn the alert off.
@MainActor private final class RestartNoticeState: ObservableObject { @Published var explaining = false }
struct RestartNotice: View {
    @ObservedObject var model: AppModel
    var compact = false
    @AppStorage("babelfin.restartExplained") private var explained = false
    @StateObject private var state = RestartNoticeState()
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(compact ? "Restart to apply changes" : "Restart to apply: " + AppModel.PendingSetting.allCases.filter { model.pendingRestart.contains($0) }.map(\.title).joined(separator: ", "))
                .font(compact ? .caption : .callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Restart") { Task { await model.restartTranslation() } }
                .controlSize(compact ? .small : .regular)
                .help("Reconnect with the new settings. Original audio continues while it connects, unless audio devices changed.")
        }
        .onAppear { if !explained { state.explaining = true } }
        .alert("Some changes need a restart", isPresented: $state.explaining) {
            Button("Restart Now") { Task { await model.restartTranslation() } }
            Button("Later", role: .cancel) {}
            Button("Don’t Show Again") { explained = true }
        } message: {
            Text("A new voice or output language applies at once on ElevenLabs and Fish Audio. The service, input language, Delay, Speak the translation and audio devices apply when you choose Restart. Original audio continues while Babelfin reconnects, unless audio devices changed.")
        }
    }
}

/// What the user hears: the translation, both, or the original alone. Translation keeps
/// running with Original, so the transcript and subtitles continue.
struct HearingPicker: View {
    @ObservedObject var model: AppModel
    var incoming: Bool
    var body: some View {
        Picker("Hear", selection: $model.hearing) {
            ForEach(AppModel.Hearing.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .accessibilityLabel("\(incoming ? "Listen" : "Speak"): hear")
        .help("Choose what you hear while translating. With Original, translation keeps running and the original plays at full volume.")
    }
}

/// The direction's output volume. It stays available while translating and does not change
/// the system volume, so it also works when macOS output goes to BlackHole.
struct OutputVolumeControl: View {
    @ObservedObject var model: AppModel
    var incoming: Bool
    var compact = false
    private var icon: String {
        switch model.outputVolume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Slider(value: $model.outputVolume, in: 0...1).frame(width: compact ? 90 : 140).controlSize(compact ? .small : .regular)
                .accessibilityLabel("\(incoming ? "Listen" : "Speak") output volume")
                .accessibilityValue("\(Int((model.outputVolume * 100).rounded())) percent")
            if !compact {
                Text("\(Int((model.outputVolume * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing).accessibilityHidden(true)
            }
        }
        .help("Output volume for this direction. It does not change the system volume.")
    }
}

/// UI intent shared with menu commands. The model remains the owner of every
/// audio transition; these actions never run as a view lifecycle side effect.
@MainActor struct TranslationControlActions {
    let model: AppModel
    var primaryDisabled: Bool { model.phase == .stopping || model.checkingAPI || (!model.active && !model.muted && !model.requiresDeviceResume && !model.requiresConsumerResume && !model.setupRequirements.isEmpty) || ((model.requiresDeviceResume || model.requiresConsumerResume) ? (!model.inputAvailable || !model.outputAvailable || model.muted) : (model.microphoneArmed && !model.consumerActive && !model.muted && model.phase != .starting)) }
    var muteDisabled: Bool { model.phase == .stopping || model.checkingAPI || (!model.active && !model.microphoneArmed && !model.muted) }
    var offDisabled: Bool { model.phase == .stopping || (!model.active && !model.microphoneArmed && !model.muted) }
    var originalDisabled: Bool { model.active || model.microphoneArmed || model.muted || model.phase == .stopping || model.checkingAPI }
    var primaryTitle: String {
        if model.requiresDeviceResume || model.requiresConsumerResume { return "Resume" }
        if model.reconnecting { return "Cancel" }
        if model.active && model.bypass && model.translationIssue != nil { return "Retry" }
        if model.phase == .starting { return "Cancel" }
        if model.muted { return "Unmute" }
        if model.active && !model.bypass { return "Stop translating" }
        return "Translate"
    }
    var primaryHelp: String {
        if model.reconnecting { return "Cancel connection and continue with original audio" }
        if model.active && model.bypass && model.translationIssue != nil { return "Retry translation while original audio continues" }
        if model.phase == .starting { return "Cancel startup and turn this direction off" }
        if model.active && !model.bypass { return "Stop translating and continue with original audio" }
        if model.microphoneArmed && !model.consumerActive { return "Translation is available when another app uses the microphone" }
        return "Translate the selected audio source"
    }
    func performPrimary() async {
        guard !primaryDisabled else { return }
        if model.requiresDeviceResume { await model.resumeSelectedDevices() }
        else if model.requiresConsumerResume { await model.resumeConsumerAudio() }
        else if model.reconnecting { await model.setTranslationEnabled(false) }
        else if model.active && model.bypass && model.translationIssue != nil { await model.retryTranslation() }
        else if model.phase == .starting { await model.stop() }
        else if model.muted { await toggleMute() }
        else { await model.setTranslationEnabled(!(model.active && !model.bypass)) }
    }
    func toggleMute() async {
        guard !muteDisabled else { return }
        if !model.muted { await model.setMuted(true); return }
        await model.setMuted(false)
    }
    func turnOff() async {
        guard !offDisabled else { return }
        await model.stop()
        if model.muted { await model.setMuted(false) }
    }
    func startOriginal() async {
        guard !originalDisabled else { return }
        await model.setBypass(true)
        await model.start()
    }
}

enum CompactPreferences {
    /// Open compact controls instead of the main window at launch.
    static let atLaunch = "babelfin.compactControls.v1"
    /// Compact controls stay above other windows.
    static let onTop = "babelfin.compactControls.onTop"
}

/// Compact controls: a small window without a title bar, like a widget. The pin keeps it above
/// other windows; the close button and the window background work as usual.
struct CompactWindow: View {
    @ObservedObject var conversation: ConversationModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(CompactPreferences.onTop) private var onTop = false
    var body: some View {
        CompactControlsView(conversation: conversation) { MainNavigation.open($0, openWindow: openWindow) }
            .frame(width: 440)
            .background(CompactWindowLevel(onTop: onTop))
    }
}

/// Floats the compact window above other windows, also over full-screen apps, when the pin is on.
private struct CompactWindowLevel: NSViewRepresentable {
    var onTop: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let onTop = onTop
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = onTop ? .floating : .normal
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            if onTop { window.collectionBehavior.insert(.fullScreenAuxiliary) } else { window.collectionBehavior.remove(.fullScreenAuxiliary) }
        }
    }
}

struct CompactControlsView: View {
    @ObservedObject var conversation: ConversationModel
    var open: (MainSection) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CompactPreferences.onTop) private var onTop = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompactDirectionView(model: conversation.outgoing, incoming: false) { open(.home) }
            Divider()
            CompactDirectionView(model: conversation.incoming, incoming: true) { open(.home) }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 14)
        // The buttons share the title bar with the close button.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                iconButton(onTop ? "pin.fill" : "pin", onTop ? "Stop keeping on top" : "Keep on top", tint: onTop) { onTop.toggle() }
                iconButton("text.bubble", "Open the transcript") { open(.transcript) }
                iconButton("arrow.up.left.and.arrow.down.right", "Show Home") { open(.home) }
            }
            .padding(.trailing, 10).padding(.top, 5)
            .ignoresSafeArea(.container, edges: .top)
        }
        .modifier(NoFocusRing())
        .onAppear { refreshDevices() }
        .onChange(of: scenePhase) { if $0 == .active { refreshDevices() } }
    }
    private func iconButton(_ symbol: String, _ help: String, tint: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
    private func refreshDevices() { conversation.outgoing.refresh(); conversation.incoming.refresh(); conversation.outgoing.refreshKeyStatus(); conversation.incoming.refreshKeyStatus() }
}

/// One direction in two rows: state and the next action, then what you hear and the volume.
private struct CompactDirectionView: View {
    @ObservedObject var model: AppModel
    var incoming: Bool
    var configure: () -> Void
    @AppStorage(PipelineTimingPreferences.visible) private var timingVisible = false
    private var actions: TranslationControlActions { TranslationControlActions(model: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(model.statusColor).frame(width: 8, height: 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(incoming ? "Listen" : "Speak").font(.headline)
                    Text("\(model.languageSummary) · \(model.sessionTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                LevelMeter(level: model.level)
                    .accessibilityLabel(incoming ? "Listen input level" : "Microphone input level")
                    .accessibilityValue("\(Int(model.level * 100)) percent")
                if model.phase == .starting || model.phase == .stopping { ProgressView().controlSize(.small) }
                if model.phase == .failed || (!model.setupRequirements.isEmpty && !model.active && !model.muted) {
                    Button(model.phase == .failed ? "Review…" : "Set Up…", action: configure)
                } else {
                    Button(actions.primaryTitle) { Task { await actions.performPrimary() } }
                        .buttonStyle(.borderedProminent).disabled(actions.primaryDisabled).help(actions.primaryHelp)
                        .accessibilityLabel("\(incoming ? "Listen" : "Speak"): \(actions.primaryTitle)")
                }
                options
            }
            HStack(spacing: 10) {
                Picker("Hear", selection: $model.hearing) {
                    ForEach(AppModel.Hearing.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                .accessibilityLabel("\(incoming ? "Listen" : "Speak"): hear")
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $model.outputVolume, in: 0...1).controlSize(.small)
                    .accessibilityLabel("\(incoming ? "Listen" : "Speak") output volume")
                    .accessibilityValue("\(Int((model.outputVolume * 100).rounded())) percent")
            }
            if model.phase == .failed || model.requiresDeviceResume || model.translationIssue != nil {
                Text(model.sessionNotice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.pendingRestart.isEmpty { RestartNotice(model: model, compact: true) }
            if timingVisible && !model.route.descriptor.isDirect { PipelineTimingView(model: model, compact: true, showsBar: false) }
        }
    }
    private var options: some View {
        Menu {
            Button(model.muted ? "Unmute" : "Mute") { Task { await actions.toggleMute() } }.disabled(actions.muteDisabled)
            Button("Off") { Task { await actions.turnOff() } }.disabled(actions.offDisabled)
            Divider()
            if !incoming && model.destination == .teams {
                Toggle("Ready for Calls", isOn: Binding(get: { model.microphoneArmed }, set: { value in
                    Task { await model.setMicrophoneArmed(value) }
                }))
                .disabled(model.phase == .stopping || model.checkingAPI || (model.active && !model.microphoneArmed))
            }
            Button("Start Original Audio") { Task { await actions.startOriginal() } }.disabled(actions.originalDisabled)
            Toggle("Show Timing", isOn: $timingVisible)
            Button("Route and Audio…", action: configure)
        } label: { Label("Options", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("\(incoming ? "Listen" : "Speak") options")
    }
}

/// SwiftUI's minimum-size policy does not shrink an existing NSWindow when
/// configuration is hidden. Own the frame transition, without recreating the
/// window or either audio model. No audio actions belong here.
struct ConversationWindowSizing: NSViewRepresentable {
    static let compactMinimum = NSSize(width: 420, height: 220)
    static let compactMaximum = NSSize(width: 560, height: 360)
    static let expandedMinimum = NSSize(width: 900, height: 640)
    static let expandedMaximum = NSSize(width: 1440, height: 1000)
    var compact: Bool
    func makeNSView(context: Context) -> WindowAnchor {
        let view = WindowAnchor()
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        context.coordinator.compact = compact
        return view
    }
    func updateNSView(_ view: WindowAnchor, context: Context) {
        context.coordinator.compact = compact
        context.coordinator.schedule()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ view: WindowAnchor, coordinator: Coordinator) {
        view.onWindow = nil
        coordinator.attach(nil)
    }
    final class WindowAnchor: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window) }
    }
    @MainActor final class Coordinator: NSObject {
        static let compactSizeKey = "babelfin.window.compactSize.v2"
        // v2: the sidebar window is wider; narrower v1 sizes are not reused.
        static let expandedSizeKey = "babelfin.window.expandedSize.v2"
        var compact = false
        private weak var window: NSWindow?
        private var appliedCompact: Bool?
        private let defaults: UserDefaults
        private var scheduled = false
        private var applyingFrame = false
        init(defaults: UserDefaults = .standard) { self.defaults = defaults; super.init() }
        deinit { NotificationCenter.default.removeObserver(self) }
        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: self.window)
            self.window = window
            appliedCompact = nil
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize(_:)), name: NSWindow.didResizeNotification, object: window)
                schedule()
            }
        }
        @objc private func windowDidResize(_ notification: Notification) {
            // Pair this conversion with frameRect(forContentRect:) on restore.
            // contentLayoutRect excludes the titlebar even when a SwiftUI window
            // uses fullSizeContentView, so saving it would lose that height.
            guard !applyingFrame, let window, appliedCompact == compact,
                  let size = normalized(window.contentRect(forFrameRect: window.frame).size, compact: compact) else { return }
            defaults.set([Double(size.width), Double(size.height)], forKey: compact ? Self.compactSizeKey : Self.expandedSizeKey)
        }
        private func normalized(_ size: NSSize, compact: Bool) -> NSSize? {
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            let minimum = compact ? ConversationWindowSizing.compactMinimum : ConversationWindowSizing.expandedMinimum
            let maximum = compact ? ConversationWindowSizing.compactMaximum : ConversationWindowSizing.expandedMaximum
            return NSSize(width: min(maximum.width, max(minimum.width, size.width)), height: min(maximum.height, max(minimum.height, size.height)))
        }
        private func savedSize(compact: Bool) -> NSSize {
            let fallback = compact ? NSSize(width: 440, height: 250) : NSSize(width: 1120, height: 740)
            guard let values = defaults.array(forKey: compact ? Self.compactSizeKey : Self.expandedSizeKey), values.count == 2,
                  let width = values[0] as? NSNumber, let height = values[1] as? NSNumber,
                  CFGetTypeID(width) != CFBooleanGetTypeID(), CFGetTypeID(height) != CFBooleanGetTypeID(),
                  let size = normalized(NSSize(width: width.doubleValue, height: height.doubleValue), compact: compact) else { return fallback }
            return size
        }
        func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.apply()
            }
        }
        private func apply() {
            guard let window, appliedCompact != compact else { return }
            applyingFrame = true
            defer { applyingFrame = false }
            let oldFrame = window.frame
            var minimum = compact ? ConversationWindowSizing.compactMinimum : ConversationWindowSizing.expandedMinimum
            let contentSize = savedSize(compact: compact)
            if let visible = window.screen?.visibleFrame {
                let available = window.contentRect(forFrameRect: visible).size
                minimum.width = min(minimum.width, available.width)
                minimum.height = min(minimum.height, available.height)
            }
            window.contentMinSize = minimum
            window.contentMaxSize = compact ? ConversationWindowSizing.compactMaximum : ConversationWindowSizing.expandedMaximum
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
            frame.origin = NSPoint(x: oldFrame.minX, y: oldFrame.maxY - frame.height)
            if let visible = window.screen?.visibleFrame {
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
                frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
            }
            appliedCompact = compact
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
