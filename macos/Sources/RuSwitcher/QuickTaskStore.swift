import CryptoKit
import Foundation
import Darwin
import Security

struct QuickTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var completed = false

    init(text: String) {
        self.text = text
        let firstLine = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        title = String(firstLine.prefix(120))
    }
}

enum QuickTaskStoreError: Error {
    case changedOnDisk
}

final class QuickTaskStore {
    // Compare the file under an exclusive lock before every write. Two running
    // copies must not overwrite each other's tasks from an older in-memory list.
    private var snapshot: Data?

    private let file: URL
    private let key: (Bool) throws -> SymmetricKey

    init(file: URL = URL.applicationSupportDirectory
        .appendingPathComponent("NormalSwitcher/Tasks", isDirectory: true)
        .appendingPathComponent("tasks.aesgcm"),
         key: @escaping (Bool) throws -> SymmetricKey = QuickTaskStore.keychainKey) {
        self.file = file
        self.key = key
    }

    func load() throws -> [QuickTask] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            snapshot = nil
            return []
        }
        let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(false))
        let tasks = try JSONDecoder().decode([QuickTask].self, from: decoded)
        guard Set(tasks.map(\.id)).count == tasks.count else { throw CocoaError(.coderReadCorrupt) }
        snapshot = data
        return tasks
    }

    func save(_ tasks: [QuickTask]) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lock = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(lock, LOCK_UN) }

        let current: Data?
        do {
            current = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            current = nil
        }
        guard current == snapshot else { throw QuickTaskStoreError.changedOnDisk }
        // A missing key for an existing file is a recoverable access error.
        // Never silently rotate that key and overwrite the encrypted data.
        let sealed = try AES.GCM.seal(JSONEncoder().encode(tasks), using: key(current == nil))
        guard let data = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        snapshot = data
    }

    private static func keychainKey(create: Bool) throws -> SymmetricKey {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.antonjas.normalswitcher.tasks",
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
        if added == errSecDuplicateItem { return try keychainKey(create: false) }
        guard added == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
        }
        return key
    }
}
