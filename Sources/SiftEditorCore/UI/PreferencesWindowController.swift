import AppKit

/// 首选项窗口 (⌘,)。macOS 标准工具栏选项卡配置。
/// “常规” = 保存时显示，“显示” = 字体 + 正文文本布局 + 长行，“配色方案” = 正文区域的主题。
/// 即使设置项数量增加，也只需在每个窗格中添加 VC，例如 `NSTabViewController`
/// 我把它留给  / 的 `.toolbar` 样式。
final class PreferencesWindowController: NSWindowController {

    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        let general = GeneralPaneViewController()
        general.title = L("prefs.general")
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        tabs.addTabViewItem(generalItem)

        let display = DisplayPaneViewController()
        display.title = L("prefs.display")
        let displayItem = NSTabViewItem(viewController: display)
        displayItem.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
        tabs.addTabViewItem(displayItem)

        let colors = ColorsPaneViewController()
        colors.title = L("prefs.colors")
        let colorsItem = NSTabViewItem(viewController: colors)
        colorsItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        tabs.addTabViewItem(colorsItem)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = L("prefs.title")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.center()
    }

    /// 将窗口置于前景（如果不存在则重用现有窗口）。
    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 通用助手

private func heading(_ key: String) -> NSTextField {
    let f = NSTextField(labelWithString: L(key))
    f.font = .boldSystemFont(ofSize: 13)
    return f
}

private func makeStack(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
    return stack
}

private func pin(_ stack: NSStackView, in root: NSView) {
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
}

// MARK: - 常规窗格（保存时显示）

private final class GeneralPaneViewController: NSViewController {
    private var statusBarRadio: NSButton!
    private var sheetRadio: NSButton!
    private var autoUpdateCheck: NSButton!
    private var autoReloadCheck: NSButton!
    private var soundPopup: NSPopUpButton!

