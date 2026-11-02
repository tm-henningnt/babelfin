import AppKit
import CryptoKit
import Foundation
import SwiftUI

// Manual, user-initiated updates from published GitHub releases. Babelfin contacts GitHub
// only when the person chooses Check for Updates. Each release carries babelfin-update.json,
// which binds the download's name, address, size and SHA-256 to that release.

enum UpdateError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

struct AppVersion: Comparable {
    let parts: [Int]
    init(_ text: String) throws {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.count <= 6 }),
              fields.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") }) else {
            throw UpdateError.invalid("The release has an invalid version.")
        }
        parts = try fields.map {
            guard let value = Int($0) else { throw UpdateError.invalid("Invalid version.") }
            return value
        } + Array(repeating: 0, count: 3 - fields.count)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct ReleaseAsset: Decodable { var name: String; var size: Int64; var browser_download_url: String }
struct GitHubRelease: Decodable {
    var tag_name: String
    var html_url: String
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var assets: [ReleaseAsset]
}
struct UpdateAsset: Codable, Equatable {
    var architecture: String
    var filename: String
    var url: String
    var size: Int64
    var sha256: String
}
struct UpdateManifest: Codable, Equatable {
    var schemaVersion: Int
    var repository: String
    var tag: String
    var version: String
    var build: Int
    var minimumSystemVersion: String
    var assets: [UpdateAsset]
}
struct AvailableUpdate {
    var manifest: UpdateManifest
    var asset: UpdateAsset
    var notes: String
    var releaseURL: URL
}

enum UpdatePolicy {
    static let repository = "tm-henningnt/babelfin"
    static let bundleIdentifier = "no.tallmaker.Babelfin"
    static let releasesPage = URL(string: "https://github.com/" + repository + "/releases")!
    static let manifestName = "babelfin-update.json"
    static let api = URL(string: "https://api.github.com/repos/" + repository + "/releases/latest")!
    static func tag(version: String, build: Int) -> String { "v\(version)-build\(build)" }
    static func releaseURL(_ tag: String) -> String { "https://github.com/" + repository + "/releases/tag/" + tag }
    static func filename(version: String, build: Int) -> String { "Babelfin-\(version)-build\(build)-macOS-arm64-unnotarized.zip" }
    static func assetURL(tag: String, filename: String) -> String {
        "https://github.com/" + repository + "/releases/download/" + tag + "/" + filename
    }
    static func safeTransport(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
        ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }
    static func validate(_ manifest: UpdateManifest, release: GitHubRelease, currentVersion: String,
                         currentBuild: Int, systemVersion: String) throws -> AvailableUpdate? {
        let version = try AppVersion(manifest.version)
        guard manifest.schemaVersion == 1, manifest.repository == repository, manifest.build > 0,
              manifest.tag == tag(version: manifest.version, build: manifest.build), release.tag_name == manifest.tag,
              !release.draft, !release.prerelease, release.html_url == releaseURL(manifest.tag),
              (try AppVersion(manifest.minimumSystemVersion)) <= (try AppVersion(systemVersion)),
              manifest.assets.count == 1, let asset = manifest.assets.first else {
            throw UpdateError.invalid("This release is incomplete or requires a newer version of macOS.")
        }
        guard asset.architecture == "arm64",
              asset.filename == filename(version: manifest.version, build: manifest.build),
              asset.url == assetURL(tag: manifest.tag, filename: asset.filename),
              asset.size > 0, asset.size <= 256 * 1024 * 1024,
              asset.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              release.assets.filter({ $0.name == asset.filename && $0.size == asset.size && $0.browser_download_url == asset.url }).count == 1 else {
            throw UpdateError.invalid("The release download could not be verified.")
        }
        let installed = try AppVersion(currentVersion)
        guard version > installed || version == installed && manifest.build > currentBuild else { return nil }
        return AvailableUpdate(manifest: manifest, asset: asset, notes: String((release.body ?? "").prefix(30_000)),
                               releaseURL: URL(string: release.html_url)!)
    }
    static func verify(file: URL, asset: UpdateAsset) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var count: Int64 = 0
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            count += Int64(chunk.count)
            guard count <= asset.size else { throw UpdateError.invalid("The download is larger than expected.") }
            hash.update(data: chunk)
        }
        guard count == asset.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
            throw UpdateError.invalid("The download failed its checksum check. Try again.")
        }
    }
}

final class UpdateRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(UpdatePolicy.safeTransport) == true ? request : nil)
    }
}

