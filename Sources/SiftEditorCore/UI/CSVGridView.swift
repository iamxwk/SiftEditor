import AppKit

private final class CSVGridTableView: NSTableView {
    var onCellClick: ((Int, Int, Bool) -> Void)?
    var onCellDrag: ((Int, Int) -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onBeginEdit: (() -> Void)?

    private func cell(at event: NSEvent) -> (Int, Int)? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let column = column(at: point)
        return row >= 0 && column >= 0 ? (row, column) : nil
    }

    override func mouseDown(with event: NSEvent) {
        if let (row, column) = cell(at: event) {
            onCellClick?(row, column, event.modifierFlags.contains(.shift))
            if event.clickCount == 2 { onBeginEdit?() }
        }
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        if let (row, column) = cell(at: event) { onCellDrag?(row, column) }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": onCopy?(); return
            case "v": onPaste?(); return
            default: break
            }
        }
        switch event.keyCode {
        case 36, 76: onBeginEdit?() // Return
        case 123: onMove?(0, -1)
        case 124: onMove?(0, 1)
        case 125: onMove?(1, 0)
        case 126: onMove?(-1, 0)
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func paste(_ sender: Any?) { onPaste?() }
    @objc func undo(_ sender: Any?) { onUndo?() }
    @objc func redo(_ sender: Any?) { onRedo?() }
}

