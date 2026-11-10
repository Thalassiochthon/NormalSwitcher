import CryptoKit
import Darwin
import Foundation
import Testing
@testable import RuSwitcher

@Suite @MainActor
struct ClipboardHistoryTests {
    private func withStore(_ body: (URL, SymmetricKey, ClipboardHistoryStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        try body(directory, key, ClipboardHistoryStore(directory: directory) { _ in key })
    }

    @Test func legacyHistoryIsEncryptedAndSurvivesRestart() throws {
        try withStore { (directory, key, store) throws in
            let legacy = directory.appendingPathComponent("entries.json")
            let entries = ["Привет 👋\nSecond line", "https://example.test"]
            try JSONEncoder().encode(entries).write(to: legacy)
            #expect(try store.load() == entries)
            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            let file = directory.appendingPathComponent("entries.aesgcm")
            let encrypted = try Data(contentsOf: file)
            #expect(encrypted.range(of: Data("Привет".utf8)) == nil)
            #expect(try ClipboardHistoryStore(directory: directory, key: { _ in key }).load() == entries)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
    }

    @Test func corruptedLegacyIsNotReplacedByNewCopies() throws {
        try withStore { (directory, _, store) throws in
            let legacy = directory.appendingPathComponent("entries.json")
            let damaged = Data("broken JSON".utf8)
            try damaged.write(to: legacy)
            let model = ClipboardHistoryModel(store: store)
            #expect(!model.setPersistent(true))
            model.capture("Copied after failure")
            #expect(model.entries == ["Copied after failure"])
            #expect(model.storageFailed)
            #expect(try Data(contentsOf: legacy) == damaged)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("entries.aesgcm").path))
            // Once the source is recovered, pending copies are merged on retry.
            try JSONEncoder().encode(["Recovered old entry"]).write(to: legacy)
            #expect(model.retry())
            #expect(model.entries == ["Copied after failure", "Recovered old entry"])
        }
    }

    @Test func deniedKeyDoesNotPromptOnEveryCopyAndCanRetry() throws {
        try withStore { (directory, key, _) throws in
            let legacy = directory.appendingPathComponent("entries.json")
            let original = try JSONEncoder().encode(["Saved"])
            try original.write(to: legacy)
            var denied = true
            var requests = 0
            let model = ClipboardHistoryModel(store: ClipboardHistoryStore(directory: directory) { _ in
                requests += 1
                if denied { throw CocoaError(.fileReadNoPermission) }
                return key
            })
            #expect(!model.setPersistent(true))
            let firstRequests = requests
            model.capture("One")
            model.capture("Two")
            #expect(requests == firstRequests)
            #expect(try Data(contentsOf: legacy) == original)
            denied = false
            #expect(model.retry())
            #expect(model.entries == ["Two", "One", "Saved"])
            #expect(!model.storageFailed)
        }
    }

    @Test func failedReadbackPreservesMigrationSource() throws {
        try withStore { (directory, key, _) throws in
            let legacy = directory.appendingPathComponent("entries.json")
            let original = try JSONEncoder().encode(["Keep me until verified"])
            try original.write(to: legacy)
            var readable = false
            let store = ClipboardHistoryStore(directory: directory) { create in
                if !create && !readable { throw CocoaError(.fileReadNoPermission) }
                return key
            }
            #expect(throws: (any Error).self) { try store.load() }
            #expect(try Data(contentsOf: legacy) == original)
            readable = true
            #expect(try store.load() == ["Keep me until verified"])
            #expect(!FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    @Test func interruptedMigrationMergesWithoutDuplicates() throws {
        try withStore { (directory, key, store) throws in
            _ = try store.load()
            try store.save(["Newer", "Shared"])
            let legacy = directory.appendingPathComponent("entries.json")
            try JSONEncoder().encode(["Shared", "Older"]).write(to: legacy)
            #expect(try ClipboardHistoryStore(directory: directory, key: { _ in key }).load() == ["Newer", "Shared", "Older"])
            #expect(!FileManager.default.fileExists(atPath: legacy.path))
        }
    }

    @Test func changedLegacyDuringMigrationIsPreserved() throws {
        try withStore { (directory, key, _) throws in
            let legacy = directory.appendingPathComponent("entries.json")
            try JSONEncoder().encode(["Old"]).write(to: legacy)
            var changed = false
            let store = ClipboardHistoryStore(directory: directory) { create in
                if !create && !changed {
                    changed = true
                    try JSONEncoder().encode(["From older running app", "Old"]).write(to: legacy)
                }
                return key
            }
            #expect(throws: (any Error).self) { try store.load() }
            let retained = try JSONDecoder().decode([String].self, from: Data(contentsOf: legacy))
            #expect(retained.contains("From older running app"))
            let restored = try store.load()
            #expect(restored.contains("From older running app"))
            #expect(restored.contains("Old"))
        }
    }

    @Test func corruptCiphertextIsNeverOverwritten() throws {
        try withStore { (directory, _, store) throws in
            _ = try store.load()
            try store.save(["Original"])
            let file = directory.appendingPathComponent("entries.aesgcm")
            var damaged = try Data(contentsOf: file)
            damaged[15] ^= 1
            try damaged.write(to: file)
            let model = ClipboardHistoryModel(store: store)
            #expect(!model.setPersistent(true))
            model.capture("New")
            #expect(!model.retry())
            #expect(try Data(contentsOf: file) == damaged)
        }
    }

    @Test func anotherWriterIsMergedOnlyOnExplicitRetry() throws {
        try withStore { (directory, key, store) throws in
            let first = ClipboardHistoryModel(store: store)
            let second = ClipboardHistoryModel(store: ClipboardHistoryStore(directory: directory) { _ in key })
            #expect(first.setPersistent(true))
            #expect(second.setPersistent(true))
            first.capture("From first")
            second.capture("From second")
            #expect(second.storageFailed)
            #expect(try store.load() == ["From first"])
            #expect(second.retry())
            #expect(second.entries == ["From second", "From first"])
            #expect(try store.load() == second.entries)
        }
    }

    @Test func failedClearKeepsVisibleHistoryAndTasks() throws {
        try withStore { (directory, key, store) throws in
            let model = ClipboardHistoryModel(store: store)
            #expect(model.setPersistent(true))
            model.capture("History")
            let tasks = QuickTaskStore(file: directory.appendingPathComponent("tasks.aesgcm")) { _ in key }
            _ = try tasks.load()
            let task = QuickTask(text: "Task")
            try tasks.save([task])
            let lock = directory.appendingPathComponent("entries.aesgcm.lock")
            let descriptor = open(lock.path, O_RDWR)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            #expect(!model.clear())
            #expect(model.entries == ["History"])
            flock(descriptor, LOCK_UN)
            #expect(try store.load() == ["History"])
            #expect(model.clear())
            #expect(model.entries.isEmpty)
            #expect(try store.load().isEmpty)
            #expect(try tasks.load() == [task])
        }
    }

    @Test func disablingPersistenceRetainsSessionEntries() throws {
        try withStore { (directory, _, store) throws in
            let model = ClipboardHistoryModel(store: store)
            #expect(model.setPersistent(true))
            model.capture("Session")
            #expect(model.setPersistent(false))
            #expect(model.entries == ["Session"])
            #expect(try store.load().isEmpty)
            model.capture("Memory only")
            #expect(try store.load().isEmpty)
            #expect(model.setPersistent(true))
            #expect(try store.load() == ["Memory only", "Session"])
        }
    }

    @Test func boundedDeduplicatedUnicodeHistory() throws {
        try withStore { (_, _, store) throws in
            let model = ClipboardHistoryModel(store: store)
            #expect(model.setPersistent(true))
            for index in 0..<40 { model.capture("Entry \(index)") }
            model.capture("Entry 20")
            model.capture(String(repeating: "😀", count: 9000))
            model.capture("")
            #expect(model.entries.count == 30)
            #expect(Set(model.entries).count == 30)
            #expect(model.entries.first == "Entry 20")
            #expect(try store.load() == model.entries)
        }
    }
}
