import AppKit

private final class SearchBarDragHandle: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// 搜索栏（位于查看器的右上角）。
///
/// custom draw() 未包含在内。背景和边框绘制在不同的图层上。
/// （当视图包含 custom draw 时，如果该视图在同一窗口中具有子控件）
/// 避免 macOS 错误导致与其他自定义绘图视图合成时出现问题。（类似于 [StatusBarView]。）
final class SearchBarView: NSView, NSSearchFieldDelegate {
    static let handleHeight: CGFloat = 16
    static let height: CGFloat = 334
    static let expandedHeight: CGFloat = 366

    private let field = NSSearchField()
    private var findHistoryAutoSave = (UserDefaults.standard.object(forKey: "SiftEditor.searchHistoryAutoSave") as? Bool) ?? true
    private var snippetInsertionRange: NSRange?
    private let countLabel = NSTextField(labelWithString: "")

    private let caseToggle = NSButton()
    private let regexToggle = NSButton()
    private let noRegexToggle = NSButton()
    private var optionButtons: [FindOption: NSButton] = [:]
    private let filterToggle = NSButton()
    /// 仅显示书签行（漏斗图旁边）。与漏斗图互斥。
    private let bookmarkToggle = NSButton()
    /// 上一行和下一行 N (`grep -C`)。**使用字母和数字代替图标** --
    /// 如果“±2”出现在筛选屏幕上，您可以读出发生了什么，但如果只是一个符号，您就不会注意到。
    private let contextLabel = NSTextField(labelWithString: "±")
    private let contextField = NSTextField()

    private let replaceField = NSTextField()
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()
    private let preserveCaseToggle = NSButton()
    private let extractControl = NSSegmentedControl()
    private var replaceRow: NSStackView?

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?
    var onCaseToggle: ((Bool) -> Void)?
    var onRegexToggle: ((Bool) -> Void)?
    var onFilterToggle: ((Bool) -> Void)?
    /// 切换仅显示书签。如果无法更改开关（例如，0 个书签），则返回 false。
    var onBookmarkToggle: ((Bool) -> Bool)?
    /// 当漏斗移至一个**无法使用**的痛点时，他退出了。这与他自己删除的内容无关。
    /// 当您返回到下一个可用窗格时，恢复到原始状态（意图保持不变）。
    var onFilterUnavailable: (() -> Void)?
    var onContextChange: ((Int) -> Void)?
    var onReplace: ((String) -> Void)?
    var onReplaceAll: ((String) -> Void)?
    var onPreserveCaseToggle: ((Bool) -> Void)?
    var onExtract: (() -> Void)?
    var onExtractOptions: (() -> Void)?
    var selectedTextForFind: (() -> String?)?
    var onReplaceRowChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        applyColors()

