import AppKit

/// Find's extraction settings. Edits remain local until OK is pressed.
final class ExtractOptionsPanel: NSPanel, NSWindowDelegate, NSComboBoxDelegate {
    private let before = NSComboBox()
    private let after = NSComboBox()
    private let separator = NSTextField()
    private let frequent = NSButton(checkboxWithTitle: L("search.countFrequent"), target: nil, action: nil)
    private let maximumRows = NSTextField()
    private let ignoredEditor = IgnoredStringsEditor(frame: NSRect(x: 13, y: 14, width: 344, height: 122))
    private var original: SearchExtraction.Options

    init(options: SearchExtraction.Options) {
        original = options
        ignoredEditor.strings = options.ignoredStrings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 370, height: 510),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = L("search.extractOptionsTitle")
        isReleasedWhenClosed = false
        delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: 510))
        contentView = content

        func frame(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: x, y: 510 - top - height, width: width, height: height)
        }
        func label(_ key: String, x: CGFloat = 13, top: CGFloat, width: CGFloat = 260) {
            let view = NSTextField(labelWithString: L(key))
            view.frame = frame(x, top, width, 20)
            content.addSubview(view)
        }
        func button(_ key: String, top: CGFloat, action: Selector) -> NSButton {
            let view = NSButton(title: L(key), target: self, action: action)
            view.bezelStyle = .rounded
            view.frame = frame(281, top, 76, 27)
            content.addSubview(view)
            return view
        }

        let outputBar = NSButton(checkboxWithTitle: L("search.outputBar") + " *", target: nil, action: nil)
        outputBar.frame = frame(13, 11, 255, 23)
        outputBar.isEnabled = false
        content.addSubview(outputBar)
        _ = button("common.ok", top: 9, action: #selector(accept))
        _ = button("common.cancel", top: 39, action: #selector(cancel))

        label("search.extractMode", top: 44)
        let mode = NSPopUpButton(frame: frame(13, 64, 257, 25))
        mode.addItem(withTitle: L("search.matchingLines"))
        content.addSubview(mode)

        label("search.linesBefore", top: 104, width: 344)
        label("search.linesAfter", top: 158, width: 344)
        for (field, top, value) in [(before, CGFloat(126), options.linesBefore),
                                    (after, CGFloat(180), options.linesAfter)] {
            field.frame = frame(13, top, 75, 25)
            field.addItems(withObjectValues: ["0", "1", "2", "3", "5", "10", "20", "50", "100"])
            field.stringValue = String(value)
            field.delegate = self
            field.action = #selector(updateEnabled)
            field.target = self
            content.addSubview(field)
        }

        label("search.separator", top: 217)
        separator.frame = frame(13, 239, 257, 24)
        separator.stringValue = options.separator
        content.addSubview(separator)

        frequent.frame = frame(13, 280, 255, 23)
        frequent.state = options.frequent ? .on : .off
        frequent.target = self
        frequent.action = #selector(updateEnabled)
        content.addSubview(frequent)
        label("search.maximumRows", top: 313, width: 105)
        maximumRows.frame = frame(120, 310, 150, 24)
        maximumRows.stringValue = String(options.maximumRows)
        content.addSubview(maximumRows)
        let csvLabel = NSTextField(labelWithString: L("search.csvFormat") + " *")
        csvLabel.frame = frame(13, 344, 105, 20)
        content.addSubview(csvLabel)
        let csvFormat = NSPopUpButton(frame: frame(120, 340, 150, 25))
        csvFormat.addItem(withTitle: L("search.commaSeparated") + " *")
        csvFormat.isEnabled = false
        content.addSubview(csvFormat)

        content.addSubview(ignoredEditor)
        _ = button("common.reset", top: 469, action: #selector(resetOptions))
        updateEnabled()
        center()
    }

    func show() -> SearchExtraction.Options? {
        makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: self)
        orderOut(nil)
        guard response == .OK else { return nil }
        var options = original
        options.linesBefore = min(max(Int(before.stringValue) ?? 0, 0), 100)
        options.linesAfter = min(max(Int(after.stringValue) ?? 0, 0), 100)
        options.separator = String(separator.stringValue.prefix(100))
        options.frequent = frequent.state == .on
        options.maximumRows = min(max(Int(maximumRows.stringValue) ?? 100, 1), 100_000)
        options.ignoredStrings = ignoredEditor.strings
        return options
    }

    @objc private func accept() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancel() { NSApp.stopModal(withCode: .cancel) }
    func windowWillClose(_ notification: Notification) { NSApp.stopModal(withCode: .cancel) }

    @objc private func updateEnabled() {
        separator.isEnabled = (Int(before.stringValue) ?? 0) > 0 || (Int(after.stringValue) ?? 0) > 0
        let counting = frequent.state == .on
        maximumRows.isEnabled = counting
        ignoredEditor.isEditingEnabled = counting
    }

    func controlTextDidChange(_ obj: Notification) { updateEnabled() }

    @objc private func resetOptions() {
        let defaults = SearchExtraction.Options()
        before.stringValue = String(defaults.linesBefore)
        after.stringValue = String(defaults.linesAfter)
        separator.stringValue = defaults.separator
        frequent.state = .off
        maximumRows.stringValue = String(defaults.maximumRows)
        ignoredEditor.strings = []
        updateEnabled()
    }
}
