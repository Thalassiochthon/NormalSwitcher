import CryptoKit
import Foundation

struct QuickTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var completed = false

    var detailPreview: String {
        let lines = text.prefix(512).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let detail = lines.first == title ? lines.dropFirst().joined(separator: " ") : lines.joined(separator: " ")
        return String(detail.prefix(160))
    }

    init(text: String) {
        self.text = text
        let firstLine = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        title = String(firstLine.prefix(120))
    }
}

typealias QuickTaskStoreError = EncryptedStoreError

final class QuickTaskStore {
    private let storage: EncryptedFileStore<[QuickTask]>

    init(file: URL = URL.applicationSupportDirectory
        .appendingPathComponent("NormalSwitcher/Tasks", isDirectory: true)
        .appendingPathComponent("tasks.aesgcm"),
         key: @escaping (Bool) throws -> SymmetricKey = {
             try LocalEncryptionKey.read(service: "com.antonjas.normalswitcher.tasks", create: $0)
         }) {
        storage = EncryptedFileStore(file: file, key: key)
    }

    func load() throws -> [QuickTask] {
        let tasks = try storage.load() ?? []
        guard Set(tasks.map(\.id)).count == tasks.count else { throw CocoaError(.coderReadCorrupt) }
        return tasks
    }

    func save(_ tasks: [QuickTask]) throws { try storage.save(tasks) }
}
