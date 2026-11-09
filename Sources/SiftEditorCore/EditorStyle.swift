import AppKit

/// 一个常用的辅助函数，它根据字体和设置来确定正文的格式（制表符宽度、行距）。
/// 大文件 (`DocumentView`/`LineLayout`) 和小文件 (`NSTextView`)
/// 在两个路径中使用相同的段落样式和行高，以确保外观一致。
enum EditorStyle {

    /// 基于当前字体和设置（包括制表符宽度和行高）的段落样式。
    /// 修复  / `minimum/maximumLineHeight`，并对每一子行进行换行。
    /// 使行高与单行相同（匹配 `DocumentView.lineHeight`）。
    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let tab = tabInterval(for: font)
        p.defaultTabInterval = tab
        p.tabStops = []                       // 将制表符统一为等间距（移除默认的 8 个制表位）
        let h = lineHeight(for: font)
        p.minimumLineHeight = h
        p.maximumLineHeight = h
        return p
    }

    /// 每行高度（包括行间距倍数，整数 px）。
    static func lineHeight(for font: NSFont) -> CGFloat {
        let lm = NSLayoutManager()
        let base = lm.defaultLineHeight(for: font)
        return ceil(base * AppSettings.lineSpacing.multiplier)
    }

    /// 一个制表符的宽度（相当于 `tabWidth` 字符的半角空格的宽度）。
    static func tabInterval(for font: NSFont) -> CGFloat {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        return space * CGFloat(AppSettings.tabWidth)
    }

    /// 块光标宽度（等宽，相当于一个字符）。
    static func caretWidth(for font: NSFont) -> CGFloat {
        columnWidth(for: font)
    }

    /// 数字尺：一个数字的宽度（一个半角字符）。
    /// **两个窗格都读取此内容**（如果分别测量，刻度和文本将错位）。
    static func columnWidth(for font: NSFont) -> CGFloat {
        let w = ("0" as NSString).size(withAttributes: [.font: font]).width
        return w > 0 ? w : max(2, font.pointSize * 0.6)
    }
}
