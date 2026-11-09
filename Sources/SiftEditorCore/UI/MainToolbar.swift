import AppKit

/// 主窗口工具栏。
///
/// 此应用程序的设计前提是，六个默认项目是应用程序的“门面”。
/// 对于刚启动该应用程序的用户来说，就好像菜单和快捷方式不存在一样。
/// 结构化显示、筛选、比较、跟踪、AI 诊断：“如果这里没有列出，那就说明这里没有。”
/// 因此，复制/保存/跳转/字体大小调整**默认情况下不包含在内**。
/// ⌘F・⌘S 是众所周知的，没有发现价值；包含它们会让编辑器看起来像一个“典型的编辑器”。
///
/// 它们的排列顺序也具有意义。在狭窄的窗户中，它们是从右向左折叠的。
/// **最右侧的 AI 诊断信息首先消失，而最左侧的结构化显示信息则一直保留到最后。**
///
/// 所有可放置的物品 (`allowedItemIdentifiers`) 和默认排列 (`defaultItemIdentifiers`) 是分开的。
/// 这允许您创建这样一种情况：某个项目出现在“自定义...”面板中，但默认情况下不会显示。
/// 非默认工具可在自定义面板中添加，不会占用初始工具栏空间。
extension NSToolbarItem.Identifier {
    static let mrSidebar     = NSToolbarItem.Identifier("mr.sidebar")
    static let mrStructured  = NSToolbarItem.Identifier("mr.structured")
    static let mrFilter      = NSToolbarItem.Identifier("mr.filter")
    static let mrCompare     = NSToolbarItem.Identifier("mr.compare")
    static let mrFollow      = NSToolbarItem.Identifier("mr.follow")
    /// 剪贴板历史记录（简单 - B6）。不包含在六个“面”中——仅包含 allowed，不包含在 default 中。
    /// 默认关闭，可由用户在自定义工具栏中添加。
    static let mrClipboardHistory = NSToolbarItem.Identifier("mr.clipboardHistory")
}

/// delegate 负责组装工具栏。所有操作均委托给 `MainWindowController`。
final class MainToolbarDelegate: NSObject, NSToolbarDelegate {
    private weak var controller: MainWindowController?

    init(controller: MainWindowController) {
        self.controller = controller
        super.init()
    }

    /// 默认布局。最左侧边栏的展开和收起遵循 macOS 约定（Finder/Mail/Xcode）。
    /// 这不包含在“面板”的费用中。主体位于分隔符的右侧。
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.mrSidebar, .space,
         .mrStructured, .mrFilter, .mrCompare, .mrFollow]
    }

    /// 自定义面板中显示的所有内容。即使是默认情况下未包含的项目，用户也可以添加。
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.mrSidebar, .mrStructured, .mrFilter, .mrCompare, .mrFollow,
         .mrClipboardHistory, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .mrSidebar:
            return button(id, label: L("toolbar.sidebar"), symbol: "sidebar.left",
                          action: #selector(MainWindowController.toolbarToggleSidebar(_:)))

        case .mrStructured:
            // 有 5 个选项（关闭 + CSV/TSV/NDJSON/JSON），因此不能做成按钮。
            // 添加菜单，菜单本身应包含与菜单栏中的项目含义相同的项目。
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = L("menu.structured")
            item.paletteLabel = L("menu.structured")
            item.toolTip = L("menu.structured")
            item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
            item.showsIndicator = true
            item.menu = structuredMenu()
            return item

        case .mrFilter:
            return button(id, label: L("toolbar.filter"), symbol: "line.3.horizontal.decrease",
                          action: #selector(MainWindowController.toolbarShowFilter(_:)))

        case .mrCompare:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = L("menu.compare")
            item.paletteLabel = L("menu.compare")
            item.toolTip = L("menu.compare")
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            item.showsIndicator = true
            item.menu = compareMenu()
            return item

        case .mrFollow:
            return button(id, label: L("menu.follow"), symbol: "arrow.down.to.line",
                          action: #selector(MainWindowController.toolbarToggleFollow(_:)))

        case .mrClipboardHistory:
            // 请勿使用  NSMenuToolbarItem。在实际设备上，点击该 ID 仍会显示旧内容。
            // 尽管多次尝试修复，问题仍然存在，并且在 .menu 端无法确定问题原因。（已点击）
            // 现场制定菜单并自行上菜更可靠（popUpContextMenu）。
            return button(id, label: L("menu.clipboardHistory"), symbol: "doc.on.clipboard",
                          action: #selector(MainWindowController.toolbarShowClipboardHistory(_:)))

        default:
            return nil
        }
    }

    // MARK: - 装配工具

    private func button(_ id: NSToolbarItem.Identifier, label: String,
                        symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = controller
        item.action = action
        item.isBordered = true
        return item
    }

    /// 结构化视图菜单。在菜单打开之前，`MainWindowController` 会再次选中该复选框。
    private func structuredMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = controller
        let off = NSMenuItem(title: L("menu.structured.off"),
                             action: #selector(MainWindowController.toolbarSetStructuredMode(_:)),
                             keyEquivalent: "")
        off.tag = -1
        off.target = controller
        menu.addItem(off)
        menu.addItem(.separator())
        for (i, mode) in StructuredMode.allCases.enumerated() {
            let item = NSMenuItem(title: L("menu.structured.\(mode.rawValue)"),
                                  action: #selector(MainWindowController.toolbarSetStructuredMode(_:)),
                                  keyEquivalent: "")
            item.tag = i
            item.target = controller
            menu.addItem(item)
        }
        return menu
    }

    /// 比较菜单。与菜单栏中的“比较 (diff)”相同的四个入口点。
    private func compareMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            (L("menu.compare.files"),    #selector(MainWindowController.toolbarCompareFiles(_:))),
            (L("menu.compare.openDocs"), #selector(MainWindowController.toolbarCompareOpenDocuments(_:))),
            (L("menu.compare.clipboard"), #selector(MainWindowController.toolbarCompareWithClipboard(_:))),
            (L("menu.compare.url"),      #selector(MainWindowController.toolbarCompareWithURL(_:))),
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = controller
            menu.addItem(item)
        }
        return menu
    }
}