/// An editable grid for small CSV/TSV documents. The source text is owned by
/// EditableViewer; this view only reports complete, source-preserving edits.
final class CSVGridView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    var onChange: ((String) -> Void)?
    var onPendingChange: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private(set) var document: CSVGridDocument
    private let table = CSVGridTableView()
    private let tableScroll = NSScrollView()
    private let editorScroll = NSScrollView()
    private let editor = NSTextView()
    private let cellLabel = NSTextField(labelWithString: L("csv.cell"))
    private let applyButton = NSButton(title: L("csv.applyCell"), target: nil, action: nil)
    private var anchor = (row: 0, column: 0)
    private var selection = (rows: 0...0, columns: 0...0)
    private var activeCell = (row: 0, column: 0)
    private var hasActiveSelection = false

    init(document: CSVGridDocument) {
        self.document = document
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { nil }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        let top = NSView()
        top.translatesAutoresizingMaskIntoConstraints = false
        addSubview(top)

        cellLabel.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(cellLabel)
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.target = self
        applyButton.action = #selector(applyCell)
        top.addSubview(applyButton)

        editor.isRichText = false
        editor.delegate = self
        editor.frame = NSRect(x: 0, y: 0, width: 500, height: 86)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = EditorFont.current()
        editor.textContainerInset = NSSize(width: 6, height: 5)
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.hasVerticalScroller = true
        editorScroll.borderType = .bezelBorder
        editorScroll.documentView = editor
        top.addSubview(editorScroll)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 25
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.onCellClick = { [weak self] row, column, extend in self?.select(row: row, column: column, extend: extend) }
        table.onCellDrag = { [weak self] row, column in self?.select(row: row, column: column, extend: true) }
        table.onMove = { [weak self] dr, dc in
            guard let self else { return }
            self.select(row: self.activeCell.row + dr, column: self.activeCell.column + dc, extend: false)
        }
        table.onBeginEdit = { [weak self] in self?.window?.makeFirstResponder(self?.editor) }
        table.onCopy = { [weak self] in self?.copySelection() }
        table.onPaste = { [weak self] in self?.pasteSelection() }
        table.onUndo = { [weak self] in self?.onUndo?() }
        table.onRedo = { [weak self] in self?.onRedo?() }
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.documentView = table
        addSubview(tableScroll)

        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: 100),
            cellLabel.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 10),
            cellLabel.centerYAnchor.constraint(equalTo: editorScroll.centerYAnchor),
            applyButton.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -8),
            applyButton.topAnchor.constraint(equalTo: top.topAnchor, constant: 7),
            editorScroll.leadingAnchor.constraint(equalTo: cellLabel.trailingAnchor, constant: 10),
            editorScroll.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            editorScroll.topAnchor.constraint(equalTo: top.topAnchor, constant: 7),
            editorScroll.bottomAnchor.constraint(equalTo: top.bottomAnchor, constant: -7),
            tableScroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        rebuildColumns()
        select(row: 0, column: 0, extend: false)
    }

    private func rebuildColumns() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        for (index, name) in document.columnNames.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("csv-\(index)"))
            column.title = name
            column.minWidth = 70
            let sampleWidth = (0..<min(document.rowCount, 80)).map {
                document.value(row: $0, column: index).count
            }.max() ?? 0
            column.width = min(520, max(110, CGFloat(max(name.count, sampleWidth) * 9 + 35)))
            table.addTableColumn(column)
        }
        table.reloadData()
    }

    func updateSource(_ source: String) {
        guard let parsed = try? CSVGridDocument(source: source, mode: document.mode, hasHeader: document.hasHeader) else { return }
        document = parsed
        rebuildColumns()
        editor.string = document.value(row: activeCell.row, column: activeCell.column)
        select(row: activeCell.row, column: activeCell.column, extend: false)
    }

    func focusContent() { window?.makeFirstResponder(table) }
    func applyCurrentFontSize() { editor.font = EditorFont.current(); table.reloadData() }

    func sourceIncludingPendingEdit() -> String {
        guard hasActiveSelection, editor.string != document.value(row: activeCell.row, column: activeCell.column) else {
            return document.source
        }
        return document.replacing([(activeCell.row, activeCell.column, editor.string)]) ?? document.source
    }

    @discardableResult func flushPendingEdit() -> Bool { commitPendingCell() }

    func textDidChange(_ notification: Notification) { onPendingChange?() }

    private func select(row: Int, column: Int, extend: Bool) {
        guard document.rowCount > 0, document.columnCount > 0 else { editor.string = ""; return }
        guard commitPendingCell() else { return }
        let row = min(max(row, 0), document.rowCount - 1)
        let column = min(max(column, 0), document.columnCount - 1)
        if !extend { anchor = (row, column) }
        activeCell = (row, column)
        hasActiveSelection = true
        selection = (min(anchor.row, row)...max(anchor.row, row),
                     min(anchor.column, column)...max(anchor.column, column))
        editor.string = document.value(row: row, column: column)
        editor.isEditable = document.containsCell(row: row, column: column)
        applyButton.isEnabled = editor.isEditable
        table.reloadData()
        table.scrollRowToVisible(row)
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard document.rowCount > 0, let column = table.tableColumns.firstIndex(of: tableColumn) else { return }
        guard commitPendingCell() else { return }
        activeCell = (0, column)
        anchor = activeCell
        selection = (0...(document.rowCount - 1), column...column)
        editor.string = document.value(row: 0, column: column)
        editor.isEditable = document.containsCell(row: 0, column: column)
        applyButton.isEnabled = editor.isEditable
        table.reloadData()
        window?.makeFirstResponder(table)
    }

    @discardableResult private func commitPendingCell() -> Bool {
        guard hasActiveSelection else { return true }
        let value = editor.string
        guard value != document.value(row: activeCell.row, column: activeCell.column) else { return true }
        guard let source = document.replacing([(activeCell.row, activeCell.column, value)]) else {
            NSSound.beep()
            return false
        }
        updateSource(source)
        onChange?(source)
        return true
    }

    @objc private func applyCell() { commitPendingCell(); window?.makeFirstResponder(table) }

    private func copySelection() {
        guard document.rowCount > 0 else { return }
        guard commitPendingCell() else { return }
        let lines = selection.rows.map { row in
            selection.columns.map { document.value(row: row, column: $0) }.joined(separator: "\t")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func pasteSelection() {
        guard commitPendingCell() else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let cells = lines.map { line in
            let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
            return clean.components(separatedBy: "\t")
        }
        let edits = cells.enumerated().flatMap { row, values in
            values.enumerated().map { column, value in
                (row: activeCell.row + row, column: activeCell.column + column, value: value)
            }
        }
        guard let source = document.replacing(edits) else { NSSound.beep(); return }
        updateSource(source)
        onChange?(source)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document.rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = table.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let id = NSUserInterfaceItemIdentifier("CSVGridCell")
        let cell = (table.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = id
        let field: NSTextField
        if let existing = cell.textField { field = existing } else {
            field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        field.stringValue = document.value(row: row, column: column).replacingOccurrences(of: "\n", with: " ↵ ")
        field.font = EditorFont.current()
        cell.wantsLayer = true
        cell.layer?.backgroundColor = selection.rows.contains(row) && selection.columns.contains(column)
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        return cell
    }
}
