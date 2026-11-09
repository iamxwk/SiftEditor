import CoreGraphics
import Foundation

/// 梁标尺和梁导向线的坐标计算（与 UI 无关的纯逻辑）。
///
/// **要求两个窗格使用相同的公式。** 小文件 (`NSTextView`) 和大文件
/// (`DocumentView`) 的绘图机制完全不同，所以如果您要为每个 ID 编写数字计算公式……
/// 它始终会错位。如果在错位的情况下包含固定长度的项目定义 (C)，则重新打开同一个文件会导致问题。
/// 单独指向不同的位置。因此，数字 ↔ x 之间的转换只能在此位置进行。
///
/// 坐标系为 **x**，文本左边缘为 0（不包括间距宽度和水平滚动量）。
/// 调用方添加或减去相应的源和水平滚动量。
enum ColumnRuler {
    /// `col`（从 1 开始）的最左边数字是 x。
    static func x(ofColumn col: Int, columnWidth: CGFloat) -> CGFloat {
        CGFloat(max(1, col) - 1) * columnWidth
    }

    /// x（从 1 开始计数）中的数字。负数 x 四舍五入到第一位。
    static func column(atX x: CGFloat, columnWidth: CGFloat) -> Int {
        guard columnWidth > 0 else { return 1 }
        return max(1, Int(floor(x / columnWidth)) + 1)
    }

    /// 尺子刻度，1 行。
    struct Tick: Equatable {
        let column: Int
        /// x，文本最左侧的元素设置为 0。
        let x: CGFloat
        /// 这是用于显示数字（`major` 的倍数和最后一位数字）的刻度吗？
        let isMajor: Bool
    }

    /// 缩放比例，覆盖可见区域。`offset` 为水平滚动量，`width` 为主文本的显示宽度。
    ///
    /// 返回一个带有数字的长刻度线（对应  / `major`），以及一个短刻度线（对应 `minor`）。
    /// 第一个数字是计数的起点，因此即使它不是 `major` 的倍数，也必须始终是 major。
    static func ticks(offset: CGFloat, width: CGFloat, columnWidth: CGFloat,
                      major: Int = 10, minor: Int = 5) -> [Tick] {
        guard columnWidth > 0, width > 0, major > 0, minor > 0 else { return [] }
        let first = column(atX: offset, columnWidth: columnWidth)
        let last = column(atX: offset + width, columnWidth: columnWidth)
        guard last >= first, last - first < 100_000 else { return [] }   // 防止失控的超大变焦
        var ticks: [Tick] = []
        for col in first...last {
            let isMajor = col == 1 || col % major == 0
            guard isMajor || col % minor == 0 else { continue }
            ticks.append(Tick(column: col, x: x(ofColumn: col, columnWidth: columnWidth), isMajor: isMajor))
        }
        return ticks
    }
}

/// 梁导向线集合。
///
/// **它最初存储为“数字数组”。** 将其创建为单个数字（例如，80 位数字）将生成固定长度的字段定义。
/// 我加载的时候肯定会把  / (`1-8,9-14,15-40`) 扔掉。即使现在我只抽取一个。
/// 如果将其放入数组中，则只需添加 `fieldRanges` 即可将 C 添加到此类型中。
struct ColumnGuides: Equatable {
    /// 用于绘制引导线的数字（从 1 开始，升序排列，不重复）。**init 和每次操作均遵循此不变条件。**
    private(set) var columns: [Int]

    init(_ columns: [Int] = []) {
        self.columns = Array(Set(columns.filter { $0 >= 1 })).sorted()
    }

    var isEmpty: Bool { columns.isEmpty }

    /// 该项目是否至少有一个分隔符？**第一个数字不是分隔符**（它是开头），
    /// `[1]` 的状态与“未定义”相同 = 未包含在固定长度显示中（当只有一列时，没有任何内容被分隔）。
    var hasFieldBoundaries: Bool { columns.contains { $0 > 1 } }

    /// 如果存在则删除，如果不存在则添加（这是单击标尺时执行的操作）。
    mutating func toggle(_ column: Int) {
        guard column >= 1 else { return }
        if let i = columns.firstIndex(of: column) {
            columns.remove(at: i)
        } else {
            columns.append(column)
            columns.sort()
        }
    }

    mutating func insert(_ column: Int) {
        guard column >= 1, !columns.contains(column) else { return }
        columns.append(column)
        columns.sort()
    }

    mutating func remove(_ column: Int) {
        columns.removeAll { $0 == column }
    }

    mutating func removeAll() {
        columns.removeAll()
    }

    /// 将参考线从 `column` 移动到 `newColumn`（拖动标尺）。移动完成后，将其移动到 true。
    ///
    /// **这是为了防止您在移动一位数字时不得不擦除并重新放置某些内容。** 当目的地已有向导时。
    /// 请勿移动（当两个放在一起时，其中一个似乎会消失，分开后无法恢复）。
    @discardableResult
    mutating func move(_ column: Int, to newColumn: Int) -> Bool {
        guard newColumn >= 1, newColumn != column,
              let i = columns.firstIndex(of: column), !columns.contains(newColumn) else { return false }
        columns[i] = newColumn
        columns.sort()
        return true
    }

