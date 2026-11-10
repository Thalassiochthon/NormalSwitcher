import CryptoKit
import Darwin
import Foundation
import Security

enum EncryptedStoreError: Error { case changedOnDisk, notLoaded }

/// AES-GCM files share write/locking rules; each feature keeps its own Keychain key.
final class EncryptedFileStore<Value: Codable> {
    private let file: URL
    private let key: (Bool) throws -> SymmetricKey
    private var snapshot: Data?
    private var loaded = false

    init(file: URL, key: @escaping (Bool) throws -> SymmetricKey) {
        self.file = file
        self.key = key
    }

    func load() throws -> Value? {
        loaded = false
        let data = try readIfPresent(file)
        let value = try data.map(decode)
        snapshot = data
        loaded = true
        return value
    }

    /// Migration holds the same lock as ordinary writes. The source is removed
    /// only after the new ciphertext has been read back and authenticated.
    func load(migrating legacy: URL, merge: (Value?, Value) -> Value) throws -> Value? {
        do {
            return try withLock {
                let current = try load()
                guard let original = try readIfPresent(legacy) else { return current }
                let old = try JSONDecoder().decode(Value.self, from: original)
                let merged = merge(current, old)
                try saveLocked(merged)
                let written = try Data(contentsOf: file)
                _ = try decode(written)
                guard written == snapshot, try readIfPresent(legacy) == original else {
                    throw EncryptedStoreError.changedOnDisk
                }
                try FileManager.default.removeItem(at: legacy)
                return merged
            }
        } catch {
            loaded = false
            throw error
        }
    }

    func save(_ value: Value) throws {
        try withLock { try saveLocked(value) }
    }

    /// Explicitly clearing/disabling clipboard persistence also works when its
    /// key is unavailable. Tasks never use this operation.
    func remove(including legacy: URL) throws {
        try withLock {
            // Legacy first: on failure keep the authoritative encrypted copy.
            try removeIfPresent(legacy)
            try removeIfPresent(file)
            snapshot = nil
            loaded = true
        }
    }

    private func saveLocked(_ value: Value) throws {
        guard loaded else { throw EncryptedStoreError.notLoaded }
        let current = try readIfPresent(file)
        guard current == snapshot else { throw EncryptedStoreError.changedOnDisk }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(value), using: key(current == nil))
        guard let data = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        snapshot = data
    }

    private func decode(_ data: Data) throws -> Value {
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(false))
        return try JSONDecoder().decode(Value.self, from: plaintext)
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

enum LocalEncryptionKey {
    static func read(service: String, create: Bool) throws -> SymmetricKey {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "encryption-key",
        ]
        var query = identity
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 {
            return SymmetricKey(data: bytes)
        }
        guard status == errSecItemNotFound, create else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status == errSecSuccess ? errSecDecode : status))
        }
        let key = SymmetricKey(size: .bits256)
        var attributes = identity
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem { return try read(service: service, create: false) }
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }
}
