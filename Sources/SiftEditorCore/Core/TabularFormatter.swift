import Foundation

/// 结构化显示模式。CSV/TSV 为分隔符格式，NDJSON 为键投影，JSON 为单行格式。
/// 文档缩进格式（后者不是面向列的，因此 `TabularFormatter` 将不起作用），
/// 已委托给查看器端的 `JsonFormatter`。（此处未包含）。
///
/// `fixedWidth` 是唯一一个无法根据其内容自动识别的 ID。因为它没有分隔符。
/// 只有人（即数字引导员）才能确定物品边界。如果没有定义……
/// 无法进入此模式（呼叫者会先询问定义）。
public enum StructuredMode: String, CaseIterable, Sendable {
    case csv, tsv, ndjson, json, fixedWidth

    /// 横幅和菜单上显示的名称。如果名称是 `rawValue.uppercased()`，则变为 `FIXEDWIDTH`。
    public var displayName: String {
        switch self {
        case .csv, .tsv, .ndjson, .json: return rawValue.uppercased()
        case .fixedWidth: return L("structured.fixedWidth")
        }
    }
}

/// 纯逻辑（与 UI 无关），用于将原始单行字符串格式化为具有固定宽度列和对齐列的显示字符串。
///
/// 根据示例行确定列（标题名称 + 固定宽度）为 `build`。`format` 为一行。
/// 将单元格分解，根据显示宽度将每个单元格填充/省略到列宽，并将它们与 ` │ ` 连接起来。
/// 因为它不依赖于字节偏移量，所以大文件 (`PieceTableViewer`) 和小文件
/// (`EditableViewer`) 可以与来自两条路径的同一调用一起使用。
public struct TabularFormatter {
    /// `originalIndex` = 此列原本指的是哪个单元格位置（从 0 开始，除以分隔符后的原始列）。
    /// **即使由于排序（B19）导致 `columns` 的顺序发生变化，也需要设置一个固定点来防止值被误解**
    /// (csv/tsv 是因为被分隔符分隔的原始单元格始终按文件顺序排列，所以是 `columns[j]` 和
    /// 排序后，第 j 个原始单元格将不再对应。（`cells(of:)` 会在此处查找并重排元素。）
    /// ndjson 是通过键检索的，而 fixedWidth 不支持排序，因此两者基本上都没有被使用。
    struct Column { let key: String; let width: Int; let originalIndex: Int }   // width 是每个显示单元。

    let mode: StructuredMode
    let columns: [Column]
    /// 当项目为固定长度（1-起始，闭合区间）时，该项目的数字范围。其他模式下为空。
    let fields: [ClosedRange<Int>]
    /// 单元格分隔符。
    static let separator = " │ "

    var columnCount: Int { columns.count }

    // MARK: - 列宽（在标题栏中拖动即可更改）

    /// 列宽的下限和上限（防止因拼写错误或粗心拖动而导致显示错误）。
    static let minColumnWidth = 1
    static let maxColumnWidth = 400

    /// 一个新的形状调整器，列宽已更改（ / `index`）。**由于它是一个结构体，因此原始形状保持不变。**
    func withColumnWidth(_ index: Int, _ width: Int) -> TabularFormatter {
        guard columns.indices.contains(index) else { return self }
        var cols = columns
        let w = min(max(width, Self.minColumnWidth), Self.maxColumnWidth)
        cols[index] = Column(key: cols[index].key, width: w, originalIndex: cols[index].originalIndex)
        return TabularFormatter(mode: mode, columns: cols, fields: fields)
    }

    // MARK: - 重新排列列（在标题栏中拖放列名称以更改其顺序）

    /// 将列  / `index` 移动到位置 `toIndex`。**由于它是一个结构体，因此原始结构体保持不变。**
    /// index/toIndex 超出范围，返回 no-op（它返回自身）。
    func movingColumn(_ index: Int, to toIndex: Int) -> TabularFormatter {
        guard columns.indices.contains(index), (0..<columns.count).contains(toIndex) else { return self }
        var cols = columns
        let col = cols.remove(at: index)
        cols.insert(col, at: toIndex)
        return TabularFormatter(mode: mode, columns: cols, fields: fields)
    }

