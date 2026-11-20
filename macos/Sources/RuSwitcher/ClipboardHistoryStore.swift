import CryptoKit
import Foundation

// Keep text entries in their existing string format, including in legacy plaintext histories.
private enum ClipboardRecord: Codable, Hashable {
    case text(String)
    case image(String)

    private enum CodingKeys: String, CodingKey { case image }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .text(text)
        } else {
            let id = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .image)
            guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self = .image(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var output = encoder.singleValueContainer()
            try output.encode(text)
        case .image(let id):
            var output = encoder.container(keyedBy: CodingKeys.self)
            try output.encode(id, forKey: .image)
        }
    }
}

final class ClipboardHistoryStore {
    static let limit = 30
    static let maxTextBytes = 32 * 1024
    static let defaultImageLimit = 10
    static let maxImageLimit = 50
    private let storage: EncryptedFileStore<[ClipboardRecord]>
    private let legacy: URL
    private let images: URL
    private let key: (Bool) throws -> SymmetricKey
    private var savedImages: Set<String> = []

    init(directory: URL = URL.applicationSupportDirectory
        .appendingPathComponent("NormalSwitcher/ClipboardHistory", isDirectory: true),
         key: @escaping (Bool) throws -> SymmetricKey = {
             try LocalEncryptionKey.read(service: "com.antonjas.normalswitcher.clipboard", create: $0)
         }) {
        self.key = key
        storage = EncryptedFileStore(file: directory.appendingPathComponent("entries.aesgcm"), key: key)
        legacy = directory.appendingPathComponent("entries.json")
        images = directory.appendingPathComponent("Images", isDirectory: true)
    }

    func load() throws -> [ClipboardEntry] {
        try storage.withLock {
            let records = try storage.loadLocked(migrating: legacy) { current, old in
                var seen = Set<ClipboardRecord>()
                return ((current ?? []) + old).filter { seen.insert($0).inserted }
            } ?? []
            var ids = Set<String>()
            let entries: [ClipboardEntry] = try records.map { record in
                switch record {
                case .text(let text): return .text(text)
                case .image(let id):
                    let sealed = try Data(contentsOf: images.appendingPathComponent(id))
                    let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key(false))
                    guard let image = ClipboardImage(bytes), image.id == id else { throw CocoaError(.fileReadCorruptFile) }
                    ids.insert(id)
                    return .image(image)
                }
            }
            try pruneImages(keeping: ids)
            savedImages = ids
            return entries
        }
    }

    func save(_ entries: [ClipboardEntry]) throws {
        try storage.withLock {
            var ids = Set<String>()
            var additions: [ClipboardImage] = []
            let records: [ClipboardRecord] = entries.map {
                switch $0 {
                case .text(let text): return .text(text)
                case .image(let image):
                    if ids.insert(image.id).inserted, !savedImages.contains(image.id) { additions.append(image) }
                    return .image(image.id)
                }
            }
            // Only create payloads after checking the index snapshot under the writer lock.
            try storage.saveLocked(records) {
                guard !additions.isEmpty else { return }
                try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let encryptionKey = try key(true)
                for image in additions {
                    let sealed = try AES.GCM.seal(image.bytes, using: encryptionKey)
                    guard let data = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: images.appendingPathComponent(image.id), options: .atomic)
                }
            }
            if ids != savedImages { try pruneImages(keeping: ids) }
            savedImages = ids
        }
    }

    private func pruneImages(keeping ids: Set<String>) throws {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        for file in files where !ids.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
    }

    func remove() throws {
        try storage.remove(including: legacy) { try pruneImages(keeping: []) }
        savedImages = []
    }

    static func normalized(_ entries: [ClipboardEntry], imageLimit: Int,
                           byteLimit: Int = ClipboardImage.totalBytes) -> [ClipboardEntry] {
        var seen = Set<ClipboardEntry>()
        var texts = 0, images = 0, bytes = 0
        var result: [ClipboardEntry] = []
        var imageBudgetFull = false
        for entry in entries where seen.insert(entry).inserted {
            switch entry {
            case .text(let text):
                guard texts < limit, !text.isEmpty, text.utf8.count <= maxTextBytes else { continue }
                texts += 1
            case .image(let image):
                guard !imageBudgetFull, images < imageLimit else { continue }
                if image.bytes.count > byteLimit - bytes {
                    imageBudgetFull = true
                    continue
                }
                images += 1
                bytes += image.bytes.count
            }
            result.append(entry)
        }
        return result
    }
}

final class ClipboardHistoryModel {
    private let store: ClipboardHistoryStore
    private var pending: [ClipboardEntry] = []
    private var persistent = false
    private var imageLimit = ClipboardHistoryStore.defaultImageLimit
    private(set) var entries: [ClipboardEntry] = []
    private(set) var storageFailed = false

    init(store: ClipboardHistoryStore = ClipboardHistoryStore()) { self.store = store }

    @discardableResult
    func setImageLimit(_ value: Int) -> Bool {
        imageLimit = min(max(value, 0), ClipboardHistoryStore.maxImageLimit)
        let trimmed = normalized(entries)
        pending = normalized(pending)
        if trimmed != entries {
            entries = trimmed
            if persistent && !storageFailed { saveEntries() }
        }
        return !storageFailed
    }

    private func normalized(_ input: [ClipboardEntry]) -> [ClipboardEntry] {
        ClipboardHistoryStore.normalized(input, imageLimit: imageLimit)
    }

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

    @discardableResult
    func capture(_ entry: ClipboardEntry) -> Bool {
        guard entries.first != entry else { return false }
        let updated = normalized([entry] + entries)
        guard updated != entries else { return false }
        entries = updated
        if persistent {
            pending = normalized([entry] + pending)
            if !storageFailed { saveEntries() }
        }
        return true
    }

    private func saveEntries() {
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
            let merged = normalized(pending + saved)
            if merged != saved { try store.save(merged) }
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

// Every model access, including image conversion, encryption and disk I/O, is serialized.
final class ClipboardHistoryWorker: @unchecked Sendable {
    enum Input: Sendable {
        case text(String)
        case image(Data)
    }
    struct State: Sendable {
        let entries: [ClipboardEntry]
        let storageFailed: Bool
        let revision: UInt64
    }
    private let queue = DispatchQueue(label: "com.antonjas.normalswitcher.clipboard-storage", qos: .utility)
    private let model = ClipboardHistoryModel()
    private var revision: UInt64 = 0

    private func snapshot() -> State {
        revision += 1
        return State(entries: model.entries, storageFailed: model.storageFailed, revision: revision)
    }

    func change(_ update: (ClipboardHistoryModel) -> Void) -> State {
        queue.sync { update(model); return snapshot() }
    }

    func restore(imageLimit: Int, persistent: Bool, complete: @escaping @MainActor @Sendable (State) -> Void) {
        queue.async {
            self.model.setImageLimit(imageLimit)
            self.model.setPersistent(persistent)
            let state = self.snapshot()
            DispatchQueue.main.async { complete(state) }
        }
    }

    func capture(_ input: Input, complete: @escaping @MainActor @Sendable (State?) -> Void) {
        queue.async {
            let state: State? = autoreleasepool {
                let entry: ClipboardEntry
                switch input {
                case .text(let value): entry = .text(value)
                case .image(let bytes):
                    guard let image = ClipboardImage(bytes) else { return nil }
                    entry = .image(image)
                }
                return self.model.capture(entry) ? self.snapshot() : nil
            }
            DispatchQueue.main.async { complete(state) }
        }
    }
}
