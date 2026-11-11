import AppKit

/// 底部状态栏。显示字符编码、行数、文件大小和索引进度。
final class StatusBarView: NSView {
    static let height: CGFloat = 24

    private let label = NSTextField(labelWithString: "")
    var onSyntaxChosen: ((EditorSyntax) -> Void)?
    var onEncodingChosen: ((DetectedEncoding) -> Void)?
    var onLineEndingChosen: ((LineEnding) -> Void)?

    private let syntaxPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let endingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var optionsStack: NSStackView = {
        let stack = NSStackView(views: [syntaxPopup, encodingPopup, endingPopup])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            syntaxPopup.widthAnchor.constraint(equalToConstant: 120),
            encodingPopup.widthAnchor.constraint(equalToConstant: 105),
            endingPopup.widthAnchor.constraint(equalToConstant: 95),
        ])
        return stack
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// 顶部的分割线（在子图层上绘制，未使用 draw()）。
    private let separator = CALayer()

    private func setup() {
        // 背景和分割线绘制在图层上，未使用 custom draw()。
        // 如果自定义 draw() 的视图包含子控件，
        // 同一窗口中的另一个自定义绘图视图 (LargeFileViewer/DocumentView)
        // 避免屏幕合成损坏的 macOS 错误。
        wantsLayer = true
        layer?.addSublayer(separator)

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setupOptions()
        applyTheme()
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: optionsStack.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setPlaceholder()
    }

    private func setupOptions() {
        for popup in [syntaxPopup, encodingPopup, endingPopup] {
            popup.controlSize = .mini
            popup.font = .systemFont(ofSize: 11)
            popup.isBordered = false
        }
        for syntax in EditorSyntax.allCases {
            syntaxPopup.addItem(withTitle: syntax.title)
            syntaxPopup.lastItem?.representedObject = syntax.rawValue
        }
        for encoding in DetectedEncoding.selectable {
            encodingPopup.addItem(withTitle: encoding.displayName)
            encodingPopup.lastItem?.representedObject = encoding.displayName
        }
        for ending in [LineEnding.lf, .crlf, .cr] {
            endingPopup.addItem(withTitle: ending.displayName)
            endingPopup.lastItem?.representedObject = ending.displayName
        }
        syntaxPopup.target = self; syntaxPopup.action = #selector(syntaxChosen)
        encodingPopup.target = self; encodingPopup.action = #selector(encodingChosen)
        endingPopup.target = self; endingPopup.action = #selector(endingChosen)
        optionsStack.isHidden = true
    }

    func setDocumentOptions(syntax: EditorSyntax?, encoding: DetectedEncoding?, ending: LineEnding?,
                            canChangeSyntax: Bool, canChangeEncoding: Bool, canChangeEnding: Bool) {
        optionsStack.isHidden = syntax == nil || isShowingMessage && onCancel != nil
        guard let syntax, let encoding, let ending else { return }
        syntaxPopup.selectItem(withTitle: syntax.title)
        encodingPopup.selectItem(withTitle: encoding.displayName)
        endingPopup.selectItem(withTitle: ending.displayName)
        syntaxPopup.isEnabled = canChangeSyntax
        encodingPopup.isEnabled = canChangeEncoding
        endingPopup.isEnabled = canChangeEnding
    }

    @objc private func syntaxChosen() {
        guard let raw = syntaxPopup.selectedItem?.representedObject as? String,
              let syntax = EditorSyntax(rawValue: raw) else { return }
        onSyntaxChosen?(syntax)
    }
    @objc private func encodingChosen() {
        let index = encodingPopup.indexOfSelectedItem
        guard DetectedEncoding.selectable.indices.contains(index) else { return }
        onEncodingChosen?(DetectedEncoding.selectable[index])
    }
    @objc private func endingChosen() {
        let endings: [LineEnding] = [.lf, .crlf, .cr]
        let index = endingPopup.indexOfSelectedItem
        guard endings.indices.contains(index) else { return }
        onLineEndingChosen?(endings[index])
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // 顶部的分割线，1px。
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // cgColor 不跟随外观变化，因此需要显式重置。
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTheme() }
    }

    /// 将配色方案（主题）应用于背景、分隔线和标签。
    func applyTheme() {
        let theme = EditorTheme.current()
        layer?.backgroundColor = EditorTheme.withBackgroundOpacity(theme.chromeBackground).cgColor
        separator.backgroundColor = theme.separator.cgColor
        label.textColor = theme.chromeSecondaryText
    }

    func setPlaceholder() {
        guard !isShowingMessage else { return }
        label.stringValue = L("status.placeholder")
    }

    /// 显示临时消息（例如，正在保存 N%）。忽略 `update`/`setPlaceholder`，直到消息被删除。
    private var isShowingMessage = false
    private var onCancel: (() -> Void)?

    /// 导航列数不匹配（上一页、下一页、计数标签）。
    var onMismatchNext: (() -> Void)?
    var onMismatchPrev: (() -> Void)?

    private let mismatchPrevButton = NSButton(title: "◀︎", target: nil, action: nil)
    private let mismatchLabelButton = NSButton(title: "", target: nil, action: nil)
    private let mismatchNextButton = NSButton(title: "▶︎", target: nil, action: nil)

    private lazy var mismatchStack: NSStackView = {
        setupMismatchNavButton(mismatchPrevButton, action: #selector(mismatchPrevTapped), tip: L("status.tip.previousMismatch"))
        setupMismatchNavButton(mismatchNextButton, action: #selector(mismatchNextTapped), tip: L("status.tip.nextMismatch"))

        mismatchLabelButton.bezelStyle = .inline
        mismatchLabelButton.controlSize = .small
        mismatchLabelButton.font = .systemFont(ofSize: 11, weight: .semibold)
        mismatchLabelButton.contentTintColor = .systemOrange
        mismatchLabelButton.toolTip = L("status.tip.nextColumnMismatch")
        mismatchLabelButton.target = self
        mismatchLabelButton.action = #selector(mismatchNextTapped)

        let stack = NSStackView(views: [mismatchPrevButton, mismatchLabelButton, mismatchNextButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: optionsStack.leadingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return stack
    }()

    private func setupMismatchNavButton(_ btn: NSButton, action: Selector, tip: String) {
        btn.bezelStyle = .inline
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 10, weight: .bold)
        btn.contentTintColor = .systemOrange
        btn.toolTip = tip
        btn.target = self
        btn.action = action
    }

    func setMismatchCount(_ count: Int) {
        if count > 0 {
            mismatchLabelButton.title = "⚠️ 列数不一致: \(count)行"
            mismatchStack.isHidden = false
        } else {
            mismatchStack.isHidden = true
        }
    }

    @objc private func mismatchNextTapped() { onMismatchNext?() }
    @objc private func mismatchPrevTapped() { onMismatchPrev?() }

    private lazy var cancelButton: NSButton = {
        let b = NSButton(title: L("common.cancel"), target: self, action: #selector(cancelTapped))
        b.bezelStyle = .inline
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.isHidden = true
        b.translatesAutoresizingMaskIntoConstraints = false
        addSubview(b)
        NSLayoutConstraint.activate([
            b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            b.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return b
    }()

    func showMessage(_ text: String) {
        isShowingMessage = true
        label.stringValue = text
    }

    /// 显示带有取消按钮的保存消息（进度模式 A）。
    func showSaving(_ text: String, onCancel: @escaping () -> Void) {
        isShowingMessage = true
        label.stringValue = text
        self.onCancel = onCancel
        cancelButton.isHidden = false
        optionsStack.isHidden = true
    }
    /// 仅更新已保存消息的文本。
    func updateSaving(_ text: String) {
        guard isShowingMessage else { return }
        label.stringValue = text
    }
    @objc private func cancelTapped() { onCancel?() }

    /// 禁用临时消息（下次 `update` 时恢复正常显示）。
    func clearMessage() {
        isShowingMessage = false
        onCancel = nil
        cancelButton.isHidden = true
        optionsStack.isHidden = false
    }

    static func searchSelectAllText(_ result: SearchSelectAllOutcome, progress: Int = 0) -> String {
        switch result {
        case .selectedMatches(let count): return L("search.selectAll.selectedMatches", formatNumber(count))
        case .selectedLines(let count): return L("search.selectAll.selectedLines", formatNumber(count))
        case .pending: return L("search.selectAll.searching", progress)
        case .noMatches: return L("search.selectAll.noMatches")
        case .capped: return L("search.selectAll.capped")
        case .unavailable: return L("search.selectAll.unavailable")
        }
    }

    func update(_ state: ViewerState) {
        guard !isShowingMessage else { return }
        let lines = Self.formatNumber(state.lineCount)
        let lineLabel = state.lineCountIsExact ? L("status.lines", lines) : L("status.linesApprox", lines)
        var text = "\(state.encodingName)    \(lineLabel)"
        // 字符计数（用于检查帖子 SNS 的字符数）。如果已选中，请选择“选择/全部”。
        if let c = state.charCount {
            text += "    " + (c.selected > 0
                ? L("status.charsSelected", Self.formatNumber(c.selected), Self.formatNumber(c.total))
                : L("status.chars", Self.formatNumber(c.total)))
        }
        // 仅当大小有意义时才会显示大小（因为 diff 有两个文件，左侧和右侧，“0 B”为假）。
        if state.fileSize > 0 { text += "    \(Self.formatBytes(state.fileSize))" }
        // 光标位置（行:列）。仅当光标存在时显示。
        if let caret = state.caret {
            text += "    " + L("status.caret", Self.formatNumber(caret.line), Self.formatNumber(caret.column))
        }
        if !state.lineCountIsExact {
            let pct = Int(state.indexProgress * 100)
            text += "    " + L("status.indexing", pct)
        }
        label.stringValue = text
    }

    private static func formatNumber(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }
        if i == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[i])
    }
}
