import AppKit

/// 将外观配置文件（主题、配色方案、字体、正文布局）合并为一个，
/// 文件写入/读取和共享。使用 URL (`sifteditor://theme?d=…`) 交换数据的值类型。
///
/// **仅包含“外观”**：主题 preset・custom 6 种颜色・字体类型/大小・标签宽度・
/// 行间距、当前行高亮显示、光标形状和长行自动换行。会话（打开的文件）和
/// “非视觉”设置，例如更新检查和保存进度的显示方式，**有意排除在外**。
/// （为了避免完全覆盖其他人的环境）。
///
/// 共享的 URL 没有后端，并且是**自包含的**（配置嵌入在 URL 中，使用 base64url）。
/// 自定义方案 `sifteditor://` 已注册为 `Info.plist` 和 `CFBundleURLTypes`，
/// `application(_:open:)` 将接收、验证并应用更改。
struct SettingsBundle: Codable, Equatable {
    /// 架构版本。此信息用于确保即使将来添加更多字段，也能安全读取旧版本。
    static let currentVersion = 1
    /// URL 的共享方案/主机。
    static let urlScheme = "sifteditor"
    static let urlHost = "theme"
    /// 查询键（主配置列为 base64url）。
    static let urlDataKey = "d"
    /// 导出文件扩展名（内容为纯文本 JSON）。
    static let fileExtension = "sifteditortheme"

    var version: Int
    /// `ThemePreset.rawValue`。读取未知值时，将四舍五入为 `.system`。
    var themePreset: String
    /// `EditorTheme.ColorKey.rawValue` → "RRGGBBAA"（8 位数字，包括 sRGB 和 alpha）。
    var customColors: [String: String]
    /// 字体类型（nil = 系统默认等宽字体）。
    var fontName: String?
    var fontSize: Double
    var tabWidth: Int
    /// `LineSpacing.rawValue`。
    var lineSpacing: String
    var highlightCurrentLine: Bool
    /// `CursorShape.rawValue`。
    var cursorShape: String
    var lineWrap: Bool
    /// 背景不透明度（0.30–1.00）。旧版本共享链接中没有此选项，请使用 optional。
    var backgroundOpacity: Double?
    /// ANSI 彩色显示屏（查看时）。由于旧版本共享链接中不包含此功能，请使用 optional。
    var ansiColors: Bool?
    /// 显示行号（装订线）。旧版本共享链接中缺少此功能，请使用 optional。
    var showLineNumbers: Bool?
    /// 显示不可见字符。旧版本共享链接中不存在此问题，因此其 ID 为 optional。
    var showInvisibles: Bool?

    enum DecodeError: Error, Equatable {
        case malformed          // JSON/base64 已损坏。
        case unsupportedVersion // 未来版
        case wrongScheme        // URL 具有不同的方案/主机。
        case missingData        // URL 没有数据。
    }

    // MARK: - 获取当前值

    /// 根据当前全局设置创建捆绑包。
    static func capture() -> SettingsBundle {
        var colors: [String: String] = [:]
        for key in EditorTheme.ColorKey.allCases {
            colors[key.rawValue] = hexString(EditorTheme.customColor(key))
        }
        return SettingsBundle(
            version: currentVersion,
            themePreset: EditorTheme.preset.rawValue,
            customColors: colors,
            fontName: EditorFont.currentName,
            fontSize: Double(EditorFont.currentSize),
            tabWidth: AppSettings.tabWidth,
            lineSpacing: AppSettings.lineSpacing.rawValue,
            highlightCurrentLine: AppSettings.highlightCurrentLine,
            cursorShape: AppSettings.cursorShape.rawValue,
            lineWrap: AppSettings.lineWrap,
            backgroundOpacity: Double(EditorTheme.backgroundOpacity),
            ansiColors: EditorTheme.ansiColorsEnabled,
            showLineNumbers: AppSettings.showLineNumbers,
            showInvisibles: AppSettings.showInvisibles)
    }

    // MARK: - 適用