enum UpdateService {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: UpdateRedirects(), delegateQueue: nil)
    }
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Babelfin", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func responseError(_ response: HTTPURLResponse) -> UpdateError {
        if response.statusCode == 403 {
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining")?.trimmingCharacters(in: .whitespaces) == "0" {
                return .invalid("GitHub's update request limit has been reached. Try again later.")
            }
            return .invalid("GitHub denied this update request. Try again later.")
        }
        if (500...599).contains(response.statusCode) { return .invalid("GitHub is having trouble serving updates. Try again later.") }
        return .invalid("GitHub could not serve the update. Try again later.")
    }
    static func transportError(_ error: URLError) -> Error {
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .networkConnectionLost:
            return UpdateError.invalid("You appear to be offline. Check your internet connection and try again.")
        case .timedOut: return UpdateError.invalid("The update request timed out. Check your connection and try again.")
        default: return error
        }
    }
    static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch is DecodingError { throw UpdateError.invalid("The update information is invalid. Try again later.") }
    }
    static func data(_ url: URL, session: URLSession, maximum: Int) async throws -> Data? {
        do {
            guard UpdatePolicy.safeTransport(url) else { throw UpdateError.invalid("Invalid update address.") }
            let (stream, response) = try await session.bytes(for: request(url))
            guard let response = response as? HTTPURLResponse else { throw UpdateError.invalid("No update response.") }
            if response.statusCode == 404 && url == UpdatePolicy.api { return nil }
            guard response.statusCode == 200 else { throw responseError(response) }
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < maximum else { throw UpdateError.invalid("The update information is too large.") }
                data.append(byte)
            }
            return data
        } catch let error as URLError { throw transportError(error) }
    }
    static func check(version: String, build: Int, system: String) async throws -> AvailableUpdate? {
        let session = session()
        defer { session.invalidateAndCancel() }
        guard let releaseData = try await data(UpdatePolicy.api, session: session, maximum: 1_048_576) else { return nil }
        let release = try decode(GitHubRelease.self, data: releaseData)
        guard !release.draft, !release.prerelease,
              release.tag_name.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+-build[0-9]+$", options: .regularExpression) != nil,
              release.html_url == UpdatePolicy.releaseURL(release.tag_name) else {
            throw UpdateError.invalid("The published release could not be verified.")
        }
        let matches = release.assets.filter { $0.name == UpdatePolicy.manifestName }
        guard matches.count == 1, let asset = matches.first, asset.size > 0, asset.size <= 65_536,
              asset.browser_download_url == UpdatePolicy.assetURL(tag: release.tag_name, filename: UpdatePolicy.manifestName),
              let url = URL(string: asset.browser_download_url),
              let manifestData = try await data(url, session: session, maximum: 65_536) else {
            throw UpdateError.invalid("This release does not include a complete update manifest.")
        }
        let manifest = try decode(UpdateManifest.self, data: manifestData)
        return try UpdatePolicy.validate(manifest, release: release, currentVersion: version, currentBuild: build, systemVersion: system)
    }
    /// Downloads into a private temporary folder, verifies size and SHA-256, then moves the archive to Downloads.
    static func download(_ asset: UpdateAsset) async throws -> URL {
        do {
            guard let url = URL(string: asset.url), UpdatePolicy.safeTransport(url) else { throw UpdateError.invalid("Invalid download address.") }
            let session = session()
            defer { session.invalidateAndCancel() }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Babelfin-update-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let staged = folder.appendingPathComponent(asset.filename)
            FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            let (stream, response) = try await session.bytes(for: request(url))
            guard let response = response as? HTTPURLResponse else { throw UpdateError.invalid("The release download is unavailable.") }
            if response.statusCode != 200 {
                if response.statusCode == 403 || (500...599).contains(response.statusCode) { throw responseError(response) }
                throw UpdateError.invalid("The release download is unavailable.")
            }
            var buffer = Data(), count: Int64 = 0
            for try await byte in stream {
                try Task.checkCancellation()
                count += 1
                guard count <= asset.size else { throw UpdateError.invalid("The download is larger than expected.") }
                buffer.append(byte)
                if buffer.count == 65_536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize()
            try UpdatePolicy.verify(file: staged, asset: asset)
            try Task.checkCancellation()
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var destination = downloads.appendingPathComponent(asset.filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = downloads.appendingPathComponent(asset.filename.replacingOccurrences(of: ".zip", with: "-" + UUID().uuidString + ".zip"))
            }
            try FileManager.default.moveItem(at: staged, to: destination)
            return destination
        } catch let error as URLError { throw transportError(error) }
    }
}

