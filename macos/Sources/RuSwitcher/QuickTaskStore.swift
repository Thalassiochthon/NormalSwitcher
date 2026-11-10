import CryptoKit
import Foundation
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

struct QuickTaskStore {
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
            return []
        }
        let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(false))
        return try JSONDecoder().decode([QuickTask].self, from: decoded)
    }

    func save(_ tasks: [QuickTask]) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let sealed = try AES.GCM.seal(JSONEncoder().encode(tasks), using: key(true))
        guard let data = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: file, options: .atomic)
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
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
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
