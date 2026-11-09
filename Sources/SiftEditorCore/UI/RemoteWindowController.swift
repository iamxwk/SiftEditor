import AppKit

/// 远程查看屏幕 (B5)。**此屏幕与本地查看器屏幕不同。**
///
/// 我的查看器是基于行索引构建的，如果不扫描整个数据，就无法创建它。
/// 如果你远程舔它，“别掉下来”的想法就毫无意义了。另一方面，你想远程看到的是
/// **结尾和筛选结果**在两种情况下都已经包含行号和正文。
/// (`RemoteLines`)。因此，我们为不需要索引的一面创建了一个单独的部分。
///
/// 目的**刚刚开始调查**。如果模式固定，则 `ssh host grep` 将在一行中获胜。
/// 这样做的原理是，在输入 grep 后，你可以查看输入前后的结果，用不同的词再次缩小范围，然后再返回。
/// -- 这是一个来回切换需要重新输入命令的场景。
///
/// **与您的设备连接的是剪贴板。** 您可以使用 ⌘C 仅提取主要文本。
/// 无论将其粘贴到自己的文档中，还是使用 ⇧⌘D 将其传递给剪贴板比较，它都能正常工作。
///
/// **可立即更正 (B12)。** 双击该行文本进行更正，然后使用 ⌘S 将其写入另一侧。
/// 只会传输更正后的行；另一边的重写将由 `sed` / `head` / `tail` / `dd` 完成。
/// (`RemoteFile.replaceLineCommand`)。如果背面的文字与您打开时显示的文字不同，**请停止书写，不要写任何东西**。
public final class RemoteWindowController: NSWindowController, NSWindowDelegate {

