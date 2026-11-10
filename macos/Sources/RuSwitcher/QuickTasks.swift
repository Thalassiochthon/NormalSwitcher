import AppKit
import Carbon
import SwiftUI

enum TaskShortcut: UInt32, CaseIterable {
    case open = 1, capture

    var label: String {
        switch self {
        case .open: taskText("Open Tasks", "Открыть задачи")
        case .capture: taskText("Add Clipboard to Tasks", "Добавить текст из буфера в задачи")
        }
    }

    var standard: ClipboardHistoryShortcut {
        switch self {
        case .open: .init(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | shiftKey), key: "T")
        case .capture: .init(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey | shiftKey), key: "V")
        }
    }

    private var preferenceKey: String { "com.antonjas.normalswitcher.tasks.shortcut.\(rawValue)" }

    var shortcut: ClipboardHistoryShortcut {
        guard let data = UserDefaults.standard.data(forKey: preferenceKey),
              let saved = try? JSONDecoder().decode(ClipboardHistoryShortcut.self, from: data) else { return standard }
        return saved
    }

    func save(_ shortcut: ClipboardHistoryShortcut) {
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: preferenceKey)
    }
}

func taskText(_ english: String, _ russian: String) -> String {
    L10n.languageCode == "ru" ? russian : english
}

@MainActor
final class QuickTasks: ObservableObject {
    private static let signature: OSType = 0x4E53544B // NSTK
    private let store: QuickTaskStore
    private var loaded = false
    private var panel: NSPanel?
    private var notice: NSPanel?
    private var dismissNotice: DispatchWorkItem?
    private var handler: EventHandlerRef?
    private var hotkeys: [TaskShortcut: EventHotKeyRef] = [:]
    var readClipboard: (() -> String?)?
    @Published private(set) var tasks: [QuickTask] = []
    @Published private(set) var errorMessage: String?

    init(store: QuickTaskStore = QuickTaskStore()) {
        self.store = store
    }

