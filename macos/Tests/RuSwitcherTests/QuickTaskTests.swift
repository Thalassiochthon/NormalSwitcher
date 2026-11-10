import CryptoKit
import Foundation
import Darwin
import Testing
@testable import RuSwitcher

@Suite @MainActor
struct QuickTaskTests {
    private func withStore(_ body: (URL, SymmetricKey, QuickTaskStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tasks.aesgcm")
        let key = SymmetricKey(size: .bits256)
        try body(url, key, QuickTaskStore(file: url) { _ in key })
    }

    @Test func encryptedRoundTripAndPrivatePermissions() throws {
        try withStore { url, key, store in
            #expect(try store.load().isEmpty)
            let task = QuickTask(text: "\n  \n  Купить кофе ☕️\nSecond line\n")
            #expect(task.title == "Купить кофе ☕️")
            try store.save([task])
            let raw = try Data(contentsOf: url)
            #expect(raw.range(of: Data("Купить кофе".utf8)) == nil)
            let reopened = QuickTaskStore(file: url) { _ in key }
            #expect(try reopened.load() == [task])
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }

    @Test func tamperedFileAndWrongKeyRemainUntouched() throws {
        try withStore { url, key, store in
            _ = try store.load()
            try store.save([QuickTask(text: "Original")])
            let raw = try Data(contentsOf: url)
            let wrong = QuickTaskStore(file: url) { _ in SymmetricKey(size: .bits256) }
            #expect(throws: (any Error).self) { try wrong.load() }
            #expect(try Data(contentsOf: url) == raw)
            var damaged = raw
            damaged[13] ^= 1
            try damaged.write(to: url)
            let reopened = QuickTaskStore(file: url) { _ in key }
            let model = QuickTasks(store: reopened)
            #expect(!model.add(QuickTask(text: "New")))
            #expect(model.errorMessage != nil)
            #expect(try Data(contentsOf: url) == damaged)
        }
    }

    @Test func lostKeyIsNotRegeneratedOnNextSave() throws {
        try withStore { url, key, store in
            _ = try store.load()
            try store.save([QuickTask(text: "Existing")])
            var missingKey = false
            var requests: [Bool] = []
            let reopened = QuickTaskStore(file: url) { create in
                requests.append(create)
                if missingKey { throw CocoaError(.fileReadNoPermission) }
                return key
            }
            let model = QuickTasks(store: reopened)
            model.reload()
            let original = try Data(contentsOf: url)
            missingKey = true
            #expect(!model.add(QuickTask(text: "Not saved")))
            #expect(requests == [false, false])
            #expect(model.tasks.count == 1)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func anotherCopyCannotOverwriteNewerTasks() throws {
        try withStore { url, key, store in
            let first = QuickTasks(store: store)
            let second = QuickTasks(store: QuickTaskStore(file: url) { _ in key })
            first.reload()
            second.reload()
            let task = QuickTask(text: "First")
            #expect(first.add(task))
            #expect(!second.add(QuickTask(text: "Second")))
            #expect(second.errorMessage != nil)
            second.reload()
            #expect(second.tasks == [task])
            #expect(second.add(QuickTask(text: "Second")))
            let persisted = try QuickTaskStore(file: url, key: { _ in key }).load()
            #expect(persisted.count == 2)
        }
    }

    @Test func staleEditorCannotResurrectDeletedTask() throws {
        try withStore { _, _, store in
            let model = QuickTasks(store: store)
            var task = QuickTask(text: "Original")
            #expect(model.add(task))
            #expect(model.delete(task.id))
            task.text = "Edited before Undo"
            #expect(!model.edit(task))
            #expect(model.tasks.isEmpty)
            #expect(model.errorMessage != nil)
        }
    }

    @Test func editingPreservesLatestCompletionAndOtherTasks() throws {
        try withStore { _, _, store in
            let model = QuickTasks(store: store)
            var draft = QuickTask(text: "Original")
            #expect(model.add(draft))
            #expect(model.setCompleted(draft.id, to: true))
            let another = QuickTask(text: "Another")
            #expect(model.add(another))
            draft.title = "Renamed"
            #expect(model.edit(draft))
            #expect(model.tasks.first { $0.id == draft.id }?.completed == true)
            #expect(model.tasks.contains(another))
        }
    }

    @Test func failedWriteKeepsMemoryAndCanBeRetried() throws {
        try withStore { url, _, store in
            let model = QuickTasks(store: store)
            let initial = QuickTask(text: "Saved")
            #expect(model.add(initial))
            let lock = url.appendingPathExtension("lock")
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            let next = QuickTask(text: "Retry me")
            #expect(!model.add(next))
            #expect(model.tasks == [initial])
            try FileManager.default.removeItem(at: lock)
            #expect(model.add(next))
            #expect(model.errorMessage == nil)
            #expect(model.tasks == [next, initial])
        }
    }
    @Test func busyWriterFailsWithoutBlockingInput() throws {
        try withStore { url, _, store in
            let model = QuickTasks(store: store)
            let initial = QuickTask(text: "Saved")
            #expect(model.add(initial))
            let descriptor = open(url.appendingPathExtension("lock").path, O_RDWR)
            #expect(descriptor >= 0)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            defer { flock(descriptor, LOCK_UN) }
            #expect(!model.add(QuickTask(text: "Busy")))
            #expect(model.tasks == [initial])
            #expect(model.errorMessage != nil)
        }
    }

}
