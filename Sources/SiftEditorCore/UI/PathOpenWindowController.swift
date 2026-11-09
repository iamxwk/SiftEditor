import AppKit

/// “通过指定路径打开...”(⌥⌘O)。本地路径可从终端复制，或由 AI 回答。
/// 一个用于粘贴和打开的小窗口。其目的并非追求原创性，而是方便用户毫不犹豫地打开路径。
///
/// 交接文件夹时，打开文件夹窗口（树状结构）。负责打开窗口的人员 (`folderHandler`)
/// 如果未提供，则照常显示 Finder。
final class PathOpenWindowController: NSWindowController {

    private let pathField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let openHandler: (URL) -> Void
    private let folderHandler: ((URL) -> Void)?

    init(openHandler: @escaping (URL) -> Void, folderHandler: ((URL) -> Void)? = nil) {
        self.openHandler = openHandler
        self.folderHandler = folderHandler
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 110),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("pathOpen.title")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("不使用 init(coder:)") }

    /// 将窗口置于前台（如果窗口不存在，则重用现有窗口）。每次调用时清除输入字段。
    func show() {
        pathField.stringValue = ""
        errorLabel.stringValue = ""
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(pathField)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        pathField.placeholderString = L("pathOpen.placeholder")
        pathField.target = self
        pathField.action = #selector(openTapped)
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        let openButton = NSButton(title: L("pathOpen.open"), target: self, action: #selector(openTapped))
        openButton.keyEquivalent = "\r"

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)

        let row = NSStackView(views: [pathField, openButton])
        row.orientation = .horizontal
        row.spacing = 8

        let stack = NSStackView(views: [row, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
    }

    @objc private func openTapped() {
        guard let url = Self.resolve(pathField.stringValue) else {
            errorLabel.stringValue = L("pathOpen.notFound")
            return
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            if let folderHandler { folderHandler(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } else {
            openHandler(url)
        }
        window?.performClose(nil)
    }

    /// 输入字符串应为现有文件/文件夹的 URL。如果不存在，则使用 nil。
    /// 删除复制时添加的前导空格、尾随空格和外引号（仅一组），并展开 `~`。
    /// 不支持相对路径（GUI 应用程序中的 cwd 实际上会变成 `/`，而不是引用）。
    static func resolve(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2 {
            let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")]
            for (open, close) in pairs where s.first == open && s.last == close {
                s = String(s.dropFirst().dropLast())
                break
            }
        }
        s = (s as NSString).expandingTildeInPath
        guard !s.isEmpty, FileManager.default.fileExists(atPath: s) else { return nil }
        return URL(fileURLWithPath: s)
    }
}
