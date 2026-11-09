import AppKit

private final class SearchBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shared, cancellable progress sheet for both extraction commands.
private final class ExtractionProgressSheet: NSObject {
    private weak var parent: NSWindow?
    private let progress: Progress
    private let sheet: NSPanel
    private let indicator = NSProgressIndicator()
    private let percentage = NSTextField(labelWithString: "0%")
    private var searchStatus: NSTextField?
    private let totalLines: Int?
    private var timer: Timer?

    init(window: NSWindow, progress: Progress, title: String,
         showSearchStatus: Bool = false, totalLines: Int? = nil) {
        parent = window
        self.progress = progress
        self.totalLines = totalLines
        sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440,
                                            height: showSearchStatus ? 175 : 145),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        sheet.title = L("extract.progressTitle")
        guard let content = sheet.contentView else { return }
        let caption = NSTextField(labelWithString: title)
        caption.lineBreakMode = .byTruncatingMiddle
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 100
        let cancel = NSButton(title: L("common.cancel"), target: self, action: #selector(cancelScan))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        for view in [caption, indicator, percentage, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        if showSearchStatus {
            let status = NSTextField(labelWithString: "")
            status.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(status)
            searchStatus = status
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
                status.trailingAnchor.constraint(equalTo: caption.trailingAnchor),
                status.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 12),
            ])
            reportSearch(found: 0, line: 0)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            indicator.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: percentage.leadingAnchor, constant: -12),
            indicator.topAnchor.constraint(equalTo: searchStatus?.bottomAnchor ?? caption.bottomAnchor,
                                           constant: showSearchStatus ? 20 : 22),
            indicator.heightAnchor.constraint(equalToConstant: 16),
            percentage.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            percentage.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
            percentage.widthAnchor.constraint(equalToConstant: 42),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 19),
        ])
        window.beginSheet(sheet)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.update() }
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        if let parent, parent.attachedSheet === sheet { parent.endSheet(sheet) }
    }

    @objc private func cancelScan() { progress.cancel() }

    func reportSearch(found: Int, line: Int) {
        guard let searchStatus else { return }
        if let totalLines {
            searchStatus.stringValue = L("extract.searchStatusTotal", found, line, totalLines)
        } else {
            searchStatus.stringValue = L("extract.searchStatus", found, line)
        }
    }

    private func update() {
        let value = min(100, max(0, progress.fractionCompleted * 100))
        indicator.doubleValue = value
        percentage.stringValue = "\(Int(value))%"
    }
}

/// 一个可通过拖放方式接收文件的容器（用于未选择文档时的空闲空间）。
final class DropView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}

