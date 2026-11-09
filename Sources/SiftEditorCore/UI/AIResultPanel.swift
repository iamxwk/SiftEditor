import AppKit

/// Escape 的只读文本视图，用于检测取消操作（即关闭面板）。
private final class AIResultTextView: NSTextView {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 用于拖动标题栏并移动面板（窗口）的拖动区域。此功能由 `performDrag` 处理。
/// 可以移动到屏幕上的任何位置，甚至可以移动到应用程序窗口之外。当放置在按钮上时，按钮会优先触发事件。
/// 这只响应标题边距 = 它不会干扰选择文本或操作按钮。
private final class DragHeaderView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// 一个浮动面板，即使没有框架也可以作为关键窗口使用（将 Escape 传递给文本视图）。
final class AIPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// **永久驻留且可移动的**工具面板，显示在查看器上，提供对  / AI 的一次性分析（错误原因估计）。
///
/// 显示后，请保持显示状态（按✕ / Esc关闭）。拖动标题栏即可移动它。使用标题栏中的“分析”按钮。
/// 每次都会分析当前选中的文本。背景采用磨砂玻璃效果，使其与主文本（主题配色方案）区分开来。
/// custom draw() 不存在（为避免综合错误）。
final class AIResultPanel: NSView {
    static let width: CGFloat = 480
    static let height: CGFloat = 300

    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let analyzeButton = NSButton()
    private let copyButton = NSButton()
    private let closeButton = NSButton()
    private let divider = NSBox()
    private let scroll = NSScrollView()
    private let textView = AIResultTextView()

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onAnalyze: (() -> Void)?

