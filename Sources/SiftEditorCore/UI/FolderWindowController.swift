import AppKit

/// 一个允许您浏览本地文件夹的窗口。展开树状结构，按名称筛选，双击即可打开文件。
///
/// 内容与远程窗口 `FileTreeView` 相同（唯一的区别是本地窗口调用 `FileManager`，而远程窗口调用 ssh）。
/// 文件将在主窗口中打开——此窗口用于**选择**，而不是编辑。
final class FolderWindowController: NSWindowController, NSWindowDelegate {

    let folderURL: URL
    private let tree = FileTreeView(provider: LocalDirectoryProvider())
    private let statusLabel = NSTextField(labelWithString: "")
    private let openHandler: (URL) -> Void
    private let onClose: (FolderWindowController) -> Void

    init(folderURL: URL, openHandler: @escaping (URL) -> Void, onClose: @escaping (FolderWindowController) -> Void) {
        self.folderURL = folderURL
        self.openHandler = openHandler
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = (folderURL.path as NSString).abbreviatingWithTildeInPath
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        super.init(window: window)
        window.delegate = self
        window.center()
        build()
        tree.setRoot(path: folderURL.path)
    }

    required init?(coder: NSCoder) { fatalError("不使用 init(coder:)") }

    private func build() {
        guard let content = window?.contentView else { return }
        tree.onOpenFile = { [weak self] node in self?.openHandler(URL(fileURLWithPath: node.path)) }
        tree.onStatus = { [weak self] text in self?.statusLabel.stringValue = text }
        tree.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tree)
        NSLayoutConstraint.activate([
            tree.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tree.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            tree.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tree.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        // 的状态显示在树状组件下方的标签上，因此不会在此窗口中显示两次。
        statusLabel.isHidden = true
        window?.initialFirstResponder = nil
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        tree.focusFilter()
    }

    func windowWillClose(_ notification: Notification) { onClose(self) }
}
