import AppKit

/// 主文本区域（5 种颜色）和周围 UI (chrome) 的配色方案的摘要。
/// 两种路径：大文件（`DocumentView` 自定义图纸）和小文件（`NSTextView`）
/// 搜索命中渲染和侧边栏/间距/状态/搜索面板/标题栏使用相同的颜色。
struct EditorColorTheme {
    // MARK: 主文本区域
    /// 正文文本颜色。
    var foreground: NSColor
    /// 文本背景颜色。
    var background: NSColor
    /// 微妙地突出显示插入符行的色带颜色（带 alpha）。
    var currentLine: NSColor
    /// 所选区域的背景颜色。
    var selection: NSColor
    /// 搜索结果的背景颜色（与 alpha 一起）。
    var searchMatch: NSColor

    // MARK: 周辺 UI（chrome）
    /// 侧边栏/装订线/状态栏/搜索面板/标题栏的背景。
    var chromeBackground: NSColor
    /// 侧边栏行等主要标签的文本颜色。
    var chromeText: NSColor
    /// 状态栏和行号等辅助标签的文本颜色。
    var chromeSecondaryText: NSColor
    /// 所选侧边栏行的背景。
    var chromeActiveBackground: NSColor
    /// 所选侧边栏行的标签颜色。
    var chromeActiveText: NSColor
    /// 分割线的颜色。
    var separator: NSColor
    /// 未保存文档的标记颜色（侧边栏中的 ● 和 ×）。
    var dirtyIndicator: NSColor
    /// 强制外观与窗口匹配（framework 控件/标题文本/滚动条亮度）。
    /// nil = OS 后续（system 预设）。
    var appearanceName: NSAppearance.Name?
}

/// 颜色方案预设。`system` 使用语义化颜色，并具有自动明暗跟踪功能。
/// 固定预设为 sRGB（固定颜色，无跟踪）和 `custom`（5 种用户指定颜色）。
enum ThemePreset: String, CaseIterable {
    case system
    case solarizedDark
    case solarizedLight
    case monokai
    case dracula
    case nord
    case grass
    case redSands
    case custom
}

/// 编辑器正文 + 周围文本：全局保留并持续使用 UI 的颜色方案。类似于字体 (`EditorFont`)。
/// 保存对  / UserDefaults 的更改，并使用现有的 `.siftEditorDisplayChanged` 通知所有查看器/窗口这些更改。
enum EditorTheme {
    private static let defaults = UserDefaults.standard
    private static let presetKey = "SiftEditor.themePreset"
    /// 自定义主题的各项颜色（通过 NSKeyedArchiver 序列化为 Data，保留透明度和色彩空间）。
    private static let customPrefix = "SiftEditor.themeCustom."
    private static let opacityKey = "SiftEditor.backgroundOpacity"
    private static let ansiKey = "SiftEditor.ansiColorsEnabled"

    /// custom：用户指定的颜色。主文本由 5 种颜色和一个未保存的标记颜色组成。周围的 UI 颜色均由此派生而来。
    enum ColorKey: String, CaseIterable {
        case foreground, background, currentLine, selection, searchMatch, dirtyIndicator
    }

    // MARK: - 预设选择

    static var preset: ThemePreset {
        get { preset(from: defaults) }
        set {
            defaults.set(newValue.rawValue, forKey: presetKey)
            defaults.synchronize()
            postChanged()
        }
    }
    private static func preset(from source: UserDefaults) -> ThemePreset {
        ThemePreset(rawValue: source.string(forKey: presetKey) ?? "") ?? .system
    }

    // MARK: - 背景不透明度（整个窗口，类似于 iTerm）

    /// 主文本及其周围区域 (UI) 的背景透明程度。1.0 = 完全不透明（默认值，与之前相同）。
    /// 可降低至 0.30。透明时，窗口变为不透明，以显示其后面的桌面。
    static var backgroundOpacity: CGFloat {
        get { backgroundOpacity(from: defaults) }
        set {
            defaults.set(Double(min(1.0, max(0.30, newValue))), forKey: opacityKey)
            defaults.synchronize()
            postChanged()
        }
    }
    private static func backgroundOpacity(from source: UserDefaults) -> CGFloat {
        guard source.object(forKey: opacityKey) != nil else { return 1.0 }
        let v = CGFloat(source.double(forKey: opacityKey))
        return min(1.0, max(0.30, v))
    }

