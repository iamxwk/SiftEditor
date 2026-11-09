import AppKit

/// 文件夹树（可展开）以及用于按名称筛选和打开的字段。**本地窗口和远程窗口均使用同一组件。**
///
/// - 每次展开时，仅读取其正下方的内容（不扫描整个内容）。远程传输时，需要进行一次 ssh 的往返。
/// - 在上面的字段中输入一个单词，然后使用 Enter 搜索并列出文件名中包含该单词的文件，从起始点下方开始。
/// 不读取文件正文。将此字段留空并按 Enter 返回树状结构。
/// - 双击（或 Return）打开文件。打开和关闭文件夹。
final class FileTreeView: NSView {

    private let filterField = NSSearchField()
    private let outline = FileOutlineView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var provider: DirectoryProvider
    private var root: FileNode?
    /// 名称搜索结果。当名称为 `nil` 时，将显示树状结构。
    private var results: [FileNode]?
    /// 用于丢弃旧响应的生成（当您重新输入搜索时，先前的结果不会稍后出现并覆盖旧的结果）。
    private var searchGeneration = 0

    private let work = DispatchQueue(label: "sifteditor.filetree", qos: .userInitiated)

    /// 打开文件。
    var onOpenFile: ((FileNode) -> Void)?
    /// 状态描述（显示在窗口下方的标签上）。
    var onStatus: ((String) -> Void)?

    init(provider: DirectoryProvider) {
        self.provider = provider
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("不使用 init(coder:)") }

    // MARK: - 组件

    private func build() {
        filterField.placeholderString = L("tree.filterPlaceholder")
        filterField.toolTip = L("tree.filterHelp")
        filterField.target = self
        filterField.action = #selector(runFilter)
        filterField.sendsSearchStringImmediately = false

        let column = NSTableColumn(identifier: .init("name"))
        column.title = L("tree.column")
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 20
        outline.style = .sourceList
        outline.allowsMultipleSelection = false
        outline.target = self
        outline.doubleAction = #selector(activateSelection)
        outline.onReturn = { [weak self] in self?.activateSelection() }

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        let bottom = NSStackView(views: [statusLabel, spinner])
        bottom.orientation = .horizontal
        bottom.spacing = 6

        let stack = NSStackView(views: [filterField, scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        filterField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    // MARK: - 起点

    /// 放置起始文件夹，并直接阅读其下方的内容。
    func setRoot(path: String, displayName: String? = nil, provider newProvider: DirectoryProvider? = nil) {
        if let newProvider { provider = newProvider }
        searchGeneration += 1
        filterField.stringValue = ""
        results = nil
        let node = FileNode(name: displayName ?? path, path: path, isDirectory: true)
        root = node
        outline.reloadData()
        load(node, thenExpand: true)
    }

    /// 聚焦于名称搜索输入字段。
    func focusFilter() { window?.makeFirstResponder(filterField) }

    // MARK: - 加载

    /// 请阅读下方背景文字，完成后再插入。**阅读完毕后，剧情将会展开。**
    private func load(_ node: FileNode, thenExpand: Bool = false) {
        guard !node.isLoading else { return }
        node.isLoading = true
        spin(true)
        let provider = self.provider
        work.async { [weak self] in
            let outcome = Result { try provider.list(node.path) }
            DispatchQueue.main.async {
                guard let self else { return }
                node.isLoading = false
                self.spin(false)
                switch outcome {
                case .success(let r):
                    node.children = r.nodes
                    node.truncated = r.truncated
                    // 根目录是 `outline` 的顶层目录，因此整个目录将被重新创建，但中间文件夹只会为其各自的子文件夹重新创建。
                    if node === self.root { self.outline.reloadData() } else { self.outline.reloadItem(node, reloadChildren: true) }
                    if thenExpand, node !== self.root { self.outline.expandItem(node) }
                    if r.truncated {
                        self.say(L("tree.truncated", r.nodes.count))
                    } else if r.nodes.isEmpty {
                        self.say(L("tree.empty"))
                    } else {
                        self.say(L("tree.count", r.nodes.count))
                    }
                case .failure(let error):
                    // 无法打开的文件夹不会显示为“空”，而是显示为失败并解释原因。
                    node.children = nil
                    self.outline.reloadItem(node === self.root ? nil : node, reloadChildren: true)
                    self.say(provider.describe(error))
                }
            }
        }
    }

    // MARK: - 按名称筛选

    @objc private func runFilter() {
        let term = filterField.stringValue.trimmingCharacters(in: .whitespaces)
        searchGeneration += 1
        guard !term.isEmpty else {
            results = nil
            outline.reloadData()
            if let kids = root?.children { say(L("tree.count", kids.count)) }
            return
        }
        guard let root else { return }
        let generation = searchGeneration
        let provider = self.provider
        spin(true)
        say(L("tree.searching"))
        work.async { [weak self] in
            let outcome = Result { try provider.search(root: root.path, term: term) }
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }   // 丢弃旧响应
                self.spin(false)
                switch outcome {
                case .success(let r):
                    self.results = r.nodes
                    self.outline.reloadData()
                    if r.nodes.isEmpty {
                        self.say(L("tree.noMatch"))
                    } else if r.truncated {
                        self.say(L("tree.matchTruncated", r.nodes.count))
                    } else {
                        self.say(L("tree.matchCount", r.nodes.count))
                    }
                case .failure(let error):
                    self.say(provider.describe(error))
                }
            }
        }
    }

    // MARK: - 打开

    @objc private func activateSelection() {
        let row = outline.clickedRow >= 0 && outline.selectedRow < 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpenFile?(node)
        }
    }

    private func say(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        onStatus?(text)
    }

    private func spin(_ on: Bool) { on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }
}

// MARK: - 数据

extension FileTreeView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    private func childrenOf(_ item: Any?) -> [FileNode] {
        if let results { return item == nil ? results : [] }       // 搜索结果为扁平列表
        if let node = item as? FileNode { return node.children ?? [] }
        return root?.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        childrenOf(item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        childrenOf(item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        results == nil && ((item as? FileNode)?.isDirectory ?? false)
    }

    /// 展开后，如果您还没有阅读，请阅读。
    func outlineViewItemWillExpand(_ notification: Notification) {
        guard results == nil, let node = notification.userInfo?["NSObject"] as? FileNode,
              node.children == nil else { return }
        load(node)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        let symbol = node.isDirectory ? "folder" : "doc.text"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = node.isDirectory ? .systemBlue : .secondaryLabelColor
        let label = NSTextField(labelWithString: node.name)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = node.path
        for v in [icon, label] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// `NSOutlineView` 的设计也允许在  / Return / Enter 上打开。
final class FileOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }
}