    /// 将此捆绑包写入全局设置（每个设置的通知也会通过现有的 setter 发送）。
    /// custom 如果先输入颜色，preset 将暂时变为 `.custom`，因此 **preset 最后确认**。
    func apply() {
        // 字体
        EditorFont.setName(fontName)
        EditorFont.setSize(CGFloat(fontSize))
        // 本文体裁
        AppSettings.tabWidth = tabWidth
        AppSettings.lineSpacing = LineSpacing(rawValue: lineSpacing) ?? .standard
        AppSettings.highlightCurrentLine = highlightCurrentLine
        AppSettings.cursorShape = CursorShape(rawValue: cursorShape) ?? .bar
        AppSettings.lineWrap = lineWrap
        if let backgroundOpacity { EditorTheme.backgroundOpacity = CGFloat(backgroundOpacity) }
        if let ansiColors { EditorTheme.ansiColorsEnabled = ansiColors }
        if let showLineNumbers { AppSettings.showLineNumbers = showLineNumbers }
        if let showInvisibles { AppSettings.showInvisibles = showInvisibles }
        // 颜色方案（custom 颜色 → preset 确认顺序）
        for key in EditorTheme.ColorKey.allCases {
            if let hex = customColors[key.rawValue], let color = SettingsBundle.color(fromHex: hex) {
                EditorTheme.setCustomColor(key, color)   // 击败  preset 至 .custom
            }
        }
        EditorTheme.preset = ThemePreset(rawValue: themePreset) ?? .system
    }

    /// 应用后主要变更项目（确认单简要说明）。包含本地化主题名称。
    func summaryLines() -> [String] {
        let themeName = L("prefs.theme.\(themePreset)")
        let fontDesc = (fontName ?? L("prefs.font.system")) + "  \(Int(fontSize)) pt"
        return ["\(L("prefs.theme")): \(themeName)",
                "\(L("prefs.font")): \(fontDesc)"]
    }

    // MARK: - 序列化

    /// 编码为  / JSON（用于文件写入的原始字节）。
    func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// JSON 已从字节中恢复。请验证版本和有效性。
    static func decode(fromJSON data: Data) throws -> SettingsBundle {
        guard let bundle = try? JSONDecoder().decode(SettingsBundle.self, from: data) else {
            throw DecodeError.malformed
        }
        guard bundle.version <= currentVersion else { throw DecodeError.unsupportedVersion }
        return bundle
    }

    /// 将配置设置为字符串 base64url（嵌入在 URL 中的便携式表单）。
    func encodedString() -> String {
        base64url(jsonData())
    }

    /// base64url 从字符串中恢复。
    static func decode(fromEncoded string: String) throws -> SettingsBundle {
        guard let data = dataFromBase64url(string) else { throw DecodeError.malformed }
        return try decode(fromJSON: data)
    }

    // MARK: - 共有 URL

    /// 创建共享的 URL (`sifteditor://theme?d=<base64url>`)。
    func shareURL() -> URL {
        var comps = URLComponents()
        comps.scheme = SettingsBundle.urlScheme
        comps.host = SettingsBundle.urlHost
        comps.queryItems = [URLQueryItem(name: SettingsBundle.urlDataKey, value: encodedString())]
        return comps.url!
    }

    /// 已分析并恢复共享的 URL。方案/主机差异和数据丢失导致出现 typed 和 error。
    static func decode(fromURL url: URL) throws -> SettingsBundle {
        guard url.scheme == urlScheme else { throw DecodeError.wrongScheme }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.host == urlHost else { throw DecodeError.wrongScheme }
        guard let data = comps.queryItems?.first(where: { $0.name == urlDataKey })?.value,
              !data.isEmpty else { throw DecodeError.missingData }
        return try decode(fromEncoded: data)
    }

    /// 此 URL 是否为配置共享方案（用于分发 open 处理程序）。
    static func isSettingsURL(_ url: URL) -> Bool {
        url.scheme == urlScheme
    }

    // MARK: - 色 ↔ hex

    /// NSColor → "RRGGBBAA"（sRGB）。
    private static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func b(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "%02X%02X%02X%02X",
                      b(c.redComponent), b(c.greenComponent), b(c.blueComponent), b(c.alphaComponent))
    }

    /// "RRGGBB" / "RRGGBBAA" → NSColor (sRGB)。如果位数不同，则变为 nil。
    static func color(fromHex hex: String) -> NSColor? {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = (s.count == 8)
        let r, g, b, a: UInt64
        if hasAlpha {
            r = (value >> 24) & 0xFF; g = (value >> 16) & 0xFF; b = (value >> 8) & 0xFF; a = value & 0xFF
        } else {
            r = (value >> 16) & 0xFF; g = (value >> 8) & 0xFF; b = value & 0xFF; a = 0xFF
        }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    // MARK: - base64url

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64url(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        // 恢复填充。
        let rem = s.count % 4
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s)
    }
}