    private let addressField = NSComboBox()
    private let searchField = NSSearchField()
    private lazy var searchButton = NSButton(title: L("remote.filter"), target: self, action: #selector(runSearch))
    private lazy var followButton = NSButton(title: L("remote.follow"), target: self, action: #selector(toggleFollow))
    private lazy var saveButton = NSButton(title: L("remote.save"), target: self, action: #selector(saveEdits))
    private let contextField = NSTextField()
    private lazy var regexCheck = NSButton(checkboxWithTitle: L("remote.regex"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = RemoteTableView()
    private let scroll = NSScrollView()
    private let spinner = NSProgressIndicator()
    /// 指定文件夹时在左侧显示的树状视图（可展开；可按名称筛选）。
    private let tree = FileTreeView(provider: RemoteDirectoryProvider(host: ""))
    private let split = NSSplitView()
    /// 树指向的点。
    private var treeHost: String?
    private var treeRoot: String?

    private var session: RemoteSession?
    private var totalLines: Int?
    private var lines: [RemoteLine] = []
    private var follower: RemoteFollower?
    /// 已更正但尚未编写的行。
    private var edits = RemoteEdits()
    private var saving = false

    /// ssh 运行缓慢。**切勿在 UI 线程中调用它**——屏幕在一次往返后就会冻结。
    /// 看来所有速度慢的问题都是这个应用程序的错（M6 的“远程屏幕不卖速度”）。
    private let work = DispatchQueue(label: "sifteditor.remote", qos: .userInitiated)

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("remote.title")
        window.center()
        super.init(window: window)
        window.delegate = self
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("不使用 init(coder:)") }

    /// **如果您关闭窗口，它将停止跟踪。** 如果放任不管，另一个 `tail -f` 将继续存活。
    public func windowWillClose(_ notification: Notification) { stopFollowing() }

    /// 请勿在文件仍有未编辑内容时关闭文件。**如果您静默删除文件，所做的更改将会丢失。**
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !edits.isEmpty, !saving else { return !saving }
        let alert = NSAlert()
        alert.messageText = L("remote.unsaved.title", edits.count)
        alert.informativeText = L("remote.unsaved.body")
        alert.addButton(withTitle: L("remote.unsaved.cancel"))
        alert.addButton(withTitle: L("remote.unsaved.discard"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.edits.removeAll()
            sender.close()
        }
        return false
    }

    // MARK: - 组件

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        addressField.placeholderString = L("remote.addressPlaceholder")
        addressField.target = self
        addressField.action = #selector(connectAndShowTail)
        addressField.completes = true
        addressField.numberOfVisibleItems = RemoteHistory.limit
        addressField.addItems(withObjectValues: RemoteHistory.load())

        let openButton = NSButton(title: L("remote.open"), target: self, action: #selector(connectAndShowTail))
        openButton.keyEquivalent = "\r"

        searchField.placeholderString = L("remote.searchPlaceholder")
        searchField.target = self
        searchField.action = #selector(runSearch)
        searchField.isEnabled = false

        contextField.stringValue = "2"
        contextField.alignment = .right
        contextField.toolTip = L("remote.contextHelp")
        contextField.isEnabled = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        // 两列：行号和正文。等宽字体，可直接阅读日志。
        let gutter = NSTableColumn(identifier: .init("line"))
        gutter.title = L("remote.column.line")
        gutter.width = 78
        let bodyColumn = NSTableColumn(identifier: .init("text"))
        bodyColumn.title = L("remote.column.text")
        bodyColumn.width = 760
        table.addTableColumn(gutter)
        table.addTableColumn(bodyColumn)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 16
        table.style = .plain
        // **⌘C 已由表格接收。** 第一个响应者是表格，因此 copy: 在这里。
        // 如果没有 ，响应链将无法到达顶部，并且编辑菜单中的“复制”选项将保持灰色。
        // （我在实际设备上发现了这个问题。如果菜单项是 disabled，按下按键后没有任何反应。）
        table.onCopy = { [weak self] in self?.copySelection() }
        table.target = self
        table.doubleAction = #selector(beginEditingClickedRow)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false

        let topRow = NSStackView(views: [addressField, openButton])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // **放置一个按压位置。** NSSearchField 只能在 Enter 上运行，并且会出现在屏幕上。
        // 未显示 = 首次打开它的人不知道他们可以“筛选”结果。
        searchButton.isEnabled = false
        // 请勿使用切换类型（.pushOnPushOff）。**开/关状态将显示在标题中。**
        // ——仅凭肉眼很难判断它是否被推入。
        followButton.isEnabled = false
        followButton.toolTip = L("remote.followHelp")
        saveButton.isEnabled = false
        saveButton.toolTip = L("remote.saveHelp")
        regexCheck.toolTip = L("remote.regexHelp")
        regexCheck.isEnabled = false
        // **由于单独显示“2”无法说明其含义，我们在其前后添加了文字说明，以明确表明它是缩小范围的一部分。
        // 将项目组合在一起，放在筛选按钮之前，并将跟踪和保存按钮放在稍远一些的地方。
        let contextLabel = NSTextField(labelWithString: L("remote.context.before"))
        let contextUnit = NSTextField(labelWithString: L("remote.context.after"))
        for l in [contextLabel, contextUnit] { l.textColor = .secondaryLabelColor; l.font = .systemFont(ofSize: 11) }
        let filterGroup = NSStackView(views: [regexCheck, contextLabel, contextField, contextUnit, searchButton])
        filterGroup.orientation = .horizontal
        filterGroup.spacing = 6
        let searchRow = NSStackView(views: [searchField, filterGroup, followButton, saveButton, spinner])
        searchRow.setCustomSpacing(20, after: filterGroup)
        searchRow.orientation = .horizontal
        searchRow.spacing = 8
        contextField.widthAnchor.constraint(equalToConstant: 40).isActive = true

        // 右侧 = 行显示。左侧 = 文件夹树（仅当指定文件夹时显示）
        let contentColumn = NSStackView(views: [searchRow, scroll])
        contentColumn.orientation = .vertical
        contentColumn.spacing = 8
        searchRow.widthAnchor.constraint(equalTo: contentColumn.widthAnchor).isActive = true
        contentColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)

        tree.isHidden = true
        tree.onOpenFile = { [weak self] node in self?.openFromTree(node) }
        tree.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(tree)
        split.addArrangedSubview(contentColumn)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)    // 当窗口变宽时，右侧会延伸。
        split.setHoldingPriority(.init(250), forSubviewAt: 1)

        let stack = NSStackView(views: [topRow, split, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        split.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        // 打开后应立即在地址栏中输入内容。**如果屏幕上没有任何焦点，
        // 响应链未启动，且 ⌘C 未工作**（我在实际设备上注意到了这一点）。
        window?.initialFirstResponder = addressField
        status(L("remote.hint"))
    }

    // MARK: - 连接

    /// 连接，**首先输出结尾。**问题出在结尾（与 `less +G` 概念相同）。
    @objc private func connectAndShowTail() {
        // 从历史记录中选择时，将读取所选项目（选择后，输入字段中的文本可能不会立即跟上）。
        let picked = addressField.indexOfSelectedItem >= 0
            ? addressField.itemObjectValue(at: addressField.indexOfSelectedItem) as? String : nil
        let text = (picked ?? addressField.stringValue).trimmingCharacters(in: .whitespaces)
        addressField.stringValue = text
        guard case .remote(let target) = Intake.resolve(text) else {
            status(L("remote.notRemote"))
            return
        }
        open(target, address: text, fromTree: false)
    }

    /// 打开树状视图中选定的文件。**树状视图保持打开状态**（允许您继续处理另一个文件）。
    private func openFromTree(_ node: FileNode) {
        guard let host = treeHost else { return }
        let address = "\(host):\(node.path)"
        addressField.stringValue = address
        open(RemoteFile.Target(host: host, path: node.path), address: address, fromTree: true)
    }

    private func open(_ target: RemoteFile.Target, address text: String, fromTree: Bool) {
        guard edits.isEmpty else {
            status(L("remote.unsavedBlocksOpen"))
            return
        }
        busy(true)
        status(L("remote.connecting", target.host))
        work.async { [weak self] in
            guard let self else { return }
            do {
                let s = try RemoteSession.connect(to: target)
                if s.kind == .directory {
                    DispatchQueue.main.async {
                        self.busy(false)
                        self.showTree(host: target.host, path: target.path)
                        if !fromTree { self.rememberAddress(text) }
                    }
                    return
                }
                let tail = s.tailLines(bytes: 64 << 10)
                DispatchQueue.main.async {
                    if !fromTree { self.hideTree() }
                    self.session = s
                    self.lines = tail
                    self.totalLines = nil
                    self.table.reloadData()
                    self.scrollToBottom()
                    self.focusList()
                    self.searchField.isEnabled = s.capabilities.canFilter
                    self.contextField.isEnabled = s.capabilities.canFilter
                    self.regexCheck.isEnabled = s.capabilities.canFilter
                    self.searchButton.isEnabled = s.capabilities.canFilter
                    self.followButton.isEnabled = s.capabilities.canFollow
                    self.busy(false)
                    self.window?.title = "\(target.host):\(target.path)"
                    if !fromTree { self.rememberAddress(text) }
                    self.reportOpened(s)
                }
                // 行号稍后填写。使用 10GB 会在对方服务器端占用几秒钟时间，所以不要让他们等待页面打开。
                self.fillLineNumbers(using: s)
            } catch {
                DispatchQueue.main.async {
                    self.busy(false)
                    self.status(Self.describe(error))
                }
            }
        }
    }

    /// 当指定文件夹时。**不要显示空列表；而是在左侧显示树状视图，并允许用户选择文件。**
    private func showTree(host: String, path: String) {
        stopFollowing()
        session = nil
        lines = []
        totalLines = nil
        table.reloadData()
        for control in [searchField, contextField, regexCheck, searchButton, followButton] as [NSControl] {
            control.isEnabled = false
        }
        treeHost = host
        treeRoot = path
        tree.isHidden = false
        tree.setRoot(path: path, provider: RemoteDirectoryProvider(host: host))
        window?.title = "\(host):\(path)"
        status(L("remote.pickFile"))
    }

    private func hideTree() {
        tree.isHidden = true
        treeHost = nil
        treeRoot = nil
    }

    /// 重新创建历史记录显示（当它已从菜单中删除时）。
    public func reloadHistory() {
        let current = addressField.stringValue
        addressField.removeAllItems()
        addressField.addItems(withObjectValues: RemoteHistory.load())
        addressField.stringValue = current
    }

    /// 将已连接的目的地添加到历史记录顶部。**仅保留已连接的条目**（以避免累积拼写错误）。
    private func rememberAddress(_ text: String) {
        RemoteHistory.record(text)
        addressField.removeAllItems()
        addressField.addItems(withObjectValues: RemoteHistory.load())
        addressField.stringValue = text
    }

    /// **折叠的功能还会显示其折叠原因。** 如果折叠后没有任何文字说明，则会显示为已损坏。
    private func reportOpened(_ s: RemoteSession) {
        var parts: [String] = [L("remote.openedTail")]
        parts.append(contentsOf: s.capabilities.degraded)
        status(parts.joined(separator: " / "))
    }

    /// `wc -l` 正在那边运行 -- **传输次数为零**，因此可以远程显示实际线路号。
    private func fillLineNumbers(using s: RemoteSession) {
        guard let total = s.lineCount() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === s else { return }
            self.totalLines = total
            // 如果  的最后一位数字仍然显示，请使用附加的号码再次检索它（如果搜索结果已经显示，请勿触摸）。
            if self.lines.allSatisfy({ !$0.isMatch }) {
                self.work.async {
                    let renumbered = s.tailLines(bytes: 64 << 10, totalLines: total)
                    DispatchQueue.main.async {
                        guard self.session === s else { return }
                        self.lines = renumbered
                        self.table.reloadData()
                        self.scrollToBottom()
                        self.status(L("remote.lineCount", total))
                    }
                }
            } else {
                self.status(L("remote.lineCount", total))
            }
        }
    }

    // MARK: - 窄

    /// **那边是 grep。** 返回匹配的行和行号，而无需传输 10GB 的任何一个字节。
    @objc private func runSearch() {
        guard let s = session else { return }
        let pattern = searchField.stringValue
        guard !pattern.isEmpty else {
            work.async { [weak self] in
                guard let self else { return }
                let tail = s.tailLines(bytes: 64 << 10, totalLines: self.totalLines)
                DispatchQueue.main.async {
                    self.lines = tail
                    self.table.reloadData()
                    self.scrollToBottom()
                    self.status(L("remote.openedTail"))
                }
            }
            return
        }

        let context = max(0, min(FilterContext.maxContext, Int(contextField.stringValue) ?? 0))
        let regex = regexCheck.state == .on
        busy(true)
        status(L("remote.searching"))
        work.async { [weak self] in
            guard let self else { return }
            let found = s.searchLines(pattern: pattern, context: context, regex: regex)
            DispatchQueue.main.async {
                self.busy(false)
                guard let found else {
                    return self.status(L(regex ? "remote.regexFailed" : "remote.searchFailed"))
                }
                self.lines = found
                self.table.reloadData()
                if !found.isEmpty { self.table.scrollRowToVisible(0) }
                // **请将焦点放在搜索栏上。** 如果切换到列表视图，则无法继续重新编辑单词（来回调整搜索结果的操作会被中断）。
                let hits = found.filter(\.isMatch).count
                self.status(hits == 0 ? L("remote.noMatch") : L("remote.matchCount", hits))
            }
        }
    }

    // MARK: - 追寻

    /// 切换尾音开启/关闭。**从另一端输入 `tail -f`。**
    ///
    /// 开始跟踪后，移除筛选条件并返回末尾 -- 当您将新到货品添加到筛选列表时，
    /// 包含不匹配的行会破坏筛选的含义。
    @objc private func toggleFollow() {
        if follower != nil { return stopFollowing() }
        guard let target = session?.target else { return }

        // 如果您正在缩小结果范围，请返回到末尾，然后再继续。
        if lines.contains(where: \.isMatch) {
            searchField.stringValue = ""
            runSearch()
        }

        let f = RemoteFollower(target: target)
        f.onLines = { [weak self] incoming in
            guard let self, self.follower === f else { return }
            self.appendFollowed(incoming)
        }
        f.onEnd = { [weak self] in
            guard let self, self.follower === f else { return }
            self.stopFollowing()
            self.status(L("remote.followEnded"))
        }
        follower = f
        followButton.title = L("remote.followStop")
        searchButton.isEnabled = false
        f.start(fromBytes: 0)   // 我将继续使用当前显示的结尾，所以只要新来的人就可以了。
        status(L("remote.following"))
    }

    private func stopFollowing() {
        follower?.stop()
        follower = nil
        followButton.title = L("remote.follow")
        searchButton.isEnabled = session?.capabilities.canFilter ?? false
    }

    /// 将收到的行添加到末尾。**从上一行开始计数行号**（不要再次询问）。
    private func appendFollowed(_ incoming: [String]) {
        guard !incoming.isEmpty else { return }
        var next = lines.last?.number.map { $0 + 1 }
        for text in incoming {
            lines.append(RemoteLine(number: next, isMatch: false, text: text))
            if let n = next { next = n + 1 }
        }
        if let last = lines.last?.number { totalLines = last }
        table.reloadData()
        scrollToBottom()
    }

    // MARK: - 把它拿到你手中

    /// 仅复制所选行的**正文**内容。不要包含行号。
    /// 添加  / 可将其从正文中移除，使用 ⇧⌘D 进行剪贴板比较将显示所有行的差异。
    public func copySelection() {
        let source = table.selectedRowIndexes.isEmpty
            ? lines
            : table.selectedRowIndexes.map { lines[$0] }
        // 对于已更正的行，复制更正后的版本（与屏幕上显示的内容相同）。
        let picked = source.map { RemoteLine(number: $0.number, isMatch: $0.isMatch, text: edits.text(for: $0)) }
        guard !picked.isEmpty else { return }
        let text = RemoteLines.plainText(picked)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status(L("remote.copied", picked.count))
    }

    // MARK: - 修复/写入 (B12)

    /// 包含正文的列（位于 `buildLayout` 中的第二个位置）。
    private static let textColumn = 1

    @objc private func beginEditingClickedRow() {
        let row = table.clickedRow
        guard row >= 0, row < lines.count, canEdit(lines[row]) else { return }
        table.editColumn(Self.textColumn, row: row, with: nil, select: true)
    }

    /// **跟踪过程中无法修复。** 每次有新项目到达时，列表都会重新创建，因此您当前正在输入的字段会消失。
    private func canEdit(_ line: RemoteLine) -> Bool {
        RemoteEdits.isEditable(line) && !saving && follower == nil
    }

    /// 确认输入字段。**请自行保留更正后的版本**，在⌘S之前不要发送给他们。
    fileprivate func commitEdit(row: Int, display: String) {
        guard row >= 0, row < lines.count, let number = lines[row].number else { return }
        let line = lines[row]
        let original = edits.edit(at: number)?.original ?? line.text
        guard let raw = RemoteEdits.raw(display: display, original: original) else {
            status(L("remote.editNoNewline"))
            reloadRow(row)
            return
        }
        edits.stage(line: number, original: original, edited: raw)
        reloadRow(row)
        refreshEditState()
        if !edits.isEmpty { status(L("remote.edited", edits.count)) }
    }

    private func reloadRow(_ row: Int) {
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<2))
    }

    /// 调整窗口中的保存按钮和“未保存”指示器，使其与正在进行的编辑相匹配。
    private func refreshEditState() {
        saveButton.isEnabled = !edits.isEmpty && !saving
        saveButton.title = edits.isEmpty ? L("remote.save") : L("remote.saveN", edits.count)
        window?.isDocumentEdited = !edits.isEmpty
    }

    /// 启用“保存”菜单的条件：**当前输入的字段尚未保存**
    /// 我只看它是否已连接且未被写入，不看它是否已被编辑。
    public var canSaveEdits: Bool { session != nil && !saving }

    /// 将我收到的修改写给对方 (⌘S)。
    ///
    /// 仅在编辑涉及更改长度（在另一侧重新创建文件）时才进行检查。
    /// 即时覆盖只会更改一行，不会影响其他字节。
    @objc public func saveEdits() {
        // 计数在确认输入字段后开始（确认前，物品不包含在存款中）。
        window?.makeFirstResponder(table)
        guard let s = session, !saving else { return }
        guard !edits.isEmpty else { return status(L("remote.nothingToSave")) }

        guard edits.rewriteCount > 0, let window else { return writeEdits(using: s) }
        let alert = NSAlert()
        alert.messageText = L("remote.rewrite.title", edits.rewriteCount)
        alert.informativeText = L("remote.rewrite.body", "\(s.target.host):\(s.target.path)")
        alert.addButton(withTitle: L("remote.rewrite.go"))
        alert.addButton(withTitle: L("remote.rewrite.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.writeEdits(using: s)
        }
    }

    private func writeEdits(using s: RemoteSession) {
        let pending = edits.all
        saving = true
        busy(true)
        refreshEditState()
        table.reloadData()
        status(L("remote.saving", pending.count))

        work.async { [weak self] in
            var done: [(RemoteEdits.Edit, RemoteFile.EditOutcome)] = []
            var failure: String?
            for e in pending {
                do {
                    done.append((e, try s.replaceLine(e.line, old: e.original, new: e.edited)))
                } catch {
                    failure = Self.describeSave(error, line: e.line)
                    break    // 如果哪怕只有一个项目停止，就不要继续。**不要隐瞒你中途停止的事实。**
                }
            }
            DispatchQueue.main.async { self?.finishSave(done, failure: failure, total: pending.count) }
        }
    }

    private func finishSave(_ done: [(RemoteEdits.Edit, RemoteFile.EditOutcome)], failure: String?, total: Int) {
        saving = false
        busy(false)
        for (edit, _) in done {
            edits.commit(line: edit.line)
            // 我已经写完了，所以这是新的“打开时显示的文本”。
            for i in lines.indices where lines[i].number == edit.line {
                lines[i] = RemoteLine(number: lines[i].number, isMatch: lines[i].isMatch, text: edit.edited)
            }
        }
        table.reloadData()
        refreshEditState()

        let rewrote = done.filter { $0.1 == .rewrote }.count
        if let failure {
            status(L("remote.saveStopped", done.count, total - done.count, failure))
        } else {
            status(L("remote.saved", done.count, done.count - rewrote, rewrote))
        }
    }

    /// 停止的原因。另一个 stderr 是**未改写内容**添加的。
    static func describeSave(_ error: Error, line: Int) -> String {
        guard let failure = error as? RemoteSession.EditFailure else { return describe(error) }
        let detail = failure.detail.isEmpty ? "" : "（\(failure.detail)）"
        switch failure.outcome {
        case .conflict:         return L("remote.err.conflict", line)
        case .notWritable:      return L("remote.err.notWritable")
        case .cannotCreateTemp: return L("remote.err.noTemp")
        case .noSuchLine:       return L("remote.err.noLine", line)
        case .missingTool:      return L("remote.err.missingTool") + detail
        case .writeFailed:      return L("remote.err.writeFailed") + detail
        case .overwrote, .rewrote: return detail
        }
    }

    // MARK: - 小物

    /// 将焦点移至列表。**现在您可以使用方向键进行导航，⌘C 也有效。**
    /// 如果没有第一响应者，响应链将不会向下传递到表格，并且编辑菜单也不会打开。
    /// “复制”按钮仍然呈灰色。
    private func focusList() {
        guard !lines.isEmpty else { return }
        window?.makeFirstResponder(table)
        if table.selectedRowIndexes.isEmpty {
            table.selectRowIndexes(IndexSet(integer: max(0, lines.count - 1)), byExtendingSelection: false)
        }
    }

    private func scrollToBottom() {
        guard !lines.isEmpty else { return }
        table.scrollRowToVisible(lines.count - 1)
    }

    private func busy(_ on: Bool) {
        on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private func status(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    /// 失败原因无需赘述。“Permission denied”和“No such file”是
    /// 任何读过它的人都会明白，如果我们在这里结束它，原因就消失了。
    static func describe(_ error: Error) -> String {
        switch error {
        case RemoteSession.Failure.timedOut:            return L("remote.timedOut")
        case RemoteSession.Failure.cannotRead:          return L("remote.cannotRead")
        case RemoteSession.Failure.missing:             return L("remote.err.missingTarget")
        case RemoteSession.Failure.unreadable:          return L("remote.err.unreadable")
        case RemoteSession.Failure.notRegular:          return L("remote.err.notRegular")
        case RemoteSession.Failure.launchFailed(let m): return m
        case RemoteSession.Failure.failed(_, let err):  return err.isEmpty ? L("remote.searchFailed") : err
        default:                                        return String(describing: error)
        }
    }
}

// MARK: - 入力欄

extension RemoteWindowController: NSTextFieldDelegate {
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commitEdit(row: table.row(for: field), display: field.stringValue)
    }
}

// MARK: - 一覧

extension RemoteWindowController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let line = lines[row]
        let isGutter = column?.identifier.rawValue == "line"

        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 11, weight: line.isMatch ? .bold : .regular)
        field.lineBreakMode = .byTruncatingTail

        if isGutter {
            // 如未计入，请留空。**请勿填写0或1。**
            field.stringValue = line.number.map(String.init) ?? ""
            field.alignment = .right
            field.textColor = .tertiaryLabelColor
        } else {
            let edited = line.number.flatMap { edits.edit(at: $0) } != nil
            field.stringValue = RemoteEdits.display(edits.text(for: line))
            // 仅设置了中奖号码。移除了中奖号码前后的数字（`grep -C`），以便将视线集中在中奖号码上。
            field.textColor = line.isMatch ? .labelColor : .secondaryLabelColor
            // 更改已修正线条的颜色。这将清楚地表明**背面尚未书写任何内容**。
            if edited { field.textColor = .systemOrange }
            if canEdit(line) {
                field.isEditable = true
                field.isSelectable = true
                field.delegate = self
                field.lineBreakMode = .byClipping
            }
        }
        return field
    }
}

/// `NSTableView` 仅用于接收  / `⌘C`。
///
/// 此表中列出了第一响应者，因此**如果 `copy:` 不在表中，编辑菜单将无法使用。**
/// “复制”按钮保持灰色，按下任何键都不会发生任何反应。
/// 即使在窗口控制器中实现，响应链也无法到达那么深的地方。
final class RemoteTableView: NSTableView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    /// 如果没有选项，请将其设为灰色（避免出现按下后没有任何反应的情况）。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return numberOfRows > 0 }
        return super.validateUserInterfaceItem(item)
    }
}