/// Starts the bundled zsh helper from a private copy, because the helper replaces this bundle.
enum UpdateInstaller {
    static func start(archive: URL, update: AvailableUpdate, onReady: @escaping @MainActor () -> Void,
                      onFailure: @escaping @MainActor (String) -> Void) throws -> Process {
        guard Bundle.main.bundleIdentifier == UpdatePolicy.bundleIdentifier else {
            throw UpdateError.invalid("This build of Babelfin cannot install release updates.")
        }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("update_installer.sh"),
              FileManager.default.isReadableFile(atPath: helper.path) else {
            throw UpdateError.invalid("The update installer is missing from this app.")
        }
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent("Babelfin-update-helper-" + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let copied = workspace.appendingPathComponent("update_installer.sh")
            try fileManager.copyItem(at: helper, to: copied)
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", copied.path,
                                 "--archive", archive.path, "--sha256", update.asset.sha256,
                                 "--version", update.manifest.version, "--build", String(update.manifest.build),
                                 "--bundle-id", UpdatePolicy.bundleIdentifier,
                                 "--target", Bundle.main.bundleURL.path,
                                 "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
                                 "--workspace", workspace.path]
            process.standardOutput = output; process.standardError = errors
            do { try process.run() } catch {
                try? fileManager.removeItem(at: workspace)
                throw UpdateError.invalid("The update installer could not be started.")
            }
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            DispatchQueue.global(qos: .userInitiated).async {
                let reader = output.fileHandleForReading
                var line = Data()
                while let value = reader.readData(ofLength: 1).first, value != 10 { line.append(value) }
                let ready = String(data: line, encoding: .utf8) == "READY"
                if ready { DispatchQueue.main.async { MainActor.assumeIsolated { onReady() } } }
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                process.waitUntilExit()
                guard !ready || process.terminationStatus != 0 else { return }
                let failure = message.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) }
                    ?? (ready ? "The update could not be completed. Babelfin is still running." : "The update could not be prepared. Babelfin is still running.")
                DispatchQueue.main.async { MainActor.assumeIsolated { onFailure(failure) } }
            }
            return process
        } catch let error as UpdateError {
            try? fileManager.removeItem(at: workspace); throw error
        } catch {
            try? fileManager.removeItem(at: workspace)
            throw UpdateError.invalid("The update installer could not be prepared.")
        }
    }
}

