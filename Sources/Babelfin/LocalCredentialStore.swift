import Foundation
import Darwin
import BridgeCore

enum CredentialStorageMode: String, CaseIterable, Identifiable {
    case keychain, localFile
    var id: String { rawValue }
    var displayName: String { self == .keychain ? "Keychain" : "This Mac (local file)" }
}

enum LocalCredentialError: LocalizedError, Equatable {
    case invalidKey, missingKey, unsafeStore, corruptKey, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Enter an API key of up to 4 KB without spaces or line breaks."
        case .missingKey: return "Enter this service's API key for This Mac in Accounts."
        case .unsafeStore: return "Local key storage has unsafe ownership, permissions or links. Restore its private permissions or choose Keychain."
        case .corruptKey: return "The local key file is invalid. Remove it and enter the key again."
        case .unavailable: return "Could not access local key storage. Try again or choose Keychain."
        }
    }
}

/// Explicit, unencrypted storage. Never reads Keychain, process environments or development files.
/// Every operation anchors traversal to directory descriptors and refuses symlink components.
struct LocalCredentialStore: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let maximumKeyBytes = 4_096
    private let directoryURL: URL
    init(directoryURL: URL) { self.directoryURL = directoryURL }
    static var defaultStore: LocalCredentialStore {
        LocalCredentialStore(directoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Babelfin", isDirectory: true))
    }
    var description: String { "LocalCredentialStore(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

    /// Metadata only. Missing is false; an unsafe/unreadable store is unknown, never an empty store.
    func containsSavedKey(for provider: ProviderService) -> Bool? {
        do {
            guard let directory = try openDirectory(create: false) else { return false }
            defer { close(directory) }
            guard let file = try openKey(in: directory, name: filename(provider)) else { return false }
            defer { close(file) }
            return true
        } catch { return nil }
    }

    func load(for provider: ProviderService) throws -> String {
        guard let directory = try openDirectory(create: false) else { throw LocalCredentialError.missingKey }
        defer { close(directory) }
        let name = filename(provider)
        guard let file = try openKey(in: directory, name: name) else { throw LocalCredentialError.missingKey }
        defer { close(file) }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw LocalCredentialError.unavailable }
            guard count <= Self.maximumKeyBytes - bytes.count else { throw LocalCredentialError.corruptKey }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        try validateFile(file)
        try validateEntry(directory: directory, name: name, descriptor: file)
        guard let key = String(data: bytes, encoding: .utf8), Self.validKey(key), key.utf8.count == bytes.count else {
            throw LocalCredentialError.corruptKey
        }
        return key
    }

    func save(_ raw: String, for provider: ProviderService) throws {
        // Bound before trimming so a large pasted value cannot create an unbounded copy.
        guard raw.utf8.count <= Self.maximumKeyBytes else { throw LocalCredentialError.invalidKey }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validKey(key) else { throw LocalCredentialError.invalidKey }
        guard let directory = try openDirectory(create: true) else { throw LocalCredentialError.unavailable }
        defer { close(directory) }
        let name = filename(provider)
        try checkDestination(directory: directory, name: name)
        let temporary = ".credential-" + UUID().uuidString
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw LocalCredentialError.unavailable }
        var renamed = false
        defer {
            close(file)
            if !renamed { _ = unlinkat(directory, temporary, 0) }
        }
        try validateFile(file, permitEmpty: true)
        let bytes = Data(key.utf8)
        try bytes.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.baseAddress else { throw LocalCredentialError.invalidKey }
            var offset = 0
            while offset < rawBytes.count {
                let written = Darwin.write(file, base.advanced(by: offset), rawBytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw LocalCredentialError.unavailable }
                offset += written
            }
        }
        guard fsync(file) == 0 else { throw LocalCredentialError.unavailable }
        try validateFile(file)
        try validateDirectory(directory, privateStore: true)
        try validateEntry(directory: directory, name: temporary, descriptor: file)
        try checkDestination(directory: directory, name: name)
        guard renameat(directory, temporary, directory, name) == 0 else { throw LocalCredentialError.unavailable }
        renamed = true
        guard fsync(directory) == 0 else { throw LocalCredentialError.unavailable }
    }

    func delete(for provider: ProviderService) throws {
        guard let directory = try openDirectory(create: false) else { return }
        defer { close(directory) }
        let name = filename(provider)
        // Invalid contents can be removed, but unsafe ownership, links and permissions cannot.
        guard let file = try openKey(in: directory, name: name, permitInvalidSize: true) else { return }
        defer { close(file) }
        try validateEntry(directory: directory, name: name, descriptor: file)
        guard unlinkat(directory, name, 0) == 0 else { throw LocalCredentialError.unavailable }
        guard fsync(directory) == 0 else { throw LocalCredentialError.unavailable }
    }

    private func filename(_ provider: ProviderService) -> String { provider.rawValue + ".key" }
    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maximumKeyBytes && !key.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/"), !directoryURL.path.contains("\0") else {
            throw LocalCredentialError.unsafeStore
        }
        let components = directoryURL.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else { throw LocalCredentialError.unsafeStore }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw LocalCredentialError.unavailable }
        var transferred = false
        defer { if !transferred { close(directory) } }
        for (index, name) in components.enumerated() {
            var next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                guard create else { return nil }
                guard mkdirat(directory, name, mode_t(0o700)) == 0 || errno == EEXIST else { throw LocalCredentialError.unavailable }
                next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw LocalCredentialError.unsafeStore }
            do {
                try validateDirectory(next, privateStore: index == components.count - 1)
                try validateEntry(directory: directory, name: name, descriptor: next)
            } catch { close(next); throw error }
            close(directory); directory = next
        }
        transferred = true
        return directory
    }

    private func openKey(in directory: Int32, name: String, permitInvalidSize: Bool = false) throws -> Int32? {
        // NONBLOCK prevents a substituted FIFO from hanging before the regular-file check.
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw LocalCredentialError.unsafeStore }
        do {
            try validateFile(file, permitInvalidSize: permitInvalidSize)
            try validateEntry(directory: directory, name: name, descriptor: file)
            return file
        } catch { close(file); throw error }
    }

    private func checkDestination(directory: Int32, name: String) throws {
        if let existing = try openKey(in: directory, name: name, permitInvalidSize: true) { close(existing) }
    }

    private func validateFile(_ descriptor: Int32, permitEmpty: Bool = false, permitInvalidSize: Bool = false) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LocalCredentialError.unavailable }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o7777 == 0o600 else { throw LocalCredentialError.unsafeStore }
        try rejectACL(descriptor)
        if !permitInvalidSize {
            guard info.st_size >= (permitEmpty ? 0 : 1), info.st_size <= Self.maximumKeyBytes else { throw LocalCredentialError.corruptKey }
        }
    }

    private func validateDirectory(_ descriptor: Int32, privateStore: Bool) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LocalCredentialError.unavailable }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LocalCredentialError.unsafeStore }
        if privateStore {
            guard info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { throw LocalCredentialError.unsafeStore }
            try rejectACL(descriptor)
        } else {
            // Trusted system/user ancestors may be searchable, never writable by other users.
            // Root-owned sticky temporary directories are safe parents of private test/user folders.
            let stickySystemDirectory = info.st_uid == 0 && info.st_mode & S_ISVTX != 0
            guard (info.st_uid == 0 || info.st_uid == geteuid()),
                  info.st_mode & 0o022 == 0 || stickySystemDirectory else { throw LocalCredentialError.unsafeStore }
        }
    }

    private func validateEntry(directory: Int32, name: String, descriptor: Int32) throws {
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_mode & S_IFMT == named.st_mode & S_IFMT else { throw LocalCredentialError.unsafeStore }
    }

    private func rejectACL(_ descriptor: Int32) throws {
        // POSIX mode bits alone do not establish owner-only access when an extended ACL exists.
        // acl_get_fd_np reports ENOENT for an absent ACL on APFS. Query the security record
        // directly instead, requiring both supported extended security and successful retrieval.
        guard fpathconf(descriptor, _PC_EXTENDED_SECURITY_NP) == 1,
              let security = filesec_init() else { throw LocalCredentialError.unsafeStore }
        defer { filesec_free(security) }
        var info = stat(), present: Int32 = -1
        guard fstatx_np(descriptor, &info, security) == 0,
              filesec_query_property(security, FILESEC_ACL, &present) == 0,
              present == 0 else { throw LocalCredentialError.unsafeStore }
    }
}
