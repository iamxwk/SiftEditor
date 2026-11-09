import AppKit

/// **必须兼容 `NSMenuItemValidation`。** 否则，`validateMenuItem` 将无法工作。
/// Objective-C 不可见，且 AppKit 从未被调用——“方法已编写，但是……”
/// 勾选标记和禁用功能完全失效；它会静默地停止工作（截至 2026 年 8 月 19 日）
/// （发现出厂时即存在此状态）。即使 Swift 4 及更高版本继承了 NSObject
/// 成员不会自动分配 @objc，因此匹配是唯一进入的方式。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var windowController: MainWindowController?
    private var followItem: NSMenuItem?
    private var recentMenu: NSMenu?
    /// 剪贴板历史记录可以在两个位置显示：编辑菜单和工具栏。
    /// 由于  / `menuNeedsUpdate` 由同一个 delegate (self) 接收，因此可以区分它们。
    private var clipboardHistoryMenus: [NSMenu] = []
    /// 简单剪贴板历史记录（B6，空闲核心）。不持久化。内存：`clipboard-history-corporate-angle`。
    private let clipboardHistory = ClipboardHistory()
    /// 一个打开的远程面板。如果不按住它，它会立即关闭（NSWindowController 不会自己保持关闭状态）。
    private var remoteWindows: [RemoteWindowController] = []
    private var folderWindows: [FolderWindowController] = []
    private var preferencesController: PreferencesWindowController?
    private var pathOpenController: PathOpenWindowController?
    /// 输入期间的临时文件 → 输入完成后的清理。
    private var pipeEnders: [String: () -> Void] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ：在设置新的产品图标之前，使用默认图标 macOS。
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        if let url = iconURL,
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        buildMenu()

        // 从  Finder 启动时，open (_:) 可能在此之前到达。
        // 为避免遗漏当时打开的任何文档，如果现有文档已存在，请重新使用现有文档。
        let controller = ensureController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 不要恢复颜色面板。
        //
        // NSColorPanel 受 macOS 窗口恢复的影响，因此一旦您在首选项中选择颜色，
        // **从现在开始，每次启动应用程序时都会自动打开此选项。** 没有人希望在启动应用程序后立即选择颜色。
        let colorPanel = NSColorPanel.shared
        colorPanel.isRestorable = false
        DispatchQueue.main.async { if colorPanel.isVisible { colorPanel.close() } }

        // 打开所有作为命令行参数传递的路径。
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { controller.open(url: url) }
        }

        // 第二个及后续的 `| sifteditor` 将传递被覆盖的临时文件的路径 (B15)。
        // 从第一个数据（在末尾之后）开始，并在输入完成后停止跟踪。
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Intake.pipeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let path = note.userInfo?["path"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            guard Intake.isScratchFile(url) else { return }
            let c = self.ensureController()
            c.showWindow(nil)
            self.pipeEnders[path] = c.openPipedStream(url)
            NSApp.activate(ignoringOtherApps: true)
        }
        center.addObserver(forName: Intake.pipeEndNotification, object: nil, queue: .main) { [weak self] note in
            guard let path = note.userInfo?["path"] as? String else { return }
            self?.pipeEnders.removeValue(forKey: path)?()
        }

        // 接收通过管道（`kubectl logs … | sifteditor`）的内容物。
        //
        // Finder 和 Dock 在启动时不是终端，因此仅 `isatty` 是不够的。
        // 无法进行判定。只有当它是 FIFO 或普通文件 (Intake.stdinIsPiped) 时才会被接受。
        //
        // 等待读取完成，但不要停止 UI。即使发送了 10 GB 的日志，操作也不会停止。
        // 在您阅读完毕后，只要您还活着，就会出现一个新标签页。
        // ：无需等待读取完成，在第一个数据到达时立即打开文件并跟随文件末尾。
        // (`tail -f app.log | sifteditor`)。请勿停止 UI。
        if Intake.stdinIsPiped() {
            DispatchQueue.global(qos: .userInitiated).async {
                var ender: (() -> Void)?
                Intake.streamStdin(onFirstData: { url in
                    DispatchQueue.main.async { ender = controller.openPipedStream(url) }
                }, onEnd: { _ in
                    DispatchQueue.main.async { ender?() }
                })
            }
        }

        // 恢复程序上次关闭时的文件列表。**打开文件时务必调用此命令：**
        // 如果跳过恢复过程，启动时打开的文件将使用之前的会话（包括任何未保存的新文本）。
        // 将被覆盖。哪个打开的文件优先处理由 restoreSession 决定。
        // 窗口完全显示后进行还原（如果运行同步，还原后立即显示的窗格将是）
        // （避免文本最初未渲染，直到执行操作后才显示为空的问题）。
        DispatchQueue.main.async { controller.restoreSession() }

        // App Store 这不是一个发行版，所以你需要自己通知其他人新版本的存在。
        // 每天只发一次话，而且只有在有新版本可用时才会发话（失败的版本会被默默丢弃）。
        UpdateChecker.check(manual: false)

        // 开始轮询剪贴板历史记录（在后台运行时，它还会从其他应用程序获取副本）。
        // 记录后立即刷新所有菜单 ── 工具栏上的 NSMenuToolbarItem 为
        // menuNeedsUpdate 不会在每次打开时都调用（而是调用编辑菜单的子菜单）。
        // 由于在实际设备上发现了 ，我们将不会仅仅依赖 delegate 的延迟更新。
        clipboardHistory.onChange = { [weak self] in self?.refreshClipboardHistoryMenus() }
        clipboardHistory.start()

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// 切换到另一个应用程序时，任何未保存的文本都将写入磁盘。
    /// 防止在等待按键防抖时系统崩溃（强制退出）导致数据丢失。
    func applicationDidResignActive(_ notification: Notification) {
        windowController?.flushDrafts()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = windowController else { return .terminateNow }
        return c.confirmTerminate() ? .terminateNow : .terminateCancel
    }

    // 打开  Finder / 文件拖放（可拖放多个文件）+ 分享链接 (sifteditor://)。
    func application(_ application: NSApplication, open urls: [URL]) {
        let c = ensureController()
        c.showWindow(nil)
        for url in urls {
            if SettingsBundle.isSettingsURL(url) {
                // 外观共享链接：请查看并应用（以确保外观不会在未通知的情况下发生更改）。
                SettingsShare.apply(url: url, presenting: NSApp.keyWindow ?? c.window)
            } else {
                c.open(url: url)
            }
        }
    }

    private func ensureController() -> MainWindowController {
        if let c = windowController { return c }
        let c = MainWindowController()
        windowController = c
        return c
    }

    @objc private func showAbout(_ sender: Any?) {
        // 明确指定即使未使用该捆绑包（开发版本），也应正确显示名称和版本。
        // 将  `.version`（括号内的版本号）留空，以防止重复显示。
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.version,
            .version: "",
            .credits: aboutCredits(),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// About 面板底部描述及项目地址。
    private func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2

        let credits = NSMutableAttributedString(
            string: L("about.credits"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
        credits.append(NSAttributedString(
            string: "\n\n" + L("about.project"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .link: AppInfo.helpURL,
                .paragraphStyle: paragraph,
            ]))
        return credits
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdateChecker.check(manual: true)   // 显式调用始终报告结果。
    }

    @objc private func newDocument(_ sender: Any?) {
        ensureController().newDocument()
    }

    @objc private func openDocument(_ sender: Any?) {
        ensureController().openDocument(sender)
    }

    @objc private func openMergedByTime(_ sender: Any?) {
        ensureController().openMergedByTime(sender)
    }

    @objc private func performFind(_ sender: Any?) {
        windowController?.showSearch()
    }

    @objc private func performFindNext(_ sender: Any?) { windowController?.findNext() }
    @objc private func performFindPrev(_ sender: Any?) { windowController?.findPrev() }
    @objc private func performReplace(_ sender: Any?) { windowController?.showReplace() }
    @objc private func performSearchFilter(_ sender: Any?) { windowController?.toolbarShowFilter(sender) }

    // 匹配行（grep -C）前后要显示的行数。每次增加一行，以响应“我想查看此行的前一行”的请求。
    @objc private func performToggleBookmark(_ sender: Any?) {
        windowController?.toggleBookmark()
    }

    @objc private func performNextBookmark(_ sender: Any?) {
        windowController?.goToBookmark(forward: true)
    }

    @objc private func performPrevBookmark(_ sender: Any?) {
        windowController?.goToBookmark(forward: false)
    }

    @objc private func increaseFilterContext(_ sender: Any?) {
        guard let c = windowController else { return }
        c.setFilterContextLines(c.filterContextLines + 1)
    }
    @objc private func decreaseFilterContext(_ sender: Any?) {
        guard let c = windowController else { return }
        c.setFilterContextLines(c.filterContextLines - 1)
    }

    @objc private func performCloseDocument(_ sender: Any?) {
        if let c = windowController { c.closeActiveDocument() } else { NSApp.keyWindow?.performClose(nil) }
    }

    /// 当前处于前台的远程窗口（如果有）。⌘S 会优先显示该窗口。
    private var keyRemoteWindow: RemoteWindowController? {
        remoteWindows.first { $0.window === NSApp.keyWindow }
    }

    @objc private func performSave(_ sender: Any?) {
        if let remote = keyRemoteWindow { return remote.saveEdits() }
        windowController?.saveActiveDocument()
    }
    @objc private func performSaveAs(_ sender: Any?) { windowController?.saveActiveDocumentAs() }
    @objc private func performRevert(_ sender: Any?) { windowController?.revertActiveDocument() }
    @objc private func performPrint(_ sender: Any?) { windowController?.printActiveDocument() }

    @objc private func reopenWithEncoding(_ sender: NSMenuItem) {
        let list = DetectedEncoding.selectable
        guard sender.tag >= 0, sender.tag < list.count else { return }
        windowController?.reopenActiveDocument(withEncoding: list[sender.tag])
    }

    @objc private func setSaveEncoding(_ sender: NSMenuItem) {
        let list = DetectedEncoding.selectable
        guard sender.tag >= 0, sender.tag < list.count else { return }
        windowController?.setActiveSaveEncoding(to: list[sender.tag])
    }

    @objc private func performGoToLine(_ sender: Any?) { windowController?.promptGoToLine() }

    @objc private func performZoomIn(_ sender: Any?) { windowController?.zoomIn() }
    @objc private func performZoomOut(_ sender: Any?) { windowController?.zoomOut() }
    @objc private func performZoomReset(_ sender: Any?) { windowController?.zoomReset() }

    // 比较 (diff)。所有四个输入 windowController 都路由到同一个 DiffViewer。
    @objc private func compareFiles(_ sender: Any?)         { windowController?.compareFiles() }
    @objc private func compareOpenDocuments(_ sender: Any?) { windowController?.compareOpenDocuments() }
    @objc private func compareWithClipboard(_ sender: Any?) { windowController?.compareWithClipboard() }
    @objc private func compareWithURL(_ sender: Any?)       { windowController?.compareWithURL() }
    @objc private func nextDifference(_ sender: Any?)       { windowController?.activeDiffViewer?.nextHunk() }
    /// 切换**比较方法**而非入口点（忽略值，仅查看形状）。无论入口点如何，此方法均有效。
    @objc private func toggleFormatCompare(_ sender: Any?)  { windowController?.activeDiffViewer?.toggleFormatCompare() }
    @objc private func adoptHunk(_ sender: Any?)            { windowController?.activeDiffViewer?.adoptCurrentHunk() }
    @objc private func revertHunk(_ sender: Any?)           { windowController?.activeDiffViewer?.revertCurrentHunk() }
    @objc private func saveMergedResult(_ sender: Any?)     { windowController?.activeDiffViewer?.saveMerged() }
    @objc private func previousDifference(_ sender: Any?)   { windowController?.activeDiffViewer?.previousHunk() }

    @objc private func setStructuredMode(_ sender: NSMenuItem) {
        let modes = StructuredMode.allCases
        let mode: StructuredMode? = (sender.tag >= 0 && sender.tag < modes.count) ? modes[sender.tag] : nil
        windowController?.setActiveStructuredMode(mode)
    }

    @objc private func toggleJsonQuery(_ sender: NSMenuItem) {
        windowController?.toggleActiveJsonQuery()
    }

    @objc private func toggleColumnRuler(_ sender: NSMenuItem) {
        windowController?.toggleActiveColumnRuler()
    }

    @objc private func resetOverlayPositions(_ sender: NSMenuItem) {
        windowController?.resetOverlayPositions()
    }

    @objc private func alignToColumnGuides(_ sender: NSMenuItem) {
        windowController?.alignActiveToColumnGuides()
    }

    @objc private func editColumnFields(_ sender: NSMenuItem) {
        windowController?.editActiveColumnFields()
    }

    @objc private func clearColumnGuides(_ sender: NSMenuItem) {
        windowController?.clearActiveColumnGuides()
    }

    @objc private func applyTextTransform(_ sender: NSMenuItem) {
        guard let t = TextTransform(rawValue: sender.tag) else { return }
        windowController?.applyActiveTextTransform(t)
    }

    @objc private func filterThroughCommand(_ sender: Any?) {
        windowController?.filterActiveSelectionThroughCommand()
    }

    @objc private func splitLines(_ sender: Any?) {
        windowController?.splitActiveSelectionIntoLines()
    }

    @objc private func numberLines(_ sender: Any?) {
        windowController?.numberActiveSelectionLines()
    }

    @objc private func extractFrequentStrings(_ sender: Any?) {
        windowController?.extractFrequentStrings()
    }

    // 多光标（添加向上和向下光标/重复选择同一个单词）。
    @objc private func addCaretAbove(_ sender: Any?) { windowController?.addCaretToActive(above: true) }
    @objc private func addCaretBelow(_ sender: Any?) { windowController?.addCaretToActive(above: false) }
    @objc private func selectNextOccurrence(_ sender: Any?) { windowController?.selectNextOccurrenceInActive() }

    // MARK: - 最近使用过的物品

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ensureController().open(url: url)
    }

    @objc private func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    @objc private func performReopenClosedDocument(_ sender: Any?) {
        windowController?.reopenLastClosedDocument()
    }

    /// 打开远程面（`⌃⌘O`）。
    ///
    /// **与我手头的视图不同。** 我的查看器是基于行索引构建的，
    /// 如果远程创建，则会丢失整个画面（“不要掉落”这一点将变得毫无意义）。
    /// 因为我只想远程查看结尾和筛选后的结果，所以我有一个不需要索引的单独部分。
    @objc func openRemote(_ sender: Any?) {
        let controller = RemoteWindowController()
        remoteWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// 选择您的文件夹并打开树状窗口 (⌥⇧⌘O)。
    @objc private func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showFolder(url)
    }

    /// 打开文件夹窗口。如果同一文件夹的窗口已存在，则会将其置于最前面，而不是创建新窗口。
    private func showFolder(_ url: URL) {
        if let existing = folderWindows.first(where: { $0.folderURL.standardizedFileURL == url.standardizedFileURL }) {
            return existing.show()
        }
        let controller = FolderWindowController(
            folderURL: url,
            openHandler: { [weak self] file in self?.ensureController().open(url: file) },
            onClose: { [weak self] closed in self?.folderWindows.removeAll { $0 === closed } }
        )
        folderWindows.append(controller)
        controller.show()
    }

    /// 删除远程连接历史记录。重新创建候选的已打开远程窗口。
    @objc private func clearRemoteHistory(_ sender: Any?) {
        RemoteHistory.clear()
        remoteWindows.forEach { $0.reloadHistory() }
    }

    /// 粘贴从终端或 AI 的答案复制的路径并打开它 (⌥⌘O)。
    @objc private func openByPath(_ sender: Any?) {
        if pathOpenController == nil {
            pathOpenController = PathOpenWindowController(
                openHandler: { [weak self] url in self?.ensureController().open(url: url) },
                folderHandler: { [weak self] url in self?.showFolder(url) }
            )
        }
        pathOpenController?.show()
    }

    /// File > 最近使用的项目 / Edit > 剪贴板历史记录：每次打开子菜单时重建。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentMenu { updateRecentMenu(menu); return }
        if clipboardHistoryMenus.contains(where: { $0 === menu }) { updateClipboardHistoryMenu(menu); return }
    }

    private func updateRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: L("menu.recentEmpty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("menu.clearRecent"),
                               action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    // MARK: - 剪贴板历史记录（简易版，B6）

    /// 每次记录副本或删除副本时调用 (`ClipboardHistory.onChange`)。
    /// 即使没有打开菜单也很轻量级（仅重新创建了几个 `NSMenuItem`）。
    private func refreshClipboardHistoryMenus() {
        for menu in clipboardHistoryMenus { updateClipboardHistoryMenu(menu) }
    }

    /// 每次调用时创建一个新菜单，并记住它以便您可以使用 `menuNeedsUpdate` 将其拾取。
    /// 编辑菜单的子菜单和工具栏项目（默认情况下关闭）都会经过这里。
    ///
    /// **创建时请填写内容。**工具栏上的 `NSMenuToolbarItem` 留空。
    /// 当你把它交给别人时，“打开后什么也没有出现”（它直接通过，无需等待 `menuNeedsUpdate`），
    /// 不要仅仅依赖延迟更新；请在此处填写首次更新。
    func makeClipboardHistoryMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.clipboardHistory"))
        menu.delegate = self
        clipboardHistoryMenus.append(menu)
        updateClipboardHistoryMenu(menu)
        return menu
    }

    /// 使用此工具栏。**无需依赖更新 (delegate) 或通知 (onChange)，
    /// 按下后立即创建并交付。** 以 `NSMenuToolbarItem` 的形式持续按住 `.menu`
    /// 在实际设备上，“按下按钮后仍然保留旧内容”的问题无论修复多少次都依然存在，问题出在 `.menu` 这边。
    /// 由于无法确定是否已缓存，因此更改了设计，使其完全不缓存。
    func freshClipboardHistoryMenu() -> NSMenu {
        let menu = NSMenu(title: L("menu.clipboardHistory"))
        updateClipboardHistoryMenu(menu)   // 内部也会调用 tick()，因此它会被更新到最新状态。
        return menu
    }

    private func updateClipboardHistoryMenu(_ menu: NSMenu) {
        // 轮询以 0.5 秒的间隔进行。如果复制后立即打开，则文件将保持过期状态，直到下一个 tick 日期。
        // 打开后立即强制重新加载（不要依赖计时器）。
        clipboardHistory.tick()
        menu.removeAllItems()
        let entries = clipboardHistory.entries
        if entries.isEmpty {
            let empty = NSMenuItem(title: L("menu.clipboardHistoryEmpty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: Self.clipboardMenuTitle(for: entry.text),
                                  action: #selector(selectClipboardHistoryItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            item.toolTip = entry.text
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("menu.clearClipboardHistory"),
                               action: #selector(clearClipboardHistory(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// 此设置会将包含换行符的长内容调整为单行菜单标题。内容本身将显示为 `toolTip`。
    static func clipboardMenuTitle(for text: String, maxLength: Int = 60) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: "⏎ ")
        guard oneLine.count > maxLength else { return oneLine }
        return String(oneLine.prefix(maxLength)) + "…"
    }

    /// 将选定的项目粘贴到当前正在编辑的位置（通过 General pasteboard）。
    @objc private func selectClipboardHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    @objc private func clearClipboardHistory(_ sender: Any?) {
        clipboardHistory.clear()
    }

    @objc private func performFollow(_ sender: Any?) {
        let on = windowController?.toggleFollow() ?? false
        followItem?.state = on ? .on : .off
    }

    // MARK: - 菜单启用/禁用

    /// 根据活动文档的功能启用/禁用菜单项。
    /// （编辑相关条目，例如 target 和 nil，包括 Undo/Cut，由 NSTextView 自动验证。）
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performSave(_:)), let remote = keyRemoteWindow {
            return remote.canSaveEdits
        }
        guard let c = windowController else { return true }
        switch item.action {
        case #selector(performSave(_:)), #selector(performSaveAs(_:)):
            return c.canSave
        case #selector(performRevert(_:)):
            return c.canRevert
        case #selector(performPrint(_:)):
            return c.canPrint   // 无法打印大型文件（它们可能长达数百万页）。
        case #selector(reopenWithEncoding(_:)):
            let list = DetectedEncoding.selectable
            if item.tag >= 0, item.tag < list.count {
                item.state = (c.activeEncoding == list[item.tag]) ? .on : .off
            }
            return c.canReopenWithEncoding
        case #selector(setSaveEncoding(_:)):
            // 检查当前保存编码（您可以稍后更改它，所以请保持启用状态）。
            let list = DetectedEncoding.selectable
            if item.tag >= 0, item.tag < list.count {
                item.state = (c.activeSaveEncoding == list[item.tag]) ? .on : .off
            }
            return c.canSave
        case #selector(performFind(_:)), #selector(performFindNext(_:)), #selector(performFindPrev(_:)):
            return c.canSearch
        case #selector(performReplace(_:)):
            return c.canSave
        case #selector(performSearchFilter(_:)):
            return c.canFilter
        case #selector(performToggleBookmark(_:)):
            return c.hasDocument
        // 当没有目的地时无法按下 ── 按下后无任何反应的菜单
        // 我无法判断书签是丢失了还是损坏了。
        case #selector(performNextBookmark(_:)), #selector(performPrevBookmark(_:)):
            return c.hasBookmarks
        case #selector(increaseFilterContext(_:)):
            return c.canFilter && c.filterContextLines < FilterContext.maxContext
        case #selector(decreaseFilterContext(_:)):
            return c.canFilter && c.filterContextLines > 0
        case #selector(performFollow(_:)):
            item.state = c.isFollowingActive ? .on : .off
            return c.canFollow
        case #selector(performGoToLine(_:)), #selector(performCloseDocument(_:)):
            return c.hasActiveDocument
        case #selector(extractFrequentStrings(_:)):
            return c.hasActiveDocument
        case #selector(performReopenClosedDocument(_:)):
            return c.canReopenClosedDocument
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)):
            return c.activeDiffViewer != nil
        case #selector(toggleFormatCompare(_:)):
            item.state = (c.activeDiffViewer?.isFormatCompare ?? false) ? .on : .off
            return c.activeDiffViewer != nil
        case #selector(adoptHunk(_:)), #selector(revertHunk(_:)):
            // ：按形状比较时，合并功能被禁用（相同形状 = 不同内容。合并会擦除内容）。
            guard let d = c.activeDiffViewer else { return false }
            return d.canMerge && d.hasCurrentHunk
        case #selector(saveMergedResult(_:)):
            return c.activeDiffViewer?.canMerge ?? false
        case #selector(setStructuredMode(_:)):
            let modes = StructuredMode.allCases
            let current = c.activeStructuredMode
            if item.tag < 0 { item.state = (current == nil) ? .on : .off }
            else if item.tag < modes.count { item.state = (current == modes[item.tag]) ? .on : .off }
            // JSON 格式设置仅应用于保留全文的小文件窗格（大文件的条目已被禁用）。
            if item.tag >= 0, item.tag < modes.count, modes[item.tag] == .json { return c.canStructuredJson }
            return c.canStructured
        case #selector(toggleJsonQuery(_:)):
            item.state = c.jsonQueryIsActive ? .on : .off
            return c.canJsonQuery
        case #selector(toggleColumnRuler(_:)):
            item.state = c.columnRulerIsVisible ? .on : .off
            return c.canColumnRuler
        case #selector(resetOverlayPositions(_:)):
            return c.hasMovedOverlays
        case #selector(alignToColumnGuides(_:)):
            return c.canAlignToColumnGuides
        case #selector(editColumnFields(_:)):
            return c.canColumnRuler
        case #selector(clearColumnGuides(_:)):
            return c.hasColumnGuides
        case #selector(applyTextTransform(_:)), #selector(filterThroughCommand(_:)),
             #selector(splitLines(_:)), #selector(numberLines(_:)):
            return c.canTransformText   // 仅在可编辑窗格中有效
        case #selector(addCaretAbove(_:)), #selector(addCaretBelow(_:)), #selector(selectNextOccurrence(_:)):
            return c.canMultiCursor     // 多光标功能仅在小文件编辑窗格中可用。

        default:
            return true
        }
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = AppInfo.name
        let aboutItem = NSMenuItem(title: L("menu.about", appName),
                                   action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        // 更新检查仅针对已声明分发源的 .app 捆绑包发出。
        // （以未声明的版本发布会导致用户被提示下载其他产品）。
        if UpdateChecker.isAvailable {
            let updateItem = NSMenuItem(title: L("menu.checkForUpdates"),
                                        action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            updateItem.target = self
            appMenu.addItem(updateItem)
        }
        appMenu.addItem(.separator())
        let prefsItem = NSMenuItem(title: L("menu.preferences"),
                                   action: #selector(openPreferences(_:)), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.hide", appName),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit", appName),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 文件菜单
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: L("menu.file"))
        fileMenuItem.submenu = fileMenu
        let newItem = NSMenuItem(title: L("menu.new"),
                                 action: #selector(newDocument(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        let openItem = NSMenuItem(title: L("menu.open"),
                                  action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        // 打开按时间顺序捆绑在一起的多个日志。
        let mergeItem = NSMenuItem(title: L("menu.openMerged"),
                                   action: #selector(openMergedByTime(_:)), keyEquivalent: "O")
        mergeItem.keyEquivalentModifierMask = [.command, .shift]
        mergeItem.target = self
        fileMenu.addItem(mergeItem)
        // 查看远程文件 (B5)。将通过您设备上的查看器打开不同的视图。
        let remoteItem = NSMenuItem(title: L("menu.openRemote"),
                                    action: #selector(openRemote(_:)), keyEquivalent: "o")
        remoteItem.keyEquivalentModifierMask = [.command, .control]
        remoteItem.target = self
        fileMenu.addItem(remoteItem)
        // 粘贴从终端或 AI 的答案中复制的路径并打开它。
        let pathItem = NSMenuItem(title: L("menu.openByPath"),
                                   action: #selector(openByPath(_:)), keyEquivalent: "o")
        pathItem.keyEquivalentModifierMask = [.command, .option]
        pathItem.target = self
        fileMenu.addItem(pathItem)
        // 以树状视图浏览文件夹（按文件名筛选和打开）
        let folderItem = NSMenuItem(title: L("menu.openFolder"),
                                    action: #selector(openFolder(_:)), keyEquivalent: "o")
        folderItem.keyEquivalentModifierMask = [.command, .option, .shift]
        folderItem.target = self
        fileMenu.addItem(folderItem)
        let clearHistoryItem = NSMenuItem(title: L("menu.clearRemoteHistory"),
                                          action: #selector(clearRemoteHistory(_:)), keyEquivalent: "")
        clearHistoryItem.target = self
        fileMenu.addItem(clearHistoryItem)
        // 最近使用的项目（每次打开子菜单时，子菜单都会使用 menuNeedsUpdate 重建）
        let recentItem = NSMenuItem(title: L("menu.openRecent"), action: nil, keyEquivalent: "")
        let recent = NSMenu(title: L("menu.openRecent"))
        recent.delegate = self
        recentItem.submenu = recent
        fileMenu.addItem(recentItem)
        self.recentMenu = recent
        // 重新打开已关闭的文件（堆栈方法 - 每次按下都会打开最近打开的文件）
        let reopenClosedItem = NSMenuItem(title: L("menu.reopenClosed"),
                                          action: #selector(performReopenClosedDocument(_:)), keyEquivalent: "t")
        reopenClosedItem.keyEquivalentModifierMask = [.command, .shift]
        reopenClosedItem.target = self
        fileMenu.addItem(reopenClosedItem)
        fileMenu.addItem(.separator())
        let saveItem = NSMenuItem(title: L("menu.save"),
                                  action: #selector(performSave(_:)), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)
        let saveAsItem = NSMenuItem(title: L("menu.saveAs"),
                                    action: #selector(performSaveAs(_:)), keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)
        let revertItem = NSMenuItem(title: L("menu.revert"),
                                    action: #selector(performRevert(_:)), keyEquivalent: "")
        revertItem.target = self
        fileMenu.addItem(revertItem)
        // 使用指定编码重新打开（纠正自动检测错误导致的乱码）
        let reopenItem = NSMenuItem(title: L("menu.reopenWithEncoding"), action: nil, keyEquivalent: "")
        let reopenMenu = NSMenu(title: L("menu.reopenWithEncoding"))
        for (i, enc) in DetectedEncoding.selectable.enumerated() {
            let it = NSMenuItem(title: enc.displayName,
                                action: #selector(reopenWithEncoding(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            reopenMenu.addItem(it)
        }
        reopenItem.submenu = reopenMenu
        fileMenu.addItem(reopenItem)
        // 文本编码（设置保存时使用的编码。更改将在下次保存后生效。）
        let encItem = NSMenuItem(title: L("menu.textEncoding"), action: nil, keyEquivalent: "")
        let encMenu = NSMenu(title: L("menu.textEncoding"))
        for (i, enc) in DetectedEncoding.selectable.enumerated() {
            let it = NSMenuItem(title: enc.displayName,
                                action: #selector(setSaveEncoding(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            encMenu.addItem(it)
        }
        encItem.submenu = encMenu
        fileMenu.addItem(encItem)
        fileMenu.addItem(.separator())
        // 打印（也可以通过在对话框中选择“另存为 PDF ▸ PDF”输出为 PDF）。
        let printItem = NSMenuItem(title: L("menu.print"),
                                   action: #selector(performPrint(_:)), keyEquivalent: "p")
        printItem.target = self
        fileMenu.addItem(printItem)
        fileMenu.addItem(.separator())
        let closeItem = NSMenuItem(title: L("menu.close"),
                                   action: #selector(performCloseDocument(_:)), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)

        // 编辑菜单（搜索）
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L("menu.edit"))
        editMenuItem.submenu = editMenu
        // 撤销/重做（⌘Z / ⌘⇧Z）：target nil 到响应链（NSTextView）。
        let undoItem = NSMenuItem(title: L("menu.undo"),
                                  action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: L("menu.redo"),
                                  action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        // 剪切/复制/粘贴/全选：将 target nil 到响应链
        // （编辑窗格由 NSTextView 处理，查看器仅由 DocumentView 复制）。
        let cutItem = NSMenuItem(title: L("menu.cut"),
                                 action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(cutItem)
        let copyItem = NSMenuItem(title: L("menu.copy"),
                                  action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: L("menu.paste"),
                                   action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(pasteItem)
        let selectAllItem = NSMenuItem(title: L("menu.selectAll"),
                                       action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(selectAllItem)
        // 剪贴板历史记录（简单 - B6）：每次打开时都使用 menuNeedsUpdate 重建，选中时粘贴。
        // 您还可以从工具栏（默认情况下是关闭的）访问相同的创建方法菜单（`makeClipboardHistoryMenu`）。
        let clipboardHistoryItem = NSMenuItem(title: L("menu.clipboardHistory"), action: nil, keyEquivalent: "")
        clipboardHistoryItem.submenu = makeClipboardHistoryMenu()
        editMenu.addItem(clipboardHistoryItem)
        editMenu.addItem(.separator())
        // 同时显示匹配行（grep - C）的前一行和后一行。这样，您可以在保持选择范围缩小的同时，展开或收起所选行的前一行和后一行。
        // 也可以通过键盘访问（将与搜索栏中的“±”字段相同的值移动到相应位置）。
        let moreContext = NSMenuItem(title: L("menu.contextMore"),
                                     action: #selector(increaseFilterContext(_:)), keyEquivalent: "]")
        moreContext.keyEquivalentModifierMask = [.command, .option]
        moreContext.target = self
        editMenu.addItem(moreContext)
        let lessContext = NSMenuItem(title: L("menu.contextLess"),
                                     action: #selector(decreaseFilterContext(_:)), keyEquivalent: "[")
        lessContext.keyEquivalentModifierMask = [.command, .option]
        lessContext.target = self
        editMenu.addItem(lessContext)

        // 多光标（仅在小型文件编辑窗格中。也可以通过单击 ⌘ 添加）。
        editMenu.addItem(.separator())
        let caretAbove = NSMenuItem(title: L("menu.addCaretAbove"),
                                    action: #selector(addCaretAbove(_:)), keyEquivalent: "\u{F700}")
        caretAbove.keyEquivalentModifierMask = [.command, .option]
        caretAbove.target = self
        editMenu.addItem(caretAbove)
        let caretBelow = NSMenuItem(title: L("menu.addCaretBelow"),
                                    action: #selector(addCaretBelow(_:)), keyEquivalent: "\u{F701}")
        caretBelow.keyEquivalentModifierMask = [.command, .option]
        caretBelow.target = self
        editMenu.addItem(caretBelow)
        // 格式菜单（编辑工具箱：转换选定文本）
        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)
        let formatMenu = NSMenu(title: L("menu.format"))
        formatMenuItem.submenu = formatMenu
        func addTransformItems(_ transforms: [TextTransform]) {
            for t in transforms {
                let it = NSMenuItem(title: L(t.localizationKey),
                                    action: #selector(applyTextTransform(_:)), keyEquivalent: "")
                it.tag = t.rawValue
                it.target = self
                formatMenu.addItem(it)
            }
        }
        addTransformItems(TextTransform.caseGroup)        // 大文字/小文字/…
        formatMenu.addItem(.separator())
        addTransformItems(TextTransform.encodingGroup)    // URL/Base64/HTML 编码/解码
        formatMenu.addItem(.separator())
        addTransformItems(TextTransform.dateTimeGroup)    // UNIX時刻 ⇄ 日時変換
        formatMenu.addItem(.separator())
        addTransformItems(TextTransform.lineGroup)        // 行排序/删除重复项/提取重复项/删除空行/反向排序/缩进/提升/制表符⇄空格
        formatMenu.addItem(.separator())
        // 将所有行与列参考分配对齐（如果将第一行与 Tab 对齐，则其余行也使用此值）。
        // ⌥Tab. **Tab = 此行，⌥Tab = 所有行** -- 可以在双手仍在键盘上时完成。
        // 也请将其添加到菜单中（以便寻找的人可以找到它）。
        let alignItem = NSMenuItem(title: L("menu.alignToColumnGuides"),
                                   action: #selector(alignToColumnGuides(_:)), keyEquivalent: "\t")
        alignItem.keyEquivalentModifierMask = [.option]
        alignItem.target = self
        formatMenu.addItem(alignItem)
        // 顺序编号和行拆分操作需要参数，因此提供了一个对话框（拆分是连接的逆操作）。
        let numberItem = NSMenuItem(title: L("menu.format.numberLines"),
                                    action: #selector(numberLines(_:)), keyEquivalent: "")
        numberItem.target = self
        formatMenu.addItem(numberItem)
        let splitItem = NSMenuItem(title: L("menu.format.splitLines"),
                                   action: #selector(splitLines(_:)), keyEquivalent: "")
        splitItem.target = self
        formatMenu.addItem(splitItem)
        formatMenu.addItem(.separator())
        // 使用外部命令替换选择（sort / jq / sed ... 即时筛选）。
        let filterItem = NSMenuItem(title: L("menu.format.filter"),
                                    action: #selector(filterThroughCommand(_:)), keyEquivalent: "r")
        filterItem.keyEquivalentModifierMask = [.command, .option]
        filterItem.target = self
        formatMenu.addItem(filterItem)
        // Search 与 EmEditor 处于同一位置（紧邻 View 之前）。已实现的操作是连接到现有路径。
        // 未实现的项目用星号 (*) 标记禁用。
        let searchMenuItem = NSMenuItem()
        mainMenu.addItem(searchMenuItem)
        let searchMenu = NSMenu(title: L("menu.search"))
        searchMenuItem.submenu = searchMenu
        func searchAction(_ key: String, _ selector: Selector, shortcut: String = "",
                          modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: L(key), action: selector, keyEquivalent: shortcut)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            searchMenu.addItem(item)
        }
        func searchUnavailable(_ key: String) {
            let item = NSMenuItem(title: L(key) + " *", action: nil, keyEquivalent: "")
            item.isEnabled = false
            searchMenu.addItem(item)
        }
        searchAction("menu.search.find", #selector(performFind(_:)), shortcut: "f")
        searchMenu.addItem(.separator())
        searchAction("menu.search.next", #selector(performFindNext(_:)), shortcut: "g")
        searchAction("menu.search.previous", #selector(performFindPrev(_:)), shortcut: "g", modifiers: [.command, .shift])
        searchUnavailable("menu.search.nextWord")
        searchUnavailable("menu.search.previousWord")
        searchMenu.addItem(.separator())
        searchAction("menu.search.addNextOccurrence", #selector(selectNextOccurrence(_:)), shortcut: "d")
        searchUnavailable("menu.search.addSecondNextOccurrence")
        searchUnavailable("menu.search.selectAllOccurrences")
        searchMenu.addItem(.separator())
        searchAction("menu.search.replace", #selector(performReplace(_:)))
        searchMenu.addItem(.separator())
        searchUnavailable("menu.search.eraseHighlight")
        searchMenu.addItem(.separator())
        searchUnavailable("menu.search.findInFiles")
        searchUnavailable("menu.search.replaceInFiles")
        searchMenu.addItem(.separator())
        searchAction("menu.search.filter", #selector(performSearchFilter(_:)), shortcut: "d", modifiers: [.command, .shift])
        searchAction("menu.extractFrequent", #selector(extractFrequentStrings(_:)))
        searchMenu.addItem(.separator())
        searchUnavailable("menu.search.longestLine")
        searchUnavailable("menu.search.nonemptyShortestLine")
        searchUnavailable("menu.search.shortestLine")
        searchMenu.addItem(.separator())
        searchUnavailable("menu.search.matchingTag")
        searchUnavailable("menu.search.currentTag")
        searchMenu.addItem(.separator())
        searchUnavailable("menu.search.nextWarning")
        searchUnavailable("menu.search.previousWarning")
        searchUnavailable("menu.search.eraseUnicodeHighlight")
        searchMenu.addItem(.separator())
        searchUnavailable("menu.search.symbols")
        searchUnavailable("menu.search.definition")

        // 显示菜单（跟随结束）
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: L("menu.view"))
        viewMenuItem.submenu = viewMenu
        let gotoItem = NSMenuItem(title: L("menu.gotoLine"),
                                  action: #selector(performGoToLine(_:)), keyEquivalent: "l")
        gotoItem.target = self
        viewMenu.addItem(gotoItem)

        // 书签——位于跳转键旁边。两者都是“跳转到哪里”的工具。
        let markItem = NSMenuItem(title: L("menu.toggleBookmark"),
                                  action: #selector(performToggleBookmark(_:)), keyEquivalent: "b")
        markItem.target = self
        viewMenu.addItem(markItem)
        // 来回切换的路径是 `⌘;` / `⇧⌘;`。书签更多用于来回切换，而不是用于添加书签。
        // 使移动侧需要 2 次按键（⌥⌘B / ⌥⇧⌘B 需要 3 或 4 次按键，对于来回移动的工具来说太重了）。
        //
        // 我选择  `;` 是因为**即使在 JIS 布局下，它也可以无需换挡即可按下**。`'` 是 JIS，Shift+7 是
        // 实际上需要 4 次按键操作（作者的环境是 JIS）。方向键（⌥⌘↑↓）填充了多光标。
        // 序列“Next → Back with Shift”与搜索格式⌘G / ⇧⌘G相同。
        let nextMark = NSMenuItem(title: L("menu.nextBookmark"),
                                  action: #selector(performNextBookmark(_:)), keyEquivalent: ";")
        nextMark.target = self
        viewMenu.addItem(nextMark)
        let prevMark = NSMenuItem(title: L("menu.prevBookmark"),
                                  action: #selector(performPrevBookmark(_:)), keyEquivalent: ";")
        prevMark.keyEquivalentModifierMask = [.command, .shift]
        prevMark.target = self
        viewMenu.addItem(prevMark)

        viewMenu.addItem(.separator())
        // 字体缩放
        let zoomIn = NSMenuItem(title: L("menu.zoomIn"),
                                action: #selector(performZoomIn(_:)), keyEquivalent: "+")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: L("menu.zoomOut"),
                                 action: #selector(performZoomOut(_:)), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: L("menu.zoomReset"),
                                   action: #selector(performZoomReset(_:)), keyEquivalent: "0")
        zoomReset.target = self
        viewMenu.addItem(zoomReset)
        viewMenu.addItem(.separator())
        let follow = NSMenuItem(title: L("menu.follow"),
                                action: #selector(performFollow(_:)), keyEquivalent: "f")
        follow.keyEquivalentModifierMask = [.command, .option]
        follow.target = self
        viewMenu.addItem(follow)
        self.followItem = follow

        // 结构化显示（CSV/TSV/NDJSON 的只读格式）
        viewMenu.addItem(.separator())
        let structMenu = NSMenu(title: L("menu.structured"))
        let offItem = NSMenuItem(title: L("menu.structured.off"),
                                 action: #selector(setStructuredMode(_:)), keyEquivalent: "")
        offItem.tag = -1; offItem.target = self
        structMenu.addItem(offItem)
        structMenu.addItem(.separator())
        for (i, m) in StructuredMode.allCases.enumerated() {
            let it = NSMenuItem(title: L("menu.structured.\(m.rawValue)"),
                                action: #selector(setStructuredMode(_:)), keyEquivalent: "")
            it.tag = i; it.target = self
            structMenu.addItem(it)
        }
        let structItem = NSMenuItem(title: L("menu.structured"), action: nil, keyEquivalent: "")
        structItem.submenu = structMenu
        viewMenu.addItem(structItem)

        // JSON 原地查询（等效于 jmespath；结果易失）。
        let queryItem = NSMenuItem(title: L("menu.jsonquery"),
                                   action: #selector(toggleJsonQuery(_:)), keyEquivalent: "j")
        queryItem.keyEquivalentModifierMask = [.command, .option]
        queryItem.target = self
        viewMenu.addItem(queryItem)

        // 数字标尺（用于统计固定长度数据）。结构化显示不适用于没有分隔符的格式。
        viewMenu.addItem(.separator())
        let rulerItem = NSMenuItem(title: L("menu.columnRuler"),
                                   action: #selector(toggleColumnRuler(_:)), keyEquivalent: "k")
        rulerItem.keyEquivalentModifierMask = [.command, .option]
        rulerItem.target = self
        viewMenu.addItem(rulerItem)
        // 这是拥有规范文档的用户的入口点（如果您没有规范文档，单击即可放置）。
        let fieldsItem = NSMenuItem(title: L("menu.columnRuler.fields"),
                                    action: #selector(editColumnFields(_:)), keyEquivalent: "k")
        fieldsItem.keyEquivalentModifierMask = [.command, .option, .shift]
        fieldsItem.target = self
        viewMenu.addItem(fieldsItem)
        let clearGuidesItem = NSMenuItem(title: L("menu.columnRuler.clearGuides"),
                                         action: #selector(clearColumnGuides(_:)), keyEquivalent: "")
        clearGuidesItem.target = self
        viewMenu.addItem(clearGuidesItem)

        // 将移动的浮动面板（搜索栏和横幅）恢复到其默认位置。
        let resetOverlays = NSMenuItem(title: L("menu.resetOverlays"),
                                       action: #selector(resetOverlayPositions(_:)), keyEquivalent: "")
        resetOverlays.target = self
        viewMenu.addItem(resetOverlays)

        // 对比 (diff)。有四个入口，但目的地相同：DiffViewer。
        viewMenu.addItem(.separator())
        let diffMenu = NSMenu(title: L("menu.compare"))
        let cmpFiles = NSMenuItem(title: L("menu.compare.files"),
                                  action: #selector(compareFiles(_:)), keyEquivalent: "d")
        cmpFiles.keyEquivalentModifierMask = [.command, .shift]
        cmpFiles.target = self
        diffMenu.addItem(cmpFiles)
        let cmpOpen = NSMenuItem(title: L("menu.compare.openDocs"),
                                 action: #selector(compareOpenDocuments(_:)), keyEquivalent: "")
        cmpOpen.target = self
        diffMenu.addItem(cmpOpen)
        let cmpClip = NSMenuItem(title: L("menu.compare.clipboard"),
                                 action: #selector(compareWithClipboard(_:)), keyEquivalent: "")
        cmpClip.target = self
        diffMenu.addItem(cmpClip)
        let cmpURL = NSMenuItem(title: L("menu.compare.url"),
                                action: #selector(compareWithURL(_:)), keyEquivalent: "")
        cmpURL.target = self
        diffMenu.addItem(cmpURL)
        diffMenu.addItem(.separator())
        let nextHunk = NSMenuItem(title: L("menu.compare.next"),
                                  action: #selector(nextDifference(_:)), keyEquivalent: "]")
        nextHunk.keyEquivalentModifierMask = [.command, .shift]
        nextHunk.target = self
        diffMenu.addItem(nextHunk)
        let prevHunk = NSMenuItem(title: L("menu.compare.previous"),
                                  action: #selector(previousDifference(_:)), keyEquivalent: "[")
        prevHunk.keyEquivalentModifierMask = [.command, .shift]
        prevHunk.target = self
        diffMenu.addItem(prevHunk)

        // “比较格式”。前四个选项是“与什么比较”= 入口点，这是“如何比较”= 模式。
        // 如果将其放置在同一行的第 5 个项目，则输入和比较方法会混淆（由于输入 × 比较方法，项目数量将翻倍），
        // 将它们放置在不同的图层中。
        diffMenu.addItem(.separator())
        let formatCompare = NSMenuItem(title: L("menu.compare.format"),
                                       action: #selector(toggleFormatCompare(_:)), keyEquivalent: "f")
        formatCompare.keyEquivalentModifierMask = [.command, .shift]
        formatCompare.target = self
        diffMenu.addItem(formatCompare)

        diffMenu.addItem(.separator())
        let adopt = NSMenuItem(title: L("menu.compare.adopt"),
                               action: #selector(adoptHunk(_:)), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        adopt.keyEquivalentModifierMask = [.option]
        adopt.target = self
        diffMenu.addItem(adopt)
        let revert = NSMenuItem(title: L("menu.compare.revert"),
                                action: #selector(revertHunk(_:)), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        revert.keyEquivalentModifierMask = [.option]
        revert.target = self
        diffMenu.addItem(revert)
        let saveMerged = NSMenuItem(title: L("menu.compare.saveMerged"),
                                    action: #selector(saveMergedResult(_:)), keyEquivalent: "")
        saveMerged.target = self
        diffMenu.addItem(saveMerged)

        let diffItem = NSMenuItem(title: L("menu.compare"), action: nil, keyEquivalent: "")
        diffItem.submenu = diffMenu
        viewMenu.addItem(diffItem)

        // 窗口菜单（Minimize / Zoom + AppKit 自动追加打开的窗口列表）
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: L("menu.window"))
        windowMenuItem.submenu = windowMenu
        // target nil 被委托给响应链（密钥窗口）。
        let minimize = NSMenuItem(title: L("menu.minimize"),
                                  action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimize)
        let zoomWindow = NSMenuItem(title: L("menu.zoomWindow"),
                                    action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(zoomWindow)
        windowMenu.addItem(.separator())
        let bringAllToFront = NSMenuItem(title: L("menu.bringAllToFront"),
                                         action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenu.addItem(bringAllToFront)
        NSApp.windowsMenu = windowMenu   // 从  开始，打开的窗口将自动显示在此处。

        // 帮助菜单
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: L("menu.help"))
        helpMenuItem.submenu = helpMenu
        let appHelp = NSMenuItem(title: L("menu.appHelp", AppInfo.name),
                                 action: #selector(openHelp(_:)), keyEquivalent: "?")
        appHelp.target = self
        helpMenu.addItem(appHelp)
        let terminalHelp = NSMenuItem(title: L("menu.terminalHelp"), action: #selector(showTerminalHelp(_:)), keyEquivalent: "")
        terminalHelp.target = self
        helpMenu.addItem(terminalHelp)
        // 请求及其发布列表仅在软件包声明了地址时可用。
        if AppInfo.requestFormURL != nil || AppInfo.requestListURL != nil {
            helpMenu.addItem(.separator())
        }
        if AppInfo.requestFormURL != nil {
            let send = NSMenuItem(title: L("menu.sendRequest"), action: #selector(sendRequest(_:)), keyEquivalent: "")
            send.target = self
            helpMenu.addItem(send)
        }
        if AppInfo.requestListURL != nil {
            let status = NSMenuItem(title: L("menu.requestStatus"), action: #selector(openRequestStatus(_:)), keyEquivalent: "")
            status.target = self
            helpMenu.addItem(status)
        }
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.helpURL)
    }

    /// 从终端 (`tail -f app.log | sifteditor`) 使用。命令输入和使用示例。
    /// 可以从该应用程序可执行文件的实际位置创建和复制要插入的命令。
    @objc private func showTerminalHelp(_ sender: Any?) {
        let exe = Bundle.main.executablePath ?? "/Applications/SiftEditor.app/Contents/MacOS/SiftEditor"
        let install = "sudo ln -sf \"\(exe)\" /usr/local/bin/sifteditor"
        let alert = NSAlert()
        alert.messageText = L("terminalHelp.title")
        alert.informativeText = L("terminalHelp.body", install)
        alert.addButton(withTitle: L("terminalHelp.copy"))
        alert.addButton(withTitle: L("terminalHelp.close"))
        if alert.runModal() == .alertFirstButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(install, forType: .string)
        }
    }

    /// 提交请求：在浏览器中打开 Issue 表单（用于提交 GitHub 请求）。版本号和 OS 默认包含在内。
    @objc private func sendRequest(_ sender: Any?) {
        guard let form = AppInfo.requestFormURL,
              let url = AppInfo.requestURL(form: form, version: AppInfo.version, os: AppInfo.osDescription()) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 请求状态：打开公共请求列表（已接收、正在考虑、已接受、未继续进行（有原因）……）。
    @objc private func openRequestStatus(_ sender: Any?) {
        guard let base = AppInfo.requestListURL else { return }
        NSWorkspace.shared.open(AppInfo.requestListURL(base: base, chinese: L("lang.code") == "zh-Hans"))
    }

    @objc private func openPreferences(_ sender: Any?) {
        if preferencesController == nil { preferencesController = PreferencesWindowController() }
        preferencesController?.show()
    }
}
