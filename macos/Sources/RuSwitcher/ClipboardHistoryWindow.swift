import AppKit

@MainActor
final class ClipboardHistoryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let entries: [String]
    private let onAddTask: ((String) -> Void)?
    private let onPaste: (String) -> Void
    private var results: [String]
    private let search = NSSearchField()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: L10n.clipboardHistoryNoMatches)
    private let pasteButton = NSButton(title: L10n.clipboardHistoryPaste, target: nil, action: nil)

    private let taskButton = NSButton(title: taskText("Add to Tasks", "В задачи"), target: nil, action: nil)

    init(entries: [String], onAddTask: ((String) -> Void)?, onPaste: @escaping (String) -> Void) {
        self.entries = entries
        self.results = entries
        self.onPaste = onPaste
        self.onAddTask = onAddTask
        let panel = ClipboardHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = L10n.clipboardHistoryTitle
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 260)
        panel.hidesOnDeactivate = false
        panel.center()

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
        let actions = NSStackView(views: [emptyLabel, NSView(), taskButton, pasteButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        let stack = NSStackView(views: [search, scroll, actions])
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
        ])
        filterChanged()
    }

    required init?(coder: NSCoder) { nil }

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
        results = query.isEmpty ? entries : entries.filter { $0.localizedStandardContains(query) }
        table.reloadData()
        emptyLabel.isHidden = !results.isEmpty
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
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
