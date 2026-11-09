import AppKit

/// 打开文档的垂直列表。
///
/// 在此窗口中，仅将 custom-draw 的最顶层子树合成到屏幕上。
/// macOS 存在一个错误（正文中的 DocumentView 就是其中之一）。因此，侧边栏
/// 它不是使用  / custom-draw，而是使用 layer 背景 + 控件（NSTextField 行）构建。
/// 将  / contentView 放置在最前面（与 StatusBar / SearchBar 的设计相同）。
final class SidebarView: NSView {
    var onSelect: ((Int) -> Void)?
    /// 请求单击行上的 × 关闭文档。
    var onClose: ((Int) -> Void)?

    private let stack = NSStackView()
    private var rows: [SidebarRow] = []

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // 最右侧分割线（子图层）
        let sep = CALayer()
        layer?.addSublayer(sep)
        separator = sep
        applyTheme()
    }

    private var separator: CALayer?
    override func layout() {
        super.layout()
        separator?.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTheme() }
    }

    /// 将配色方案（主题）应用于背景、分隔线和每一行。
    func applyTheme() {
        let theme = EditorTheme.current()
        layer?.backgroundColor = EditorTheme.withBackgroundOpacity(theme.chromeBackground).cgColor
        separator?.backgroundColor = theme.separator.cgColor
        rows.forEach { $0.applyTheme(theme) }
    }

    func reload(names: [String], dirty: [Bool], active: Int) {
        rows.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows.removeAll()
        for (i, name) in names.enumerated() {
            let row = SidebarRow()
            row.index = i
            row.label.stringValue = name
            row.onClick = { [weak self] idx in self?.onSelect?(idx) }
            row.onClose = { [weak self] idx in self?.onClose?(idx) }
            row.setActive(i == active)
            row.setDirty(i < dirty.count ? dirty[i] : false)
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right).isActive = true
            rows.append(row)
        }
    }

    func setActive(_ index: Int) {
        for (i, r) in rows.enumerated() { r.setActive(i == index) }
    }

    /// 更新指定行的未保存状态（每次编辑/保存时调用此函数。不会重新创建行）。
    func setDirty(_ index: Int, _ dirty: Bool) {
        guard index >= 0, index < rows.count else { return }
        rows[index].setDirty(dirty)
    }
}

/// 侧边栏行（layer 背景 + 未保存的点 + 标签 + 关闭按钮）。
final class SidebarRow: NSView {
    let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// 未保存指示器（最左侧的小点。保存时隐藏）。
    private let dirtyDot = NSView()
    var index = 0
    var onClick: ((Int) -> Void)?
    /// 请求使用 × 按钮关闭此行。
    var onClose: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.isHidden = true
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dirtyDot)

        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.setButtonType(.momentaryChange)
        closeButton.toolTip = L("sidebar.close")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            // 最左侧的固定列，用于存放未保存的点（始终保留，以防止名称的左侧位置因是否保存而发生偏移）。
            dirtyDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dirtyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 6),
            dirtyDot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dirtyDot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?(index) }
    @objc private func closeTapped() { onClose?(index) }

    private var isActive = false
    private var isDirty = false
    private var theme = EditorTheme.current()

    func setActive(_ active: Bool) {
        isActive = active
        restyle()
    }

    /// 反映未保存的状态（● 显示 + × 图标颜色变化）。
    func setDirty(_ dirty: Bool) {
        isDirty = dirty
        restyle()
    }

    /// 主题更改时替换颜色（保留选择和未保存状态）。
    func applyTheme(_ theme: EditorColorTheme) {
        self.theme = theme
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = (isActive ? theme.chromeActiveBackground : .clear).cgColor
        // 为便于阅读，名称保持其原有颜色。未保存的项目用●和×以强调色进行颜色编码。
        label.textColor = isActive ? theme.chromeActiveText : theme.chromeText
        dirtyDot.isHidden = !isDirty
        dirtyDot.layer?.backgroundColor = theme.dirtyIndicator.cgColor
        closeButton.image = NSImage(
            systemSymbolName: isDirty ? "xmark.circle.fill" : "xmark.circle",
            accessibilityDescription: L("sidebar.close"))
        closeButton.contentTintColor = isDirty ? theme.dirtyIndicator
                                               : (isActive ? theme.chromeActiveText : theme.chromeSecondaryText)
    }
}
