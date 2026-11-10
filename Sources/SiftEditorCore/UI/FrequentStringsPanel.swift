import AppKit

/// EmEditor-style frequent-string input and output choices.
final class FrequentStringsPanel: NSPanel, NSWindowDelegate {
    struct Options {
        let kind: FrequentStrings.Kind
        let pattern: String
        let maximumRows: Int
        let maximumMatches: Int
        let caseSensitive: Bool
        let ignoredStrings: [String]
    }

    private var kindButtons: [NSButton] = []
    private let pattern = NSTextField()
    private let matchCase = NSButton(checkboxWithTitle: L("frequent.matchCase"), target: nil, action: nil)
    private let maximumRows = NSTextField(string: "100")
    private let maximumMatches = NSTextField(string: String(FrequentStrings.defaultMatchLimit))
    private let ignoredEditor = IgnoredStringsEditor(frame: NSRect(x: 13, y: 43, width: 344, height: 112))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 370, height: 650),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = L("frequent.title")
        isReleasedWhenClosed = false
        delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: 650))
        contentView = content
        func frame(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: x, y: 650 - top - height, width: width, height: height)
        }
        func label(_ key: String, top: CGFloat) {
            let view = NSTextField(labelWithString: L(key))
            view.frame = frame(31, top, 105, 20)
            content.addSubview(view)
        }
        let inputBox = NSBox(frame: frame(13, 17, 344, 337))
        inputBox.title = L("frequent.input")
        content.addSubview(inputBox)
        let kinds: [(FrequentStrings.Kind, String, Int)] = [
            (.lines, "frequent.kind.0", 42), (.words, "frequent.kind.1", 67),
            (.ipv4, "frequent.kind.3", 117), (.ipv6, "frequent.kind.4", 142),
            (.url, "frequent.kind.6", 167), (.email, "frequent.kind.5", 192),
            (.regex, "frequent.kind.2", 217)
        ]
        for (index, pair) in kinds.enumerated() {
            let button = NSButton(radioButtonWithTitle: L(pair.1), target: self, action: #selector(kindChanged(_:)))
            button.tag = pair.0.rawValue
            button.frame = frame(29, CGFloat(pair.2), 315, 22)
            button.state = index == 0 ? .on : .off
            content.addSubview(button)
            kindButtons.append(button)
        }
        let cells = NSButton(radioButtonWithTitle: L("frequent.cells") + " *", target: nil, action: nil)
        cells.frame = frame(29, 92, 315, 22)
        cells.isEnabled = false
        content.addSubview(cells)
        pattern.placeholderString = L("frequent.pattern")
        pattern.frame = frame(46, 242, 280, 23)
        pattern.isHidden = true
        content.addSubview(pattern)
        let divider = NSBox(frame: frame(30, 269, 311, 1))
        divider.boxType = .separator
        content.addSubview(divider)
        matchCase.frame = frame(29, 275, 315, 22)
        matchCase.state = .on
        content.addSubview(matchCase)
        let allDocuments = NSButton(checkboxWithTitle: L("frequent.allDocuments") + " *", target: nil, action: nil)
        allDocuments.frame = frame(29, 300, 315, 22)
        allDocuments.isEnabled = false
        content.addSubview(allDocuments)
        let selection = NSButton(checkboxWithTitle: L("frequent.selectionOnly") + " *", target: nil, action: nil)
        selection.frame = frame(29, 325, 315, 22)
        selection.isEnabled = false
        content.addSubview(selection)

        let outputBox = NSBox(frame: frame(13, 365, 344, 120))
        outputBox.title = L("frequent.output")
        content.addSubview(outputBox)
        label("search.maximumRows", top: 385)
        maximumRows.frame = frame(137, 381, 203, 24)
        content.addSubview(maximumRows)
        label("search.csvFormat", top: 416)
        let format = NSPopUpButton(frame: frame(137, 412, 203, 25))
        for key in ["search.commaSeparated", "frequent.tabSeparated", "frequent.semicolonSeparated",
                    "frequent.comparisonReport", "frequent.pipeSeparated", "frequent.datFormat"] {
            let supported = key == "search.commaSeparated"
            format.addItem(withTitle: L(key) + (supported ? "" : " *"))
            format.lastItem?.isEnabled = supported
        }
        content.addSubview(format)
        label("frequent.maximumMatches", top: 447)
        maximumMatches.frame = frame(137, 442, 203, 24)
        maximumMatches.isEnabled = false
        content.addSubview(maximumMatches)

        content.addSubview(ignoredEditor)
        func button(_ key: String, x: CGFloat, action: Selector) {
            let view = NSButton(title: L(key), target: self, action: action)
            view.bezelStyle = .rounded
            view.frame = frame(x, 615, 76, 27)
            content.addSubview(view)
        }
        button("common.ok", x: 197, action: #selector(accept))
        button("common.cancel", x: 281, action: #selector(cancel))
        center()
    }

    func show() -> Options? {
        makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: self)
        orderOut(nil)
        guard response == .OK else { return nil }
        let kind = FrequentStrings.Kind(rawValue: kindButtons.first(where: { $0.state == .on })?.tag ?? 0) ?? .lines
        return Options(kind: kind, pattern: pattern.stringValue,
                       maximumRows: min(max(Int(maximumRows.stringValue) ?? 100, 1), 100_000),
                       maximumMatches: min(max(Int(maximumMatches.stringValue) ?? FrequentStrings.defaultMatchLimit, 1), 1_000_000_000),
                       caseSensitive: matchCase.state == .on, ignoredStrings: ignoredEditor.strings)
    }

    @objc private func kindChanged(_ sender: NSButton) {
        for button in kindButtons { button.state = button === sender ? .on : .off }
        pattern.isHidden = sender.tag != FrequentStrings.Kind.regex.rawValue
        maximumMatches.isEnabled = sender.tag == FrequentStrings.Kind.regex.rawValue
    }
    @objc private func accept() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancel() { NSApp.stopModal(withCode: .cancel) }
    func windowWillClose(_ notification: Notification) { NSApp.stopModal(withCode: .cancel) }
}