    /// 在  / `column` 至 `tolerance` 范围内最接近的参考线。用于点击命中检测。
    ///（不支持像素级细线定位）。如果距离相同，则返回较少位数。
    func nearest(to column: Int, within tolerance: Int) -> Int? {
        columns
            .filter { abs($0 - column) <= tolerance }
            .min { (abs($0 - column), $0) < (abs($1 - column), $1) }
    }

    /// 当指南被读取为“项目中断”（1-开始，闭合区间）时，固定长度字段的范围。
    ///
    /// 数字 `[9, 15]` 表示三个项目：“1-8 / 9-14 / 15-”。最后一个项目是
    /// 如果知道  / `lastColumn`（包括行的长度），则在此处关闭页面；否则，丢弃页面。
    /// **这是 C（固定长度项定义）使用的端口。在 B 阶段没有人调用它，但设计目的是将其保存为数组。
    /// 此处放置此项表示该物品将直接送达 C。**
    func fieldRanges(lastColumn: Int? = nil) -> [ClosedRange<Int>] {
        let bounds = columns.filter { $0 > 1 }
        if bounds.isEmpty, lastColumn == nil { return [] }
        var ranges: [ClosedRange<Int>] = []
        var start = 1
        for b in bounds {
            if b - 1 >= start { ranges.append(start...(b - 1)) }
            start = b
        }
        if let last = lastColumn, last >= start {
            ranges.append(start...last)
        }
        return ranges
    }
}

extension ColumnGuides {
    /// 项目的首位数字（从 1 开始，升序排列）。首位数字始终是第一个项目的首位数字。
    ///
    /// **绘制的线条成为制表符位置。** 更正固定长度数据时，将其移至项目开头。
    /// 画线的第一个奖励是能够一气呵成地飞翔。
    var fieldStarts: [Int] { [1] + columns.filter { $0 > 1 } }

    /// `column` 之后的下一个条目的开头。如果是最后一个条目，则为 nil（调用者将其发送到下一行）。
    func nextFieldStart(after column: Int) -> Int? {
        fieldStarts.first { $0 > column }
    }

    /// `column` 的前一条记录的开头。如果是第一条记录，则为 nil（调用者发送到上一行）。
    func previousFieldStart(before column: Int) -> Int? {
        fieldStarts.last { $0 < column }
    }

    /// 包含  / `column` 的项的数字范围。用于向标尺显示您当前所在的项。
    /// 最后一个项目用 `lastColumn` 关闭（如果保持打开状态，进度条将延伸到屏幕边缘）。
    func fieldRange(containing column: Int, lastColumn: Int) -> ClosedRange<Int>? {
        guard hasFieldBoundaries, column >= 1 else { return nil }
        let starts = fieldStarts
        guard let start = starts.last(where: { $0 <= column }) else { return nil }
        // 返回范围必须始终包含 `column`（即使光标位于文本右边缘之外）。
        // （您将位于该传送带内。）
        let end = (starts.first { $0 > start }).map { $0 - 1 } ?? max(lastColumn, column, start)
        guard end >= start else { return nil }
        return start...end
    }

    /// 要以条纹形式着色的数字范围（从 1 开始，闭合区间）。返回每隔一个数字。
    ///
    /// 固定长度数据**已经是对齐的数字**，因此无需格式化即可将其显示为列。
    /// 只需将每隔一个项目轻轻涂上颜色，并在其下方画一条线，即可将其变成表格，而主要文本保持不变 = **可编辑**。
    func stripes(upTo lastColumn: Int) -> [ClosedRange<Int>] {
        guard lastColumn >= 1 else { return [] }
        return fieldRanges(lastColumn: lastColumn)
            .enumerated()
            .compactMap { $0.offset % 2 == 1 ? $0.element : nil }
            // **在可见数字处截断。** 该项目的范围延伸至下一个断点。
            // 如果您发送的命令要绘制到屏幕之外，则通话双方最终都将不得不断开连接。
            .compactMap { $0.lowerBound > lastColumn ? nil : $0.lowerBound...min($0.upperBound, lastColumn) }
    }

    /// 与示例行匹配的项目的列范围。**最后一个项目位于最长行的末尾。**
    ///
    /// 该指南只有断点，因此数据决定“最后一个项目在哪里结束”。
    /// 宽度以**可见数字**为单位测量（全宽=2），而非字符数。屏幕上设有参考线。
    /// 因为要进行减法运算，如果按字符数来衡量，则在包含全角字符的行中，行和项目将错位。
    func fieldRanges(fitting sampleLines: [String]) -> [ClosedRange<Int>] {
        // 即使  的定义延伸到 data 的右侧（例如，将 `…15-40` 分配给 30 位数据），
        // 请关闭数据末尾。请勿添加空列。
        let widest = sampleLines.reduce(0) { max($0, TabularFormatter.displayWidth($1)) }
        guard widest >= 1 else { return [] }
        return fieldRanges(lastColumn: widest)
    }
}

