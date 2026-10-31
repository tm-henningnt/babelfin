import AppKit
import Combine
import SwiftUI

/// A non-activating control, shown once per observed consumer onset while armed.
/// It never starts translation by itself or steals keyboard focus from the meeting.
@MainActor final class CallPromptController {
    private let model: AppModel
    private var panel: NSPanel?
    private var subscriptions = Set<AnyCancellable>()
    init(model: AppModel) {
        self.model = model
        model.$consumerActive.removeDuplicates().sink { [weak self] active in
            guard let self else { return }
            if active, self.model.microphoneArmed, !self.model.muted { self.show() }
            else if !active { self.close() }
        }.store(in: &subscriptions)
        model.$microphoneArmed.removeDuplicates().sink { [weak self] armed in if !armed { self?.close() } }.store(in: &subscriptions)
    }
    func close() { panel?.orderOut(nil) }
    private func show() {
        if panel == nil {
            let window = CallControlPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 160), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Babelfin"
            window.isFloatingPanel = true
            window.becomesKeyOnlyIfNeeded = false
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CallPromptView(model: model))
            window.center()
            panel = window
        }
        panel?.orderFrontRegardless()
    }
}

private struct CallPromptView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your virtual microphone is in use", systemImage: "mic").font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            ScrollView {
                Text(model.sessionTitle + ". " + model.sessionNotice)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel("Microphone status")
            TranslationControls(model: model)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .accessibilityElement(children: .contain)
        }.padding(20).frame(width: 340, height: 160)
    }
}

/// User interaction may focus the panel; merely ordering it on screen does not.
private final class CallControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