    /// 列名 (key) 用于映射和应用排序顺序和宽度。
    ///
    /// `order` 中不存在的键（意外 = 文件结构已更改）将**按其原始顺序保留在最后**。
    /// -- 不要丢失任何数据。忽略位于 `order` 中但不在当前列中的键。
    func applyingLayout(order: [String], widths: [String: Int]) -> TabularFormatter {
        var byKey: [String: Column] = [:]
        for c in columns { byKey[c.key] = c }   // 如果存在多个同名密钥，则最后输入的密钥优先（无意优先考虑第一个输入的密钥）。
        var cols: [Column] = []
        for key in order {
            guard var c = byKey.removeValue(forKey: key) else { continue }
            if let w = widths[key] {
                c = Column(key: c.key, width: min(max(w, Self.minColumnWidth), Self.maxColumnWidth),
                          originalIndex: c.originalIndex)
            }
            cols.append(c)
        }
        // 未处理的列（意外的键配置）将按其原始顺序保留在末尾。
        for c in columns where byKey[c.key] != nil { cols.append(c) }
        return TabularFormatter(mode: mode, columns: cols, fields: fields)
    }

    /// 格式化显示中每一列的起始数字（从 1 开始）。最左侧列的位置。
    ///
    /// **这是列边界的位置。** 它用于标题栏中的碰撞检测以及拖动后计算宽度。
    /// 数字 ↔ x 之间的转换由 `ColumnRuler` 处理，因此这里只返回数字。
    func columnStartColumns() -> [Int] {
        var out: [Int] = []
        var col = 1
        let sep = Self.displayWidth(Self.separator)
        for c in columns {
            out.append(col)
            col += c.width + sep
        }
        return out
    }

    /// `index` 分隔符所在列中最右边的数字。拖拽手柄位于此处。
    func separatorColumn(after index: Int) -> Int? {
        guard columns.indices.contains(index) else { return nil }
        return columnStartColumns()[index] + columns[index].width
    }

    /// 当抓取的分隔符移动到数字 `column` 时，列的新宽度。
    /// 即使向左移动太多，也要至少保留一位数字（以防止列消失而变得无法访问）。
    func width(forSeparatorOf index: Int, draggedTo column: Int) -> Int {
        guard columns.indices.contains(index) else { return 0 }
        let start = columnStartColumns()[index]
        return min(max(column - start, Self.minColumnWidth), Self.maxColumnWidth)
    }

    // MARK: - 構築

    /// 从样本行（原始字符串，假设为前 1000 行）中确定列（名称 + 固定宽度）。
    ///
    /// `fields` 仅在长度固定时才有意义（来自数字指南的项目范围）。
    /// 如果将 `.fixedWidth` 为空，则该列变为 0 = **调用者必须先有定义**。
    static func build(mode: StructuredMode, sampleLines: [String], widthCap: Int = 40,
                      fields: [ClosedRange<Int>] = [], firstRowIsHeader: Bool = true) -> TabularFormatter {
        let rows = sampleLines.filter { !$0.isEmpty }
        switch mode {
        case .fixedWidth:
            let fmt = TabularFormatter(mode: mode, columns: [], fields: fields)
            var widths = fields.map { displayWidth(label(of: $0)) }
            for line in rows {
                for (j, cell) in fmt.fixedCells(of: line).enumerated() where j < widths.count {
                    widths[j] = max(widths[j], displayWidth(cell))
                }
            }
            // 宽度没有上限。项目的宽度由定义决定，截断后……
            // “显示数字计数时出现数字丢失”的情况。
            let cols = zip(fields, widths).enumerated()
                .map { i, pair in Column(key: label(of: pair.0), width: max(1, pair.1), originalIndex: i) }
            return TabularFormatter(mode: mode, columns: cols, fields: fields)
        case .csv, .tsv:
            let sep: Character = (mode == .csv) ? "," : "\t"
            let parsed = rows.map { splitDelimited($0, sep: sep, csvQuotes: mode == .csv) }
            let header = parsed.first ?? []
            let colCount = parsed.map(\.count).max() ?? header.count
            var cols: [Column] = []
            for j in 0..<max(colCount, header.count) {
                let name = firstRowIsHeader && j < header.count ? header[j] : String(j + 1)
                var w = displayWidth(name)
                for cells in parsed where j < cells.count { w = max(w, displayWidth(cells[j])) }
                cols.append(Column(key: name, width: clampWidth(w, cap: widthCap), originalIndex: j))
            }
            return TabularFormatter(mode: mode, columns: cols, fields: [])
        case .ndjson:
            var order: [String] = []
            var seen = Set<String>()
            var maxW: [String: Int] = [:]
            for line in rows {
                guard let obj = jsonObject(line) else { continue }
                for key in orderedKeys(of: line) {
                    if !seen.contains(key) { seen.insert(key); order.append(key); maxW[key] = displayWidth(key) }
                    let v = valueString(obj[key] ?? NSNull())
                    maxW[key] = max(maxW[key] ?? 0, displayWidth(v))
                }
            }
            let cols = order.enumerated().map { i, key in
                Column(key: key, width: clampWidth(maxW[key] ?? displayWidth(key), cap: widthCap), originalIndex: i)
            }
            return TabularFormatter(mode: mode, columns: cols, fields: [])
        case .json:
            // JSON 不会出现在这里，因为查看器委托给 JsonFormatter（为了安全起见，此处留空）。
            return TabularFormatter(mode: mode, columns: [], fields: [])
        }
    }

