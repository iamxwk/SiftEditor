import Foundation

/// 用于可视化不可见字符的符号，以及计算在每行上绘制什么内容的计算（纯逻辑，与 UI 无关）。
///
/// 两个窗格（`DocumentView` 的自定义渲染和 `EditorTextView` 对 NSTextView 的渲染）
/// 由于使用了相同的结果，外观将保持一致。**正文不会被重写**（只有符号会重叠绘制）。
/// 将制表符替换为“→”会破坏字符的对齐方式和光标的字节映射。
///
/// 如果在每个半角空格后都加一个点，文本就会变得难以辨认，所以我只会在行尾添加空格。
/// （剩余空格是有用信息，但文本中的空格是噪音）。全角空格是
/// 这是一篇重要的日语优先帖子，因此无论其位置如何，它都会显示出来。
enum InvisibleGlyphs {
    static let tab = "→"
    static let eol = "¬"
    static let ideographicSpace = "□"
    static let trailingSpace = "·"

    /// 应该在线内的哪个 UTF-16 位置绘制哪个符号？
    struct Marker: Equatable {
        /// UTF-16 在字符串中的偏移量（在该字符**上方**绘制符号）。
        let utf16Index: Int
        let glyph: String
    }

    /// 返回一行文本（不包括换行符）中的符号序列。换行符单独绘制在行尾，因此不包含在内。
    static func markers(in line: String) -> [Marker] {
        let ns = line as NSString
        guard ns.length > 0 else { return [] }

        // 行尾的一系列半角空格（只有从此位置开始的空格才用点标记）。
        var trailingStart = ns.length
        while trailingStart > 0, ns.character(at: trailingStart - 1) == 0x0020 { trailingStart -= 1 }

        var out: [Marker] = []
        for i in 0..<ns.length {
            switch ns.character(at: i) {
            case 0x0009: out.append(Marker(utf16Index: i, glyph: tab))
            case 0x3000: out.append(Marker(utf16Index: i, glyph: ideographicSpace))
            case 0x0020 where i >= trailingStart: out.append(Marker(utf16Index: i, glyph: trailingSpace))
            default: break
            }
        }
        return out
    }
}
