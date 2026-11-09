import AppKit

/// Shared exact-string exclusion list for both extraction dialogs.
final class IgnoredStringsEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let addButton = NSButton()
    private let deleteButton = NSButton()
    var strings: [String] = [] { didSet { table.reloadData(); updateButtons() } }
    var isEditingEnabled = true { didSet { updateButtons() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ignoredString"))
        column.title = L("search.stringsToIgnore")
        column.width = 254
        table.addTableColumn(column)
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.target = self
        table.action = #selector(updateButtons)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 257, height: bounds.height))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)
        addButton.title = L("common.add")
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: 268, y: bounds.height - 27, width: 76, height: 27)
        addButton.target = self
        addButton.action = #selector(addString)
        addSubview(addButton)
        deleteButton.title = L("common.delete")
        deleteButton.bezelStyle = .rounded
        deleteButton.frame = NSRect(x: 268, y: bounds.height - 57, width: 76, height: 27)
        deleteButton.target = self
        deleteButton.action = #selector(deleteString)
        addSubview(deleteButton)
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func updateButtons() {
        table.isEnabled = isEditingEnabled
        addButton.isEnabled = isEditingEnabled
        deleteButton.isEnabled = isEditingEnabled && table.selectedRow >= 0
    }

    @objc private func addString() {
        let alert = NSAlert()
        alert.messageText = L("search.addIgnoredString")
        alert.addButton(withTitle: L("common.add"))
        alert.addButton(withTitle: L("common.cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
        guard !strings.contains(input.stringValue) else { NSSound.beep(); return }
        strings.append(input.stringValue)
        table.selectRowIndexes(IndexSet(integer: strings.count - 1), byExtendingSelection: false)
        updateButtons()
    }

    @objc private func deleteString() {
        guard table.selectedRow >= 0 else { return }
        strings.remove(at: table.selectedRow)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { strings.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: strings[row])
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }
}