    // MARK: - 整形

    /// 1 行 → 1 列对齐的显示字符串。
    func format(_ rawLine: String) -> String {
        let cells = self.cells(of: rawLine)
        var parts: [String] = []
        parts.reserveCapacity(columns.count)
        for (j, col) in columns.enumerated() {
            let raw = j < cells.count ? cells[j] : ""
            parts.append(Self.pad(raw, to: col.width))
        }
        return parts.joined(separator: Self.separator)
    }

    /// 表头行（列名对齐到最接近的整数）。用于将来固定表头。在 CSV/TSV 中，第 0 行是实际数据的表头。
    func headerLine() -> String {
        columns.map { Self.pad($0.key, to: $0.width) }.joined(separator: Self.separator)
    }

    /// 1 行 → 单元格数组。**返回的顺序为 `columns`**（排序后的显示顺序）。
    ///
    /// csv/tsv 用分隔符分隔时，总是会生成一个按文件顺序（原始列位置）排列的数组。
    /// 使用  / `columns[j].originalIndex` 重新计算“显示的 j 列是哪个原始单元格”。
    /// 如果您不这样做并按原样返回原始单元格，则排序后列名会更改，但值不会更改 (B19)。
    /// (在真机上测试 - 2026-09-25)。
    func cells(of rawLine: String) -> [String] {
        switch mode {
        case .csv, .tsv:
            let sep: Character = (mode == .csv) ? "," : "\t"
            let raw = Self.splitDelimited(rawLine, sep: sep, csvQuotes: mode == .csv)
            return columns.map { $0.originalIndex < raw.count ? raw[$0.originalIndex] : "" }
        case .ndjson:
            guard let obj = Self.jsonObject(rawLine) else { return [rawLine] }
            return columns.map { Self.valueString(obj[$0.key] ?? NSNull()) }
        case .fixedWidth:
            return fixedCells(of: rawLine)
        case .json:
            return [rawLine]   // JSON 将在查看器端进行格式化。这只是一个预防措施。
        }
    }

    // MARK: - 固定长度（按数字截断）

    /// 项目标题 (`1-8`)。由于固定长度列没有列名，因此使用**数字本身**作为列名。
    /// 此名称也可用于列选择，因此其格式应能显示对应的数字。
    static func label(of range: ClosedRange<Int>) -> String { "\(range.lowerBound)-\(range.upperBound)" }

    /// 1 按项目的列范围截断该行。
    ///
    /// **切割单位不是“字符”，而是“可见数字”**（全角字符为两位数字）。数字标尺和辅助线是
    /// 因为它被绘制到屏幕上的位置，所以如果按字符数将其裁剪，则只有包含全角字符的行才会出现行和内容错位的情况。
    /// 跨越多个数字的全角字符应放在**起始项**中（不要拆分成单个字符）。
    /// 删除项目的边距（右边缘的空白）= 显示值本身。
    func fixedCells(of rawLine: String) -> [String] {
        guard !fields.isEmpty else { return [rawLine] }
        var cells = [String](repeating: "", count: fields.count)
        var column = 1                      // 您当前查看的字符的起始数字（从 1 开始）
        var f = 0                           // 当前已录入项目
        for ch in rawLine {
            let w = Self.charWidth(ch)
            while f < fields.count, column > fields[f].upperBound { f += 1 }
            if f >= fields.count { break }   // 定义之外（右侧）
            if column >= fields[f].lowerBound { cells[f].append(ch) }
            column += w
        }
        return cells.map { cell in
            var s = cell
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }
    }