        let dragHandle = SearchBarDragHandle()
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal",
                                              accessibilityDescription: L("search.moveBar"))!)
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.contentTintColor = .tertiaryLabelColor
        dragHandle.addSubview(grip)
        addSubview(dragHandle)

        field.placeholderString = L("search.placeholder")
        field.font = .systemFont(ofSize: 12)
        field.controlSize = .small
        field.delegate = self
        field.target = self
        field.action = #selector(enterPressed)
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = false
        (field.cell as? NSSearchFieldCell)?.searchButtonCell?.isTransparent = false
        // 搜索历史记录。`recentsAutosaveName` 表示“将 `recentSearches` 设置为用户默认值”。
        // 它只执行“自动读写”操作——**向数组中添加元素是我们的工作。**
        // （最初，我以为它会自动累加 Enter，但它并没有在实际设备上累加，所以我弄错了）。
        // `searchMenuTemplate` 也**空的 NSMenu 不显示任何内容** -- 标题、列表、清除
        // 您需要手动放置一个带有特殊标签的物品，该标签指示插入位置（另一个误解）。
        // （我以为如果我创建一个空菜单，AppKit 会自动组装它。）
        field.recentsAutosaveName = "SiftEditor.searchHistory"
        field.searchMenuTemplate = Self.makeSearchMenuTemplate()
        field.maximumRecents = 10
        normalizeRecentSearches()

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        // 大/小切换开关 (Aa)
        caseToggle.title = L("search.dialog.case")
        caseToggle.setButtonType(.switch)
        caseToggle.font = .systemFont(ofSize: 11)
        caseToggle.controlSize = .small
        caseToggle.target = self
        caseToggle.action = #selector(caseTapped)
        caseToggle.toolTip = L("search.tip.matchCase")
        caseToggle.setContentHuggingPriority(.required, for: .horizontal)
        optionButtons[.matchCase] = caseToggle

        // 正则表达式切换 (.*)
        regexToggle.title = L("search.dialog.regex")
        regexToggle.setButtonType(.radio)
        regexToggle.font = .systemFont(ofSize: 11)
        regexToggle.controlSize = .small
        regexToggle.target = self
        regexToggle.action = #selector(regexTapped)
        regexToggle.toolTip = L("search.tip.regex")
        regexToggle.setContentHuggingPriority(.required, for: .horizontal)
        optionButtons[.regex] = regexToggle
        noRegexToggle.title = L("search.dialog.none")
        noRegexToggle.setButtonType(.radio)
        noRegexToggle.font = .systemFont(ofSize: 11)
        noRegexToggle.controlSize = .small
        noRegexToggle.state = .on
        noRegexToggle.target = self
        noRegexToggle.action = #selector(noRegexTapped)

        // 筛选器显示切换（漏斗）
        filterToggle.title = L("search.dialog.filter")
        filterToggle.setButtonType(.switch)
        filterToggle.font = .systemFont(ofSize: 11)
        filterToggle.controlSize = .small
        filterToggle.target = self
        filterToggle.action = #selector(filterTapped)
        filterToggle.toolTip = L("search.tip.matchingLines")
        filterToggle.setContentHuggingPriority(.required, for: .horizontal)

        bookmarkToggle.title = L("search.dialog.bookmarkLines")
        bookmarkToggle.setButtonType(.switch)
        bookmarkToggle.font = .systemFont(ofSize: 11)
        bookmarkToggle.controlSize = .small
        bookmarkToggle.target = self
        bookmarkToggle.action = #selector(bookmarkTapped)
        bookmarkToggle.toolTip = L("search.tip.bookmarkedLines")
        bookmarkToggle.setContentHuggingPriority(.required, for: .horizontal)

        // 前后 N 行（grep -C）。放在筛选控件旁边，便于筛选时看到。
        contextLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        contextLabel.setContentHuggingPriority(.required, for: .horizontal)
        contextField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        contextField.alignment = .right
        contextField.placeholderString = "0"
        contextField.target = self
        contextField.action = #selector(contextEdited)   // Enter - 失去焦点时
        contextField.toolTip = L("search.tip.contextLines")
        contextField.setContentHuggingPriority(.required, for: .horizontal)

        let prev = NSButton(title: L("search.dialog.previous"), target: self, action: #selector(prevTapped))
        let next = NSButton(title: L("search.dialog.next"), target: self, action: #selector(nextTapped))
        prev.font = .systemFont(ofSize: 11)
        next.font = .systemFont(ofSize: 11)
        prev.controlSize = .large
        next.controlSize = .large
        let close = iconButton("xmark", #selector(closeTapped))

        // 结果数量（“1/18”）也不允许缩短。如果末尾被截断，则无法读取具体是哪条结果。
        keepIntrinsicWidth([caseToggle, regexToggle, filterToggle, bookmarkToggle, contextLabel, countLabel,
                            preserveCaseToggle, replaceButton, replaceAllButton])

        // 替换管路。
        replaceField.placeholderString = L("search.replacePlaceholder")
        replaceField.font = field.font
        replaceField.target = self
        replaceField.action = #selector(replaceTapped)   // 替换  Enter
        replaceButton.title = L("search.replace")
        replaceButton.bezelStyle = .rounded
        replaceButton.font = .systemFont(ofSize: 11)
        replaceButton.controlSize = .small
        replaceButton.target = self
        replaceButton.action = #selector(replaceTapped)
        replaceButton.setContentHuggingPriority(.required, for: .horizontal)
        replaceAllButton.title = L("search.replaceAll")
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.font = .systemFont(ofSize: 11)
        replaceAllButton.controlSize = .small
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllTapped)
        replaceAllButton.setContentHuggingPriority(.required, for: .horizontal)
        extractControl.segmentCount = 2
        extractControl.trackingMode = .momentary
        extractControl.segmentStyle = .rounded
        extractControl.controlSize = .large
        extractControl.font = .systemFont(ofSize: 11)
        extractControl.setLabel(L("search.extract"), forSegment: 0)
        extractControl.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("search.extractOptions")), forSegment: 1)
        extractControl.setToolTip(L("search.extractOptions"), forSegment: 1)
        extractControl.setWidth(67, forSegment: 0)
        extractControl.setWidth(22, forSegment: 1)
        extractControl.target = self
        extractControl.action = #selector(extractSegmentTapped(_:))

        // 大小写保留切换（Aa → aA）。匹配字符串将不区分大小写，并将匹配结果传递给替换字符串。
        preserveCaseToggle.title = "aA"
        preserveCaseToggle.setButtonType(.pushOnPushOff)
        preserveCaseToggle.bezelStyle = .roundRect
        preserveCaseToggle.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        preserveCaseToggle.controlSize = .small
        preserveCaseToggle.target = self
        preserveCaseToggle.action = #selector(preserveCaseTapped)
        preserveCaseToggle.toolTip = L("search.tip.preserveCase")
        preserveCaseToggle.setContentHuggingPriority(.required, for: .horizontal)

        let replaceRow = NSStackView(views: [replaceField, preserveCaseToggle, replaceButton, replaceAllButton])
        replaceRow.orientation = .horizontal
        replaceRow.spacing = 5
        replaceRow.isHidden = true
        self.replaceRow = replaceRow

        func disabledOption(_ option: FindOption, _ title: String, radio: Bool = false) -> NSButton {
            let button = NSButton(checkboxWithTitle: title + " *", target: self,
                                  action: #selector(optionTapped(_:)))
            if radio { button.setButtonType(.radio) }
            button.font = .systemFont(ofSize: 11)
            button.controlSize = .small
            button.state = AppSettings.findOption(option) ? .on : .off
            button.isEnabled = false
            button.identifier = NSUserInterfaceItemIdentifier(option.rawValue)
            optionButtons[option] = button
            return button
        }
        func column(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 9
            return stack
        }
        func action(_ title: String, selector: Selector?, enabled: Bool = true) -> NSButton {
            let button = NSButton(title: enabled ? title : title + " *", target: selector == nil ? nil : self, action: selector)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.controlSize = .large
            button.isEnabled = enabled
            button.widthAnchor.constraint(equalToConstant: 89).isActive = true
            button.heightAnchor.constraint(equalToConstant: 27).isActive = true
            return button
        }
        let title = NSTextField(labelWithString: L("search.dialog.title"))
        title.font = .systemFont(ofSize: 12)
        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyDown
        appIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let headerSpacer = NSView()
        let help = NSButton(title: "?", target: nil, action: nil)
        help.isEnabled = false
        help.isBordered = false
        let header = NSStackView(views: [appIcon, title, headerSpacer, help, close])
        header.orientation = .horizontal
        header.spacing = 4

        let findMore = NSButton(title: ">", target: nil, action: nil)
        findMore.controlSize = .small
        findMore.font = .systemFont(ofSize: 12)
        findMore.bezelStyle = .rounded
        findMore.target = self
        findMore.action = #selector(showFindAssistMenu)
        findMore.toolTip = L("search.assist.menu")
        findMore.widthAnchor.constraint(equalToConstant: 19).isActive = true
        let findInput = NSView()
        findInput.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        let findRow = NSStackView(views: [findInput, findMore])
        findRow.orientation = .horizontal
        findRow.spacing = 7
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 203).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let wholeWord = disabledOption(.wholeWord, L("search.dialog.wholeWord"))
        let leftOptions = column([
            caseToggle,
            wholeWord,
            divider,
            disabledOption(.incremental, L("search.dialog.incremental")),
            disabledOption(.allDocuments, L("search.dialog.allDocuments")),
            disabledOption(.selectionOnly, L("search.dialog.selectionOnly")),
            disabledOption(.wrap, L("search.dialog.wrap")),
            disabledOption(.countMatches, L("search.dialog.showCount")),
            disabledOption(.closeAfter, L("search.dialog.closeAfter"))
        ])
        leftOptions.spacing = 12.5
        leftOptions.setCustomSpacing(9.25, after: wholeWord)
        leftOptions.setCustomSpacing(9.25, after: divider)
        let fuzzy = disabledOption(.fuzzy, L("search.dialog.fuzzy"))
        let fuzzyMore = NSButton(title: "…", target: nil, action: nil)
        fuzzyMore.isEnabled = false
        fuzzyMore.controlSize = .small
        let fuzzyRow = NSStackView(views: [fuzzy, fuzzyMore])
        fuzzyRow.orientation = .horizontal
        fuzzyRow.spacing = 20
        let escapes = disabledOption(.escapes, L("search.dialog.escapes"), radio: true)
        let rightOptions = column([
            noRegexToggle, regexToggle,
            escapes,
            disabledOption(.numberRange, L("search.dialog.numberRange"), radio: true),
            fuzzyRow
        ])
        rightOptions.spacing = 12.5
        rightOptions.setCustomSpacing(19.5, after: escapes)
        let options = NSStackView(views: [leftOptions, rightOptions])
        options.orientation = .horizontal
        options.alignment = .top
        options.spacing = 20
        let queryLabel = NSTextField(labelWithString: L("search.dialog.query"))
        let left = column([queryLabel, findRow, options, replaceRow])
        left.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 0, right: 0)
        left.setCustomSpacing(2, after: queryLabel)
        left.setCustomSpacing(23.5, after: findRow)
        extractControl.widthAnchor.constraint(equalToConstant: 89).isActive = true
        extractControl.heightAnchor.constraint(equalToConstant: 27).isActive = true
        prev.widthAnchor.constraint(equalToConstant: 89).isActive = true
        next.widthAnchor.constraint(equalToConstant: 89).isActive = true
        prev.heightAnchor.constraint(equalToConstant: 27).isActive = true
        next.heightAnchor.constraint(equalToConstant: 27).isActive = true
        let batch = action(L("search.dialog.batch"), selector: nil, enabled: false)
        let right = column([
            prev, next,
            action(L("search.dialog.selectAll"), selector: nil, enabled: false),
            action(L("search.dialog.setBookmark"), selector: nil, enabled: false),
            extractControl,
            action(L("search.dialog.replaceExpand"), selector: #selector(replaceExpandTapped)),
            action(L("search.dialog.close"), selector: #selector(closeTapped)),
            action(L("search.dialog.advanced"), selector: nil, enabled: false),
            batch
        ])
        right.spacing = 3
        right.setCustomSpacing(10, after: next)
        right.setCustomSpacing(10.5, after: extractControl)
        right.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 0, right: 0)
        let addBatch = NSSegmentedControl()
        addBatch.segmentCount = 2
        addBatch.trackingMode = .momentary
        addBatch.segmentStyle = .rounded
        addBatch.font = .systemFont(ofSize: 11)
        addBatch.controlSize = .large
        addBatch.setLabel(L("search.dialog.addBatch") + " *", forSegment: 0)
        addBatch.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("search.dialog.addBatch")), forSegment: 1)
        addBatch.setWidth(96, forSegment: 0)
        addBatch.setWidth(22, forSegment: 1)
        addBatch.isEnabled = false
        addBatch.widthAnchor.constraint(equalToConstant: 118).isActive = true
        addBatch.heightAnchor.constraint(equalToConstant: 27).isActive = true
        addBatch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addBatch)
        let body = NSStackView(views: [left, right])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 17
        let root = column([header, body])
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: topAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: Self.handleHeight),
            grip.centerXAnchor.constraint(equalTo: dragHandle.centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: dragHandle.centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 18),
            grip.heightAnchor.constraint(equalToConstant: 10),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.widthAnchor.constraint(equalTo: root.widthAnchor),
            left.widthAnchor.constraint(equalToConstant: 445),
            findInput.widthAnchor.constraint(equalToConstant: 419),
            findInput.heightAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: findInput.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: findInput.trailingAnchor),
            field.topAnchor.constraint(equalTo: findInput.topAnchor),
            field.bottomAnchor.constraint(equalTo: findInput.bottomAnchor),
            contextField.widthAnchor.constraint(equalToConstant: 35),
            replaceField.widthAnchor.constraint(equalToConstant: 200),
            addBatch.trailingAnchor.constraint(equalTo: batch.leadingAnchor, constant: -7),
            addBatch.centerYAnchor.constraint(equalTo: batch.centerYAnchor),
        ])
    }

    /// 文本切换按钮 (Aa / .*) 不应被缩短。如果被压缩，它会变成“...”，您将无法阅读按钮的功能。
    ///（这是添加±N字段时实际发生的情况）。当空间变窄时，搜索字段应该缩小。
    private func keepIntrinsicWidth(_ views: [NSView]) {
        for v in views {
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            v.setContentHuggingPriority(.required, for: .horizontal)
        }
    }

    /// 搜索历史菜单模板。**只需列出已标记的项目**；内容可以为空。
    /// 每次显示  / `NSSearchField` 时，它都会移动到 `recentsTitleMenuItemTag`/`recentsMenuItemTag` 的位置。
    /// 插入标题和实际历史记录，仅当没有历史记录时才保留 `noRecentsMenuItemTag`。
    private static func makeSearchMenuTemplate() -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(title: L("search.recentSearches"), action: nil, keyEquivalent: "")
        title.tag = NSSearchField.recentsTitleMenuItemTag
        menu.addItem(title)

        let recentsPlaceholder = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recentsPlaceholder.tag = NSSearchField.recentsMenuItemTag
        menu.addItem(recentsPlaceholder)

        let noRecents = NSMenuItem(title: L("search.noRecentSearches"), action: nil, keyEquivalent: "")
        noRecents.tag = NSSearchField.noRecentsMenuItemTag
        menu.addItem(noRecents)

        menu.addItem(.separator())

        let clear = NSMenuItem(title: L("search.clearRecentSearches"), action: nil, keyEquivalent: "")
        clear.tag = NSSearchField.clearRecentsMenuItemTag
        menu.addItem(clear)

        return menu
    }

    private static func uniqueRecentSearches(_ searches: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array(searches.filter { seen.insert($0).inserted }.prefix(limit))
    }

    private func normalizeRecentSearches() {
        let unique = Self.uniqueRecentSearches(field.recentSearches, limit: field.maximumRecents)
        if unique != field.recentSearches { field.recentSearches = unique }
    }

    private func findAssistMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ key: String, action: Selector? = nil, enabled: Bool = true,
                 checked: Bool = false) {
            let item = NSMenuItem(title: L(key) + (action == nil ? " *" : ""),
                                  action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.isEnabled = enabled && action != nil
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add("search.assist.selectionOrWord", enabled: false, checked: true)
        let selection = selectedTextForFind?()
        let canUseSelection = selection.map { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") } ?? false
        add("search.assist.selection", action: #selector(useSelectedText),
            enabled: canUseSelection)
        add("search.assist.wordAtCursor", enabled: false)
        add("search.assist.lastUsed", action: #selector(useLastSearch), enabled: !field.recentSearches.isEmpty)
        add("search.assist.fixedValue", enabled: false)
        menu.addItem(.separator())
        add("search.assist.autoSave", action: #selector(toggleFindHistoryAutoSave), checked: findHistoryAutoSave)
        menu.addItem(.separator())
        add("search.assist.multiline", enabled: false)
        add("search.assist.editorFont", enabled: false)
        add("search.assist.autoHighlight", enabled: false)

        func snippet(_ pattern: String, _ key: String, supported: Bool = true) {
            let item = NSMenuItem(title: pattern + "    " + L(key) + (supported ? "" : " *"),
                                  action: supported ? #selector(insertRegexSnippet(_:)) : nil,
                                  keyEquivalent: "")
            item.target = supported ? self : nil
            item.isEnabled = supported
            item.representedObject = pattern
            menu.addItem(item)
        }
        menu.addItem(.separator())
        snippet("^", "search.assist.beginLine")
        snippet("$", "search.assist.endLine")
        menu.addItem(.separator())
        snippet(".", "search.assist.anyCharacter")
        snippet("*", "search.assist.zeroOrMore")
        snippet("+", "search.assist.oneOrMore")
        snippet("?", "search.assist.zeroOrOne")
        snippet("{n,m}", "search.assist.nToM")
        menu.addItem(.separator())
        snippet("*?", "search.assist.lazyZeroOrMore")
        snippet("+?", "search.assist.lazyOneOrMore")
        snippet("??", "search.assist.lazyZeroOrOne")
        snippet("{n,m}?", "search.assist.lazyNToM")
        menu.addItem(.separator())
        snippet("()", "search.assist.group")
        snippet("|", "search.assist.or")
        snippet("[]", "search.assist.characterSet")
        snippet("[^]", "search.assist.negatedSet")
        menu.addItem(.separator())
        snippet(#"\n"#, "search.assist.newline", supported: false)
        snippet(#"\r"#, "search.assist.carriageReturn", supported: false)
        snippet(#"\t"#, "search.assist.tab")
        snippet(#"\w"#, "search.assist.word")
        snippet(#"\s"#, "search.assist.space")
        snippet(#"\d"#, "search.assist.digit")
        snippet(#"\l"#, "search.assist.lowercase", supported: false)
        snippet(#"\u"#, "search.assist.uppercase", supported: false)
        snippet(#"\Q"#, "search.assist.startQuote", supported: false)
        snippet(#"\E"#, "search.assist.endQuote", supported: false)
        snippet(#"\"#, "search.assist.escape", supported: false)
        menu.addItem(.separator())
        snippet("(?:pattern)", "search.assist.nonCapturing")
        snippet("(?=pattern)", "search.assist.positiveLookahead")
        snippet("(?!pattern)", "search.assist.negativeLookahead")
        snippet("(?<=pattern)", "search.assist.positiveLookbehind")
        snippet("(?<!pattern)", "search.assist.negativeLookbehind")
        snippet("(?~pattern)", "search.assist.absentOperator", supported: false)
        menu.addItem(.separator())
        add("search.assist.regexHelp", enabled: false)
        return menu
    }

    @objc private func showFindAssistMenu(_ sender: NSButton) {
        snippetInsertionRange = (field.currentEditor() as? NSTextView)?.selectedRange()
        findAssistMenu().popUp(positioning: nil, at: .zero, in: sender)
    }

    @objc private func useSelectedText() {
        guard let selected = selectedTextForFind?(), !selected.isEmpty,
              !selected.contains("\n"), !selected.contains("\r") else { return }
        prefillFromSelection(selected)
        focusField()
    }

    @objc private func useLastSearch() {
        normalizeRecentSearches()
        guard let term = field.recentSearches.first else { return }
        field.stringValue = term
        onQueryChange?(term)
        focusField()
    }

    @objc private func toggleFindHistoryAutoSave() {
        findHistoryAutoSave.toggle()
        UserDefaults.standard.set(findHistoryAutoSave, forKey: "SiftEditor.searchHistoryAutoSave")
    }

    @objc private func insertRegexSnippet(_ item: NSMenuItem) {
        guard let snippet = item.representedObject as? String else { return }
        let old = field.stringValue as NSString
        let range = snippetInsertionRange.flatMap { NSMaxRange($0) <= old.length ? $0 : nil }
            ?? NSRange(location: old.length, length: 0)
        field.stringValue = old.replacingCharacters(in: range, with: snippet)
        if !isRegex { selectRegexMode() }
        onQueryChange?(field.stringValue)
        window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.setSelectedRange(
            NSRange(location: range.location + (snippet as NSString).length, length: 0))
    }

    private func iconButton(_ symbol: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let b = NSButton(image: img ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .smallSquare
        b.imageScaling = .scaleProportionallyDown
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func applyColors() {
        let theme = EditorTheme.current()
        layer?.backgroundColor = EditorTheme.withBackgroundOpacity(theme.chromeBackground).cgColor
        layer?.borderColor = theme.separator.cgColor
        countLabel.textColor = theme.chromeSecondaryText
        syncContextEnabled()   // “±”符号的颜色会根据其是否可用而改变。
    }
    /// 将配色方案（主题）应用于搜索面板（内部搜索字段和按钮将跟随窗口外观）。
    func applyTheme() { applyColors() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    // MARK: - 公開API

    var query: String { field.stringValue }
    var isCaseSensitive: Bool { caseToggle.state == .on }
    var isRegex: Bool { regexToggle.state == .on }

    /// 打开窗口时恢复所有选项；禁用项启用后无需另写持久化逻辑。
    func restoreSearchOptions() {
        for (option, button) in optionButtons {
            button.state = AppSettings.findOption(option) ? .on : .off
        }
        noRegexToggle.state = isRegex ? .off : .on
    }

    func selectRegexMode() {
        guard !isRegex else { return }
        regexTapped()
    }

    /// 用于检查搜索词历史记录（AppKit 标准功能）是否已启用的测试访问器。
    var _testSearchHistoryAutosaveName: String? { field.recentsAutosaveName }
    var _testSearchHistoryMenuEnabled: Bool { field.searchMenuTemplate != nil }
    var _testFindAssistMenu: NSMenu { findAssistMenu() }
    var _testRecentSearches: [String] { field.recentSearches }
    func _testLoadRecentSearches(_ searches: [String]) { field.recentSearches = searches }
    func _testInsertRegexSnippet(_ snippet: String) {
        let item = NSMenuItem(title: snippet, action: nil, keyEquivalent: "")
        item.representedObject = snippet
        insertRegexSnippet(item)
    }
    /// 与在搜索栏中输入文本并按 Enter 相同的路径（以确认已记录在历史记录中）。
    func _testCommitSearch(_ text: String) {
        field.stringValue = text
        enterPressed()
    }
    /// `recentsAutosaveName` 将保留为用户默认值，因此 `SearchBarView()`
    /// 即使创建新的测试，它也会继承之前测试的历史记录。使用测试 `setUp` 调用它即可删除它。
    /// 清除后端中的默认值，以防止在同一进程中再次看到先前的状态。
    func resetHistoryForTesting() {
        field.recentSearches = []
        if let key = field.recentsAutosaveName {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.synchronize()
        }
    }

    /// 在筛选（仅显示匹配的行）不可用的窗格中隐藏漏斗按钮。
    func setFilterAvailable(_ available: Bool) {
        if !available, filterToggle.state == .on {
            filterToggle.state = .off
            onFilterUnavailable?()
        }
        filterToggle.isEnabled = available
        if !available { bookmarkToggle.state = .off }
        bookmarkToggle.isEnabled = available
        syncContextEnabled()
    }

    /// Previous/Next N 列仅在启用筛选时才具有交互性（未筛选时没有上一列或下一列）。
    private func syncContextEnabled() {
        let on = filterToggle.isEnabled && filterToggle.state == .on
        contextField.isEnabled = on
        contextLabel.textColor = on ? EditorTheme.current().chromeText
                                    : EditorTheme.current().chromeSecondaryText
    }

    /// 上一行/下一行 N 是从外部创建的（当添加/删除菜单项或切换窗格时）。
    func setContextLines(_ n: Int) {
        contextField.stringValue = n > 0 ? String(n) : ""
        syncContextEnabled()
    }

    /// 在无法进行替换的窗格（结构化视图或仅显示匹配行）中，无法编辑要替换的行。
    /// 删除而不隐藏的原因是条形高度是固定的，删除一行会留下空隙。
    func setReplaceAvailable(_ available: Bool) {
        replaceField.isEnabled = available
        preserveCaseToggle.isEnabled = available
        replaceButton.isEnabled = available
        replaceAllButton.isEnabled = available
    }

    /// 从外部更改漏斗按钮的状态（当从工具栏上的“筛选器”菜单打开时）。
    /// 由于没有点击事件，调用者负责反映主要文本中的更改。
    func setFilterOn(_ on: Bool) {
        guard filterToggle.isEnabled else { return }
        filterToggle.state = on ? .on : .off
        syncContextEnabled()
    }

    /// “仅显示书签”按钮的状态可以从外部更改（切换窗格时或删除最后一行时）。
    func setBookmarkViewOn(_ on: Bool) {
        bookmarkToggle.state = on ? .on : .off
    }
    var isBookmarkViewOn: Bool { bookmarkToggle.state == .on }

    func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func showReplaceRow() {
        let wasHidden = replaceRow?.isHidden == true
        replaceRow?.isHidden = false
        if wasHidden { onReplaceRowChange?(true) }
        if replaceField.isEnabled {
            window?.makeFirstResponder(replaceField)
        }
    }

    /// 从外部创建整个搜索条件（当您从分析窗格中的表格单击“按此值筛选”时）。
    /// **呼叫者负责反映主要文本中的更改**（与 `setFilterOn` 的协议相同）。
    func setQuery(_ text: String, regex: Bool, caseSensitive: Bool, filter: Bool) {
        field.stringValue = text
        regexToggle.state = regex ? .on : .off
        noRegexToggle.state = regex ? .off : .on
        caseToggle.state = caseSensitive ? .on : .off
        setFilterOn(filter)
    }

    func prefillFromSelection(_ text: String) {
        field.stringValue = text
        onQueryChange?(text)
    }

    /// 如果  / `capped` 为真，则总数在上限处截断，下限为“N 或更多”。
    /// 如果您只是简单地将终止的项目数声明为“N 个项目”，那么您声明的数字实际上会小于实际数量。
    ///
    /// **扫描进行中，进度将显示在商品数量之后。**（修订于 2026-09-05）
    /// 之前，当搜索结果为 `total == 0` 时，只会显示“正在搜索... N%”，所以即使只找到一个结果……
    /// 它立即切换到“13 件商品”，即使扫描仍在进行中，看起来也已确认。
    /// 对于大文件，条目数量持续增加，但没有迹象表明这种情况会结束。
    ///（“我不知道什么时候结束”）。如果同时显示案件数量和进度，
    /// **进度指示器消失时，即表示游戏结束。**
    func setCount(current: Int, total: Int, searching: Bool, progress: Int,
                  invalid: Bool, capped: Bool = false) {
        countLabel.stringValue = Self.countText(query: query, current: current, total: total,
                                                searching: searching, progress: progress,
                                                invalid: invalid, capped: capped)
    }

    /// 要显示的文本（设计为可与 UI 分开测试）。
    static func countText(query: String, current: Int, total: Int, searching: Bool,
                          progress: Int, invalid: Bool, capped: Bool) -> String {
        let fmt = { (n: Int) in NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
        if query.isEmpty { return "" }
        if invalid { return L("search.invalid") }
        if total == 0 {
            return searching ? L("search.searching", progress) : L("search.none")
        }
        // 扫描时未显示“商品编号”。**扫描条宽度不足，末端被截断。**
        // （右括号消失了，显示为“2 of 1,365,193 results (0% searching)”）。
        // 我想知道的是“已经找到了多少个”和“还剩下多少个”。
        // 启动后您才能知道它的编号。
        if searching {
            let found = capped ? L("search.foundCapped", fmt(total)) : L("search.found", fmt(total))
            return L("search.stillSearching", found, progress)
        }
        if current == 0 {
            return capped ? L("search.foundCapped", fmt(total)) : L("search.found", fmt(total))
        }
        return capped ? L("search.countCapped", fmt(current), fmt(total))
                      : L("search.count", fmt(current), fmt(total))
    }

    // MARK: - 事件

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(field.stringValue)
    }

    @objc private func enterPressed() {
        // 从“最近搜索”菜单中选择时，只有 stringValue 会发生变化。
        // controlTextDidChange (=onQueryChange) 将不会发送。在此明确说明。
        // 如果您不进行同步，则显示的文字和搜索框中实际的文字将不同步。
        // （搜索栏显示了选中的单词，但搜索结果仍然是前一个单词的；这是故障。）
        onQueryChange?(field.stringValue)
        rememberRecentSearch()
        // Shift+Enter 继续前进。
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrev?() } else { onNext?() }
    }

    /// 将已确认的搜索词添加到历史记录的顶部（最新的在前，没有重复项，上限为 `maximumRecents`）。
    /// 分配给  / `recentSearches` 将通过 `recentsAutosaveName` 将其保存到用户默认值。
    /// “最近搜索”菜单更新由 AppKit 处理。
    private func rememberRecentSearch() {
        guard findHistoryAutoSave else { return }
        let term = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let recents = [term] + field.recentSearches.filter { $0 != term }
        field.recentSearches = Self.uniqueRecentSearches(recents, limit: field.maximumRecents)
    }
    @objc private func nextTapped() { rememberRecentSearch(); onNext?() }
    @objc private func prevTapped() { rememberRecentSearch(); onPrev?() }
    @objc private func closeTapped() { onClose?() }
    @objc private func caseTapped() {
        AppSettings.setFindOption(.matchCase, caseToggle.state == .on)
        onCaseToggle?(caseToggle.state == .on)
    }
    @objc private func regexTapped() {
        regexToggle.state = .on
        noRegexToggle.state = .off
        AppSettings.setFindOption(.regex, true)
        onRegexToggle?(true)
    }
    @objc private func noRegexTapped() {
        noRegexToggle.state = .on
        regexToggle.state = .off
        AppSettings.setFindOption(.regex, false)
        onRegexToggle?(false)
    }
    @objc private func optionTapped(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let option = FindOption(rawValue: rawValue) else { return }
        AppSettings.setFindOption(option, sender.state == .on)
    }
    @objc private func filterTapped() {
        syncContextEnabled()
        onFilterToggle?(filterToggle.state == .on)
    }
    @objc private func bookmarkTapped() {
        let want = bookmarkToggle.state == .on
        if want { filterToggle.state = .off; syncContextEnabled() }
        if onBookmarkToggle?(want) == false { bookmarkToggle.state = .off }
    }
    @objc private func contextEdited() {
        let n = min(max(0, Int(contextField.stringValue) ?? 0), FilterContext.maxContext)
        contextField.stringValue = n > 0 ? String(n) : ""   // 显示输入值四舍五入后的结果。
        onContextChange?(n)
    }
    @objc private func preserveCaseTapped() { onPreserveCaseToggle?(preserveCaseToggle.state == .on) }
    @objc private func replaceTapped() { onReplace?(replaceField.stringValue) }
    @objc private func replaceAllTapped() { onReplaceAll?(replaceField.stringValue) }
    @objc private func extractSegmentTapped(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { extractTapped() }
        else if sender.selectedSegment == 1 { extractOptionsTapped() }
    }
    @objc private func extractTapped() { rememberRecentSearch(); onExtract?() }
    @objc private func extractOptionsTapped() { onExtractOptions?() }
    @objc private func replaceExpandTapped() {
        replaceRow?.isHidden.toggle()
        onReplaceRowChange?(replaceRow?.isHidden == false)
    }

    /// 关闭栏时重置状态。
    func clear() {
        if replaceRow?.isHidden == false {
            replaceRow?.isHidden = true
            onReplaceRowChange?(false)
        }
        field.stringValue = ""
        replaceField.stringValue = ""
        caseToggle.state = .off
        regexToggle.state = .off
        noRegexToggle.state = .on
        filterToggle.state = .off
        bookmarkToggle.state = .off
        preserveCaseToggle.state = .off
        countLabel.stringValue = ""
        // 请勿删除  N 之前和之后的行（这些是应用程序记住的设置值，因此每次关闭应用程序时不要将其重置为 0）。
        syncContextEnabled()
    }

    /// 关闭  / Esc 的酒吧。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}
