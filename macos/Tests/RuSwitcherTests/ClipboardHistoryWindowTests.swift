import AppKit
import Testing
@testable import RuSwitcher

@Suite(.serialized) @MainActor
struct ClipboardHistoryWindowTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @Test func quickListCanAddExactTextAndSearchOlderEntries() throws {
        _ = NSApplication.shared
        let entries = (0..<30).map { "Entry \($0)\nFull text 👋" }
        var captured: String?
        var pasted: String?
        let controller = ClipboardHistoryWindow(entries: entries, storageFailed: false,
            emptyMessage: "Empty", onAddTask: { captured = $0 }, onRetry: {}, onClear: {}) { pasted = $0 }
        defer { controller.close() }
        let panel = try #require(controller.window)
        panel.layoutIfNeeded()
        let views = descendants(try #require(panel.contentView))
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        let search = try #require(views.compactMap { $0 as? NSSearchField }.first)
        #expect(table.numberOfRows == 8)
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        let add = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("addSelectedToTasks")
        })
        add.performClick(nil)
        #expect(captured == entries[4])
        #expect(pasted == nil)

        search.stringValue = "Entry 25"
        #expect(NSApp.sendAction(try #require(search.action), to: search.target, from: search))
        #expect(table.numberOfRows == 1)
        #expect(controller.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(pasted == entries[25])
        #expect(!panel.styleMask.contains(.resizable))
    }

    @Test func allEntriesToggleAndRefreshPreserveSelection() throws {
        _ = NSApplication.shared
        let entries = (0..<30).map { "Entry \($0)" }
        var captured: String?
        let controller = ClipboardHistoryWindow(entries: entries, storageFailed: false,
            emptyMessage: "Empty", onAddTask: { captured = $0 }, onRetry: {}, onClear: {}) { _ in }
        defer { controller.close() }
        let views = descendants(try #require(controller.window?.contentView))
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        let all = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("filterChanged")
        })
        all.performClick(nil)
        #expect(table.numberOfRows == 30)
        table.selectRowIndexes(IndexSet(integer: 20), byExtendingSelection: false)
        controller.update(entries: ["New"] + entries, storageFailed: true)
        let add = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("addSelectedToTasks")
        })
        add.performClick(nil)
        #expect(captured == entries[20])
        all.performClick(nil)
        #expect(table.numberOfRows == 8)
    }

    @Test func taskSettingsExposeBothShortcutsAndOpenAction() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController()
        var opened = false
        controller.onOpenTasks = { opened = true }
        let window = controller.makeWindow()
        defer { window.close() }
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        tabs.selectedTabViewItemIndex = 3
        window.layoutIfNeeded()
        let clipboard = try #require(tabs.tabViewItems[3].viewController?.view)
        let buttons = descendants(clipboard).compactMap { $0 as? NSButton }
        let enabled = buttons.filter { $0.action == NSSelectorFromString("taskShortcutEnabledChanged:") }
        let record = buttons.filter { $0.action == NSSelectorFromString("recordTaskShortcut:") }
        #expect(enabled.count == 2)
        #expect(record.count == 2)
        let open = try #require(buttons.first { $0.action == NSSelectorFromString("openTasksFromSettings") })
        open.performClick(nil)
        #expect(opened)
        #expect(!window.styleMask.contains(.resizable))
    }
}