/// 读取和写入固定长度字段定义 (`1-8,9-14,15-40`)。
///
/// **处理固定长度的人通常会有规格说明** = 简单地通过点击来放置边界将是一件苦差事。
/// 反之，当没有规范文档时，找到边界是主要任务，因此点击也是必要的。两者属于同一状态。
/// 这里是放置  / (`ColumnGuides`) 的位置。**引导线是项目之间的分隔符**，所以字符串的来回移动是
/// 通过“边界数字集”（[[ColumnGuides.fieldRanges]] 的倒置版本）。
enum ColumnFieldSpec {
    /// 可接受的分隔符（半角/全角逗号、句号和空格）。
    private static let separators = CharacterSet(charactersIn: ",，、 \u{3000}\t\n")
    /// 可接受的范围符号（半角/全角连字符、各种破折号、波浪号）。
    private static let dashes: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}",
                                                 "\u{2014}", "\u{2015}", "\u{FF0D}", "\u{FF5E}",
                                                 "\u{301C}", "~", "\u{30FC}"]
    /// 最大位数（防止因拼写错误而创建非常大的数组）。
    static let maxColumn = 100_000
    /// 最大项目数。
    static let maxFields = 512

    /// 将  / `1-8,9-14,15-40` 读取为**边界数字**（从 1 开始，升序排列，无重复项）。
    ///
    /// - `a-b` = 从数字 a 到数字 b，`a-` = 从数字 a 到行尾，单独的 `a` = 从数字 a 到下一个边界。
    /// - 空字符串是“undefined”= 空数组（不是错误）。
    /// - 如果数字颠倒/重叠/小于 0/超过上限，则为 nil（静默地阻止一部分）。
    static func parse(_ text: String) -> [Int]? {
        let tokens = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        guard tokens.count <= maxFields else { return nil }

        var boundaries: [Int] = []
        var prevEnd = 0            // 前一项为封闭数字（0 = 尚未出现）
        for token in tokens {
            guard let field = parseToken(token) else { return nil }
            guard field.start > prevEnd else { return nil }        // 数字颠倒/重叠
            if let end = field.end {
                guard end >= field.start, end <= maxColumn else { return nil }
                prevEnd = end
            } else {
                prevEnd = field.start                              // 已打开项目 = 无法再写入任何内容
            }
            if field.start > 1 { boundaries.append(field.start) }
            if let end = field.end { boundaries.append(end + 1) }
        }
        // 当末端闭合 (`…-40`) 时，41 表示“到此结束”。项目直至行尾。
        // 保留  以区别于以下定义 (`41-`)。
        let unique = Array(Set(boundaries.filter { $0 >= 2 && $0 <= maxColumn + 1 })).sorted()
        return unique
    }

    /// 1 个标记 → （起始数字，结束数字 or nil = 到行尾）。
    private static func parseToken(_ token: String) -> (start: Int, end: Int?)? {
        let chars = Array(token)
        guard let dashIndex = chars.firstIndex(where: { dashes.contains($0) }) else {
            guard let n = number(String(chars)) else { return nil }
            return (n, nil)
        }
        guard let start = number(String(chars[chars.startIndex..<dashIndex])) else { return nil }
        let tail = String(chars[chars.index(after: dashIndex)...])
        if tail.isEmpty { return (start, nil) }
        guard let end = number(tail) else { return nil }
        return (start, end)
    }

    /// 大于或等于 1 的整数，仅由半角/全角数字组成。
    private static func number(_ s: String) -> Int? {
        let normalized = String(s.map { ch -> Character in
            guard let v = ch.unicodeScalars.first?.value, (0xFF10...0xFF19).contains(v) else { return ch }
            return Character(UnicodeScalar(v - 0xFF10 + 0x30)!)
        })
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(normalized),
              n >= 1, n <= maxColumn else { return nil }
        return n
    }

    /// 以 `1-8,9-14,15-` 格式导出当前指南（对话框中的默认值）。
    ///
    /// 最后一件商品**一直开放到队伍末尾**。指南中只有休息时间，
    /// 不要随意决定“它的终点”。
    static func text(for guides: ColumnGuides) -> String {
        let bounds = guides.columns.filter { $0 > 1 }
        guard !bounds.isEmpty else { return "" }
        var parts: [String] = []
        var start = 1
        for b in bounds {
            if b - 1 >= start { parts.append("\(start)-\(b - 1)") }
            start = b
        }
        parts.append("\(start)-")
        return parts.joined(separator: ",")
    }
}
