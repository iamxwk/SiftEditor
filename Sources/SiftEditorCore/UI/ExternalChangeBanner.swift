import AppKit

/// 一个小横幅，显示“此文件已在其他地方修改”。
///
/// 自动加载失败（存在未保存的更改 / 由于格式或筛选，主要文本已被替换）
/// 仅在  中显示（自动加载关闭时）。浮动于主文本区域底部边缘：
/// 顶部边缘已被搜索栏、只读横幅和结构化横幅占据。
final class ExternalChangeBanner: NSView {
    /// 当按下“加载”键时。
    var onReload: (() -> Void)?
    /// 当你按下 × 时。
    var onClose: (() -> Void)?

    static let height: CGFloat = 26

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
        applyBackground()
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.30).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.arrow.circlepath", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L("external.banner"))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let reload = NSButton(title: L("external.reload"), target: self, action: #selector(reloadTapped))
        reload.bezelStyle = .rounded
        reload.controlSize = .small
        reload.font = .systemFont(ofSize: 11)
        reload.translatesAutoresizingMaskIntoConstraints = false
        reload.setContentHuggingPriority(.required, for: .horizontal)

        let close = NSButton()
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isBordered = false
        close.bezelStyle = .inline
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("common.cancel"))
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)

        addSubview(icon)
        addSubview(label)
        addSubview(reload)
        addSubview(close)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            reload.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            reload.centerYAnchor.constraint(equalTo: centerYAnchor),

            close.leadingAnchor.constraint(equalTo: reload.trailingAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    /// 此横幅将出现在正文上方，因此背景应该是**不透明的**（如果背景是半透明的，下面的文字就会透出来，变得无法阅读）。
    private func applyBackground() {
        let base = EditorTheme.current().background
        let tinted = base.blended(withFraction: 0.16, of: .systemOrange) ?? base
        layer?.backgroundColor = tinted.withAlphaComponent(1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    @objc private func reloadTapped() { onReload?() }
    @objc private func closeTapped() { onClose?() }
}