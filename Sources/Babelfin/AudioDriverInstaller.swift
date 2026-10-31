import Foundation
import CryptoKit

/// One virtual audio driver that the app bundle includes.
struct AudioDriver: Equatable, Sendable {
    let name: String
    let deviceUID: String
    var bundleName: String { name + ".driver" }
    static let microphone = AudioDriver(name: "Babelfin Microphone", deviceUID: AudioDevice.babelfinMicrophoneUID)
    static let speaker = AudioDriver(name: "Babelfin Speaker", deviceUID: AudioDevice.babelfinSpeakerUID)
    static let all = [microphone, speaker]
}

/// What Babelfin found for one driver. A digest is nil when that bundle does not exist.
struct AudioDriverObservation: Equatable, Sendable {
    var bundledDigest: String?
    var installedDigest: String?
    var deviceLoaded: Bool
}

enum AudioDriverStatus: Equatable, Sendable {
    case notInstalled, installed, versionDiffers, incomplete, notLoaded, removalPending

    var text: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .versionDiffers: return "Installed version differs"
        case .incomplete: return "Only one device is installed"
        case .notLoaded: return "Installed. Core Audio has not loaded the devices yet."
        case .removalPending: return "Removed. The devices stay visible until Core Audio restarts."
        }
    }

    /// Compares the bundles on disk with the bundles in the app, and the devices that Core Audio publishes.
    static func evaluate(_ drivers: [AudioDriverObservation]) -> AudioDriverStatus {
        let installed = drivers.filter { $0.installedDigest != nil }
        if installed.isEmpty { return drivers.contains { $0.deviceLoaded } ? .removalPending : .notInstalled }
        if installed.count < drivers.count { return .incomplete }
        if drivers.contains(where: { $0.bundledDigest != nil && $0.bundledDigest != $0.installedDigest }) { return .versionDiffers }
        return drivers.allSatisfy(\.deviceLoaded) ? .installed : .notLoaded
    }
}

enum AudioDriverInstallerError: LocalizedError, Equatable {
    case unsafePath, missingBundles, cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .unsafePath: return "Move Babelfin to a folder whose path has no line breaks, then try again."
        case .missingBundles: return "This copy of Babelfin does not include the audio devices."
        case .cancelled: return "Cancelled. Nothing was changed."
        case .failed(let message): return message.isEmpty ? "The administrator command failed." : "The administrator command failed: \(message)"
        }
    }
}

/// Builds and runs the administrator commands that install or remove the two driver bundles.
/// The commands touch only the two bundle paths in the HAL folder. They never change default devices.
enum AudioDriverInstaller {
    static let halDirectory = "/Library/Audio/Plug-Ins/HAL"
    static let restartCoreAudio = "/usr/bin/killall -9 coreaudiod"
    static let bundledFolderName = "AudioDrivers"
    static let licenseFileName = "GPL-3.0.txt"

    static func installedPath(_ driver: AudioDriver) -> String { halDirectory + "/" + driver.bundleName }

    /// Quotes one argument for /bin/sh. The result is a single word with no expansion.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for an AppleScript string literal.
    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Replaces both bundles and restarts Core Audio. The source folder is the app's AudioDrivers folder.
    static func installCommand(sourceDirectory: String) throws -> String {
        guard sourceDirectory.hasPrefix("/"), !sourceDirectory.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw AudioDriverInstallerError.unsafePath
        }
        let source = sourceDirectory.hasSuffix("/") ? String(sourceDirectory.dropLast()) : sourceDirectory
        let targets = AudioDriver.all.map { shellQuote(installedPath($0)) }.joined(separator: " ")
        var steps = ["/bin/mkdir -p " + shellQuote(halDirectory), "/bin/rm -rf " + targets]
        for driver in AudioDriver.all {
            // --noqtn and --noextattr keep a download quarantine flag off the installed driver.
            steps.append("/usr/bin/ditto --noextattr --noqtn --noacl " + shellQuote(source + "/" + driver.bundleName) + " " + shellQuote(installedPath(driver)))
        }
        steps.append("/usr/sbin/chown -R root:wheel " + targets)
        steps.append(restartCoreAudio)
        return steps.joined(separator: " && ")
    }

    /// Deletes exactly the two bundles and restarts Core Audio.
    static func removeCommand() -> String {
        "/bin/rm -rf " + AudioDriver.all.map { shellQuote(installedPath($0)) }.joined(separator: " ") + " && " + restartCoreAudio
    }

    /// One `do shell script` call, so macOS shows one administrator prompt for all steps.
    static func appleScript(command: String, prompt: String) -> String {
        "do shell script " + appleScriptLiteral(command) + " with prompt " + appleScriptLiteral(prompt) + " with administrator privileges"
    }

    static func bundledDirectory(in bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent(bundledFolderName, isDirectory: true)
    }
    /// True when this app build includes both driver bundles (BABELFIN_BUNDLE_DRIVERS=1).
    static func bundlesDrivers(in bundle: Bundle = .main) -> Bool {
        guard let directory = bundledDirectory(in: bundle) else { return false }
        return AudioDriver.all.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.bundleName).path) }
    }

    /// SHA-256 over the relative path and content of every regular file in a bundle. Nil when the bundle is absent.
    static func digest(of bundle: URL) -> String? {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: bundle.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let paths = try? files.subpathsOfDirectory(atPath: bundle.path) else { return nil }
        var hash = SHA256()
        for relative in paths.sorted() {
            let path = bundle.appendingPathComponent(relative).path
            // attributesOfItem does not follow a symbolic link; a link contributes its target text.
            guard let type = (try? files.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return nil }
            let content: Data
            switch type {
            case .typeDirectory: continue
            case .typeSymbolicLink: content = Data(((try? files.destinationOfSymbolicLink(atPath: path)) ?? "").utf8)
            case .typeRegular:
                guard let data = files.contents(atPath: path) else { return nil }
                content = data
            default: return nil
            }
            hash.update(data: Data(relative.utf8)); hash.update(data: Data([0]))
            hash.update(data: content); hash.update(data: Data([0]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func observe(bundled: URL?, installedDirectory: URL = URL(fileURLWithPath: halDirectory, isDirectory: true),
                        loadedUIDs: Set<String>) -> [AudioDriverObservation] {
        AudioDriver.all.map { driver in
            AudioDriverObservation(bundledDigest: bundled.flatMap { digest(of: $0.appendingPathComponent(driver.bundleName)) },
                                   installedDigest: digest(of: installedDirectory.appendingPathComponent(driver.bundleName)),
                                   deviceLoaded: loadedUIDs.contains(driver.deviceUID))
        }
    }

    /// Runs one command with administrator privileges. macOS shows the password prompt.
    /// NSAppleScript must run on the main thread; the call blocks until the command ends.
    @MainActor static func runPrivileged(_ command: String, prompt: String) throws {
        guard let script = NSAppleScript(source: appleScript(command: command, prompt: prompt)) else {
            throw AudioDriverInstallerError.failed("")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw AudioDriverInstallerError.cancelled }
        throw AudioDriverInstallerError.failed(error[NSAppleScript.errorMessage] as? String ?? "")
    }
}
