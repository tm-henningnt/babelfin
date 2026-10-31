import AppKit
import SwiftUI

struct AboutView: View {
    var artwork: NSImage = Bundle.main.url(forResource: "BrandFish", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    @Environment(\.dismiss) private var dismiss
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: artwork)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 136, height: 136).accessibilityHidden(true)
                .padding(.bottom, 16)
            Text("Babelfin").font(.system(size: 28, weight: .semibold))
            Text("Let your words travel.").font(.headline).padding(.top, 8)
            Text("Live speech translation for macOS. Speak your language and be heard in another, or hear a meeting in yours.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            Text("By Henning Naarlien-Tolpinrud")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 16).textSelection(.enabled)
            HStack(spacing: 10) {
                Button("How to use") { AppLinks.openHelp() }
                Button("Check for Updates…") { UpdatesWindow.show(beforeQuit: {}) }
            }.buttonStyle(.bordered).padding(.top, 22)
            HStack(spacing: 20) {
                Link("Babelfin website", destination: AppLinks.website)
                Link("Source on GitHub", destination: AppLinks.repository)
                Button("License") { AppLinks.openLicense() }.buttonStyle(.link)
            }.font(.callout).padding(.top, 14)
            Divider().padding(.top, 24).padding(.bottom, 16)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Version \(version) (\(build))").textSelection(.enabled)
                    Text("Source-available under the Sustainable Use License")
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(32).frame(width: 460)
    }
}
