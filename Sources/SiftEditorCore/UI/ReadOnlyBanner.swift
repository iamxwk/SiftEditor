import AppKit

/// 一个小横幅，指示正在以只读模式打开一个大文件。
/// `MainWindowController` 浮动在主文本区域的左上角，可以用 × 按钮关闭。
final class ReadOnlyBanner: NSView {
    /// 当你按下 × 时。
    var onClose: (() -> Void)?

    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: L("readonly.banner"))

    /// 为什么我无法编辑？**措辞会根据原因而变化**——“太大”会被过滤掉或
    /// JSON 如果在现场询问时将其包含在一个小文件中，它就会立即变成谎言。
    /// 被误认为是“一个漏洞”（正如用户指出的那样）
    enum Reason {
        case tooLarge
        case filtered
        case jsonQuery

        var messageKey: String {
            switch self {
            case .tooLarge:  return "readonly.banner"
            case .filtered:  return "readonly.banner.filter"
            case .jsonQuery: return "readonly.banner.jsonQuery"
            }
        }
    }

    var reason: Reason = .tooLarge {
        didSet { label.stringValue = L(reason.messageKey) }
    }

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
        layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.30).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

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
        addSubview(close)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    /// 由于这是一个悬浮在正文上方的横幅，因此背景应该是**不透明的**（如果是半透明的，下面的文字就会透出来，变得无法阅读）。
    /// 将 16% 的强调色混合到主题的背景色中，使其不透明，同时保持其亮度。
    private func applyBackground() {
        let base = EditorTheme.current().background
        let tinted = base.blended(withFraction: 0.16, of: .systemYellow) ?? base
        layer?.backgroundColor = tinted.withAlphaComponent(1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { applyBackground() }
    }

    @objc private func closeTapped() { onClose?() }
}
