import AppKit

/// 用于在结构化视图中直接编辑相关行的内联编辑栏 (CSV/TSV)。
///
/// 它会平滑地直接出现在相关行的上方，您可以直接使用键盘编辑原始的逗号分隔文本，并使用 Enter 立即反映更改。
final class LineEditorBar: NSVisualEffectView, NSTextFieldDelegate {

    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let lineBadge = NSTextField(labelWithString: "")
    private let textField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "Return: 確定  Esc: 取消")
    private let saveButton = NSButton(title: "確定", target: nil, action: nil)
    private let cancelButton = NSButton(title: "✕", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.controlAccentColor.cgColor

        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
        shadow?.shadowBlurRadius = 8

        lineBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        lineBadge.textColor = .controlAccentColor
        lineBadge.setContentHuggingPriority(.required, for: .horizontal)

        textField.font = EditorFont.current()
        textField.focusRingType = .none
        textField.isBordered = false
        textField.drawsBackground = false
        textField.delegate = self
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.font = .systemFont(ofSize: 11, weight: .medium)
        saveButton.target = self
        saveButton.action = #selector(commitTapped)
        saveButton.keyEquivalent = "\r"
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        cancelButton.bezelStyle = .inline
        cancelButton.isBordered = false
        cancelButton.font = .systemFont(ofSize: 11)
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            lineBadge,
            textField,
            hintLabel,
            saveButton,
            cancelButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 8)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 开始编辑。
    func beginEdit(line: Int, text: String) {
        lineBadge.stringValue = "\(line)行目:"
        textField.stringValue = text
        textField.selectText(nil)
        window?.makeFirstResponder(textField)
    }

    @objc private func commitTapped() {
        onCommit?(textField.stringValue)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    // 处理  Esc 和 Return 密钥
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            cancelTapped()
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            commitTapped()
            return true
        }
        return false
    }
}