    // MARK: - 分割（1行内）

    /// 分隔符拆分。仅在 `csvQuotes` 的情况下处理 RFC4180 样式的引号（“...” 和“” 转义符）。
    /// 引号内的换行符将被排除（由于行方向，每个物理行 = 1 条记录）。
    public static func splitDelimited(_ line: String, sep: Character, csvQuotes: Bool) -> [String] {
        if !csvQuotes { return line.components(separatedBy: String(sep)) }
        var out: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1
            } else {
                if c == "\"" && field.isEmpty { inQuotes = true; i += 1 }
                else if c == sep { out.append(field); field = ""; i += 1 }
                else { field.append(c); i += 1 }
            }
        }
        out.append(field)
        return out
    }

    // MARK: - JSON

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// JSON 按**出现顺序**返回对象的键（`JSONSerialization` 不保留顺序，因此它只是简单地扫描原始字符串）。
    private static func orderedKeys(of line: String) -> [String] {
        guard let obj = jsonObject(line) else { return [] }
        var keys: [String] = []
        var seen = Set<String>()
        let chars = Array(line)
        var i = 0
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" || c == "[" { depth += 1; i += 1; continue }
            if c == "}" || c == "]" { depth -= 1; i += 1; continue }
            // 仅从顶层拾取“key”（depth==1）。
            if c == "\"" && depth == 1 {
                var k = ""; i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    k.append(chars[i]); i += 1
                }
                i += 1 // 关闭
                // 如果紧随其后的字符（跳过一个空格）是冒号（:），那么它就是一个密钥。
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, chars[j] == ":", obj[k] != nil, !seen.contains(k) {
                    seen.insert(k); keys.append(k)
                }
                continue
            }
            i += 1
        }
        // 扫描过程中无法拾取的钥匙将添加到末尾（即使顺序不正确，也不会省略）。
        for k in obj.keys where !seen.contains(k) { keys.append(k) }
        return keys
    }

    /// JSON 的值以字符串形式显示。该字符串保持不变，而 compact、JSON 和 null 则留空。
    private static func valueString(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let s = value as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(value)"
    }

    // MARK: - 内边距/显示宽度

    /// 根据显示宽度，向单元格 `width` 添加左对齐内边距。超出部分将在单元格 `width-1` 处截断，然后截断至单元格 `…`。
    static func pad(_ s: String, to width: Int) -> String {
        let w = displayWidth(s)
        if w == width { return s }
        if w < width { return s + String(repeating: " ", count: width - w) }
        // 修剪（保留 1 个单元格...）。
        var out = ""
        var used = 0
        for ch in s {
            let cw = charWidth(ch)
            if used + cw > width - 1 { break }
            out.append(ch); used += cw
        }
        out.append("…")            // ... 宽度为 1
        let pad = width - (used + 1)
        return pad > 0 ? out + String(repeating: " ", count: pad) : out
    }

    /// 字符串显示宽度（基于等宽字体；CJK/ 全宽 = 2）。
    static func displayWidth(_ s: String) -> Int {
        var w = 0
        for ch in s { w += charWidth(ch) }
        return w
    }

    private static func charWidth(_ ch: Character) -> Int {
        for u in ch.unicodeScalars where isWide(u.value) { return 2 }
        return 1
    }

    private static func clampWidth(_ w: Int, cap: Int) -> Int { max(1, min(cap, w)) }

    /// East Asian Wide/Fullwidth 的近似范围确定（适合两个等宽单元格的字符）。
    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F,      // Hangul Jamo
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols/punct
             0x3041...0x33FF,      // Hiragana, Katakana, CJK symbols
             0x3400...0x4DBF,      // CJK Ext A
             0x4E00...0x9FFF,      // CJK Unified
             0xA000...0xA4CF,      // Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compat ideographs
             0xFE30...0xFE4F,      // CJK compat forms
             0xFF00...0xFF60,      // Fullwidth forms
             0xFFE0...0xFFE6,      // Fullwidth signs
             0x1F300...0x1FAFF,    // emoji / symbols
             0x20000...0x3FFFD:    // CJK Ext B+
            return true
        default:
            return false
        }
    }
}
