import Foundation
import Darwin
import BridgeCore

private struct CheckFailure: Error { let message: String }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message: message) }
}
private func rejects(_ expected: LocalCredentialError, _ body: () throws -> Void) throws {
    do { try body() }
    catch let error as LocalCredentialError {
        try expect(error == expected, "Unexpected safe credential error"); return
    }
    throw CheckFailure(message: "Expected credential operation rejection")
}
private func metadata(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw CheckFailure(message: "Fixture metadata unavailable") }
    return value
}
private func permission(_ mode: mode_t, _ url: URL) throws {
    guard chmod(url.path, mode) == 0 else { throw CheckFailure(message: "Could not set fixture permissions") }
}
private func fixture(_ directory: URL) -> LocalCredentialStore { LocalCredentialStore(directoryURL: directory) }

@main private struct CredentialChecks {
    @MainActor static func main() {
        // Foundation canonicalizes macOS /private/var back to its /var symlink; use libc realpath
        // so the fixture can keep the production rule that rejects every symlink component.
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            fputs("FAIL: temporary directory unavailable\n", stderr); exit(1)
        }
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent(UUID().uuidString)
        free(canonical)
        do {
            guard mkdir(root.path, 0o700) == 0 else { throw CheckFailure(message: "Could not create private fixture") }
            defer { try? FileManager.default.removeItem(at: root) }
            try selectionAndRemovalChecks()
            try storageChecks(root)
            try validationChecks(root)
            try unsafeFileChecks(root)
            try unsafeDirectoryChecks(root)
            try aclChecks(root)
            try facadeChecks(root)
            print("PASS: 14 credential storage check groups (synthetic keys, temporary files; no real Keychain access)")
        } catch let error as CheckFailure {
            fputs("FAIL: \(error.message)\n", stderr); exit(1)
        } catch let error as LocalCredentialError {
            // Closed enum only, without filesystem paths, underlying errors or credential values.
            let label: String
            switch error { case .invalidKey: label = "invalidKey"; case .missingKey: label = "missingKey"
            case .unsafeStore: label = "unsafeStore"; case .corruptKey: label = "corruptKey"; case .unavailable: label = "unavailable" }
            fputs("FAIL: unexpected safe credential error (\(label))\n", stderr); exit(1)
        } catch { fputs("FAIL: unexpected credential check error\n", stderr); exit(1) }
    }

    @MainActor private static func selectionAndRemovalChecks() throws {
        let suite = "BabelfinSelectionChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(KeychainStore.recommendedStorageMode == .localFile, "New-user recommendation is local")
        try expect(KeychainStore.needsStorageSelection(in: defaults), "Unknown installation requires explicit choice")
        try expect(KeychainStore.storageMode(in: defaults) == .keychain, "Legacy absent preference never silently switches")
        defaults.set("invalid", forKey: KeychainStore.storagePreferenceKey)
        try expect(KeychainStore.needsStorageSelection(in: defaults), "Invalid preference is not a valid choice")
        for mode in CredentialStorageMode.allCases {
            KeychainStore.setStorageMode(mode, in: defaults)
            try expect(!KeychainStore.needsStorageSelection(in: defaults) && KeychainStore.storageMode(in: defaults) == mode, "Explicit selection is preserved")
        }
        print("PASS: local recommendation and explicit first-use choice preserve legacy fallback")
        var calls: [(ProviderService, CredentialStorageMode)] = []
        let result = KeychainStore.removeAll(storage: .localFile) { service, storage in
            calls.append((service, storage))
            if service == .elevenLabs { throw LocalCredentialError.unavailable }
        }
        try expect(calls.map { $0.0 } == ProviderService.allCases && calls.allSatisfy { $0.1 == .localFile }, "Remove all targets every provider in only the confirmed store")
        try expect(result.failed == [.elevenLabs] && Set(result.removed) == [.openAI, .fish], "Partial failure preserves successful removal results")
        let complete = KeychainStore.removeAll(storage: .keychain) { _, storage in
            try expect(storage == .keychain, "Explicit Keychain removal does not fall back")
        }
        try expect(complete.failed.isEmpty && complete.removed.count == 3, "All-success result")
        print("PASS: injected removal is scoped and partial failures remain visible without real stores")
        let activity = CredentialOperationActivity()
        let first = activity.begin(), second = activity.begin()
        try expect(activity.active, "Concurrent operations prevent editing")
        activity.end(first)
        try expect(activity.active, "One completion cannot unlock another operation")
        activity.end(first)
        try expect(activity.active, "Duplicate release cannot unlock another operation")
        activity.end(second)
        try expect(!activity.active, "Last operation releases editing guard")
        print("PASS: credential activity remains locked until all operations release")
    }

    private static func storageChecks(_ root: URL) throws {
        let directory = root.appendingPathComponent("basic"), store = fixture(directory)
        try expect(store.containsSavedKey(for: .openAI) == false, "Missing store is absent")
        try rejects(.missingKey) { _ = try store.load(for: .openAI) }
        try store.delete(for: .openAI)
        try expect(!FileManager.default.fileExists(atPath: directory.path), "Presence/load/delete do not create storage")
        try store.save("  synthetic-openai  ", for: .openAI)
        try expect(try store.load(for: .openAI) == "synthetic-openai", "Save/load trimmed key")
        try expect(store.containsSavedKey(for: .openAI) == true && store.containsSavedKey(for: .fish) == false, "Provider presence isolation")
        try expect(try metadata(directory).st_mode & 0o7777 == 0o700, "Private directory mode")
        let file = directory.appendingPathComponent("openai.key")
        let first = try metadata(file)
        try expect(first.st_mode & 0o7777 == 0o600 && first.st_uid == geteuid() && first.st_nlink == 1, "Owner-only regular key metadata")
        print("PASS: nonmutating presence checks and private directory/file creation")

        try store.save("synthetic-new", for: .openAI)
        let second = try metadata(file)
        try expect(first.st_ino != second.st_ino, "Replacement installs a fresh inode atomically")
        try expect(try store.load(for: .openAI) == "synthetic-new", "Replacement value")
        try store.save("synthetic-eleven", for: .elevenLabs); try store.save("synthetic-fish", for: .fish)
        try store.delete(for: .openAI); try store.delete(for: .openAI)
        try expect(store.containsSavedKey(for: .openAI) == false, "Selected key deletion is idempotent")
        try expect(try store.load(for: .elevenLabs) == "synthetic-eleven" && store.load(for: .fish) == "synthetic-fish", "Deletion does not affect other providers")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try expect(Set(names) == ["elevenlabs.key", "fish.key"], "No temporary keys remain")
        print("PASS: atomic replacement, independent providers and scoped deletion")
    }

    private static func validationChecks(_ root: URL) throws {
        let directory = root.appendingPathComponent("validation"), store = fixture(directory)
        for bad in ["", " \n", "synthetic key", "synthetic\nkey", "synthetic\0key", String(repeating: "x", count: 4_097)] {
            try rejects(.invalidKey) { try store.save(bad, for: .openAI) }
        }
        try expect(!FileManager.default.fileExists(atPath: directory.path), "Invalid input does not create storage")
        let bounded = String(repeating: "x", count: 4_096)
        try store.save(bounded, for: .openAI)
        try expect(try store.load(for: .openAI) == bounded, "Exact key byte bound accepted")
        print("PASS: key validation and exact 4 KB limit before filesystem mutation")

        let file = directory.appendingPathComponent("openai.key")
        for data in [Data(), Data([0xff, 0xfe]), Data("invalid\nkey".utf8), Data(repeating: 0x61, count: 4_097)] {
            try data.write(to: file)
            try permission(0o600, file)
            try rejects(.corruptKey) { _ = try store.load(for: .openAI) }
            if data.isEmpty || data.count > 4_096 { try expect(store.containsSavedKey(for: .openAI) == nil, "Invalid size is unknown presence") }
            try store.delete(for: .openAI)
            try expect(store.containsSavedKey(for: .openAI) == false, "Corrupt contents may be explicitly removed")
            try store.save("synthetic", for: .openAI)
        }
        print("PASS: invalid UTF-8, whitespace, empty and oversized stored contents")
    }

    private static func unsafeFileChecks(_ root: URL) throws {
        let directory = root.appendingPathComponent("file-safety"), store = fixture(directory)
        try store.save("synthetic", for: .openAI)
        let file = directory.appendingPathComponent("openai.key")
        for mode: mode_t in [0o644, 0o660, 0o400, 0o4600] {
            try permission(mode, file)
            try rejects(.unsafeStore) { _ = try store.load(for: .openAI) }
            try rejects(.unsafeStore) { try store.save("replacement", for: .openAI) }
            try rejects(.unsafeStore) { try store.delete(for: .openAI) }
            try expect(store.containsSavedKey(for: .openAI) == nil, "Unsafe key is unknown presence")
            try expect(try metadata(file).st_mode & 0o7777 == mode, "Unsafe permissions are not silently repaired")
        }
        try permission(0o600, file)
        let hardlink = root.appendingPathComponent("outside-hardlink")
        guard link(file.path, hardlink.path) == 0 else { throw CheckFailure(message: "Could not create hardlink fixture") }
        try rejects(.unsafeStore) { _ = try store.load(for: .openAI) }
        try rejects(.unsafeStore) { try store.save("replacement", for: .openAI) }
        try rejects(.unsafeStore) { try store.delete(for: .openAI) }
        try expect(try metadata(hardlink).st_nlink == 2, "Hardlinks remain unchanged on rejection")
        guard unlink(hardlink.path) == 0 else { throw CheckFailure(message: "Could not remove hardlink fixture") }
        print("PASS: unsafe modes and hardlinks fail closed without chmod or removal")

        try store.delete(for: .openAI)
        let outside = root.appendingPathComponent("outside-value")
        try Data("outside-synthetic".utf8).write(to: outside)
        try permission(0o600, outside)
        guard symlink(outside.path, file.path) == 0 else { throw CheckFailure(message: "Could not create symlink fixture") }
        try rejects(.unsafeStore) { _ = try store.load(for: .openAI) }
        try rejects(.unsafeStore) { try store.save("replacement", for: .openAI) }
        try rejects(.unsafeStore) { try store.delete(for: .openAI) }
        try expect(try Data(contentsOf: outside) == Data("outside-synthetic".utf8), "Symlink target is unchanged")
        guard unlink(file.path) == 0, mkfifo(file.path, 0o600) == 0 else { throw CheckFailure(message: "Could not create FIFO fixture") }
        try rejects(.unsafeStore) { _ = try store.load(for: .openAI) }
        try rejects(.unsafeStore) { try store.save("replacement", for: .openAI) }
        try rejects(.unsafeStore) { try store.delete(for: .openAI) }
        guard unlink(file.path) == 0, mkdir(file.path, 0o700) == 0 else { throw CheckFailure(message: "Could not create non-file fixture") }
        try rejects(.unsafeStore) { _ = try store.load(for: .openAI) }
        print("PASS: key symlinks, FIFOs and directories rejected without following or blocking")
    }

    private static func unsafeDirectoryChecks(_ root: URL) throws {
        let directory = root.appendingPathComponent("directory-safety"), store = fixture(directory)
        try store.save("synthetic", for: .openAI)
        for mode: mode_t in [0o755, 0o770] {
            try permission(mode, directory)
            try rejects(.unsafeStore) { _ = try store.load(for: .openAI) }
            try rejects(.unsafeStore) { try store.save("replacement", for: .openAI) }
            try rejects(.unsafeStore) { try store.delete(for: .openAI) }
            try expect(store.containsSavedKey(for: .openAI) == nil, "Unsafe directory is unknown")
            try expect(try metadata(directory).st_mode & 0o7777 == mode, "Directory permissions are not repaired")
        }
        try permission(0o700, directory)
        let alias = root.appendingPathComponent("directory-alias")
        guard symlink(directory.path, alias.path) == 0 else { throw CheckFailure(message: "Could not create directory alias") }
        for path in [alias, alias.appendingPathComponent("nested")] {
            let linked = fixture(path)
            try rejects(.unsafeStore) { _ = try linked.load(for: .openAI) }
            try rejects(.unsafeStore) { try linked.save("replacement", for: .openAI) }
            try rejects(.unsafeStore) { try linked.delete(for: .openAI) }
        }
        try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("nested").path), "No directory created through a linked ancestor")
        print("PASS: store and ancestor symlinks plus unsafe directory permissions")
    }

    private static func aclChecks(_ root: URL) throws {
        let directory = root.appendingPathComponent("acl-safety"), store = fixture(directory)
        try store.save("synthetic", for: .openAI)
        let file = directory.appendingPathComponent("openai.key")
        for target in [file, directory] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "everyone allow read", target.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            try expect(process.terminationStatus == 0, "Extended ACL fixture creation")
            try rejects(.unsafeStore) { _ = try store.load(for: .openAI) }
            try rejects(.unsafeStore) { try store.save("replacement", for: .openAI) }
            try rejects(.unsafeStore) { try store.delete(for: .openAI) }
            try expect(store.containsSavedKey(for: .openAI) == nil, "ACL-protected presence is unknown")
            let reset = Process(); reset.executableURL = URL(fileURLWithPath: "/bin/chmod")
            reset.arguments = ["-N", target.path]
            reset.standardOutput = FileHandle.nullDevice; reset.standardError = FileHandle.nullDevice
            try reset.run(); reset.waitUntilExit()
            try expect(reset.terminationStatus == 0, "Extended ACL fixture cleanup")
        }
        print("PASS: extended ACLs cannot bypass owner-only mode bits")
    }

    private static func facadeChecks(_ root: URL) throws {
        let directory = root.appendingPathComponent("facade"), store = fixture(directory)
        // Explicit local selection prevents every test from entering a Security.framework branch.
        try KeychainStore.save("synthetic-facade", for: .fish, storage: .localFile, localStore: store)
        try expect(KeychainStore.containsSavedKey(for: .fish, storage: .localFile, localStore: store) == true, "Facade routes local presence")
        try expect(try KeychainStore.load(for: .fish, storage: .localFile, localStore: store) == "synthetic-facade", "Facade routes local load")
        try KeychainStore.delete(for: .fish, storage: .localFile, localStore: store)
        try rejects(.missingKey) { _ = try KeychainStore.load(for: .fish, storage: .localFile, localStore: store) }
        try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("openai.key").path), "Facade never copies another provider")
        print("PASS: selected local facade load/save/delete; missing key never falls back")

        let suite = "BabelfinCredentialChecks-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure(message: "Could not create isolated preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(KeychainStore.storageMode(in: defaults) == .keychain, "Default remains Keychain")
        try store.save("synthetic-retained", for: .openAI)
        for selection in [CredentialStorageMode.localFile, .keychain, .localFile] {
            KeychainStore.setStorageMode(selection, in: defaults)
            try expect(KeychainStore.storageMode(in: defaults) == selection, "Explicit preference selection retained")
            try expect(try store.load(for: .openAI) == "synthetic-retained", "Mode changes do not remove stored keys")
        }
        print("PASS: isolated preference default and selection without credential migration")

        for error in [LocalCredentialError.invalidKey, .missingKey, .unsafeStore, .corruptKey, .unavailable] {
            let message = error.localizedDescription
            try expect(!message.contains(root.path) && !message.contains("synthetic-"), "Error excludes path and key")
        }
        try expect(String(reflecting: store) == "LocalCredentialStore(redacted)" && Mirror(reflecting: store).children.isEmpty,
                   "Store descriptions exclude private location")
        print("PASS: closed errors and redacted descriptions")
    }
}