/// 主窗口。左侧是已打开文档的垂直列表，右侧是主文本和状态栏。
public final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let statusBar = StatusBarView()
    private let searchBar = SearchBarView()
    private var searchExtractOptions = SearchExtraction.Options()
    private var searchPanel: NSPanel?
    private let readOnlyBanner = ReadOnlyBanner()
    private let structuredBanner = StructuredBanner()
    private let externalBanner = ExternalChangeBanner()

    // MARK: - 导入外部更改
    //
    // 如果打开的文件被另一个应用程序覆盖，除非更改已保存，否则它将静默重新加载。
    // 无法压缩（未保存、正在格式化/过滤）且自动加载已关闭。
    // 我们只会通过横幅通知您。**我们承诺不会在不发出任何提示的情况下继续展示旧内容。**

    private let externalWatcher = ExternalChangeWatcher()
    /// 外部已更改但尚未合并的窗格（用于显示横幅的目标）。
    private var externallyChangedPanes = Set<ObjectIdentifier>()
    /// 用于移除临时“已加载”消息的定时器。
    private var externalMessageTimer: Timer?

    private let sidebar = SidebarView()
    private let viewerContainer = DropView()

    /// 在此会话期间不再显示只读横幅（如果用 × 关闭，则为 true）。
    private var readOnlyBannerDismissed = false

    /// 主文本底部的约束。插入辅助窗格时替换。
    private var viewerBottomConstraint: NSLayoutConstraint?
    /// 辅助窗格及其高度约束。
    private var analysisAccessory: NSView?
    private var analysisHeightConstraint: NSLayoutConstraint?

    /// 打开文件（1 个文件 = 1 个窗格。只需切换显示即可）。
    private var viewers: [DocumentPane] = []
    private var activeIndex = -1

    /// 已关闭文件的路径（按关闭顺序排列；最近关闭的文件在最后）。使用 `⌘⇧T` 从末尾开始逐个重新打开它们。
    /// 尚未最终生成为文件（没有 fileURL）的新文档将无法加载——无法恢复。
    private var closedDocumentURLs: [URL] = []

    /// 未保存文本的位置 (draft)。**与会话分开的独立容器**，仅保存删除后无法恢复的文本。
    var draftStore: DraftStore = .shared

    /// 上次会话的会话记录。**生成时加载**（启动时打开的文件）
    /// （需要先预留此值，然后通过  / `persistSession` 进行覆盖）。
    private var pendingSession: SessionState? = AppSettings.session
    /// 恢复是否已完成？在恢复完成之前，请勿写入会话（请参阅下面的 `persistSession`）。
    private var didRestoreSession = false

    private var activeViewer: DocumentPane? {
        (activeIndex >= 0 && activeIndex < viewers.count) ? viewers[activeIndex] : nil
    }

    private let sidebarWidth: CGFloat = 200
    /// 侧边栏宽度。要打开/关闭，请将宽度设置为 0 并折叠（使用 `isHidden` 会在主文本侧创建约束）。
    private var sidebarWidthConstraint: NSLayoutConstraint?
    /// 工具栏上的  / delegate。窗口中包含 weak，所以我们将其保留在此处。
    private var toolbarDelegate: MainToolbarDelegate?
    /// 可抓取和移动的小窗口（搜索栏、各种横幅广告）。它们的位置会在整个应用程序中被记住。
    private var draggableOverlays: [DraggableOverlay] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.center()
        window.setFrameAutosaveName("SiftEditorMainWindow")
        window.tabbingMode = .disallowed
        self.init(window: window)
        window.delegate = self
        setupContent()
        setupToolbar()
        NotificationCenter.default.addObserver(self, selector: #selector(lineWrapChanged),
                                               name: .siftEditorLineWrapChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fontChanged),
                                               name: .siftEditorFontChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
                                               name: .siftEditorDisplayChanged, object: nil)
    }

    @objc private func lineWrapChanged() { viewers.forEach { $0.applyLineWrap() } }
    @objc private func fontChanged() { viewers.forEach { $0.applyCurrentFontSize() } }
    @objc private func displayChanged() {
        viewers.forEach { $0.applyDisplaySettings() }
        applyChrome()
    }

    /// 将主题应用于周围的 UI（标题栏、侧边栏、状态栏、搜索面板）。
    /// 在深色/浅色主题下，窗口外观也相匹配，framework 控件
    /// 调整（搜索字段、滚动条、标题文本、信号按钮）的亮度。
    private func applyChrome() {
        let theme = EditorTheme.current()
        let translucent = !EditorTheme.isOpaqueBackground
        let baseBG = theme.appearanceName != nil ? theme.chromeBackground : NSColor.windowBackgroundColor
        window?.appearance = theme.appearanceName.map { NSAppearance(named: $0) } ?? nil
        // 当标题栏透明时，标题栏也透明（使整个窗口不透明以显示背景）。
        window?.titlebarAppearsTransparent = (theme.appearanceName != nil) || translucent
        window?.isOpaque = !translucent
        window?.backgroundColor = translucent ? EditorTheme.withBackgroundOpacity(baseBG) : baseBG
        sidebar.applyTheme()
        statusBar.applyTheme()
        searchBar.applyTheme()
    }

    /// 一个标志，用于在关闭带有未保存更改的窗口时抑制双重确认。
    private var forceClose = false

    private func setupContent() {
        guard let content = window?.contentView else { return }
        content.translatesAutoresizingMaskIntoConstraints = true

        // 侧边栏（打开的文档列表）
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.onSelect = { [weak self] i in self?.activate(i) }
        sidebar.onClose = { [weak self] i in self?.closeDocument(at: i) }

        viewerContainer.translatesAutoresizingMaskIntoConstraints = false
        viewerContainer.onDropFiles = { [weak self] urls in urls.forEach { self?.open(url: $0) } }
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(viewerContainer)
        content.addSubview(statusBar)
        content.addSubview(sidebar)   // 将侧边栏移到最前面（尽量避免构图问题）

        let sidebarWidthC = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
        sidebarWidthConstraint = sidebarWidthC

        // 正文底部。插入辅助窗格时替换。
        let viewerContainerBottom = viewerContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        self.viewerBottomConstraint = viewerContainerBottom

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidthC,

            viewerContainer.topAnchor.constraint(equalTo: content.topAnchor),
            viewerContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            viewerContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            viewerContainerBottom,

            statusBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        ])

        statusBar.onMismatchNext = { [weak self] in
            self?.activeViewer?.jumpToNextMismatchLine()
        }
        statusBar.onMismatchPrev = { [weak self] in
            self?.activeViewer?.jumpToPrevMismatchLine()
        }

        // 搜索栏应放置在单独的面板中，并使其可移动到主窗口之外。
        let panel = SearchBarPanel(contentRect: NSRect(x: 0, y: 0, width: 576, height: SearchBarView.height),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = searchBar
        panel.orderOut(nil)
        searchPanel = panel
        searchBar.onQueryChange = { [weak self] q in
            self?.endBookmarkViewIfNeeded()
            self?.activeViewer?.setSearchQuery(q)
        }
        searchBar.onBookmarkToggle = { [weak self] on in
            guard let v = self?.activeViewer else { return false }
            // 与漏斗图互斥。在仅显示书签之前，请降低漏斗图筛选器的级别。
            if on { v.setFilterMode(false); AppSettings.searchFilterOn = false }
            let ok = v.setBookmarkView(on)
            self?.refreshSearchBarCapabilities()
            return ok
        }
        NotificationCenter.default.addObserver(forName: .bookmarkViewEnded, object: nil, queue: .main) { [weak self] note in
            guard let self, let v = self.activeViewer, note.object as AnyObject? === v as AnyObject else { return }
            self.searchBar.setBookmarkViewOn(false)
            self.refreshSearchBarCapabilities()
        }
        searchBar.onNext = { [weak self] in self?.activeViewer?.findNext() }
        searchBar.onPrev = { [weak self] in self?.activeViewer?.findPrev() }
        searchBar.onClose = { [weak self] in self?.hideSearch() }
        searchBar.onCaseToggle = { [weak self] on in self?.activeViewer?.setCaseSensitive(on) }
        searchBar.onRegexToggle = { [weak self] on in self?.activeViewer?.setRegexMode(on) }
        searchBar.onFilterToggle = { [weak self] on in
            // 仅当用户点击时才显示匹配的行。对于普通搜索，保留文本内容，并高亮显示匹配项。
            // 为了导出兼容性，这些设置将被保留，但在启动 ⌘F 时不会自动应用。
            AppSettings.searchFilterOn = on
            self?.endBookmarkViewIfNeeded()
            self?.activeViewer?.setFilterMode(on)
            self?.refreshSearchBarCapabilities()   // 过滤过程中更换滴管。
        }
        // 如果您因移动到无法使用的窗格而退出，则窗格中的更改将反映出来，但您的操作意图不会被清除。
        searchBar.onFilterUnavailable = { [weak self] in
            self?.activeViewer?.setFilterMode(false)
        }
        searchBar.onContextChange = { [weak self] n in self?.activeViewer?.setFilterContextLines(n) }
        searchBar.onReplace = { [weak self] r in self?.activeViewer?.replaceCurrent(with: r) }
        searchBar.onReplaceAll = { [weak self] r in self?.activeViewer?.replaceAll(with: r) }
        searchBar.onPreserveCaseToggle = { [weak self] on in self?.activeViewer?.setPreserveCase(on) }
        searchBar.onExtract = { [weak self] in self?.extractSearchResults() }
        searchBar.onExtractOptions = { [weak self] in self?.showExtractOptions() }
        searchBar.selectedTextForFind = { [weak self] in self?.activeViewer?.selectedTextForFind }
        searchBar.onReplaceRowChange = { [weak self] expanded in
            guard let panel = self?.searchPanel else { return }
            let height = expanded ? SearchBarView.expandedHeight : SearchBarView.height
            let frame = panel.frame
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height,
                                  width: frame.width, height: height), display: true)
        }

        // 只读横幅（浮动在主文本区域的左上角。仅在打开大文件时显示。）
        readOnlyBanner.translatesAutoresizingMaskIntoConstraints = false
        readOnlyBanner.isHidden = true
        readOnlyBanner.onClose = { [weak self] in
            self?.readOnlyBannerDismissed = true
            self?.readOnlyBanner.isHidden = true
        }
        content.addSubview(readOnlyBanner)
        let roTop = readOnlyBanner.topAnchor.constraint(equalTo: viewerContainer.topAnchor, constant: 10)
        let roLeading = readOnlyBanner.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            roTop, roLeading,
            readOnlyBanner.heightAnchor.constraint(equalToConstant: ReadOnlyBanner.height),
        ])
        addDraggable("readonly", readOnlyBanner, horizontal: roLeading, .leading, vertical: roTop, .leading)

        // 结构化文本横幅（位于主文本区域左上角；仅在启用结构化文本时显示。单击“恢复”即可恢复正常显示。）
        structuredBanner.translatesAutoresizingMaskIntoConstraints = false
        structuredBanner.isHidden = true
        structuredBanner.onRevert = { [weak self] in self?.setActiveStructuredMode(nil) }
        structuredBanner.onPresetTapped = { [weak self] in self?.presentViewPresets() }
        content.addSubview(structuredBanner)
        // 浮动在右上角（不会遮挡左侧标题栏）。它与搜索栏位于同一角落，因此默认情况下……
        // 将搜索栏向下移动（如下图 searchBarTopConstraint 所示）。两者均可拖动和移动。
        let stTop = structuredBanner.topAnchor.constraint(equalTo: viewerContainer.topAnchor, constant: 10)
        let stTrailing = structuredBanner.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor, constant: -28)
        NSLayoutConstraint.activate([
            stTop, stTrailing,
            structuredBanner.heightAnchor.constraint(equalToConstant: StructuredBanner.height),
        ])
        addDraggable("structured", structuredBanner, horizontal: stTrailing, .trailing, vertical: stTop, .leading)

        // 外部变更横幅（位于主文本区域底部。顶部包含搜索栏、只读部分和结构化文本。）
        externalBanner.translatesAutoresizingMaskIntoConstraints = false
        externalBanner.isHidden = true
        externalBanner.onReload = { [weak self] in self?.reloadActiveFromDisk() }
        externalBanner.onClose = { [weak self] in self?.dismissExternalBanner() }
        content.addSubview(externalBanner)
        let exBottom = externalBanner.bottomAnchor.constraint(equalTo: viewerContainer.bottomAnchor, constant: -10)
        let exLeading = externalBanner.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            exBottom, exLeading,
            externalBanner.heightAnchor.constraint(equalToConstant: ExternalChangeBanner.height),
        ])
        addDraggable("external", externalBanner, horizontal: exLeading, .leading, vertical: exBottom, .trailing)

        // 当主文本区域的大小发生变化时（打开/关闭侧边栏，调整窗口大小），重新定位浮动面板。
        viewerContainer.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewerContainerResized),
                                               name: NSView.frameDidChangeNotification, object: viewerContainer)

        externalWatcher.onChange = { [weak self] key in self?.externalChangeDetected(key) }
        externalWatcher.start()

        applyChrome()   // 在启动时应用持久主题。
    }

    // MARK: - 文档管理

    /// 打开文件（如果已打开则选择，否则添加）。
    ///
    /// gzip 文件在打开前需要解压缩。文件内容将决定文件类型——扩展名具有误导性（实际文件类型仍为 `.log`）。
    /// gzip（实际上是原文）和 `.gz` 都存在。
    func open(url: URL) {
        OpenTiming.begin()      // 仅当  SIFTEDITOR_TIMING=1 时有效
        if let head = try? FileHandle(forReadingFrom: url).read(upToCount: 4) {
            let magic = [UInt8](head)
            if Intake.isGzip(magic) {
                if let expanded = Intake.gunzip(url) {
                    openExpanded(expanded, origin: url)
                } else {
                    presentOpenFailure(url, reason: L("open.failed.gzip"))
                }
                return
            }
            if Intake.isZip(magic) { openZip(url); return }
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)

        if let i = viewers.firstIndex(where: { $0.fileURL == url }) {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            activate(i); return
        }

        let v = makePane(for: url)
        install(v)
        guard v.open(url: url) else { v.removeFromSuperview(); return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)
    }

    /// 打开提取/接收的文件内容。原始源文件显示在“临时文件”选项卡中。
    /// 如果只显示名称，则无法确定正在查看的内容。
    @discardableResult
    private func openExpanded(_ url: URL, origin: URL?, streaming: Bool = false) -> DocumentPane? {
        // 无论大小如何，传入的输入内容都将在具有跟踪和过滤功能的查看器中打开。
        // （小文件编辑查看器无法追踪文件末尾）。
        let v: DocumentPane = streaming ? PieceTableViewer() : makePane(for: url)
        install(v)
        guard v.open(url: url) else { v.removeFromSuperview(); return nil }
        if let origin { NSDocumentController.shared.noteNewRecentDocumentURL(origin) }
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)
        return v
    }

    /// 打开通过管道 (`kubectl logs … | sifteditor`) 接收的内容。
    func openPiped(_ url: URL) { openExpanded(url, origin: nil) }

    /// 打开传入的输入并跟踪到末尾 (`tail -f app.log | sifteditor`)。
    /// 返回值是一个清理调用（停止跟随），当“输入完成”时调用该调用。
    func openPipedStream(_ url: URL) -> () -> Void {
        guard let v = openExpanded(url, origin: nil, streaming: true) else { return {} }
        if v.supportsFollow { v.setFollowMode(true) }
        return { v.endFollow() }
    }

    /// 打开  / zip。**如果只输入一个选项，则会静默打开。** — 将打开一个只有一个选项的对话框。
    /// 这并非确认，只是额外的工作。如果有多个选项，请列出名称，让他们选择。
    private func openZip(_ url: URL) {
        let entries = Intake.zipEntries(url)
        guard !entries.isEmpty else {
            presentOpenFailure(url, reason: L("open.failed.zipEmpty")); return
        }
        guard entries.count > 1 else {
            openZipEntry(url, entry: entries[0]); return
        }

        let alert = NSAlert()
        alert.messageText = L("open.zip.chooseTitle")
        alert.informativeText = String(format: L("open.zip.chooseBody"),
                                       url.lastPathComponent, entries.count)
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        picker.addItems(withTitles: entries)
        alert.accessoryView = picker
        alert.addButton(withTitle: L("open.zip.open"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openZipEntry(url, entry: entries[picker.indexOfSelectedItem])
    }

    private func openZipEntry(_ url: URL, entry: String) {
        if let expanded = Intake.unzip(url, entry: entry) {
            openExpanded(expanded, origin: url)
        } else {
            presentOpenFailure(url, reason: L("open.failed.zipEntry"))
        }
    }

    private func presentOpenFailure(_ url: URL, reason: String) {
        let alert = NSAlert()
        alert.messageText = L("open.failed.title")
        alert.informativeText = String(format: reason, url.lastPathComponent)
        alert.runModal()
    }

    /// 创建并打开一个新的空白文档（保存时将确认路径）。
    func newDocument() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let v = EditableViewer()
        v.draftStore = draftStore
        install(v)
        v.newDocument()
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)
    }

    /// EmEditor-style extraction: configure the scan, then show a CSV report in a new document.
    func extractFrequentStrings() {
        guard let source = activeViewer, let window else { return }
        // A dirty large-file pane has no in-memory text snapshot. Reading its URL would count
        // the old disk version while the editor displays unsaved changes.
        if source.isDirty && source.restorableText == nil {
            let warning = NSAlert()
            warning.messageText = L("frequent.saveFirst")
            warning.beginSheetModal(for: window)
            return
        }
        let dialog = FrequentStringsPanel()
        guard let options = dialog.show() else { return }
        guard options.kind != .regex || !options.pattern.isEmpty else {
            showFrequentError(FrequentStrings.Failure.invalidPattern, in: window)
            return
        }
        let task = Progress(totalUnitCount: 1000)
        let waiting = ExtractionProgressSheet(window: window, progress: task,
                                              title: L("frequent.scanning"))
        let inputURL = source.fileURL
        let inputText = source.restorableText
        let inputEncoding = source.currentEncoding
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try FrequentStrings.count(url: inputURL, text: inputText, encoding: inputEncoding,
                                          kind: options.kind, pattern: options.pattern, limit: options.maximumRows,
                                          caseSensitive: options.caseSensitive,
                                          ignoredStrings: options.ignoredStrings,
                                          progress: { task.completedUnitCount = Int64($0 * 1000) },
                                          cancelled: { task.isCancelled })
            }
            DispatchQueue.main.async {
                waiting.finish()
                guard !task.isCancelled, let self else { return }
                switch result {
                case .success(let rows):
                    self.showExtractedCSV(FrequentStrings.csv(rows, includeHeader: false),
                                          hasHeader: false,
                                          title: L("frequent.title") + " — " + L("frequent.kind.\(options.kind.rawValue)"))
                case .failure(let error): self.showFrequentError(error, in: window)
                }
            }
        }
    }

    private func showExtractOptions() {
        let dialog = ExtractOptionsPanel(options: searchExtractOptions)
        if let updated = dialog.show() { searchExtractOptions = updated }
        searchPanel?.makeKeyAndOrderFront(nil)
    }

    private func extractSearchResults() {
        guard let source = activeViewer, let window else { return }
        let query = searchBar.query
        guard !query.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("search.extractNeedsQuery")
            alert.runModal()
            searchPanel?.makeKeyAndOrderFront(nil)
            searchBar.focusField()
            return
        }
        if !searchBar.isRegex && query.contains(".*") {
            let alert = NSAlert()
            alert.messageText = L("search.regexSyntaxTitle")
            alert.informativeText = L("search.regexSyntaxHint")
            alert.addButton(withTitle: L("search.useRegex"))
            alert.addButton(withTitle: L("search.searchLiterally"))
            alert.addButton(withTitle: L("common.cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: searchBar.selectRegexMode()
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        if source.isDirty && source.restorableText == nil {
            let warning = NSAlert()
            warning.messageText = L("frequent.saveFirst")
            warning.beginSheetModal(for: window)
            return
        }
        let task = Progress(totalUnitCount: 1000)
        let sourcePane = activeViewer as? PieceTableViewer
        let progressParent = (searchPanel?.isVisible == true ? searchPanel : nil) ?? window
        let waiting = ExtractionProgressSheet(window: progressParent, progress: task,
                                              title: L("extract.searching", query),
                                              showSearchStatus: true,
                                              totalLines: sourcePane?.exactSourceLineCount)
        let options = searchExtractOptions
        let isRegex = searchBar.isRegex
        let caseSensitive = searchBar.isCaseSensitive
        let inputURL = source.fileURL
        let inputText = source.restorableText
        let inputEncoding = source.currentEncoding
        let suspendedSearch = sourcePane?.suspendSearchForExtraction() ?? false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try SearchExtraction.run(url: inputURL, text: inputText, encoding: inputEncoding,
                                         query: query, regex: isRegex, caseSensitive: caseSensitive,
                                         options: options,
                                         progress: { task.completedUnitCount = Int64($0 * 1000) },
                                         scanStatus: { found, line in
                                             DispatchQueue.main.async { waiting.reportSearch(found: found, line: line) }
                                         },
                                         cancelled: { task.isCancelled })
            }
            DispatchQueue.main.async {
                waiting.finish()
                defer { if suspendedSearch { sourcePane?.resumeSearchAfterExtraction() } }
                guard !task.isCancelled, let self else { return }
                switch result {
                case .success(let output):
                    guard !output.isEmpty, !(options.frequent && output == "Content,Count\n") else {
                        let alert = NSAlert()
                        alert.messageText = L("search.noMatches")
                        DispatchQueue.main.async { alert.beginSheetModal(for: window) }
                        return
                    }
                    self.showExtractedCSV(output, hasHeader: options.frequent,
                                          title: String(query.prefix(80)))
                case .failure(let error): self.showFrequentError(error, in: window)
                }
            }
        }
    }

    private func showExtractedCSV(_ text: String, hasHeader: Bool, title: String) {
        newDocument()
        guard let pane = activeViewer as? EditableViewer else { return }
        pane.setGeneratedCSVText(text, hasHeader: hasHeader, title: title)
        reloadSidebar()
        window?.title = displayName(of: pane) + " — " + AppInfo.name
        setActiveStructuredMode(.csv)
    }

    private func showFrequentError(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = L("frequent.failed")
        let key: String
        switch error {
        case FrequentStrings.Failure.invalidPattern: key = "frequent.error.pattern"
        case FrequentStrings.Failure.lineTooLong: key = "frequent.error.line"
        case FrequentStrings.Failure.tooManyValues: key = "frequent.error.values"
        case FrequentStrings.Failure.tooMuchText: key = "frequent.error.memory"
        case FrequentStrings.Failure.unsupportedEncoding: key = "frequent.error.encoding"
        case FrequentStrings.Failure.outputTooLarge: key = "frequent.error.output"
        default: key = "frequent.error.read"
        }
        alert.informativeText = L(key)
        alert.beginSheetModal(for: window)
    }

    /// 排列窗格以填充主文本区域并连接处理程序（初始隐藏）。
    private func install(_ v: DocumentPane) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        wire(v)
        viewerContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: viewerContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: viewerContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: viewerContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: viewerContainer.bottomAnchor),
        ])
    }

    /// 根据文件大小确定要打开的窗格（小 = NSTextView 编辑，大 = piece table 编辑查看器）。
    private func makePane(for url: URL) -> DocumentPane {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size, size <= EditableViewer.sizeThreshold {
            return EditableViewer()
        }
        // 大文件为 piece table 和后台编辑查看器（mmap + 索引 + 搜索/关注 + 即时编辑/保存）。
        return PieceTableViewer()
    }

    private func reloadSidebar() {
        sidebar.reload(names: viewers.map { displayName(of: $0) },
                       dirty: viewers.map { $0.isDirty },
                       active: activeIndex)
        syncExternalWatch()   // 监控打开文件数量的变化及其保存位置的变化。
    }

    // MARK: - 导入外部更改

    /// 调整监视列表以匹配当前打开的文件。
    private func syncExternalWatch() {
        externalWatcher.sync(viewers.compactMap { pane in
            pane.fileURL.map { (key: ObjectIdentifier(pane), url: $0) }
        })
    }

    /// 当检测到磁盘内容发生更改时（来自监控计时器）。
    ///
    /// 只有没有未保存更改且按原样显示文本的窗格才会被静默导入。
    /// 显示格式化、筛选或查询时正文文本将被替换 (`canEdit == false`)
    /// 重新加载页面会自动破坏用户的自定义布局，因此应该显示一个横幅来通知用户并允许他们选择一个选项。
    private func externalChangeDetected(_ key: ObjectIdentifier) {
        guard let pane = viewers.first(where: { ObjectIdentifier($0) == key }) else { return }
        guard AppSettings.autoReloadExternalChanges, !pane.isDirty, pane.canEdit else {
            externallyChangedPanes.insert(key)
            updateExternalBanner()
            return
        }
        applyDiskReload(to: pane)
    }

    /// 将窗格更新为磁盘内容并对齐周围的 UI。
    private func applyDiskReload(to pane: DocumentPane) {
        guard let url = pane.fileURL, pane.reloadFromDisk() else { return }
        externallyChangedPanes.remove(ObjectIdentifier(pane))
        // 将您刚刚导入的版本设为“已知版本”（否则它将一直发出相同的更改）。
        externalWatcher.note(key: ObjectIdentifier(pane), url: url)
        reloadSidebar()
        updateExternalBanner()
        updateEditedState()
        if pane === activeViewer { showExternalReloadMessage() }
    }

    /// “加载”横幅。仅当您想要清除未保存的更改时才需要确认。
    private func reloadActiveFromDisk() {
        guard let pane = activeViewer, pane.fileURL != nil else { return }
        guard pane.isDirty, let win = window else { applyDiskReload(to: pane); return }
        let alert = NSAlert()
        alert.messageText = L("external.confirmTitle", displayName(of: pane))
        alert.informativeText = L("external.confirmMessage")
        alert.addButton(withTitle: L("external.reload"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            self.applyDiskReload(to: pane)
        }
    }

    /// 横幅 ×。我决定不导入它，所以我会保持沉默，并将当前的磁盘版本标记为“已知版本”。
    /// (如有变更，我会再次通知您)。
    private func dismissExternalBanner() {
        guard let pane = activeViewer, let url = pane.fileURL else { return }
        externallyChangedPanes.remove(ObjectIdentifier(pane))
        externalWatcher.note(key: ObjectIdentifier(pane), url: url)
        updateExternalBanner()
    }

    /// 仅显示活动窗格的横幅（根据文档状态）。
    private func updateExternalBanner() {
        guard let pane = activeViewer else { externalBanner.isHidden = true; return }
        externalBanner.isHidden = !externallyChangedPanes.contains(ObjectIdentifier(pane))
    }

    /// 如果您在不发出任何提示的情况下替换它，它会显示为“自动更改”，因此状态栏中会出现几秒钟的通知。
    private func showExternalReloadMessage() {
        statusBar.showMessage(L("external.reloaded"))
        externalMessageTimer?.invalidate()
        externalMessageTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.statusBar.clearMessage()
            self?.activeViewer?.reEmitState()
        }
    }

    /// 保存打开的文档列表（下次启动时恢复）。
    /// 已保存的项目将被传递，未保存的新项目将保留其文本（不包括空的新标签页）。
    /// 在保存、打开、关闭、切换以及退出之前调用。
    ///
    /// **恢复前请勿写入。** 启动时从 Finder 打开的参数和文件也会经过 `activate`。
    /// 无条件写入将覆盖即将读取的会话（包括新的、未保存的文本）。
    private func persistSession() {
        guard didRestoreSession else { return }
        let docs = viewers.map {
            (url: $0.fileURL, text: $0.restorableText, draftID: $0.draftID, dirty: $0.isDirty)
        }
        AppSettings.session = SessionState.make(docs: docs, activeIndex: activeIndex)
    }

    /// 立即将打开的未保存文档写入 draft 文件（在关闭之前/停用时）。
    func flushDrafts() {
        viewers.forEach { $0.flushDraft() }
    }

    /// 恢复程序上次关闭时的文档列表（保持顺序）。仅在启动时调用一次。
    ///
    /// **读取 draft 文件（磁盘上的实际文件）的值，而非会话的值。**
    /// 即使没有会话，会话已损坏，或者在启动时被打开的会话覆盖，它仍然存在。
    /// 未保存的文本必须始终重新打开（`SessionState.restorePlan` 具有不变条件）。
    /// 会话维护一个已保存文件的列表，但如果丢失此信息，可以重新创建。
    func restoreSession() {
        guard !didRestoreSession else { return }
        defer {
            // 从这里开始，持久化过程将照常进行。之前被抑制的启动状态也会写入此处。
            didRestoreSession = true
            persistSession()
        }

        // 旧版本（~1.0.1）直接将主要文本包含在会话中。为避免更新时丢失，将将其移至 draft。
        let session = pendingSession.map { draftStore.migratingLegacyText(in: $0) }

        // 启动时打开的文件（参数 / Finder）。恢复的文件在此之后添加。
        let launchOpened = viewers.count
        let plan = SessionState.restorePlan(session: session,
                                            draftIDs: draftStore.allIDs(),
                                            hasOpenDocuments: launchOpened > 0)
        guard !plan.items.isEmpty else { return }

        let fm = FileManager.default
        for item in plan.items {
            switch item {
            case .file(let path):
                if fm.fileExists(atPath: path) { open(url: URL(fileURLWithPath: path)) }
            case .draft(let id, let dirty):
                guard let text = draftStore.read(id: id) else { continue }
                restoreDraft(id: id, text: text, dirty: dirty)
            }
        }
        if launchOpened > 0 {
            activate(launchOpened - 1)   // 启动时保持打开的文件处于活动状态。
        } else if plan.activeIndex >= 0, !viewers.isEmpty {
            // ：由于跳过缺失的文件，位置可能会发生偏移，因此请将其限制在范围内。
            activate(min(plan.activeIndex, viewers.count - 1))
        }
        // 确保活动窗格在恢复后立即可靠地呈现。
        activeViewer?.needsDisplay = true
        window?.displayIfNeeded()
    }

    /// 恢复文本为 draft 的未保存新文档，并将其添加到侧边栏。
    private func restoreDraft(id: String, text: String, dirty: Bool) {
        let v = EditableViewer()
        v.draftStore = draftStore
        install(v)
        v.restoreDraft(id: id, text: text, dirty: dirty)
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)   // activate 位于 persistSession 内
    }

    /// 侧边栏/标题的显示名称（新建的、未保存的文档将显示“未命名”）。
    private func displayName(of v: DocumentPane) -> String {
        if let d = v as? DiffViewer { return d.displayTitle }   // diff 不属于任何文件。
        return v.fileURL?.lastPathComponent ?? (v as? EditableViewer)?.generatedTitle ?? L("doc.untitled")
    }

    // MARK: - diff（三个入口在此汇合）

    /// 如果活动窗格为 diff，则使用该窗格（用于“下一个/上一个差异”菜单）。
    var activeDiffViewer: DiffViewer? { activeViewer as? DiffViewer }


    /// 打开比较选项卡。源准备（mmap，索引）和 diff 在后台运行。
    /// `makeSources` 在后台线程中调用（在此处停止主线程会导致其冻结在 10GB）。
    func openDiff(title: String,
                  notReadableMessage: String? = nil,
                  makeSources: @escaping () -> (DiffSource, DiffSource)?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let v = DiffViewer()
        install(v)
        viewers.append(v)
        reloadSidebar()
        activate(viewers.count - 1)

        v.onCompared = { [weak self] in self?.reloadSidebar() }
        // 合并结果应该保存，然后打开并显示（不要只是保持原样）。
        v.onMergedSaved = { [weak self] url in self?.open(url: url) }
        v.beginCompare(title: title, makeSources: makeSources, notReadableMessage: notReadableMessage, onFailure: { [weak self, weak v] message in
            guard let self, let v, let i = self.viewers.firstIndex(where: { $0 === v }) else { return }
            self.closeDocument(at: i)
            let alert = NSAlert()
            alert.messageText = L("diff.failedTitle")
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        })
    }

    /// 条目 1：选择并比较两个文件。
    ///
    /// **不允许在一个面板中选择两项。** 最初就是这样，但通常是“选择一个并打开”。
    /// 由于我正在执行操作，所以对于那些没有使用 ⌘单击选择两个项目的人来说，**什么也没发生**（它只是静静地关闭了）。
    /// 先问第一个问题，再问第二个问题，依此类推。如果一次选择两个项目，则按原样进行。
    func compareFiles() {
        let first = NSOpenPanel()
        first.message = L("diff.chooseFirst")
        first.prompt = L("diff.chooseNext")
        first.allowsMultipleSelection = true      // 选择两种方式的人也将被允许通过。
        first.canChooseDirectories = false
        guard first.runModal() == .OK, !first.urls.isEmpty else { return }

        var urls = first.urls
        if urls.count == 1 {
            let second = NSOpenPanel()
            second.message = L("diff.chooseSecond", urls[0].lastPathComponent)
            second.prompt = L("diff.compare")
            second.allowsMultipleSelection = false
            second.canChooseDirectories = false
            second.directoryURL = urls[0].deletingLastPathComponent()   // 从同一地点开始
            guard second.runModal() == .OK, let u = second.urls.first else { return }
            urls.append(u)
        }

        let pick = Array(urls.prefix(2))
        let title = "\(pick[0].lastPathComponent) ↔ \(pick[1].lastPathComponent)"
        openDiff(title: title) {
            guard let l = FileDiffSource(url: pick[0]), let r = FileDiffSource(url: pick[1]) else { return nil }
            return (l, r)
        }
    }

    /// 条目 2：比较两个打开的标签页（当前标签页和它之前的标签页）。
    /// 也可以在正文中比较未保存的标签页（比较当前可见的内容，而不是磁盘上的文件）。
    func compareOpenDocuments() {
        let comparable = viewers.enumerated().filter { !($0.element is DiffViewer) }
        guard comparable.count >= 2 else { NSSound.beep(); return }
        let pick = comparable.suffix(2).map { $0.element }
        // 未保存的文本首先在主线程中检索（只能在主线程中访问窗格状态）。
        let recipes = pick.map { diffRecipe(for: $0) }
        let title = "\(displayName(of: pick[0])) ↔ \(displayName(of: pick[1]))"
        openDiff(title: title) {
            guard let l = recipes[0].makeSource(), let r = recipes[1].makeSource() else { return nil }
            return (l, r)
        }
    }

    /// 条目 3：将剪贴板的内容与当前打开的文档进行比较。
    func compareWithClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep(); return
        }
        let clipName = L("diff.clipboard")
        guard let active = activeViewer, !(active is DiffViewer) else {
            openDiff(title: clipName) {
                (TextDiffSource(text: "", displayName: L("doc.untitled")),
                 TextDiffSource(text: text, displayName: clipName))
            }
            return
        }
        let recipe = diffRecipe(for: active)
        let title = "\(displayName(of: active)) ↔ \(clipName)"
        openDiff(title: title) {
            guard let l = recipe.makeSource() else { return nil }
            return (l, TextDiffSource(text: text, displayName: clipName))
        }
    }

    /// 入口 4：将 URL 的内容与当前打开的文档进行比较。
    /// URL 将在打开前提示输入（如果剪贴板包含 URL，则会预先填充）。
    func compareWithURL() {
        promptForCompareURL { [weak self] url in
            guard let self, let url else { return }
            let name = CompareURL.displayName(for: url)
            // 如果没有活动项目，则会将一个空文档和 URL 并排放置（行为与剪贴板相同）。
            guard let active = self.activeViewer, !(active is DiffViewer) else {
                self.openDiff(title: name, notReadableMessage: L("diff.urlFailed")) {
                    guard let r = downloadDiffSource(from: url, displayName: name) else { return nil }
                    return (TextDiffSource(text: "", displayName: L("doc.untitled")), r)
                }
                return
            }
            let recipe = self.diffRecipe(for: active)
            let title = "\(self.displayName(of: active)) ↔ \(name)"
            self.openDiff(title: title, notReadableMessage: L("diff.urlFailed")) {
                guard let l = recipe.makeSource(),
                      let r = downloadDiffSource(from: url, displayName: name) else { return nil }
                return (l, r)
            }
        }
    }

    /// 此表要求输入 URL 进行比较。只有有效的 https 才会传递给 `completion`（所有其他值都会传递给 nil）。
    private func promptForCompareURL(completion: @escaping (URL?) -> Void) {
        guard let win = window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = L("diff.url.prompt")
        alert.informativeText = L("diff.url.message")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://…"
        // 如果剪贴板包含 URL，则保存它（复制和比较是最常见的工作流程）。
        if let clip = NSPasteboard.general.string(forType: .string),
           let u = CompareURL.normalize(clip) {
            field.stringValue = u.absoluteString
        }
        alert.accessoryView = field
        alert.addButton(withTitle: L("diff.compare"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))  // .alertSecondButtonReturn
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            guard let url = CompareURL.normalize(field.stringValue) else {
                NSSound.beep(); completion(nil); return
            }
            completion(url)
        }
    }

    /// 如何将窗格设置为 diff 的输入。**窗格的状态由主程序读取。**
    /// 实际的 mmap 和索引构建（资源密集型）将在后台运行。
    private struct DiffRecipe {
        let makeSource: () -> DiffSource?
    }

    /// 如果已保存，则将文件与 mmap 进行比较；否则，按原样比较文本（比较当前可见的内容）。
    private func diffRecipe(for pane: DocumentPane) -> DiffRecipe {
        let name = displayName(of: pane)
        if let text = pane.restorableText, pane.isDirty || pane.fileURL == nil {
            return DiffRecipe { TextDiffSource(text: text, displayName: name) }
        }
        if let url = pane.fileURL {
            return DiffRecipe { FileDiffSource(url: url) }
        }
        return DiffRecipe { nil }
    }

    // MARK: - 活动文档功能（用于菜单验证）

    /// 是否有可编辑和可保存的文档打开？
    var canSave: Bool { activeViewer?.canEdit ?? false }
    /// 能否恢复到已保存状态？（文件可编辑，有未保存的更改，且已最终定稿。）
    var canRevert: Bool {
        guard let v = activeViewer else { return false }
        return v.canEdit && v.isDirty && v.fileURL != nil
    }
    /// 是否有可搜索的文档打开？
    /// 是否有可打印的文档（= PDF 输出）？不支持大文件。
    var canPrint: Bool { activeViewer?.canPrint ?? false }

    /// 打印当前文档（也可以从打印对话框中将其另存为 PDF）。
    func printActiveDocument() {
        guard let v = activeViewer, v.canPrint else { NSSound.beep(); return }
        v.printDocument()
    }

    var canSearch: Bool { activeViewer?.supportsSearch ?? false }
    /// 是否有可以跟随其名称结尾的文档打开？
    var canFollow: Bool { activeViewer?.supportsFollow ?? false }
    /// 是否有一个文档打开，只允许显示匹配的行（前后行 N 的增加或减少也遵循此规则）？
    var canFilter: Bool { (activeViewer?.supportsSearch ?? false) && (activeViewer?.supportsSearchFilter ?? false) }
    /// 是否有任何文档打开？
    var hasActiveDocument: Bool { activeIndex >= 0 }
    /// 是否有任何“已关闭的文件”可以重新打开？
    var canReopenClosedDocument: Bool { !closedDocumentURLs.isEmpty }
    /// 当前活动文档是否位于末尾？
    var isFollowingActive: Bool { activeViewer?.isFollowing ?? false }
    /// 是否可以启用结构化显示？（启用 View 菜单）。
    var canStructured: Bool { activeViewer?.supportsStructured ?? false }
    /// JSON：当前窗格中是否支持格式设置（单文档缩进）？大文件无法实现。
    var canStructuredJson: Bool { activeViewer?.supportsJsonReformat ?? false }
    /// JSON 当前窗格中是否可以使用即时查询？不支持大文件。
    var canJsonQuery: Bool { activeViewer?.supportsJsonQuery ?? false }
    var jsonQueryIsActive: Bool { activeViewer?.jsonQueryIsActive ?? false }

    func toggleActiveJsonQuery() {
        guard let v = activeViewer, v.supportsJsonQuery else { NSSound.beep(); return }
        v.toggleJsonQuery()
    }

    // MARK: - 数字尺（用于计数固定长度数据）

    /// 能否显示数字标尺？（两个查看器都支持；diff 不支持。）
    var canColumnRuler: Bool { activeViewer?.supportsColumnRuler ?? false }
    var columnRulerIsVisible: Bool { activeViewer?.columnRulerVisible ?? false }
    /// 是否至少有一个数字引导？（启用“隐藏数字引导”）。
    var hasColumnGuides: Bool { activeViewer?.hasColumnGuides ?? false }

    func toggleActiveColumnRuler() {
        guard let v = activeViewer, v.supportsColumnRuler else { NSSound.beep(); return }
        v.setColumnRulerVisible(!v.columnRulerVisible)
    }

    func clearActiveColumnGuides() {
        activeViewer?.clearColumnGuides()
    }

    /// 输入固定长度的字段定义，格式为数字 (`1-8,9-14,15-40`)。
    ///
    /// **仅仅点击放置是不够的。** 处理固定长度物品的人通常会有一份规格文件。
    /// 目测检查并放置  / 32 号物品简直是折磨。反之，如果没有规格说明文件，确定边界就成了主要任务。
    /// 也需要点击和拖动。两种方法都会重写同一个单状态（数字指南）。
    func editActiveColumnFields(completion: ((Bool) -> Void)? = nil) {
        guard let v = activeViewer, v.supportsColumnRuler else { NSSound.beep(); completion?(false); return }
        let current = ColumnFieldSpec.text(for: ColumnGuides(v.columnGuideColumns))
        promptForColumnFields(initial: current) { [weak self] columns in
            guard let columns else { completion?(false); return }        // 取消
            v.setColumnGuides(columns)
            // ：避免出现输入内容但看不到任何内容的情况（线条和标尺同时出现）。
            if !columns.isEmpty, !v.columnRulerVisible { v.setColumnRulerVisible(true) }
            _ = self
            completion?(!columns.isEmpty)
        }
    }

    /// 此表用于填写项目定义。OK 为边界数字（空表示未定义），nil 用于取消。
    /// 如果字迹难以辨认，**我不会允许只通过一部分**（我会回到同一张纸上，直到字迹改正为止）。
    private func promptForColumnFields(initial: String, completion: @escaping ([Int]?) -> Void) {
        guard let win = window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = L("columnFields.prompt")
        alert.informativeText = L("columnFields.message")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "1-8,9-14,15-40"
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            let text = field.stringValue
            guard let columns = ColumnFieldSpec.parse(text) else {
                let bad = NSAlert()
                bad.alertStyle = .warning
                bad.messageText = L("columnFields.invalid")
                bad.informativeText = L("columnFields.message")
                bad.beginSheetModal(for: win) { _ in
                    self?.promptForColumnFields(initial: text, completion: completion)
                }
                return
            }
            completion(columns)
        }
    }
    /// 当前文档是否可编辑？（用于启用编辑工具箱菜单）。
    var canTransformText: Bool { activeViewer?.canEdit ?? false }
    /// 能否与数字导板对齐（可编辑且已绘制分隔符）？
    /// 即使没有中断，你也可以从内部创建它，所以**如果你能编辑它，你就能按下它**。
    var canAlignToColumnGuides: Bool {
        guard let v = activeViewer as? EditableViewer else { return false }
        return v.canEdit
    }

    /// 分配数字引导线时，对齐选定的范围（如果未选择任何范围，则对齐整个文本）。
    func alignActiveToColumnGuides() {
        guard let v = activeViewer as? EditableViewer, canAlignToColumnGuides else { NSSound.beep(); return }
        v.alignToColumnGuides()
    }

    /// 将编辑工具箱中的转换应用于选定的活动文档。
    func applyActiveTextTransform(_ transform: TextTransform) {
        guard let v = activeViewer, v.canEdit else { NSSound.beep(); return }
        v.applyTextTransform(transform)
    }

    // MARK: - 分割行（分隔符通过对话框接收）

    private static let lastSplitDelimiterKey = "toolbox.lastSplitDelimiter"

    /// 按分隔符拆分每个选定的行（“连接行”的逆操作）。
    func splitActiveSelectionIntoLines() {
        guard let pane = activeViewer, pane.canEdit,
              let selection = pane.selectedText, !selection.isEmpty else { NSSound.beep(); return }
        promptForSplitOptions { [weak self] options in
            guard let self, let options else { return }
            UserDefaults.standard.set(options.delimiter, forKey: Self.lastSplitDelimiterKey)
            // 在执行替换操作之前，请检查在工作表关闭时所选内容是否已更改。
            guard self.activeViewer === pane, pane.selectedText == selection else { return }
            guard let result = LineSplitter.split(selection, options: options) else { NSSound.beep(); return }
            guard result != selection else { return }   // 无更改意味着无撤销。
            pane.replaceSelection(with: result)
        }
    }

    /// 询问分隔符及其处理方式的表格（前一个分隔符用作初始值）。
    private func promptForSplitOptions(completion: @escaping (LineSplitter.Options?) -> Void) {
        guard let win = window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = L("split.prompt")
        alert.informativeText = L("split.message")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = ","
        field.stringValue = UserDefaults.standard.string(forKey: Self.lastSplitDelimiterKey) ?? ","
        let label = NSTextField(labelWithString: L("split.delimiter"))
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        let trimCheck = NSButton(checkboxWithTitle: L("split.trim"), target: nil, action: nil)
        let dropCheck = NSButton(checkboxWithTitle: L("split.dropEmpty"), target: nil, action: nil)
        let stack = NSStackView(views: [row, trimCheck, dropCheck])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 84)
        alert.accessoryView = stack

        alert.addButton(withTitle: L("split.run"))      // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))  // .alertSecondButtonReturn
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            completion(LineSplitter.Options(delimiter: field.stringValue,
                                            trimEach: trimCheck.state == .on,
                                            dropEmpty: dropCheck.state == .on))
        }
    }

    // MARK: - 序列号（起始号、增量号、填充号和分隔符通过对话框接收）

    private static let lastNumberOptionsKey = "toolbox.lastNumberOptions"

    /// 为每个选定行的开头分配一个顺序编号（参数 = `TextTransform.numberLines` 的一般形式）。
    func numberActiveSelectionLines() {
        guard let pane = activeViewer, pane.canEdit,
              let selection = pane.selectedText, !selection.isEmpty else { NSSound.beep(); return }
        promptForNumberOptions { [weak self] options in
            guard let self, let options else { return }
            self.saveNumberOptions(options)
            // 在执行替换操作之前，请检查在工作表关闭时所选内容是否已更改。
            guard self.activeViewer === pane, pane.selectedText == selection else { return }
            let result = LineNumberer.number(selection, options: options)
            guard result != selection else { return }   // 无更改意味着无撤销。
            pane.replaceSelection(with: result)
        }
    }

    /// 具有先前设置（起始值、增量、填充、分隔符）作为初始值的工作表。
    private func promptForNumberOptions(completion: @escaping (LineNumberer.Options?) -> Void) {
        guard let win = window else { completion(nil); return }
        let saved = loadNumberOptions()
        let alert = NSAlert()
        alert.messageText = L("number.prompt")
        alert.informativeText = L("number.message")

        func numberField(_ value: Int) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 24))
            f.alignment = .right
            f.integerValue = value
            return f
        }
        let startField = numberField(saved.start)
        let stepField = numberField(saved.step)
        let padField = numberField(saved.padWidth)
        let sepField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        sepField.stringValue = saved.separator
        sepField.placeholderString = "\\t"

        func row(_ key: String, _ field: NSTextField) -> NSStackView {
            let label = NSTextField(labelWithString: L(key))
            label.setContentHuggingPriority(.required, for: .horizontal)
            let r = NSStackView(views: [label, field])
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }
        let stack = NSStackView(views: [row("number.start", startField), row("number.step", stepField),
                                        row("number.pad", padField), row("number.separator", sepField)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 124)
        alert.accessoryView = stack

        alert.addButton(withTitle: L("number.run"))     // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))  // .alertSecondButtonReturn
        alert.window.initialFirstResponder = startField
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            completion(LineNumberer.Options(start: startField.integerValue,
                                            step: stepField.integerValue,
                                            padWidth: max(0, padField.integerValue),
                                            separator: sepField.stringValue))
        }
    }

    /// 设置顺序编号有 4 个项目，因此将它们全部存储在一个数组中（分隔符仍然是字符串）。
    private func saveNumberOptions(_ o: LineNumberer.Options) {
        UserDefaults.standard.set(["\(o.start)", "\(o.step)", "\(o.padWidth)", o.separator],
                                  forKey: Self.lastNumberOptionsKey)
    }

    private func loadNumberOptions() -> LineNumberer.Options {
        guard let saved = UserDefaults.standard.stringArray(forKey: Self.lastNumberOptionsKey), saved.count == 4
        else { return LineNumberer.Options() }
        return LineNumberer.Options(start: Int(saved[0]) ?? 1, step: Int(saved[1]) ?? 1,
                                    padWidth: Int(saved[2]) ?? 0, separator: saved[3])
    }

    // MARK: - 多光标（仅限小文件编辑窗格）

    /// 是否可以启用多光标菜单？
    var canMultiCursor: Bool { activeViewer?.supportsMultiCursor ?? false }

    /// 将插入符号添加到上一行/下一行的相同数字上（⌥⌘↑ / ⌥⌘↓）。
    func addCaretToActive(above: Bool) {
        guard let v = activeViewer, v.supportsMultiCursor else { NSSound.beep(); return }
        v.addCaret(above: above)
    }

    /// 将与当前选定单词相同的下一个单词添加到选择中 (⌘D)。
    func selectNextOccurrenceInActive() {
        guard let v = activeViewer, v.supportsMultiCursor else { NSSound.beep(); return }
        v.selectNextOccurrence()
    }

    // MARK: - 外部命令过滤器（通过 /bin/sh 替换选择）

    private static let lastFilterCommandKey = "toolbox.lastFilterCommand"

    /// 通过外部命令替换活动文档的选择（相当于 `!` 替换 vim）。
    func filterActiveSelectionThroughCommand() {
        guard let pane = activeViewer, pane.canEdit,
              let selection = pane.selectedText, !selection.isEmpty else { NSSound.beep(); return }
        promptForFilterCommand { [weak self] command in
            guard let self, let command, !command.isEmpty else { return }
            UserDefaults.standard.set(command, forKey: Self.lastFilterCommandKey)
            // 执行在后台进行（请勿使用缓慢/卡顿的命令停止 UI）。结果将在主程序中应用。
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try ShellFilter.run(command: command, input: selection) }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let output):
                        // 如果在执行过程中选择发生变化，则不应用（不要用旧输入覆盖新选择）。
                        guard self.activeViewer === pane, pane.selectedText == selection else {
                            self.presentFilterError(L("filter.selectionChanged")); return
                        }
                        pane.replaceSelection(with: output)
                    case .failure(let error):
                        self.presentFilterError(self.describeFilterError(error))
                    }
                }
            }
        }
    }

    /// 要求输入要执行的命令的表格（前一个命令用作初始值）。
    private func promptForFilterCommand(completion: @escaping (String?) -> Void) {
        guard let win = window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = L("filter.prompt")
        alert.informativeText = L("filter.message")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "sort | uniq"
        field.stringValue = UserDefaults.standard.string(forKey: Self.lastFilterCommandKey) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("filter.run"))     // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))  // .alertSecondButtonReturn
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { completion(nil); return }
            completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func describeFilterError(_ error: Error) -> String {
        guard let f = error as? ShellFilter.Failure else { return error.localizedDescription }
        switch f {
        case .launchFailed(let m): return L("filter.launchFailed", m)
        case .timedOut:            return L("filter.timedOut")
        case .nonZeroExit(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L("filter.exitCode", code)
                                   : L("filter.exitCodeStderr", code, trimmed)
        }
    }

    private func presentFilterError(_ message: String) {
        guard let win = window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("filter.failed")
        alert.informativeText = message
        alert.beginSheetModal(for: win)   // 按钮未指定 = 系统 OK
    }
    /// 活动文档的结构化视图模式（用于检查菜单）。
    var activeStructuredMode: StructuredMode? { activeViewer?.structuredMode }
    /// 设置活动文档的结构化视图模式。
    ///
    /// 无法根据内容识别固定长度列（没有分隔符）。**如果未定义而选中**
    /// 立即询问**—避免创建无法解释的状态，例如“结构化模式，但列未定义”。
    public func setActiveStructuredMode(_ mode: StructuredMode?) {
        guard let v = activeViewer, v.supportsStructured else { NSSound.beep(); return }
        if mode == .fixedWidth, !ColumnGuides(v.columnGuideColumns).hasFieldBoundaries {
            editActiveColumnFields { [weak self] defined in
                guard defined else { return }        // 未定义 = 未切换
                self?.applyStructuredMode(.fixedWidth, to: v)
            }
            return
        }
        applyStructuredMode(mode, to: v)
    }

    private func applyStructuredMode(_ mode: StructuredMode?, to v: DocumentPane) {
        v.setStructuredMode(mode)
        // 大文件端不需要关闭，因为即使文件结构化，搜索和筛选功能也能正常工作（它会执行 grep，同时保持数字对齐）。
        // 较小的文件的内容在格式化后被替换，无法搜索，因此只会关闭该文件。
        if searchPanel?.isVisible == true {
            if v.supportsSearch { refreshSearchBarCapabilities() } else { hideSearch() }
        }
        updateStructuredBanner()
        updateReadOnlyBanner()
    }

    /// 更新结构化显示横幅的显示设置（仅在结构化时显示）。
    private func updateStructuredBanner() {
        if let mode = activeStructuredMode {
            structuredBanner.configure(mode: mode)
            structuredBanner.isHidden = false
        } else {
            structuredBanner.isHidden = true
        }
    }

    /// 将状态/搜索/拖放处理程序连接到每个查看器（仅在激活时反映）。
    private func wire(_ v: DocumentPane) {
        v.onStateChange = { [weak self, weak v] state in
            guard let self, self.activeViewer === v else { return }
            self.statusBar.update(state)
        }
        v.onSearchState = { [weak self, weak v] cur, tot, searching, prog, invalid, capped in
            guard let self, self.activeViewer === v else { return }
            self.searchBar.setCount(current: cur, total: tot, searching: searching,
                                    progress: prog, invalid: invalid, capped: capped)
        }
        v.onDropFiles = { [weak self] urls in urls.forEach { self?.open(url: $0) } }
        v.onDirtyChange = { [weak self, weak v] dirty in
            guard let self, let v else { return }
            // 更新侧边栏标记，无论任何窗格是否已保存。
            if let idx = self.viewers.firstIndex(where: { $0 === v }) {
                self.sidebar.setDirty(idx, dirty)
            }
            // 标题栏中编辑过的点仅反映当前活动的窗格。
            if self.activeViewer === v { self.window?.isDocumentEdited = dirty }
        }
        v.onColumnMismatchChange = { [weak self, weak v] count in
            guard let self, self.activeViewer === v else { return }
            self.statusBar.setMismatchCount(count)
        }
        v.onSaveCompleted = { [weak self, weak v] in
            guard let self, let v else { return }
            self.afterSave(v)
        }
    }

    /// 标题栏中的编辑点（反映 active 窗格的未保存状态）。
    private func updateEditedState() {
        window?.isDocumentEdited = activeViewer?.isDirty ?? false
    }

    /// 激活指定索引中的文档。
    private func activate(_ index: Int) {
        guard index >= 0, index < viewers.count else { return }
        if searchPanel?.isVisible == true { hideSearch() }   // 切换时关闭搜索。
        // AI 该面板常驻显示（即使切换文档也不会消失）。它可以直接分析对其他文档的选择。
        for (i, v) in viewers.enumerated() { v.isHidden = (i != index) }
        activeIndex = index
        let v = viewers[index]
        v.ensureVisibleLayout()                    // 确保在文本隐藏时，插入的文本能够正确呈现。
        v.reEmitState()                            // 将状态栏更新为当前状态
        statusBar.setMismatchCount(v.columnMismatchCount)
        sidebar.setActive(index)
        window?.title = displayName(of: v) + " — " + AppInfo.name
        updateEditedState()
        updateStructuredBanner()
        updateReadOnlyBanner()
        updateExternalBanner()
        v.focusContent()
        persistSession()
    }

    /// 更新只读横幅的显示设置和文本。
    /// **根据原因更改措辞** -- 即使是过滤器和 JSON 查询中的小文件。
    /// 如果您选择“太大”，则会立即显示为谎言，并显示为错误（用户于 2026 年 9 月 24 日指出）。
    private func updateReadOnlyBanner() {
        // 使用结构化显示的只读内容将被排除在外，因为它将由专用横幅引导。
        // diff 也应该被排除在外（“太大无法编辑”的消息是谎言；它甚至不是一个可编辑的屏幕）。
        guard let v = activeViewer, !v.canEdit, v.structuredMode == nil, !(v is DiffViewer) else {
            readOnlyBanner.isHidden = true
            return
        }
        if v.filterMatchLines != nil {
            readOnlyBanner.reason = .filtered
        } else if v.jsonQueryIsActive {
            readOnlyBanner.reason = .jsonQuery
        } else {
            readOnlyBanner.reason = .tooLarge
        }
        readOnlyBanner.isHidden = readOnlyBannerDismissed
    }

    /// 关闭当前文档（如果文档不存在，则关闭窗口）。如果尚未保存，请确认。
    func closeActiveDocument() {
        guard activeIndex >= 0 else { window?.performClose(nil); return }
        let pane = viewers[activeIndex]
        confirmClose(pane) { [weak self] proceed in
            guard let self, proceed else { return }
            self.removePane(pane)
        }
    }

    /// 关闭指定索引处的文档（通过侧边栏中的“×”按钮）。如果尚未保存，请确认。
    func closeDocument(at index: Int) {
        guard index >= 0, index < viewers.count else { return }
        let pane = viewers[index]
        confirmClose(pane) { [weak self] proceed in
            guard let self, proceed else { return }
            self.removePane(pane)
        }
    }

    /// 重新打开最近关闭的文件 (`⌘⇧T`)。每次按下都会从堆栈中移除一个文件 (pop)。
    /// 即使标签页已经重新打开，`open(url:)` 也会将其移动到该标签页，因此不会打开两次。
    func reopenLastClosedDocument() {
        guard let url = closedDocumentURLs.popLast() else { return }
        open(url: url)
    }

    /// 如果未保存，将显示确认表，并返回一条消息询问您是否要关闭它（保存/放弃 = true，取消 = false）。
    private func confirmClose(_ pane: DocumentPane, _ completion: @escaping (Bool) -> Void) {
        guard pane.isDirty, let win = window else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = L("close.unsavedTitle", displayName(of: pane))
        alert.informativeText = L("close.unsavedMessage")
        alert.addButton(withTitle: L("common.save"))       // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.addButton(withTitle: L("common.dontSave"))   // .alertThirdButtonReturn
        alert.beginSheetModal(for: win) { resp in
            switch resp {
            case .alertFirstButtonReturn: completion(pane.save())
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    /// 实际关闭窗格（假设已验证这一点）。
    private func removePane(_ pane: DocumentPane) {
        guard let idx = viewers.firstIndex(where: { $0 === pane }) else { return }
        if searchPanel?.isVisible == true { hideSearch() }
        // 关闭文档是用户主动操作。这是删除 draft 的两种途径之一。
        // 还有一个（保存成功后会从窗格中消失）。如果您不关闭它就关闭它，draft 会保留下来。
        pane.discardDraft()
        if let url = pane.fileURL { closedDocumentURLs.append(url) }
        externallyChangedPanes.remove(ObjectIdentifier(pane))
        externalWatcher.forget(key: ObjectIdentifier(pane))
        let v = viewers.remove(at: idx)
        v.removeFromSuperview()
        if viewers.isEmpty {
            activeIndex = -1
            reloadSidebar()
            window?.title = AppInfo.name
            statusBar.setPlaceholder()
            updateEditedState()
            updateReadOnlyBanner()
            updateExternalBanner()
            persistSession()
        } else {
            activeIndex = min(idx, viewers.count - 1)
            reloadSidebar()
            activate(activeIndex)   // activate 位于 persistSession 内
        }
    }

    /// 将活动文档恢复到其保存的磁盘内容（放弃未保存的更改）。
    func revertActiveDocument() {
        guard activeIndex >= 0 else { return }
        let pane = viewers[activeIndex]
        guard pane.canEdit, pane.isDirty, let url = pane.fileURL, let win = window else { return }
        let alert = NSAlert()
        alert.messageText = L("revert.confirmTitle", displayName(of: pane))
        alert.informativeText = L("revert.confirmMessage")
        alert.addButton(withTitle: L("revert.confirm"))    // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            guard let idx = self.viewers.firstIndex(where: { $0 === pane }) else { return }
            _ = pane.open(url: url)          // 重新加载（dirty=false・状态重置）
            self.externalWatcher.note(key: ObjectIdentifier(pane), url: url)
            self.externallyChangedPanes.remove(ObjectIdentifier(pane))
            self.reloadSidebar()
            self.activate(idx)               // 更新标题/状态/编辑点
        }
    }

    /// 活动文档的缓冲区字符编码（用于检查“重新打开”菜单）。
    var activeEncoding: DetectedEncoding? { activeViewer?.currentEncoding }
    /// 保存活动文档的编码（用于在“文本编码”菜单中显示复选框）。
    var activeSaveEncoding: DetectedEncoding? { activeViewer?.currentSaveEncoding }
    /// 能否使用指定的编码重新打开该文件（文件已确认）？
    var canReopenWithEncoding: Bool { (activeViewer?.fileURL) != nil }

    /// 使用指定的编码重新打开活动文档（纠正自动编码错误导致的乱码）。
    /// 检查是否有未保存的更改（重新打开文件将丢弃编辑内容）。
    func reopenActiveDocument(withEncoding enc: DetectedEncoding) {
        guard activeIndex >= 0 else { return }
        let pane = viewers[activeIndex]
        guard pane.fileURL != nil, enc != pane.currentEncoding else { return }

        let apply: () -> Void = { [weak self] in
            guard let self, let idx = self.viewers.firstIndex(where: { $0 === pane }) else { return }
            _ = pane.reopen(withEncoding: enc)
            if let url = pane.fileURL {
                self.externalWatcher.note(key: ObjectIdentifier(pane), url: url)
                self.externallyChangedPanes.remove(ObjectIdentifier(pane))
            }
            self.reloadSidebar()
            self.activate(idx)
        }
        guard pane.isDirty, let win = window else { apply(); return }
        let alert = NSAlert()
        alert.messageText = L("reopen.confirmTitle", displayName(of: pane))
        alert.informativeText = L("reopen.confirmMessage")
        alert.addButton(withTitle: L("reopen.confirm"))    // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.beginSheetModal(for: win) { resp in
            if resp == .alertFirstButtonReturn { apply() }
        }
    }

    // MARK: - 保存

    func saveActiveDocument() { performSave(saveAs: false) }
    func saveActiveDocumentAs() { performSave(saveAs: true) }

    /// 执行保存。对于大型文件（PieceTableViewer），请使用异步处理和进度显示，以防止 UI 卡死。
    /// 小文件 (EditableViewer) 是瞬时的，因此将像以前一样同步保存。
    private func performSave(saveAs: Bool) {
        guard let v = activeViewer, v.canEdit else { NSSound.beep(); return }
        if let pt = v as? PieceTableViewer {
            let style = AppSettings.saveProgressStyle
            savingPane = pt
            pt.saveAsync(
                saveAs: saveAs,
                onBegin: { [weak self] in self?.beginSaveUI(style) },
                progress: { [weak self] f in self?.updateSaveUI(style, f) },
                completion: { [weak self] ok in
                    self?.savingPane = nil
                    self?.endSaveUI(style)
                    if ok { self?.afterSave(pt) }
                })
        } else {
            if (saveAs ? v.saveAs() : v.save()) { afterSave(v) }
        }
    }

    /// 设置当前文档的“保存时编码”（尚未导出）。
    /// ID 为  / dirty，实际转换和导出将在下次保存时显示进度（⌘S）。
    func setActiveSaveEncoding(to enc: DetectedEncoding) {
        guard let v = activeViewer, v.canEdit, enc != v.currentSaveEncoding else { NSSound.beep(); return }
        v.setSaveEncoding(enc)
        updateEditedState()
    }

    // MARK: - 保存进度 UI（A: 状态栏 / B: 表格 / config 开关。可取消）

    private var savePresenting = false
    private var saveSheet: NSPanel?
    private var saveProgress: NSProgressIndicator?
    private var saveSheetLabel: NSTextField?
    /// 当前正在保存的窗格（取消操作已委托给该窗格）。
    private weak var savingPane: PieceTableViewer?

    /// 取消正在进行的保存（从进度 UI 处的取消按钮）。
    @objc private func cancelActiveSave() { savingPane?.cancelSave() }

    private func beginSaveUI(_ style: SaveProgressStyle) {
        savePresenting = true
        switch style {
        case .statusBar:
            statusBar.showSaving(L("status.saving", 0), onCancel: { [weak self] in self?.cancelActiveSave() })
        case .sheet:
            presentSaveSheet()
        }
    }

    private func updateSaveUI(_ style: SaveProgressStyle, _ fraction: Double) {
        let pct = Int((fraction * 100).rounded())
        switch style {
        case .statusBar: statusBar.updateSaving(L("status.saving", pct))
        case .sheet:
            saveProgress?.doubleValue = Double(pct)
            saveSheetLabel?.stringValue = L("status.saving", pct)
        }
    }

    private func endSaveUI(_ style: SaveProgressStyle) {
        guard savePresenting else { return }
        savePresenting = false
        switch style {
        case .statusBar:
            statusBar.clearMessage()
            activeViewer?.reEmitState()
        case .sheet:
            if let sheet = saveSheet { window?.endSheet(sheet) }
            saveSheet = nil; saveProgress = nil; saveSheetLabel = nil
        }
    }

    /// 显示模态保存表单（进度条 + 标签 + 取消）。
    private func presentSaveSheet() {
        guard let window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 132),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = L("save.sheetTitle")
        guard let content = panel.contentView else { return }

        let label = NSTextField(labelWithString: L("status.saving", 0))
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 100; bar.doubleValue = 0
        let cancel = NSButton(title: L("common.cancel"), target: self, action: #selector(cancelActiveSave))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"   // 已取消， Escape
        for v in [label, bar, cancel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),

            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 16),
        ])
        saveSheet = panel; saveProgress = bar; saveSheetLabel = label
        window.beginSheet(panel, completionHandler: nil)
    }

    /// UI 保存后更新（如果保存位置更改，文件名可能会更改）。
    private func afterSave(_ v: DocumentPane) {
        if let url = v.fileURL {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            // 将您自己编写的版本设为“已知版本”。如果您忘记这样做，每次保存时……
            // 监控系统错误地将数据识别为“外部更改”并重新加载（即，撤销历史记录丢失）。
            externalWatcher.note(key: ObjectIdentifier(v), url: url)
            externallyChangedPanes.remove(ObjectIdentifier(v))
            updateExternalBanner()
        }
        reloadSidebar()
        if activeViewer === v {
            window?.title = displayName(of: v) + " — " + AppInfo.name
        }
        updateEditedState()
        persistSession()   // 保存时 URL 可能确定或改变，因此更新列表
    }

    // MARK: - 浮动面板（可抓取和移动）

    /// 抓住小窗口，猜猜你记得的地点。
    /// 当确定/更改主文本区域的大小时，记忆的位置将被重置。
    /// **启动后立即，大小仍为 0**，因此简单地用 init 敲击它不会恢复其位置。
    /// （在实际设备上发现：水平移动正常，但垂直移动无法恢复正常）。
    @objc private func viewerContainerResized() {
        draggableOverlays.forEach { $0.reclamp() }
    }

    @discardableResult
    private func addDraggable(_ name: String, _ view: NSView,
                              horizontal: NSLayoutConstraint, _ h: OverlayPlacement.Anchor,
                              vertical: NSLayoutConstraint, _ v: OverlayPlacement.Anchor) -> DraggableOverlay {
        let o = DraggableOverlay(name: name, view: view, container: viewerContainer,
                                 horizontal: horizontal, horizontalAnchor: h,
                                 vertical: vertical, verticalAnchor: v)
        draggableOverlays.append(o)
        return o
    }

    /// 将所有移动的窗口重置到其默认位置（同时忘记其原始位置）。
    public func resetOverlayPositions() {
        draggableOverlays.forEach { $0.reset() }
    }

    /// 是否有任何已记住的位置从其默认位置（菜单激活）移动过？
    var hasMovedOverlays: Bool { draggableOverlays.contains { $0.offset != .zero } }

    // MARK: - NSWindowDelegate

    /// 如果窗口大小发生变化，将较小的窗口向内移动。
    /// **如果调整大小后仍位于屏幕外，则无法移除且无法移回原位。**
    public func windowDidResize(_ notification: Notification) {
        draggableOverlays.forEach { $0.reclamp() }
    }


    /// 最常见的用户体验是使用另一个应用程序修复问题，然后再返回，因此请在切换的那一刻检查问题。
    ///（不包含 1 秒计时器等待期）。
    public func windowDidBecomeKey(_ notification: Notification) {
        externalWatcher.tick()
    }

    /// 关闭窗口前检查是否有未保存的文档。
    /// 未保存的新条目（URL 未确认）将在会话恢复后保留，因此不会被检查。已保存文件
    /// 仅检查未保存的编辑。在关闭会话前，将最新文本写入会话。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forceClose { return true }
        flushDrafts()      // 将未保存的文本保存到磁盘（以避免丢失等待去抖动的数据）
        persistSession()
        let dirty = viewers.filter { $0.isDirty && $0.fileURL != nil }
        if dirty.isEmpty { return true }
        let alert = NSAlert()
        alert.messageText = L("close.unsavedAllTitle", dirty.count)
        alert.informativeText = L("close.unsavedMessage")
        alert.addButton(withTitle: L("common.saveAll"))    // .alertFirstButtonReturn
        alert.addButton(withTitle: L("common.cancel"))     // .alertSecondButtonReturn
        alert.addButton(withTitle: L("common.discard"))    // .alertThirdButtonReturn
        alert.beginSheetModal(for: sender) { [weak self] resp in
            guard let self else { return }
            switch resp {
            case .alertFirstButtonReturn:
                if dirty.allSatisfy({ $0.save() }) { self.forceClose = true; sender.close() }
            case .alertThirdButtonReturn:
                self.forceClose = true; sender.close()
            default: break
            }
        }
        return false
    }

    /// 关闭应用前请检查是否有未保存的数据（同步）。如需关闭应用，请按 true。
    /// 会话恢复后，未保存的新条目将保留，因此不会被检查。最新文本将在会话终止前写入。
    func confirmTerminate() -> Bool {
        flushDrafts()      // 将未保存的文本保存到磁盘（以避免因等待防抖而丢失数据）
        persistSession()
        let dirty = viewers.filter { $0.isDirty && $0.fileURL != nil }
        if dirty.isEmpty { return true }
        let alert = NSAlert()
        alert.messageText = L("close.unsavedAllTitle", dirty.count)
        alert.informativeText = L("close.unsavedMessage")
        alert.addButton(withTitle: L("common.saveAll"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.addButton(withTitle: L("common.discard"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return dirty.allSatisfy { $0.save() }
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: - 搜索/关注（委托给活跃的查看者）

    @discardableResult
    func toggleFollow() -> Bool {
        guard let v = activeViewer, v.supportsFollow else { NSSound.beep(); return false }
        v.setFollowMode(!v.isFollowing)
        return v.isFollowing
    }

    func findNext() { activeViewer?.findNext() }
    func findPrev() { activeViewer?.findPrev() }

    // MARK: - 字体大小调整（适用于所有文档）

    func zoomIn()    { applyFontSize(EditorFont.currentSize + 1) }
    func zoomOut()   { applyFontSize(EditorFont.currentSize - 1) }
    func zoomReset() { applyFontSize(EditorFont.defaultSize) }

    private func applyFontSize(_ size: CGFloat) {
        // setSize 抛出 .siftEditorFontChanged，所有窗口都将其反映为 applyCurrentFontSize。
        EditorFont.setSize(size)
    }

    /// 行号跳转对话框。
    func promptGoToLine() {
        guard let v = activeViewer, let win = window else { return }
        let alert = NSAlert()
        alert.messageText = L("gotoLine.prompt")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("gotoLine.go"))
        alert.addButton(withTitle: L("common.cancel"))
        // 表格显示后立即聚焦于输入字段（beginSheetModal 之后）
        // makeFirstResponder 在座位上无法稳定工作，因此请改用 initialFirstResponder。
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { resp in
            // 接受全角数字（日文输入 ON）和逗号分隔值。详情请参见 LineNumberInput。
            if resp == .alertFirstButtonReturn, let n = LineNumberInput.parse(field.stringValue) {
                v.goToLine(n)
            }
        }
    }

    func showSearch() {
        guard let v = activeViewer, v.supportsSearch else { NSSound.beep(); return }
        let selection = v.selectedTextForFind
        let wasHidden = searchPanel?.isVisible != true
        // ⌘F 始终以保留主要文本的搜索开始。漏斗的自动恢复功能会搜索长句。
        // 停止，因为点击区域外的所有内容都会消失，上下文也会丢失。使用漏斗按钮缩小结果范围。
        // 从工具栏的“筛选”选项中显式访问它。
        if wasHidden {
            searchBar.setFilterOn(false)
            v.setFilterMode(false)
        }
        if let panel = searchPanel, !panel.isVisible {
            if let screen = window?.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 28,
                                             y: visible.maxY - panel.frame.height - 48))
            }
        }
        searchPanel?.makeKeyAndOrderFront(nil)
        refreshSearchBarCapabilities()
        if let selection, !selection.isEmpty,
           !selection.contains("\n"), !selection.contains("\r") {
            searchBar.prefillFromSelection(selection)
        }
        searchBar.focusField()
    }

    func showReplace() {
        showSearch()
        searchBar.showReplaceRow()
    }

    /// 调整搜索栏的显示以匹配当前窗格状态。
    /// 当您切换到结构化视图或仅显示匹配行时，您可以搜索但不能写入，
    /// 每次都会重新计算漏斗是否可以更换（打开时的值不会被继承）。
    /// 如果在仅显示书签时触摸搜索词或漏斗，则书签显示将结束。
    private func endBookmarkViewIfNeeded() {
        guard searchBar.isBookmarkViewOn || activeViewer?.isBookmarkView == true else { return }
        searchBar.setBookmarkViewOn(false)
        activeViewer?.setBookmarkView(false)
    }

    private func refreshSearchBarCapabilities() {
        guard let v = activeViewer else { return }
        searchBar.setFilterAvailable(v.supportsSearchFilter)
        searchBar.setBookmarkViewOn(v.isBookmarkView)
        searchBar.setReplaceAvailable(v.supportsReplace)
        searchBar.setContextLines(v.filterContextLines)
        // 解释了过滤器更换失败的原因（用户自己的观察：没有解释的失败会让人觉得像是一个错误）。
        updateReadOnlyBanner()
    }

    /// 更改匹配行前后显示的行数（在搜索栏或菜单中的“±”字段中增加/减少）。
    /// 确保隐藏搜索栏的显示也正确（这样下次打开时值就不会冲突）。
    func setFilterContextLines(_ n: Int) {
        guard let v = activeViewer else { NSSound.beep(); return }
        v.setFilterContextLines(n)
        searchBar.setContextLines(v.filterContextLines)
    }

    /// 当前窗格前后的行数（显示/增加/减少菜单项的起始点）。
    var filterContextLines: Int { activeViewer?.filterContextLines ?? AppSettings.filterContextLines }

    // MARK: - 书签（可从菜单访问）

    /// 当前窗格中是否有书签？（用于启用/禁用菜单）。
    var hasBookmarks: Bool { !(activeViewer?.bookmarkedLines.isEmpty ?? true) }
    var hasDocument: Bool { activeViewer != nil }

    func toggleBookmark() { activeViewer?.toggleBookmark() }
    func goToBookmark(forward: Bool) { activeViewer?.goToBookmark(forward: forward) }

    // MARK: - 结构化视图辅助操作

    /// 将结构化视图的列顺序和宽度应用到当前窗格。
    public func applyViewPreset(order: [String], widths: [String: Int]) {
        activeViewer?.applyStructuredLayout(order: order, widths: widths)
    }

    /// 视图预设尚未实现；标题栏中的入口保持禁用。
    private func presentViewPresets() {
        NSSound.beep()
    }

    /// 在正文下方插入分析窗格（使用 nil 删除）。**core 不知道其内容。**
    public func setAnalysisAccessory(_ view: NSView?, height: CGFloat = 220) {
        guard let content = window?.contentView else { return }
        analysisAccessory?.removeFromSuperview()
        analysisAccessory = nil
        analysisHeightConstraint = nil
        viewerBottomConstraint?.isActive = false

        guard let view else {
            let c = viewerContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            viewerBottomConstraint = c
            c.isActive = true
            return
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        let h = view.heightAnchor.constraint(equalToConstant: height)
        let bottom = viewerContainer.bottomAnchor.constraint(equalTo: view.topAnchor)
        analysisHeightConstraint = h
        viewerBottomConstraint = bottom
        NSLayoutConstraint.activate([
            bottom, h,
            view.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
        analysisAccessory = view
    }

    /// 分析窗格高度（拖动顶部边缘进行更改）。将顶部和底部设置为圆角，以免主文本被挤压。
    public var analysisAccessoryHeight: CGFloat {
        get { analysisHeightConstraint?.constant ?? 0 }
        set {
            let available = window?.contentView?.bounds.height ?? 800
            analysisHeightConstraint?.constant = max(120, min(newValue, available - 200))
        }
    }

    /// 接收一个值并切换到“仅显示匹配的行”（在分析表和表之间来回切换）。
    /// 将其作为**字面值**传递，而不是正则表达式（即使值包含 `.` 或 `[` 也不会出错）。
    public func applyLiteralFilter(_ value: String) {
        guard let v = activeViewer, v.supportsSearchFilter else { NSSound.beep(); return }
        showSearch()
        searchBar.setQuery(value, regex: false, caseSensitive: true, filter: true)
        v.setRegexMode(false)
        v.setCaseSensitive(true)
        v.setSearchQuery(value)
        v.setFilterMode(true)
        refreshSearchBarCapabilities()
    }

    /// 仅显示按时间段选定的行（拖动选择时间分布）。行从 0 开始计数，并按升序排列。
    /// 清除空数组。**这不是搜索**，所以请勿在搜索栏中输入任何内容。
    public func showOnlyLines(_ lines: [Int]) {
        guard let v = activeViewer else { NSSound.beep(); return }
        v.showOnlyLines(lines)
    }

    /// 打开文件并跳转到该行（单击交叉搜索结果）。行号从 1 开始。
    public func open(url: URL, line: Int) {
        open(url: url)
        // 打开后，索引仍在运行，因此会在下一个循环中跳转。
        DispatchQueue.main.async { [weak self] in self?.activeViewer?.goToLine(line) }
    }

    /// 检索活动窗格中指定行（从 1 开始）的正文。
    public func lineText(_ line1Based: Int) -> String? {
        activeViewer?.lineText(line1Based)
    }

    /// 将活动窗格中指定的行（从 1 开始）替换为 `newText`（已启用撤销）。
    public func replaceLine(_ line1Based: Int, with newText: String) -> Bool {
        activeViewer?.replaceLine(line1Based, with: newText) ?? false
    }

    func hideSearch() {
        searchPanel?.orderOut(nil)
        if let v = activeViewer {
            v.setFilterMode(false)
            v.setRegexMode(false)
            v.setCaseSensitive(false)
            v.setSearchQuery("")
            v.focusContent()
        }
        searchBar.clear()
        updateReadOnlyBanner()   // 我已经移除了过滤器，因此由于该过滤器而显示的横幅广告也会消失。
    }

    // MARK: - 打开

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            if response == .OK { panel.urls.forEach { self?.open(url: $0) } }
        }
    }

    // MARK: - 按时间顺序打开

    /// 选择多个日志并按时间分组将其作为单个日志打开。
    ///
    /// 打包后的结果写入临时文件，并通过**常规“打开”路径**传递。使用专用查看器。
    /// 由于没有创建新文件，搜索、筛选、结构化视图和另存为功能仍然可用。
    @objc func openMergedByTime(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = L("merge.open.message")
        panel.prompt = L("merge.open.prompt")
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.mergeByTime(urls: panel.urls)
        }
    }

    /// 实际上负责打包和打开文件。加载和排序在后台进行，UI 只接收结果。
    func mergeByTime(urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let builder = MergedLogBuilder()
            do {
                let result = try builder.build(urls: urls)
                DispatchQueue.main.async { [weak self] in
                    self?.open(url: result.url)
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = L("merge.failedTitle")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - 工具栏
//
// 六个默认项目是对“此应用程序是什么”的声明（面孔）。
// 选择  及其顺序的理由写在 `MainToolbar.swift` 的开头。
// 所有操作都集中在这里，工具栏只处理装配。

extension MainWindowController: NSToolbarItemValidation, NSMenuDelegate {

    fileprivate func setupToolbar() {
        let delegate = MainToolbarDelegate(controller: self)
        toolbarDelegate = delegate
        let toolbar = NSToolbar(identifier: "SiftEditorMainToolbar")
        toolbar.delegate = delegate
        toolbar.allowsUserCustomization = true      // “自定义工具栏...”默认包含在内。
        toolbar.autosavesConfiguration = true       // 排序后的结果将保存给每个用户。
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    // MARK: 活性制御
    //
    // 查看 `can*`，与菜单侧 (`AppDelegate.validateMenuItem`) 相同。
    // 如果判决书写两遍，总是会错位，所以条件是 `MainWindowController`
    // 属性：将其保存在一个位置，并从两边减去。

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .mrSidebar:    return true
        case .mrStructured: return canStructured
        case .mrFilter:
            // 由于它的名称是“仅显示匹配的行”，如果窗格无法筛选，则会失败。
            // 如果你打开后发现没有漏斗，那就违反了承诺。
            return (activeViewer?.supportsSearch ?? false) && (activeViewer?.supportsSearchFilter ?? false)
        case .mrCompare:    return true            // 照看好四个入口中的每一个。
        case .mrFollow:
            // 是否跟踪由按钮本身指示（因为 NSToolbarItem 没有 on/off 的开口，所以用图标表示）。
            let symbol = isFollowingActive ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line"
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
            return canFollow
        default:            return true
        }
    }

    /// 在结构化视图菜单打开之前重新选中该复选框。
    /// JSON 格式仅适用于包含小文件全部文本的窗格，因此只会单独下载该部分。
    public func menuNeedsUpdate(_ menu: NSMenu) {
        let modes = StructuredMode.allCases
        let current = activeStructuredMode
        for item in menu.items where item.action == #selector(toolbarSetStructuredMode(_:)) {
            if item.tag < 0 {
                item.state = (current == nil) ? .on : .off
                item.isEnabled = canStructured
            } else if item.tag < modes.count {
                let mode = modes[item.tag]
                item.state = (current == mode) ? .on : .off
                item.isEnabled = (mode == .json) ? canStructuredJson : canStructured
            }
        }
    }

    // MARK: 動作

    /// 折叠/恢复侧边栏。通过将宽度设置为 0 来折叠（使用 `isHidden` 会对主文本创建约束）。
    @objc func toolbarToggleSidebar(_ sender: Any?) {
        guard let c = sidebarWidthConstraint else { return }
        let collapsed = c.constant == 0
        c.constant = collapsed ? sidebarWidth : 0
        sidebar.isHidden = !collapsed
    }

    /// “筛选” = 首先打开搜索栏，并将匹配行筛选器设置为 ON。
    /// 此按钮的作用是将搜索和缩小结果范围这两个步骤合并为一个步骤。
    @objc func toolbarShowFilter(_ sender: Any?) {
        guard let v = activeViewer, v.supportsSearch, v.supportsSearchFilter else { NSSound.beep(); return }
        showSearch()
        searchBar.setFilterOn(true)
        v.setFilterMode(true)
        refreshSearchBarCapabilities()
    }

    @objc func toolbarSetStructuredMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let modes = StructuredMode.allCases
        setActiveStructuredMode(item.tag < 0 || item.tag >= modes.count ? nil : modes[item.tag])
    }

    @objc func toolbarToggleFollow(_ sender: Any?) { _ = toggleFollow() }

    /// 剪贴板历史记录（简单 - B6）。按下时立即创建并显示菜单。
    /// (继续让 `.menu` 持有 `NSMenuToolbarItem` 并没有消除缓存的怀疑)。
    @objc func toolbarShowClipboardHistory(_ sender: Any?) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let view = window?.contentView,
              let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(appDelegate.freshClipboardHistoryMenu(), with: event, for: view)
    }

    @objc func toolbarCompareFiles(_ sender: Any?)          { compareFiles() }
    @objc func toolbarCompareOpenDocuments(_ sender: Any?)   { compareOpenDocuments() }
    @objc func toolbarCompareWithClipboard(_ sender: Any?)   { compareWithClipboard() }
    @objc func toolbarCompareWithURL(_ sender: Any?)         { compareWithURL() }
}
