import AppKit

/// ANSI SGR (Select Graphic Rendition) 16 色调色板用于解释转义 + 默认值 fg/bg。
/// 标准颜色为符合 xterm 的固定颜色。默认颜色 fg/bg 可接受当前主题颜色（以便与任何主题自然搭配）。
struct ANSIPalette {
    /// 标准 8 色 (0–7) + 高亮度 8 色 (8–15)。index 对应于 SGR 的颜色编号。
    var colors: [NSColor]
    var defaultForeground: NSColor
    var defaultBackground: NSColor

    /// 从当前主题（主文本 fg/bg）中获取默认颜色，并将标准 16 种颜色设置为 xterm。
    static func from(theme: EditorColorTheme) -> ANSIPalette {
        ANSIPalette(colors: xterm16, defaultForeground: theme.foreground, defaultBackground: theme.background)
    }

    /// xterm 有 16 种标准颜色（0=black … 7=white，8–15=高亮度）。
    static let xterm16: [NSColor] = [
        hex(0x000000), hex(0xCD0000), hex(0x00CD00), hex(0xCDCD00),
        hex(0x0000EE), hex(0xCD00CD), hex(0x00CDCD), hex(0xE5E5E5),
        hex(0x7F7F7F), hex(0xFF0000), hex(0x00FF00), hex(0xFFFF00),
        hex(0x5C5CFF), hex(0xFF00FF), hex(0x00FFFF), hex(0xFFFFFF),
    ]

    /// xterm 是 256 色调色板中的第 n 种颜色（16–231 = 6 × 6 × 6 个立方体，232–255 = 灰度）。
    func color256(_ n: Int) -> NSColor {
        if n < 16 { return colors[n] }
        if n >= 232 {
            let v = CGFloat(8 + (n - 232) * 10) / 255
            return NSColor(srgbRed: v, green: v, blue: v, alpha: 1)
        }
        let i = n - 16
        let r = i / 36, g = (i / 6) % 6, b = i % 6
        func c(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
        return NSColor(srgbRed: c(r), green: c(g), blue: c(b), alpha: 1)
    }

    private static func hex(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// ANSI SGR 解释转义并返回带颜色的 `NSAttributedString` 和转义后的纯字符串。
enum ANSIColor {
    /// 扫描一行（假设没有换行符）。如果没有转义字符，则返回 `nil`（调用者将跳转到常规路径）。
    /// - `base`：基本属性，例如字体/段落样式（fg 被 SGR 覆盖）。
    /// - 返回值 `plain` 是转义后的可见文本（用于搜索高亮显示的范围计算）。
    static func attributed(_ line: String, base: [NSAttributedString.Key: Any],
                           palette: ANSIPalette) -> (attributed: NSAttributedString, plain: String)? {
        // 如果  ESC (0x1B) 不存在，则 ANSI 不适用。
        guard line.utf8.contains(0x1B) else { return nil }

        let scalars = Array(line.unicodeScalars)
        let out = NSMutableAttributedString()
        var plain = String.UnicodeScalarView()
        var state = SGRState(palette: palette)
        var i = 0
        // 存储当前的 run，并在属性更改/结束时将它们全部转换为 emit。
        var run = String.UnicodeScalarView()

        func flushRun() {
            guard !run.isEmpty else { return }
            let s = String(run)
            out.append(NSAttributedString(string: s, attributes: state.attributes(base: base)))
            run = String.UnicodeScalarView()
        }

        while i < scalars.count {
            let sc = scalars[i]
            // CSI 序列：ESC '[' …（直到终止字符）。仅解释 SGR('m')，其余部分将从显示中移除。
            if sc.value == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "[" {
                var j = i + 2
                var params = String.UnicodeScalarView()
                while j < scalars.count {
                    let c = scalars[j]
                    // 终止符 = 0x40–0x7E 的最后一个字节。
                    if c.value >= 0x40 && c.value <= 0x7E {
                        if c == "m" { flushRun(); state.apply(String(params)) }
                        // 丢弃所有 CSI（光标移动等），但  'm' 除外。
                        break
                    }
                    params.append(c)
                    j += 1
                }
                i = j + 1
                continue
            }
            // 裸露的 ESC 和其他 C0 控件不显示，并被跳过（例如，单独的 ESC）。
            if sc.value == 0x1B { i += 1; continue }
            run.append(sc)
            plain.append(sc)
            i += 1
        }
        flushRun()
        return (out, String(plain))
    }

    /// SGR 的当前状态（颜色、粗体、斜体、下划线）。`apply` 反映了 `1;31` 等参数列。
    /// 颜色为 palette，立即解析为 `NSColor`，状态传递到下一个 SGR。
    private struct SGRState {
        let palette: ANSIPalette
        var fg: NSColor?
        var bg: NSColor?
        var bold = false
        var italic = false
        var underline = false

        mutating func apply(_ params: String) {
            // Sora (`ESC[m`) 被视为 reset。
            let parts = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            var k = 0
            while k < parts.count {
                let code = Int(parts[k]) ?? 0
                switch code {
                case 0: fg = nil; bg = nil; bold = false; italic = false; underline = false
                case 1: bold = true
                case 3: italic = true
                case 4: underline = true
                case 22: bold = false
                case 23: italic = false
                case 24: underline = false
                case 30...37: fg = palette.colors[code - 30]
                case 90...97: fg = palette.colors[code - 90 + 8]
                case 40...47: bg = palette.colors[code - 40]
                case 100...107: bg = palette.colors[code - 100 + 8]
                case 39: fg = nil
                case 49: bg = nil
                case 38, 48:                     // 扩展颜色：38;5;n / 38;2;r;g;b (bg 为 48)
                    let isFG = (code == 38)
                    if k + 1 < parts.count, parts[k + 1] == "5", k + 2 < parts.count {
                        let c = palette.color256(Int(parts[k + 2]) ?? 0)
                        if isFG { fg = c } else { bg = c }
                        k += 2
                    } else if k + 1 < parts.count, parts[k + 1] == "2", k + 4 < parts.count {
                        let r = Int(parts[k + 2]) ?? 0, g = Int(parts[k + 3]) ?? 0, b = Int(parts[k + 4]) ?? 0
                        let c = NSColor(srgbRed: CGFloat(min(255, r)) / 255, green: CGFloat(min(255, g)) / 255,
                                        blue: CGFloat(min(255, b)) / 255, alpha: 1)
                        if isFG { fg = c } else { bg = c }
                        k += 4
                    }
                default: break
                }
                k += 1
            }
        }

        func attributes(base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attrs = base
            if let fg { attrs[.foregroundColor] = fg }
            if let bg { attrs[.backgroundColor] = bg }
            if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if bold || italic, let f = base[.font] as? NSFont {
                var traits: NSFontTraitMask = []
                if bold { traits.insert(.boldFontMask) }
                if italic { traits.insert(.italicFontMask) }
                attrs[.font] = NSFontManager.shared.convert(f, toHaveTrait: traits)
            }
            return attrs
        }
    }
}