    /// 背景是否完全不透明（不透明度 1.0）？用于确定是否启用了透明度编程。
    static var isOpaqueBackground: Bool { backgroundOpacity >= 0.999 }

    /// 指定颜色乘以当前不透明度（遵循原始 alpha 并进行乘法运算）。
    /// 当完全不透明时，它会原样返回原始颜色。
    static func withBackgroundOpacity(_ color: NSColor) -> NSColor {
        guard !isOpaqueBackground else { return color }
        let base = color.alphaComponent
        return color.withAlphaComponent(base * backgroundOpacity)
    }

    // MARK: - ANSI 彩色显示屏（仅供查看）

    /// 日志中的 ANSI、SGR 和转义字符 (`ESC[…m`) 是否应转换为颜色并显示？
    /// 默认值 ON（因为原始转义列无法读取）。仅适用于浏览路径。
    static var ansiColorsEnabled: Bool {
        get { ansiColorsEnabled(from: defaults) }
        set {
            defaults.set(newValue, forKey: ansiKey)
            defaults.synchronize()
            postChanged()
        }
    }
    private static func ansiColorsEnabled(from source: UserDefaults) -> Bool {
        source.object(forKey: ansiKey) == nil ? true : source.bool(forKey: ansiKey)
    }

    // MARK: - 当前配色方案

    /// 当前配色方案。根据 preset 返回固定颜色/语义颜色/custom 保存的颜色。
    static func current() -> EditorColorTheme {
        switch preset {
        case .custom: return customTheme()
        default:      return builtin(preset)
        }
    }

    /// 预设颜色定义（也用于预览）。`custom` 是 custom 当前保存的颜色。
    static func builtin(_ preset: ThemePreset) -> EditorColorTheme {
        switch preset {
        case .system:
            // 与现有硬编码值匹配（默认情况下与当前值完全匹配；周围的 UI 也会自动进行语义跟踪）。
            return EditorColorTheme(
                foreground: .textColor,
                background: .textBackgroundColor,
                currentLine: NSColor.textColor.withAlphaComponent(0.06),
                selection: .selectedTextBackgroundColor,
                searchMatch: NSColor.systemYellow.withAlphaComponent(0.45),
                chromeBackground: .windowBackgroundColor,
                chromeText: .labelColor,
                chromeSecondaryText: .secondaryLabelColor,
                chromeActiveBackground: .selectedContentBackgroundColor,
                chromeActiveText: .white,
                separator: .separatorColor,
                dirtyIndicator: .systemOrange,
                appearanceName: nil)
        case .solarizedDark:
            return themed(fg: hex(0x93A1A1), bg: hex(0x002B36),
                          currentLine: hex(0xFFFFFF, 0.06), selection: hex(0x274642),
                          searchMatch: hex(0xB58900, 0.45), dirty: .systemOrange)
        case .solarizedLight:
            return themed(fg: hex(0x586E75), bg: hex(0xFDF6E3),
                          currentLine: hex(0x000000, 0.05), selection: hex(0xD6CFB8),
                          searchMatch: hex(0xB58900, 0.40), dirty: .systemOrange)
        case .monokai:
            return themed(fg: hex(0xF8F8F2), bg: hex(0x272822),
                          currentLine: hex(0xFFFFFF, 0.06), selection: hex(0x49483E),
                          searchMatch: hex(0xE6DB74, 0.40), dirty: .systemOrange)
        case .dracula:
            return themed(fg: hex(0xF8F8F2), bg: hex(0x282A36),
                          currentLine: hex(0xFFFFFF, 0.06), selection: hex(0x44475A),
                          searchMatch: hex(0xBD93F9, 0.45), dirty: hex(0xFF79C6))
        case .nord:
            return themed(fg: hex(0xD8DEE9), bg: hex(0x2E3440),
                          currentLine: hex(0xFFFFFF, 0.05), selection: hex(0x434C5E),
                          searchMatch: hex(0xEBCB8B, 0.40), dirty: hex(0xEBCB8B))
        case .grass:
            // iTerm2 “Grass”系列：黄色前景，深绿色背景。
            return themed(fg: hex(0xFFF0A5), bg: hex(0x13773D),
                          currentLine: hex(0xFFFFFF, 0.07), selection: hex(0x1E5C33),
                          searchMatch: hex(0xF6C744, 0.45), dirty: .systemOrange)
        case .redSands:
            // iTerm2 "Red Sands" 系列：沙质前景，红棕色背景。
            return themed(fg: hex(0xD7C9A7), bg: hex(0x7A251E),
                          currentLine: hex(0xFFFFFF, 0.06), selection: hex(0x9E3B32),
                          searchMatch: hex(0xE0A020, 0.45), dirty: hex(0xF2D06B))
        case .custom:
            return customTheme()
        }
    }