    func start() {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            return MainActor.assumeIsolated {
                guard status == noErr, id.signature == QuickTasks.signature,
                      let action = TaskShortcut(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
                let tasks = Unmanaged<QuickTasks>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    switch action {
                    case .open: tasks.show()
                    case .capture: tasks.capture()
                    }
                }
                return noErr
            }
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return }
        for action in TaskShortcut.allCases { _ = register(action, shortcut: action.shortcut) }
    }

    func stop() {
        dismissNotice?.cancel()
        notice?.orderOut(nil)
        panel?.close()
        for hotkey in hotkeys.values { UnregisterEventHotKey(hotkey) }
        hotkeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func changeShortcut(_ action: TaskShortcut, to shortcut: ClipboardHistoryShortcut) -> Bool {
        // Leave standard macOS editing and application shortcuts available.
        let modifiers = shortcut.menuModifierFlags
        guard modifiers.contains(.control) || modifiers.contains(.option) else { return false }
        if shortcut.keyCode == action.shortcut.keyCode, shortcut.modifiers == action.shortcut.modifiers,
           hotkeys[action] != nil { return true }
        if let old = hotkeys.removeValue(forKey: action) { UnregisterEventHotKey(old) }
        guard register(action, shortcut: shortcut) else {
            _ = register(action, shortcut: action.shortcut)
            return false
        }
        action.save(shortcut)
        return true
    }

    private func register(_ action: TaskShortcut, shortcut: ClipboardHistoryShortcut) -> Bool {
        guard handler != nil else { return false }
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        var ref: EventHotKeyRef?
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(),
                                  UInt32(kEventHotKeyExclusive), &ref) == noErr, let ref else { return false }
        hotkeys[action] = ref
        return true
    }

    func isAvailable(_ action: TaskShortcut) -> Bool { hotkeys[action] != nil }

    func show() {
        guard NSApp.modalWindow == nil else { return }
        _ = loadIfNeeded()
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.center()
            panel = window
        }
        guard let panel else { return }
        if !panel.isVisible {
            panel.title = taskText("Tasks", "Задачи")
            panel.contentView = NSHostingView(rootView: QuickTaskList(model: self).frame(width: 480, height: 360))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func capture() {
        guard NSApp.modalWindow == nil else { return }
        guard let text = readClipboard?() else {
            notify(taskText("No available clipboard text", "В буфере нет доступного текста"))
            return
        }
        addFromClipboard(text)
    }

    func addFromClipboard(_ text: String) {
        let task = QuickTask(text: text)
        guard !task.title.isEmpty else {
            notify(taskText("No available clipboard text", "В буфере нет доступного текста"))
            return
        }
        if add(task) {
            notify(taskText("Added to tasks", "Добавлено в задачи")) { [weak self] in
                guard let self else { return }
                guard self.delete(task.id) else {
                    self.notify(taskText("Could not undo. Open Tasks to retry.", "Не удалось отменить. Откройте задачи и повторите."))
                    return
                }
                self.notify(taskText("Task removed", "Задача удалена"))
            }
        } else {
            notify(taskText("Could not save the task", "Не удалось сохранить задачу"))
        }
    }

    @discardableResult
    func add(_ task: QuickTask) -> Bool {
        guard loadIfNeeded(), !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tasks.contains(where: { $0.id == task.id }) else { return false }
        return save([task] + tasks)
    }

    @discardableResult
    func edit(_ draft: QuickTask) -> Bool {
        guard loadIfNeeded(), let index = existingIndex(draft.id) else { return false }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        var updated = tasks
        updated[index].title = title
        updated[index].text = draft.text
        return save(updated)
    }

    @discardableResult
    func setCompleted(_ id: UUID, to completed: Bool) -> Bool {
        guard loadIfNeeded(), let index = existingIndex(id) else { return false }
        var updated = tasks
        updated[index].completed = completed
        return save(updated)
    }

    private func existingIndex(_ id: UUID) -> Int? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            errorMessage = taskText("This task has been removed. Copy your text before closing.",
                                    "Эта задача удалена. Скопируйте текст перед закрытием.")
            return nil
        }
        return index
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard loadIfNeeded() else { return false }
        return save(tasks.filter { $0.id != id })
    }

    func reload() {
        loaded = false
        _ = loadIfNeeded()
    }

    private func loadIfNeeded() -> Bool {
        if loaded { return true }
        do {
            tasks = try store.load()
            loaded = true
            errorMessage = nil
            return true
        } catch {
            errorMessage = taskText("Could not read or save tasks. Check storage and Keychain access, then retry.",
                                    "Не удалось прочитать или сохранить задачи. Проверьте доступ к хранилищу и Связке ключей, затем повторите.")
            return false
        }
    }

    private func save(_ updated: [QuickTask]) -> Bool {
        do {
            try store.save(updated)
            tasks = updated
            errorMessage = nil
            return true
        } catch QuickTaskStoreError.changedOnDisk {
            errorMessage = taskText("Tasks changed in another copy of the app. Reload before saving.",
                                    "Задачи изменились в другой копии программы. Обновите список перед сохранением.")
            return false
        } catch {
            errorMessage = taskText("Could not read or save tasks. Check storage and Keychain access, then retry.",
                                    "Не удалось прочитать или сохранить задачи. Проверьте доступ к хранилищу и Связке ключей, затем повторите.")
            return false
        }
    }

    private func notify(_ message: String, undo: (() -> Void)? = nil) {
        dismissNotice?.cancel()
        notice?.orderOut(nil)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let rect = NSRect(x: frame.midX - 180, y: frame.minY + 30, width: 360, height: 48)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HStack {
            Text(message).accessibilityAddTraits(.updatesFrequently)
            if let undo { Button(taskText("Undo", "Отменить"), action: undo) }
        }
        .padding(10)
        .frame(width: 360, height: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)))
        notice = panel
        panel.orderFrontRegardless()
        let dismiss = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        dismissNotice = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + (undo == nil ? 3 : 6), execute: dismiss)
    }
}
