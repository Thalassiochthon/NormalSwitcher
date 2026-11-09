import AppKit

/// Таблица автозамены (3.5.0b): «сокращение → текст», кнопки «+»/«−», двойной щелчок — правка.
/// Привязка к данным — замыканиями, как у ExceptionListEditor.
@MainActor
final class AbbreviationEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let getList: () -> [Abbreviation]
    private let setList: ([Abbreviation]) -> Void
    private var items: [Abbreviation] = []
    private let table = NSTableView()
    private let removeButton = NSButton()

    init(get: @escaping () -> [Abbreviation], set: @escaping ([Abbreviation]) -> Void) {
        getList = get
        setList = set
        super.init()
        items = get()
    }

    func makeContainer(frame: NSRect) -> NSView {
        let container = NSView(frame: frame)
        let stripH: CGFloat = 26
        let scroll = NSScrollView(frame: NSRect(x: 0, y: stripH, width: frame.width, height: frame.height - stripH))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        let shortCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("short"))
        shortCol.title = L10n.settingsAbbrShort
        shortCol.width = 110
        let fullCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("full"))
        fullCol.title = L10n.settingsAbbrFull
        fullCol.width = frame.width - 4 - 110 - 6
        table.addTableColumn(shortCol)
        table.addTableColumn(fullCol)
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editTapped)
        scroll.documentView = table
        container.addSubview(scroll)

        let addBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        addBtn.title = "+"
        addBtn.bezelStyle = .smallSquare
        addBtn.target = self
        addBtn.action = #selector(addTapped)
        container.addSubview(addBtn)

        removeButton.frame = NSRect(x: 30, y: 0, width: 28, height: 24)
        removeButton.title = "−"
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.isEnabled = false
        container.addSubview(removeButton)
        return container
    }

    /// Перечитать список (если окно открыто, а стор поменялся снаружи).
    func reload() {
        items = getList()
        table.reloadData()
        removeButton.isEnabled = table.selectedRow >= 0
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = items[row]
        let text = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "short" ? a.short : a.full)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    @objc private func addTapped() {
        guard let a = prompt(nil) else { return }
        items = getList()
        items.removeAll { $0.short.caseInsensitiveCompare(a.short) == .orderedSame }   // то же сокращение — заменяем
        items.append(a)
        persist()
    }

    @objc private func editTapped() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < items.count else { return }
        let old = items[row]
        guard let a = prompt(old) else { return }
        items = getList()
        if let i = items.firstIndex(of: old) { items[i] = a } else { items.append(a) }
        persist()
    }

    @objc private func removeTapped() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        let value = items[row]
        items = getList()
        items.removeAll { $0 == value }
        persist()
    }

    /// Диалог «сокращение + текст». nil — отмена или не прошло чистку (пусто, пробел в
    /// сокращении, слишком длинно).
    private func prompt(_ existing: Abbreviation?) -> Abbreviation? {
        let alert = NSAlert()
        alert.messageText = L10n.settingsAbbrPrompt
        let shortField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        shortField.placeholderString = L10n.settingsAbbrShortPlaceholder
        shortField.stringValue = existing?.short ?? ""
        let fullField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        fullField.placeholderString = L10n.settingsAbbrFullPlaceholder
        fullField.stringValue = existing?.full ?? ""
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        box.addSubview(shortField)
        box.addSubview(fullField)
        alert.accessoryView = box
        alert.addButton(withTitle: existing == nil ? L10n.commonAdd : L10n.commonSave)
        alert.addButton(withTitle: L10n.commonCancel)
        alert.window.initialFirstResponder = shortField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let clean = Abbreviations.sanitize([Abbreviation(short: shortField.stringValue, full: fullField.stringValue)]).first
        if clean == nil { NSSound.beep() }   // ревью M8: пусто, пробел в сокращении или слишком длинно
        return clean
    }

    private func persist() {
        setList(items)
        reload()
    }
}