    // MARK: - 自定义颜色

    /// 为  / custom 设置一种颜色，并将 preset 切换为 `.custom` 以发送通知。
    static func setCustomColor(_ key: ColorKey, _ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
            defaults.set(data, forKey: customPrefix + key.rawValue)
        }
        // 切换到  custom（postChanged 仅在此处使用一次）。
        defaults.set(ThemePreset.custom.rawValue, forKey: presetKey)
        defaults.synchronize()
        postChanged()
    }

    /// 从  / custom 读取一种颜色。如果未设置，则回退到 system 预设中的对应颜色。
    static func customColor(_ key: ColorKey) -> NSColor { customColor(key, from: defaults) }

    private static func customColor(_ key: ColorKey, from source: UserDefaults) -> NSColor {
        if let data = source.data(forKey: customPrefix + key.rawValue),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        let sys = builtin(.system)
        switch key {
        case .foreground:    return sys.foreground
        case .background:    return sys.background
        case .currentLine:   return sys.currentLine
        case .selection:     return sys.selection
        case .searchMatch:   return sys.searchMatch
        case .dirtyIndicator: return sys.dirtyIndicator
        }
    }

    private static func customTheme() -> EditorColorTheme {
        themed(fg: customColor(.foreground), bg: customColor(.background),
               currentLine: customColor(.currentLine), selection: customColor(.selection),
               searchMatch: customColor(.searchMatch), dirty: customColor(.dirtyIndicator))
    }

    // MARK: - 周围 UI 颜色衍生

    /// 正文：从 5 种主要颜色中衍生出周围颜色 UI (chrome)。
    /// chrome 是通过混合前景和背景颜色创建的，因此暗色调自然会稍微变亮，亮色调会稍微变暗。
    private static func themed(fg: NSColor, bg: NSColor, currentLine: NSColor,
                              selection: NSColor, searchMatch: NSColor, dirty: NSColor) -> EditorColorTheme {
        let bgS = bg.usingColorSpace(.sRGB) ?? bg
        let fgS = fg.usingColorSpace(.sRGB) ?? fg
        func blend(_ t: CGFloat) -> NSColor { mix(bgS, fgS, t) }
        // 使用相对亮度（sRGB 近似值）确定亮度和暗度，并确定窗口外观。
        let lum = 0.2126 * bgS.redComponent + 0.7152 * bgS.greenComponent + 0.0722 * bgS.blueComponent
        return EditorColorTheme(
            foreground: fg, background: bg,
            currentLine: currentLine, selection: selection, searchMatch: searchMatch,
            // 为了将阴影与正文明显区分开来，chrome 与前景的 0.14 颜色混合在一起。
            chromeBackground: blend(0.14),
            chromeText: blend(0.90),
            chromeSecondaryText: blend(0.58),
            chromeActiveBackground: blend(0.28),
            chromeActiveText: blend(0.98),
            separator: blend(0.26),
            dirtyIndicator: dirty,
            appearanceName: lum < 0.5 ? .darkAqua : .aqua)
    }

    /// 使用 t 逐分量对 2 种颜色进行线性插值（alpha 固定为 1）。
    private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                alpha: 1.0)
    }

    // MARK: - 助手

    private static func hex(_ rgb: Int, _ alpha: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: alpha)
    }

    private static func postChanged() {
        NotificationCenter.default.post(name: .siftEditorDisplayChanged, object: nil)
    }

}
