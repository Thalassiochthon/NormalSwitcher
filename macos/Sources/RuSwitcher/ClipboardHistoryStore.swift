import CryptoKit
import Foundation

final class ClipboardHistoryStore {
    static let limit = 30
    static let maxTextBytes = 32 * 1024
    private let storage: EncryptedFileStore<[String]>
    private let legacy: URL

    init(directory: URL = URL.applicationSupportDirectory
        .appendingPathComponent("NormalSwitcher/ClipboardHistory", isDirectory: true),
         key: @escaping (Bool) throws -> SymmetricKey = {
             try LocalEncryptionKey.read(service: "com.antonjas.normalswitcher.clipboard", create: $0)
         }) {
        storage = EncryptedFileStore(file: directory.appendingPathComponent("entries.aesgcm"), key: key)
        legacy = directory.appendingPathComponent("entries.json")
    }

    func load() throws -> [String] {
        Self.normalized(try storage.load(migrating: legacy) { current, old in
            Self.normalized((current ?? []) + old)
        } ?? [])
    }

    func save(_ entries: [String]) throws { try storage.save(Self.normalized(entries)) }
    func remove() throws { try storage.remove(including: legacy) }

    static func normalized(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for text in entries where !text.isEmpty && text.utf8.count <= maxTextBytes {
            if seen.insert(text).inserted { result.append(text) }
            if result.count == limit { break }
        }
        return result
    }
}

/// Keep new clipboard entries in memory after a storage error. An explicit retry
/// reloads disk and merges only new entries, never an outdated full snapshot.
@MainActor
final class ClipboardHistoryModel {
    private let store: ClipboardHistoryStore
    private var pending: [String] = []
    private var persistent = false
    private(set) var entries: [String] = []
    private(set) var storageFailed = false

    init(store: ClipboardHistoryStore = ClipboardHistoryStore()) { self.store = store }

    @discardableResult
    func setPersistent(_ enabled: Bool) -> Bool {
        if enabled {
            if !persistent { pending = entries }
            persistent = true
            return retry()
        }
        persistent = false
        return removeSaved()
    }

    func capture(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= ClipboardHistoryStore.maxTextBytes,
              entries.first != text else { return }
        entries = ClipboardHistoryStore.normalized([text] + entries)
        guard persistent else { return }
        pending = ClipboardHistoryStore.normalized([text] + pending)
        // Do not prompt for Keychain access every 350 ms after denial/failure.
        guard !storageFailed else { return }
        do {
            try store.save(entries)
            pending.removeAll()
        } catch { storageFailed = true }
    }

    @discardableResult
    func retry() -> Bool {
        guard persistent else { return removeSaved() }
        do {
            let saved = try store.load()
            let merged = ClipboardHistoryStore.normalized(pending + saved)
            if !pending.isEmpty { try store.save(merged) }
            entries = merged
            pending.removeAll()
            storageFailed = false
            return true
        } catch {
            storageFailed = true
            return false
        }
    }

    @discardableResult
    func clear() -> Bool {
        guard removeSaved() else { return false }
        entries.removeAll()
        return true
    }

    private func removeSaved() -> Bool {
        do {
            try store.remove()
            pending.removeAll()
            storageFailed = false
            return true
        } catch {
            storageFailed = true
            return false
        }
    }
}
