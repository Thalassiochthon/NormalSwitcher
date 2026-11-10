import AppKit

@MainActor
final class ClipboardHistoryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var entries: [String]
    private let onAddTask: ((String) -> Void)?
    private let onPaste: (String) -> Void
    private var results: [String]
    private let search = NSSearchField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: L10n.clipboardHistoryNoMatches)
    private let pasteButton = NSButton(title: L10n.clipboardHistoryPaste, target: nil, action: nil)
    private let allButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let storageWarning = NSStackView()
    private let onRetry: () -> Void
    private let onClear: () -> Void
    private let emptyMessage: String

    private let taskButton = NSButton(title: taskText("Add to Tasks", "В задачи"), target: nil, action: nil)

    init(entries: [String], storageFailed: Bool, emptyMessage: String,
         onAddTask: ((String) -> Void)?, onRetry: @escaping () -> Void,
         onClear: @escaping () -> Void, onPaste: @escaping (String) -> Void) {
        self.entries = entries
        self.results = entries
        self.onPaste = onPaste
        self.onAddTask = onAddTask
        self.onRetry = onRetry
        self.onClear = onClear
        self.emptyMessage = emptyMessage
        let panel = ClipboardHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = L10n.clipboardHistoryTitle
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            panel.setFrameOrigin(NSPoint(x: max(bounds.minX, min(point.x, bounds.maxX - panel.frame.width)),
                                         y: max(bounds.minY, min(point.y - panel.frame.height, bounds.maxY - panel.frame.height))))
        }

        search.placeholderString = L10n.clipboardHistorySearch
        search.setAccessibilityLabel(L10n.clipboardHistorySearch)
        search.delegate = self
        search.target = self
        search.action = #selector(filterChanged)
        search.sendsSearchStringImmediately = true
        panel.initialFirstResponder = search

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipboard"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 25
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(pasteDoubleClick)
        table.setAccessibilityLabel(L10n.clipboardHistoryTitle)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        pasteButton.target = self
        pasteButton.action = #selector(pasteSelected)
        pasteButton.keyEquivalent = "\r"
        taskButton.target = self
        taskButton.action = #selector(addSelectedToTasks)
        taskButton.isHidden = onAddTask == nil
        let clearButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L10n.clipboardHistoryClear)!,
                                   target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .texturedRounded
        clearButton.toolTip = L10n.clipboardHistoryClear
        let actions = NSStackView(views: [clearButton, NSView(), taskButton, pasteButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        allButton.title = taskText("All entries", "Все записи")
        allButton.target = self
        allButton.action = #selector(filterChanged)
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let summary = NSStackView(views: [countLabel, NSView(), allButton])
        summary.orientation = .horizontal
        let warning = NSTextField(wrappingLabelWithString: taskText(
            "History storage is unavailable. New copies stay in memory until you quit.",
            "Хранилище истории недоступно. Новые записи останутся в памяти до выхода."))
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.textColor = .systemRed
        let retry = NSButton(title: taskText("Retry", "Повторить"), target: self, action: #selector(retryStorage))
        storageWarning.addArrangedSubview(warning)
        storageWarning.addArrangedSubview(retry)
        storageWarning.orientation = .horizontal
        storageWarning.spacing = 8
        storageWarning.isHidden = !storageFailed
        let stack = NSStackView(views: [search, summary, storageWarning, scroll, emptyLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            storageWarning.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        filterChanged()
    }

    required init?(coder: NSCoder) { nil }

    func update(entries: [String], storageFailed: Bool) {
        self.entries = entries
        storageWarning.isHidden = !storageFailed
        filterChanged()
    }

    @objc private func retryStorage() { onRetry() }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = L10n.clipboardHistoryClear + "?"
        alert.informativeText = taskText("Saved tasks will remain.", "Сохранённые задачи останутся.")
        alert.addButton(withTitle: taskText("Clear", "Очистить"))
        alert.addButton(withTitle: L10n.commonCancel)
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onClear() }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let label = NSTextField(labelWithString: ClipboardHistory.preview(results[row], limit: 120))
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            pasteSelected()
            return true
        }
        if selector == #selector(NSResponder.moveDown(_:)), !results.isEmpty {
            window?.makeFirstResponder(table)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), search.stringValue.isEmpty {
            close()
            return true
        }
        return false
    }

    @objc private func filterChanged() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
        results = query.isEmpty ? (allButton.state == .on ? entries : Array(entries.prefix(8))) :
            entries.filter { $0.localizedStandardContains(query) }
        countLabel.stringValue = taskText("Showing \(results.count) of \(entries.count)",
                                          "Показано \(results.count) из \(entries.count)")
        allButton.isHidden = entries.count <= 8
        emptyLabel.stringValue = query.isEmpty ? emptyMessage : L10n.clipboardHistoryNoMatches
        table.reloadData()
        emptyLabel.isHidden = !results.isEmpty || !storageWarning.isHidden
        if !results.isEmpty {
            let index = selected.flatMap { results.firstIndex(of: $0) } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        updateActions()
    }

    private func updateActions() {
        let row = table.selectedRow
        pasteButton.isEnabled = results.indices.contains(row)
        taskButton.isEnabled = pasteButton.isEnabled && !results[row].allSatisfy(\.isWhitespace)
    }

    @objc private func addSelectedToTasks() {
        let row = table.selectedRow
        if results.indices.contains(row) { onAddTask?(results[row]) }
    }

    @objc private func pasteDoubleClick() {
        if table.clickedRow >= 0 { pasteSelected() }
    }

    @objc private func pasteSelected() {
        let row = table.selectedRow
        guard results.indices.contains(row) else { return }
        let text = results[row]
        close()
        onPaste(text)
    }
}


private final class ClipboardHistoryPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