    private static let soundOptions: [(id: String, labelKey: String)] = [
        ("Glass", "Glass"),
        ("Tink", "Tink"),
        ("Pop", "Pop"),
        ("Ping", "Ping"),
        ("Hero", "Hero"),
        ("Bottle", "Bottle"),
        ("Purr", "Purr"),
        ("none", "prefs.sound.none"),
    ]

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))

        statusBarRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.statusBar"),
                                  target: self, action: #selector(radioChanged(_:)))
        sheetRadio = NSButton(radioButtonWithTitle: L("menu.saveProgress.sheet"),
                              target: self, action: #selector(radioChanged(_:)))

        let hint = NSTextField(wrappingLabelWithString: L("prefs.saveProgress.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        autoUpdateCheck = NSButton(checkboxWithTitle: L("prefs.autoUpdateCheck"),
                                   target: self, action: #selector(autoUpdateChanged(_:)))

        autoReloadCheck = NSButton(checkboxWithTitle: L("prefs.autoReload"),
                                   target: self, action: #selector(autoReloadChanged(_:)))
        let reloadHint = NSTextField(wrappingLabelWithString: L("prefs.autoReload.hint"))
        reloadHint.font = .systemFont(ofSize: 11)
        reloadHint.textColor = .secondaryLabelColor

        soundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        soundPopup.target = self
        soundPopup.action = #selector(soundChanged(_:))
        for opt in Self.soundOptions {
            let title = (opt.id == "none") ? L(opt.labelKey) : opt.labelKey
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = opt.id
            soundPopup.menu?.addItem(item)
        }
        let currentSound = AppSettings.lineEditSound.lowercased()
        if let idx = Self.soundOptions.firstIndex(where: { $0.id.lowercased() == currentSound }) {
            soundPopup.selectItem(at: idx)
        } else {
            soundPopup.selectItem(at: 0)
        }

        let soundRow = NSStackView()
        soundRow.orientation = .horizontal
        soundRow.alignment = .firstBaseline
        soundRow.spacing = 8
        let soundLabel = NSTextField(labelWithString: L("prefs.sound.lineEdit") + ":")
        soundLabel.font = .systemFont(ofSize: 12)
        soundRow.addArrangedSubview(soundLabel)
        soundRow.addArrangedSubview(soundPopup)

        let sep = NSBox(); sep.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator
        let sep3 = NSBox(); sep3.boxType = .separator

        var rows: [NSView] = [heading("prefs.saveProgress"), statusBarRadio, sheetRadio, hint,
                              sep,
                              heading("prefs.sound"), soundRow,
                              sep2,
                              heading("prefs.externalChanges"), autoReloadCheck, reloadHint]
        // 未检查更新。.app 版本（未声明其分发来源）不包含设置。
        if UpdateChecker.isAvailable {
            rows += [sep3, heading("prefs.updates"), autoUpdateCheck]
        }
        let stack = makeStack(rows)
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        reloadHint.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        sep.widthAnchor.constraint(equalToConstant: 400).isActive = true
        sep2.widthAnchor.constraint(equalToConstant: 400).isActive = true
        sep3.widthAnchor.constraint(equalToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        syncRadios()
        autoUpdateCheck.state = AppSettings.automaticUpdateChecks ? .on : .off
        autoReloadCheck.state = AppSettings.autoReloadExternalChanges ? .on : .off
    }

    @objc private func soundChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        AppSettings.lineEditSound = id
        AppSettings.playLineEditSound()
    }

    @objc private func autoUpdateChanged(_ sender: NSButton) {
        AppSettings.automaticUpdateChecks = (sender.state == .on)
    }

    @objc private func autoReloadChanged(_ sender: NSButton) {
        AppSettings.autoReloadExternalChanges = (sender.state == .on)
    }

    private func syncRadios() {
        let s = AppSettings.saveProgressStyle
        statusBarRadio.state = (s == .statusBar) ? .on : .off
        sheetRadio.state = (s == .sheet) ? .on : .off
    }

    @objc private func radioChanged(_ sender: NSButton) {
        AppSettings.saveProgressStyle = (sender === sheetRadio) ? .sheet : .statusBar
        syncRadios()
    }
}

// MARK: - 显示窗格（字体、文本格式、长行）

private final class DisplayPaneViewController: NSViewController {
    private var fontPopup: NSPopUpButton!
    private var sizePopup: NSPopUpButton!
    private var sample: NSTextField!
    private var tabWidthPopup: NSPopUpButton!
    private var lineSpacingPopup: NSPopUpButton!
    private var highlightCheck: NSButton!
    private var lineNumbersCheck: NSButton!
    private var invisiblesCheck: NSButton!
    private var cursorPopup: NSPopUpButton!
    private var noWrapRadio: NSButton!
    private var wrapRadio: NSButton!

    /// 第一项，tag，代表  / nil（系统默认值）。
    private static let systemDefaultTag = -1

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 460))

        // --- 字体类型 ---
        fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let systemItem = NSMenuItem(title: L("prefs.font.system"), action: nil, keyEquivalent: "")
        systemItem.tag = Self.systemDefaultTag
        fontPopup.menu?.addItem(systemItem)
        fontPopup.menu?.addItem(.separator())
        for name in EditorFont.availableMonospaceFamilies() {
            fontPopup.addItem(withTitle: name)
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontPicked(_:))

        // --- 尺寸 ---
        sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for s in Int(EditorFont.minSize)...Int(EditorFont.maxSize) {
            sizePopup.addItem(withTitle: "\(s)")
            sizePopup.lastItem?.tag = s
        }
        sizePopup.target = self
        sizePopup.action = #selector(sizePicked(_:))
        let ptLabel = NSTextField(labelWithString: L("prefs.font.pt"))
        ptLabel.textColor = .secondaryLabelColor

        let fontRow = NSStackView(views: [fontPopup, label("prefs.font.size"), sizePopup, ptLabel])
        fontRow.orientation = .horizontal
        fontRow.spacing = 8
        fontRow.alignment = .firstBaseline

        // --- 现场采样 ---
        sample = NSTextField(labelWithString: L("preferences.fontSample"))
        sample.textColor = .secondaryLabelColor
        sample.lineBreakMode = .byTruncatingTail

        // --- 制表符宽度和行间距 ---
        tabWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for w in [2, 4, 8] { tabWidthPopup.addItem(withTitle: "\(w)"); tabWidthPopup.lastItem?.tag = w }
        tabWidthPopup.target = self
        tabWidthPopup.action = #selector(tabWidthPicked(_:))

        lineSpacingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, s) in LineSpacing.allCases.enumerated() {
            lineSpacingPopup.addItem(withTitle: L("prefs.lineSpacing.\(s.rawValue)"))
            lineSpacingPopup.lastItem?.tag = i
        }
        lineSpacingPopup.target = self
        lineSpacingPopup.action = #selector(lineSpacingPicked(_:))

        let metricsRow = NSStackView(views: [label("prefs.tabWidth"), tabWidthPopup,
                                             label("prefs.lineSpacing"), lineSpacingPopup])
        metricsRow.orientation = .horizontal
        metricsRow.spacing = 8
        metricsRow.alignment = .firstBaseline

        // --- 当前行高亮显示、行号、不可见字符 ---
        highlightCheck = NSButton(checkboxWithTitle: L("prefs.highlightCurrentLine"),
                                  target: self, action: #selector(highlightChanged(_:)))
        lineNumbersCheck = NSButton(checkboxWithTitle: L("prefs.showLineNumbers"),
                                    target: self, action: #selector(lineNumbersChanged(_:)))
        invisiblesCheck = NSButton(checkboxWithTitle: L("prefs.showInvisibles"),
                                   target: self, action: #selector(invisiblesChanged(_:)))

        // --- 光标形状 ---
        cursorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, c) in CursorShape.allCases.enumerated() {
            cursorPopup.addItem(withTitle: L("prefs.cursorShape.\(c.rawValue)"))
            cursorPopup.lastItem?.tag = i
        }
        cursorPopup.target = self
        cursorPopup.action = #selector(cursorPicked(_:))
        let cursorRow = NSStackView(views: [label("prefs.cursorShape"), cursorPopup])
        cursorRow.orientation = .horizontal
        cursorRow.spacing = 8
        cursorRow.alignment = .firstBaseline

        // --- 长线 ---
        noWrapRadio = NSButton(radioButtonWithTitle: L("prefs.lineWrap.off"),
                               target: self, action: #selector(wrapChanged(_:)))
        wrapRadio = NSButton(radioButtonWithTitle: L("prefs.lineWrap.on"),
                             target: self, action: #selector(wrapChanged(_:)))

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        let stack = makeStack([heading("prefs.font"), fontRow, sample,
                               sep1,
                               heading("prefs.text"), metricsRow, highlightCheck,
                               lineNumbersCheck, invisiblesCheck, cursorRow,
                               sep2,
                               heading("prefs.lineWrap"), noWrapRadio, wrapRadio])
        sep1.widthAnchor.constraint(equalToConstant: 400).isActive = true
        sep2.widthAnchor.constraint(equalToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        sync()
    }

    private func label(_ key: String) -> NSTextField { NSTextField(labelWithString: L(key)) }

    private func sync() {
        // 字体类型
        if let name = EditorFont.currentName, fontPopup.itemTitles.contains(name) {
            fontPopup.selectItem(withTitle: name)
        } else {
            fontPopup.selectItem(withTag: Self.systemDefaultTag)
        }
        sizePopup.selectItem(withTag: Int(EditorFont.currentSize))
        tabWidthPopup.selectItem(withTag: AppSettings.tabWidth)
        lineSpacingPopup.selectItem(withTag: LineSpacing.allCases.firstIndex(of: AppSettings.lineSpacing) ?? 0)
        highlightCheck.state = AppSettings.highlightCurrentLine ? .on : .off
        lineNumbersCheck.state = AppSettings.showLineNumbers ? .on : .off
        invisiblesCheck.state = AppSettings.showInvisibles ? .on : .off
        cursorPopup.selectItem(withTag: CursorShape.allCases.firstIndex(of: AppSettings.cursorShape) ?? 0)
        noWrapRadio.state = AppSettings.lineWrap ? .off : .on
        wrapRadio.state = AppSettings.lineWrap ? .on : .off
        // 使用当前字体绘制示例。
        sample.font = EditorFont.current()
    }

    @objc private func fontPicked(_ sender: NSPopUpButton) {
        if sender.selectedItem?.tag == Self.systemDefaultTag {
            EditorFont.setName(nil)
        } else {
            EditorFont.setName(sender.titleOfSelectedItem)
        }
        sync()
    }

    @objc private func sizePicked(_ sender: NSPopUpButton) {
        EditorFont.setSize(CGFloat(sender.selectedTag()))
        sync()
    }

    @objc private func tabWidthPicked(_ sender: NSPopUpButton) {
        AppSettings.tabWidth = sender.selectedTag()
    }

    @objc private func lineSpacingPicked(_ sender: NSPopUpButton) {
        AppSettings.lineSpacing = LineSpacing.allCases[sender.selectedTag()]
        sync()   // 样本的行高不会改变，但为了选择一致性。
    }

    @objc private func highlightChanged(_ sender: NSButton) {
        AppSettings.highlightCurrentLine = (sender.state == .on)
    }

    @objc private func lineNumbersChanged(_ sender: NSButton) {
        AppSettings.showLineNumbers = (sender.state == .on)
    }

    @objc private func invisiblesChanged(_ sender: NSButton) {
        AppSettings.showInvisibles = (sender.state == .on)
    }

    @objc private func cursorPicked(_ sender: NSPopUpButton) {
        AppSettings.cursorShape = CursorShape.allCases[sender.selectedTag()]
    }

    @objc private func wrapChanged(_ sender: NSButton) {
        AppSettings.lineWrap = (sender === wrapRadio)
        sync()
    }
}

// MARK: - 颜色方案窗格（主文本区域的主题）

private final class ColorsPaneViewController: NSViewController {
    private var themePopup: NSPopUpButton!
    private var sample: NSTextField!
    /// 一个区域，包含五个单独的颜色选择器行，仅当选择  / custom 时才会显示。
    private var customStack: NSStackView!
    private var wells: [EditorTheme.ColorKey: NSColorWell] = [:]
    private var opacitySlider: NSSlider!
    private var opacityValue: NSTextField!
    private var ansiCheck: NSButton!
    /// 添加有关共享操作结果的简短评论（复制完成，应用完成）。
    private var shareStatus: NSTextField!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))

        // --- 主题选择 ---
        themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, p) in ThemePreset.allCases.enumerated() {
            themePopup.addItem(withTitle: L("prefs.theme.\(p.rawValue)"))
            themePopup.lastItem?.tag = i
        }
        themePopup.target = self
        themePopup.action = #selector(themePicked(_:))
        let themeRow = NSStackView(views: [label("prefs.theme"), themePopup])
        themeRow.orientation = .horizontal
        themeRow.spacing = 8
        themeRow.alignment = .firstBaseline

        // --- 实时示例（显示前景色/背景色）---
        sample = NSTextField(labelWithString: L("preferences.fontSample"))
        sample.drawsBackground = true
        sample.isBezeled = true
        sample.lineBreakMode = .byTruncatingTail
        sample.font = EditorFont.current()

        // --- custom 的 5 色选择器 ---
        var rows: [NSView] = []
        for key in EditorTheme.ColorKey.allCases {
            let well = NSColorWell()
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            well.target = self
            well.action = #selector(colorPicked(_:))
            well.tag = EditorTheme.ColorKey.allCases.firstIndex(of: key)!
            wells[key] = well
            let row = NSStackView(views: [well, label("prefs.color.\(key.rawValue)")])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
            rows.append(row)
        }
        customStack = NSStackView(views: rows)
        customStack.orientation = .vertical
        customStack.alignment = .leading
        customStack.spacing = 8

        // --- 背景不透明度（整个窗口，iTerm 样式）---
        opacitySlider = NSSlider(value: Double(EditorTheme.backgroundOpacity * 100),
                                 minValue: 30, maxValue: 100,
                                 target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        opacityValue = NSTextField(labelWithString: "")
        opacityValue.font = .systemFont(ofSize: 11)
        opacityValue.textColor = .secondaryLabelColor
        let opacityRow = NSStackView(views: [label("prefs.opacity"), opacitySlider, opacityValue])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8
        opacityRow.alignment = .centerY

        // --- ANSI 彩色显示屏（观看时） ---
        ansiCheck = NSButton(checkboxWithTitle: L("prefs.ansi"), target: self, action: #selector(ansiToggled(_:)))

        let sep = NSBox(); sep.boxType = .separator
        sep.widthAnchor.constraint(equalToConstant: 400).isActive = true

        // --- 共享（导出/导入/链接）---
        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.widthAnchor.constraint(equalToConstant: 400).isActive = true

        let shareHint = NSTextField(wrappingLabelWithString: L("prefs.share.hint"))
        shareHint.font = .systemFont(ofSize: 11)
        shareHint.textColor = .secondaryLabelColor
        shareHint.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true

        let exportBtn = NSButton(title: L("prefs.share.export"), target: self, action: #selector(exportSettings(_:)))
        let importBtn = NSButton(title: L("prefs.share.import"), target: self, action: #selector(importSettings(_:)))
        let copyBtn = NSButton(title: L("prefs.share.copyLink"), target: self, action: #selector(copyLink(_:)))
        let fromClipBtn = NSButton(title: L("prefs.share.importClipboard"), target: self, action: #selector(importFromClipboard(_:)))
        let shareRow = NSStackView(views: [exportBtn, importBtn, copyBtn, fromClipBtn])
        shareRow.orientation = .horizontal
        shareRow.spacing = 8

        shareStatus = NSTextField(labelWithString: "")
        shareStatus.font = .systemFont(ofSize: 11)
        shareStatus.textColor = .secondaryLabelColor

        let stack = makeStack([heading("prefs.theme"), themeRow, sample, opacityRow, ansiCheck, sep, customStack,
                               sep2, heading("prefs.share"), shareHint, shareRow, shareStatus])
        sample.widthAnchor.constraint(equalToConstant: 400).isActive = true
        pin(stack, in: root)
        self.view = root
        sync()
    }

    private func label(_ key: String) -> NSTextField { NSTextField(labelWithString: L(key)) }

    private func sync() {
        let idx = ThemePreset.allCases.firstIndex(of: EditorTheme.preset) ?? 0
        themePopup.selectItem(withTag: idx)
        let theme = EditorTheme.current()
        // 将配色方案应用于样品（）。
        sample.textColor = theme.foreground
        sample.backgroundColor = theme.background
        // 仅当选中 custom 时才会显示选择器。当前颜色会反映在每个 well 中。
        customStack.isHidden = (EditorTheme.preset != .custom)
        for key in EditorTheme.ColorKey.allCases {
            wells[key]?.color = EditorTheme.customColor(key)
        }
        let pct = Int((EditorTheme.backgroundOpacity * 100).rounded())
        opacitySlider.doubleValue = Double(pct)
        opacityValue.stringValue = "\(pct)%"
        ansiCheck.state = EditorTheme.ansiColorsEnabled ? .on : .off
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        EditorTheme.backgroundOpacity = CGFloat(sender.doubleValue) / 100
        opacityValue.stringValue = "\(Int(sender.doubleValue.rounded()))%"
    }

    @objc private func ansiToggled(_ sender: NSButton) {
        EditorTheme.ansiColorsEnabled = (sender.state == .on)
    }

    @objc private func themePicked(_ sender: NSPopUpButton) {
        EditorTheme.preset = ThemePreset.allCases[sender.selectedTag()]
        sync()
    }

    @objc private func colorPicked(_ sender: NSColorWell) {
        let key = EditorTheme.ColorKey.allCases[sender.tag]
        EditorTheme.setCustomColor(key, sender.color)   // preset 到 .custom - 切换和通知
        shareStatus.stringValue = ""
        sync()
    }

    // MARK: - 共有

    @objc private func exportSettings(_ sender: Any?) {
        shareStatus.stringValue = ""
        SettingsShare.export(presenting: view.window)
    }

    @objc private func importSettings(_ sender: Any?) {
        shareStatus.stringValue = ""
        SettingsShare.importFromFile(presenting: view.window) { [weak self] in self?.applied() }
    }

    @objc private func copyLink(_ sender: Any?) {
        SettingsShare.copyShareLink()
        shareStatus.stringValue = L("prefs.share.copied")
    }

    @objc private func importFromClipboard(_ sender: Any?) {
        shareStatus.stringValue = ""
        SettingsShare.importFromClipboard(presenting: view.window) { [weak self] in self?.applied() }
    }

    /// 应用后：将弹出窗口/选择器同步到新值并添加简短消息。
    private func applied() {
        sync()
        shareStatus.stringValue = L("prefs.share.imported")
    }
}