@MainActor final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published var status = "Check for a published Babelfin release."
    @Published var checking = false
    @Published var downloading = false
    @Published var installing = false
    @Published var failed = false
    @Published var available: AvailableUpdate?
    @Published var downloaded: URL?
    private var downloadTask: Task<Void, Never>?
    private var installProcess: Process?
    var waitingToClose: Bool { installProcess != nil }
    init() {
        if let reason = Self.installFailureReason() {
            failed = true; status = reason
        }
    }
    /// The helper leaves a short, owner-only note beside the app when it restores the previous version.
    private static func installFailureReason() -> String? {
        let arguments = CommandLine.arguments
        guard let option = arguments.firstIndex(of: "--update-install-failure-file"), arguments.indices.contains(option + 1) else { return nil }
        let file = URL(fileURLWithPath: arguments[option + 1]).standardizedFileURL
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().path == parent.path,
              file.lastPathComponent.hasPrefix(".Babelfin-update-failure-"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= 2048,
              let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        let reason = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }
    func check() async {
        guard !checking, !downloading, !installing else { return }
        checking = true; failed = false; available = nil; downloaded = nil
        status = "Checking GitHub releases…"
        defer { checking = false }
        do {
            let info = Bundle.main.infoDictionary ?? [:]
            let system = ProcessInfo.processInfo.operatingSystemVersion
            available = try await UpdateService.check(version: info["CFBundleShortVersionString"] as? String ?? "0.0",
                                                      build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0,
                                                      system: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
            status = available == nil ? "Babelfin is up to date." : "A new version of Babelfin is available."
        } catch {
            failed = true; status = error.localizedDescription
        }
    }
    func download() {
        guard let update = available, !downloading else { return }
        downloading = true; failed = false
        status = "Downloading and verifying Babelfin…"
        downloadTask = Task {
            defer { downloading = false; downloadTask = nil }
            do {
                downloaded = try await UpdateService.download(update.asset)
                status = "Download verified. Ready to install and reopen Babelfin."
            } catch is CancellationError {
                failed = true; status = "Download canceled."
            } catch let error as URLError where error.code == .cancelled {
                failed = true; status = "Download canceled."
            } catch {
                failed = true; status = error.localizedDescription
            }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func install(beforeQuit: @escaping @MainActor () -> Void) {
        guard let update = available, let downloaded, installProcess == nil, !installing, !downloading else { return }
        installing = true; failed = false
        status = "Preparing the verified update…"
        do {
            installProcess = try UpdateInstaller.start(archive: downloaded, update: update, onReady: { [weak self] in
                self?.status = "Installing the update and reopening Babelfin…"
                beforeQuit()
                MeetingRecorder.shared.keepForUpdate()
                NSApp.terminate(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, self.installing, NSApp.isRunning else { return }
                    MeetingRecorder.shared.keepsAtQuit = false
                    self.installing = false; self.failed = true
                    self.status = "Babelfin is still open. Close open dialogs or choose Quit to let the installer continue."
                }
            }, onFailure: { [weak self] message in
                self?.installing = false; self?.failed = true; self?.status = message; self?.installProcess = nil
            })
        } catch {
            installing = false; failed = true; status = error.localizedDescription; installProcess = nil
        }
    }
}

@MainActor enum UpdatesWindow {
    private static var window: NSWindow?
    static func show(check: Bool = true, beforeQuit: @escaping @MainActor () -> Void) {
        if window == nil {
            let created = NSWindow(contentViewController: NSHostingController(rootView: UpdatesView(beforeQuit: beforeQuit)))
            created.title = "Babelfin Updates"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if check, AppUpdater.shared.available == nil, AppUpdater.shared.downloaded == nil { Task { await AppUpdater.shared.check() } }
    }
}

struct UpdatesView: View {
    @ObservedObject private var updater = AppUpdater.shared
    var beforeQuit: @MainActor () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Babelfin updates").font(.title2.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if updater.failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true) }
                Text(updater.status).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if updater.checking || updater.downloading || updater.installing { ProgressView().controlSize(.small) }
            }.accessibilityElement(children: .combine)
            if updater.failed { Link("View releases on GitHub", destination: UpdatePolicy.releasesPage) }
            if let update = updater.available {
                Text("Version \(update.manifest.version) (\(update.manifest.build)) · \(ByteCountFormatter.string(fromByteCount: update.asset.size, countStyle: .file))")
                    .font(.callout.weight(.medium))
                ScrollView {
                    ReleaseNotesView(markdown: update.notes.isEmpty ? "No release notes were provided." : update.notes)
                }
                .frame(height: 180)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Link("Release on GitHub", destination: update.releaseURL)
            }
            if updater.downloaded != nil {
                Text("Babelfin turns translation off, quits, replaces the app and opens it again. A meeting recording stays and opens again. macOS may ask for microphone or Keychain access again after an update.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Check again") { Task { await updater.check() } }
                    .disabled(updater.checking || updater.downloading || updater.installing)
                Spacer()
                if updater.downloading {
                    Button("Cancel download") { updater.cancelDownload() }
                } else if updater.downloaded != nil {
                    Button(updater.installing ? "Preparing…" : (updater.waitingToClose ? "Waiting to close…" : "Install and reopen")) {
                        updater.install(beforeQuit: beforeQuit)
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(updater.installing || updater.waitingToClose)
                } else if updater.available != nil {
                    Button("Download update") { updater.download() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 520)
    }
}

/// Release notes are rendered as headings, bullets and paragraphs; only https links stay active.
private struct ReleaseNotesView: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ReleaseNotesMarkup.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .heading(let level): Text(block.text).font(level == 1 ? .title3 : .headline)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").accessibilityHidden(true); Text(block.text) }.font(.callout)
                case .paragraph: Text(block.text).font(.callout)
                }
            }
        }
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }
}

enum ReleaseNotesMarkup {
    enum Kind: Equatable { case heading(Int), bullet, paragraph }
    struct Block { let kind: Kind; let text: AttributedString }
    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(Block(kind: .paragraph, text: inline(paragraph.joined(separator: "\n")))); paragraph.removeAll()
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { flush(); continue }
            let level = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), line.dropFirst(level).first == " " {
                flush(); blocks.append(Block(kind: .heading(level), text: inline(String(line.dropFirst(level + 1)))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); blocks.append(Block(kind: .bullet, text: inline(String(line.dropFirst(2)))))
            } else { paragraph.append(line) }
        }
        flush()
        return blocks
    }
    private static func inline(_ source: String) -> AttributedString {
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let unsafe = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link else { return nil }
            return link.scheme?.lowercased() == "https" && link.host?.isEmpty == false && link.user == nil && link.password == nil ? nil : run.range
        }
        for range in unsafe { result[range].link = nil }
        return result
    }
}
