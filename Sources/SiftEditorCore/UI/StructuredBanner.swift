import AppKit

/// 仅在启用结构化显示（CSV/TSV/NDJSON 对齐）时，才会出现在文本左上角的横幅。
///
/// 明确说明“此内容仅供展示，只读，可随时撤销”。
/// 一个令人安心的元素，以防止误解“它可能被保存时带有竖线”。
final class StructuredBanner: NSView {
    /// 按下“撤销”键时。
    var onRevert: (() -> Void)?
    /// 查看预设入口点。SiftEditor 显示此功能未实现。
    var onPresetTapped: (() -> Void)?

    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")
    private let presetButton = NSButton(title: "", target: nil, action: nil)
    private let revertButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        applyBackground()
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.32).cgColor
        toolTip = L("structured.hint")

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        revertButton.title = L("structured.revert")
        revertButton.bezelStyle = .rounded
        revertButton.controlSize = .small
        revertButton.font = .systemFont(ofSize: 11)
        revertButton.translatesAutoresizingMaskIntoConstraints = false
        revertButton.setContentHuggingPriority(.required, for: .horizontal)
        revertButton.target = self
        revertButton.action = #selector(revertTapped)

        presetButton.title = L("structured.presetsButton") + " *"
        presetButton.isEnabled = false
        presetButton.bezelStyle = .rounded
        presetButton.controlSize = .small
        presetButton.font = .systemFont(ofSize: 11)
        presetButton.translatesAutoresizingMaskIntoConstraints = false
        presetButton.setContentHuggingPriority(.required, for: .horizontal)
        presetButton.target = self
        presetButton.action = #selector(presetTapped)

        addSubview(icon); addSubview(label); addSubview(presetButton); addSubview(revertButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            presetButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            presetButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            revertButton.leadingAnchor.constraint(equalTo: presetButton.trailingAnchor, constant: 8),
            revertButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            revertButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// 反映模式名称 (CSV/TSV/NDJSON)。**预设按钮在 fixedWidth 中隐藏。**
    /// （由于排序和 B19 不是受支持的模式，因此没有地方可以保存和重用它们）。
    func configure(mode: StructuredMode) {
        label.stringValue = L("structured.banner") + " · " + mode.displayName
        presetButton.isHidden = (mode == .fixedWidth)
        applyBackground()   // 主题可能会更改。
    }

    /// 由于这是一个漂浮在主文本之上的条带，因此背景必须是**不透明的**。
    /// 当设置为半透明 (alpha 0.16) 时，下面的线条会变得透明，并与横幅上的文字重叠，导致两者都无法阅读。
    /// 为了保持低调的外观，我将使用一种不透明的颜色，这种颜色是通过将 16% 的强调色与主题的背景色混合而创建的。
    private func applyBackground() {
        let base = EditorTheme.current().background
        let tinted = base.blended(withFraction: 0.16, of: .systemTeal) ?? base
        layer?.backgroundColor = tinted.withAlphaComponent(1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    @objc private func revertTapped() { onRevert?() }
    @objc private func presetTapped() { onPresetTapped?() }
}
