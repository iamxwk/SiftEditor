import Foundation

/// 按“形状”而不是“值”比较行的规范化（纯逻辑，与 UI 无关）。
///
/// 即使将测试环境中的数据与生产环境中的数据进行比较，**数值不同也是很正常的。**
/// 我想看的是“它们的形状是否相同？” --- 日期是 `2026-08-19` 还是 `2026/08/19`？
/// ID 是否填充了零，或者 NULL 是否为空或为 `NULL`？如果是，则**删除该行，仅保留形状**。
/// 哈希值。
///
/// **工作原理：** diff 引擎根本不检查行的内容（`LineDiff.compute` 的输入是
/// （仅限  / `[LineHash]`）。换句话说，**仅仅更改哈希值**将导致“比较格式”。
/// 唯一需要替换的地方是 `DiffSource.lineHashes(mask:)`，显示效果与原始线路相同（`DiffModel` 为
/// （只有左行和右行编号）。
///
/// **破解的关键在于“不要用类型名称替换它”。** 如果您将日期更改为 `<DATE>`
/// `2026-08-19` 和 `2026/08/19` 现在是一样的，**我们最想看到的区别消失了**。
/// 将数字的每个数字转换为 `9`，并将每个字母序列转换为单个 `A`，**保持分隔符和数字不变**。
///
///     2026-08-19 12:00:00 ERROR uid=41    →  9999-99-99 99:99:99 A A=99
///     2026/08/19 12:00:00 WARN  uid=7     →  9999/99/99 99:99:99 A A=9
/// ^^^^ 这是唯一显示为差异的部分。
///
/// **全角字符和半角字符的标记符号不同**（半角数字为 `9`，全角数字为 `#`）。数值差异消失。
/// `１２３` 和 `123` 之间的差异仍然存在——这是由于环境差异造成的最常见错误之一。
/// 不要将这些混为一谈。
public struct FormatMask: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 忽略数字的**值**（保留数字位数）。`007` 和 `123` 相同，但 `7` 不同。
    public static let digits      = FormatMask(rawValue: 1 << 0)
    /// 数字位数也被忽略（与 `.digits` 结合使用）。`007` 和 `7` 相同。
    public static let digitCount  = FormatMask(rawValue: 1 << 1)
    /// 忽略字符串的内容（`ERROR`、`WARN` 以及 `A`、`釧路検察審査会`）
    /// `伊達簡易裁判所` 也是 `T` 之一）。**假名和汉字也作为“值”折叠** — 日文 CSV
    /// 如果此项未折叠，则名称和地址都将变为差异，并且“忽略值”语句将为假。
    /// 但是，**全角符号和全角空格不会被折叠**（`、` 和 `,`，全角空格和半角空格）
    /// 差异正是我们想要找到的“形状”上的差异。
    public static let letters     = FormatMask(rawValue: 1 << 2)
    /// 忽略大小写（如果已输入 `.letters`，则会被该输入吸收）。
    public static let letterCase  = FormatMask(rawValue: 1 << 3)
    /// 将连续空格视为一个空格，并删除行尾的空格。
    public static let spaces      = FormatMask(rawValue: 1 << 4)
    /// 忽略引号的存在与否（`"` `'`）。
    public static let quotes      = FormatMask(rawValue: 1 << 5)

    /// “比较格式”中使用的默认格式。**数值将被忽略，但数字和分隔符将被考虑。**
    ///
    /// 我们不忽略数字的原因是零填充差异（`007` ⇔ `7`）是环境差异的常见原因。
    /// 如果你把它们全部摧毁，你就找不到你最想要的东西了。
    public static let standard: FormatMask = [.digits, .letters]

    // MARK: - 正規化

    // 压碎后放置的标记。**半角字符和全角字符使用不同的标记**（以保持区分）。
    private static let asciiDigitMark: UInt8 = 0x39   // '9'
    private static let wideDigitMark:  UInt8 = 0x23   // '#'
    private static let asciiLetterMark: UInt8 = 0x41  // 'A'
    private static let wideLetterMark:  UInt8 = 0x40  // '@'
    private static let cjkMark:         UInt8 = 0x54  // 'T'（假名、汉字等的序列）

    /// 将单行字节（不包括换行符）规范化并发送到 `emit`。
    ///
    /// **逐行确认并输出**（不要创建包含返回值的数组）。由于我们正在处理一个包含 86,000,000 行的文件，
    /// 当每一行都创建 `[UInt8]` 或 `String` 时，该过程结束。
    @inline(__always)
    func transform(_ p: UnsafePointer<UInt8>, count n: Int, _ emit: (UInt8) -> Void) {
        var i = 0
        var run: UInt8 = 0            // 折叠序列指示器（0 = 不在序列中间）
        var pendingSpace = false      // 是否发送  取决于下一个内容的到达情况（如果它位于行尾，则会被丢弃）。

        @inline(__always) func flushSpace() {
            if pendingSpace { emit(0x20); pendingSpace = false; run = 0 }
        }

        while i < n {
            let c = p[i]
            var width = 1

            // 分类。全角数字和字母为 3 字节（U+FF10.. / U+FF21.. / U+FF41..）。
            // 0 = 其他，1 = 半角数字，2 = 全角数字，3 = 半角英文字母，4 = 全角英文字母
            // 5 = 空格，6 = 引号，7 = 假名/汉字等。
            var kind = 0
            if c >= 0x30, c <= 0x39 { kind = 1 }
            else if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { kind = 3 }
            else if c == 0x20 || c == 0x09 { kind = 5 }
            else if c == 0x22 || c == 0x27 { kind = 6 }
            else if c >= 0xE3, c <= 0xE9, i + 2 < n {
                // 假名/汉字（U+3040 至 U+9FFF）。但是，U+3000 个单位 = 标点符号/全角空格
                // (E3 80 xx) 是一个符号，因此它不会被折叠，而是保持其“形状”。
                if !(c == 0xE3 && p[i + 1] == 0x80) { kind = 7; width = 3 }
            }
            else if c == 0xEF, i + 2 < n {
                let b = p[i + 1], d = p[i + 2]
                if b == 0xBC, d >= 0x90, d <= 0x99 { kind = 2; width = 3 }              // ０-９
                else if b == 0xBC, d >= 0xA1, d <= 0xBA { kind = 4; width = 3 }         // Ａ-Ｚ
                else if b == 0xBD, d >= 0x81, d <= 0x9A { kind = 4; width = 3 }         // ａ-ｚ
            }

            @inline(__always) func emitRaw() { for k in 0..<width { emit(p[i + k]) } }

            switch kind {
            case 1, 2:
                let mark = (kind == 1) ? Self.asciiDigitMark : Self.wideDigitMark
                if contains(.digits) {
                    flushSpace()
                    if contains(.digitCount) {
                        if run != mark { emit(mark); run = mark }
                    } else {
                        emit(mark); run = 0
                    }
                } else {
                    flushSpace(); emitRaw(); run = 0
                }
            case 3, 4, 7:
                let mark: UInt8
                switch kind {
                case 3:  mark = Self.asciiLetterMark
                case 4:  mark = Self.wideLetterMark
                default: mark = Self.cjkMark
                }
                if contains(.letters) {
                    flushSpace()
                    if run != mark { emit(mark); run = mark }
                } else {
                    flushSpace()
                    if kind == 3, contains(.letterCase) { emit(c | 0x20) } else { emitRaw() }
                    run = 0
                }
            case 5:
                if contains(.spaces) { pendingSpace = true; run = 0 } else { emit(c); run = 0 }
            case 6:
                if !contains(.quotes) { flushSpace(); emit(c); run = 0 }
            default:
                flushSpace(); emitRaw(); run = 0
            }
            i += width
        }
        // pendingSpace 将不会被流式传输 = 末尾空格将被丢弃。
    }

    /// 规范化字符串。**仅用于测试和说明目的**（生产环境会将其直接发送到哈希表）。
    public func masked(_ line: String) -> String {
        var out: [UInt8] = []
        let bytes = Array(line.utf8)
        out.reserveCapacity(bytes.count)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            transform(base, count: buf.count) { out.append($0) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - 哈希值（diff 的输入）

    /// 将一行字节序列规范化，然后对其进行哈希处理。
    func hashLine(_ p: UnsafePointer<UInt8>, count n: Int) -> LineHash {
        var h = LineHasher()
        transform(p, count: n) { h.feed($0) }
        return h.value
    }

    func hashLine(_ bytes: [UInt8]) -> LineHash {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return LineHasher().value }
            return hashLine(base, count: buf.count)
        }
    }

    /// 字节序列被分割成 0x0A 段，并规范化为每一行的哈希值。
    ///
    /// 行的分割方式和行尾的处理方式必须与 `LineHasher.hashLines` **完全相同**（去掉行尾的 0x0D，
    /// 如果结尾是换行符，则不要添加空行。如果对齐错误，简单地切换模式会导致问题。
    /// 行数发生变化，破坏了左右对应关系。
    func hashLines(_ buf: UnsafeRawBufferPointer) -> [LineHash] {
        var out: [LineHash] = []
        out.reserveCapacity(max(16, buf.count / 64))
        guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return out }
        var start = 0
        for i in 0..<buf.count where base[i] == 0x0A {
            var end = i
            if end > start, base[end - 1] == 0x0D { end -= 1 }      // 不要仅仅基于  CRLF 和 LF 之间的差异，为所有行创建差异。
            out.append(hashLine(base + start, count: end - start))
            start = i + 1
        }
        if start < buf.count || buf.count == 0 {
            var end = buf.count
            if end > start, base[end - 1] == 0x0D { end -= 1 }
            out.append(hashLine(base + start, count: end - start))
        }
        return out
    }
}