    /// 当前是否正在显示流（接受差异添加）？
    private var isStreaming = false
    /// 该流尚未收到任何文本字符（即，它仍然显示“正在查询...”）。
    private var streamIsEmpty = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // 窗户（NSPanel.hasShadow）投射的阴影，因此未包含在此处。
        // 磨砂玻璃背景（圆角夹）。
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        // 标头：✦ AI（重音符号）+ 解析 / 复制 / 关闭。
        let spark = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        spark.contentTintColor = .controlAccentColor
        spark.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.stringValue = L("ai.menu.title")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        analyzeButton.title = L("ai.panel.analyze")
        analyzeButton.bezelStyle = .rounded
        analyzeButton.controlSize = .small
        analyzeButton.font = .systemFont(ofSize: 11, weight: .medium)
        analyzeButton.keyEquivalent = "\r"   // 如果面板处于聚焦状态，请使用 Return 进行分析
        analyzeButton.target = self
        analyzeButton.action = #selector(analyzeTapped)
        analyzeButton.setContentHuggingPriority(.required, for: .horizontal)

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("ai.panel.copy"))
        copyButton.toolTip = L("ai.panel.copy")
        styleIconButton(copyButton, action: #selector(copyTapped))
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("ai.panel.close"))
        closeButton.toolTip = L("ai.panel.close")
        styleIconButton(closeButton, action: #selector(closeTapped))

        let headerRow = NSStackView(views: [spark, titleLabel, spinner, analyzeButton, copyButton, closeButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 7
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let header = DragHeaderView()
        header.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor),
            headerRow.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        divider.boxType = .separator

        // 本文。
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.onCancel = { [weak self] in self?.onClose?() }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true      // 仅在需要时取出
        scroll.scrollerStyle = .overlay       // 叠加层类型（占用宽度不大，并非始终显示）
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let stack = NSStackView(views: [header, divider, scroll])
        stack.orientation = .vertical
        stack.spacing = 9
        stack.distribution = .fill
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 15, bottom: 13, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -27),
            divider.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: header.widthAnchor),
        ])
    }

    private func styleIconButton(_ b: NSButton, action: Selector) {
        b.isBordered = false
        b.bezelStyle = .smallSquare
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = .secondaryLabelColor
        b.target = self
        b.action = action
        b.setContentHuggingPriority(.required, for: .horizontal)
    }

    func applyTheme() {
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyTheme() }
    }

    // MARK: - 状態

    /// 查询进行中（加载指示器 + “查询进行中……”）。文本已隐藏。聚焦于 Escape。
    func showThinking() {
        isStreaming = false
        spinner.startAnimation(nil)
        copyButton.isHidden = true
        setBody(L("ai.panel.thinking"), color: .secondaryLabelColor)
        window?.makeFirstResponder(textView)
    }

    /// 流式传输已启动。正在等待“正在查询...”直到收到第一个差异。
    func beginStreaming() {
        showThinking()
        isStreaming = true
        streamIsEmpty = true
    }

    /// 将收到的差值添加到末尾。如果您向上滚动阅读，请勿移动此行。
    func appendStreamDelta(_ chunk: String) {
        guard isStreaming, !chunk.isEmpty else { return }
        if streamIsEmpty {                       // 将 “查询进行中……”替换为正文。
            setBody("", color: .labelColor)
            streamIsEmpty = false
        }
        let follow = isScrolledToBottom
        textView.textStorage?.append(NSAttributedString(string: chunk,
                                                        attributes: Self.bodyAttributes(color: .labelColor)))
        if follow { textView.scrollToEndOfDocument(nil) }
    }

    /// 流已成功完成。停止加载指示器并创建副本（主要文本保持不变）。
    func finishStreaming() {
        isStreaming = false
        spinner.stopAnimation(nil)
        copyButton.isHidden = false
    }

    func showResult(_ text: String) {
        isStreaming = false
        spinner.stopAnimation(nil)
        copyButton.isHidden = false
        setBody(text, color: .labelColor)
        window?.makeFirstResponder(textView)
    }

    /// 故障。当视频流中途崩溃时，保留崩溃点之前的文本，并添加红色文本。
    /// (请勿删除已读取的部分)。
    func showError(_ message: String) {
        let hadPartialText = isStreaming && !streamIsEmpty
        isStreaming = false
        spinner.stopAnimation(nil)
        copyButton.isHidden = !hadPartialText
        if hadPartialText {
            textView.textStorage?.append(errorText("\n\n" + message))
            textView.scrollToEndOfDocument(nil)
        } else {
            textView.textStorage?.setAttributedString(errorText(message))
            textView.scrollToBeginningOfDocument(nil)
        }
        window?.makeFirstResponder(textView)
    }

    /// 如何显示故障：**第 1 行 = 系统语言**（发生的情况），以红色显示，提供商的原始文本（英文）为：
    /// 保持简洁隐蔽，仅作线索。删除原文将使调查无法进行。
    private func errorText(_ message: String) -> NSAttributedString {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let out = NSMutableAttributedString(string: parts[0], attributes: Self.bodyAttributes(color: .systemRed))
        if parts.count > 1, !parts[1].isEmpty {
            var detail = Self.bodyAttributes(color: .secondaryLabelColor)
            detail[.font] = NSFont.systemFont(ofSize: 11)
            out.append(NSAttributedString(string: "\n" + parts[1], attributes: detail))
        }
        return out
    }

    /// 未进行选择时，会显示一个淡淡的提示（不是红色）。
    func showHint(_ text: String) {
        isStreaming = false
        spinner.stopAnimation(nil)
        copyButton.isHidden = true
        setBody(text, color: .secondaryLabelColor)
        window?.makeFirstResponder(textView)
    }

    /// 正文外观（可读行距和段落间距）。即使是不同的新增内容，也请使用相同的设置。
    private static func bodyAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        return [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    /// 替换文本。
    private func setBody(_ text: String, color: NSColor) {
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: Self.bodyAttributes(color: color)))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// 现在可以查看结果了吗（即，可以跟踪差异了吗）？
    private var isScrolledToBottom: Bool {
        guard let document = scroll.documentView else { return true }
        let visible = scroll.contentView.documentVisibleRect
        return visible.maxY >= document.bounds.maxY - 4
    }

    var bodyText: String { textView.string }

    @objc private func analyzeTapped() { onAnalyze?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func closeTapped() { onClose?() }
}
