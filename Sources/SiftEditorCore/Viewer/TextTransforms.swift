import Foundation

/// 编辑工具箱中的纯文本转换 (String → String)。
/// 不管后端 (NSTextView / PieceTable) 是什么，两个面板都使用相同的逻辑。
/// 行处理系统“按原样分割和处理选定的文本”（与过滤器 ⌥⌘R 的概念相同）。
enum TextTransform: Int, CaseIterable {
    // 大小写转换
    case uppercase
    case lowercase
    case titlecase
    case togglecase
    // 编码/解码
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode
    case htmlEncode
    case htmlDecode
    // 行操作
    case sortAscending
    case sortDescending
    case uniqueLines
    case duplicateLinesOnly
    case removeEmptyLines
    case reverseLines
    case numberLines
    case joinLines
    case indent
    case outdent
    case tabsToSpaces
    case spacesToTabs
    // 日時・時刻変換
    case unixTimestampToDate
    case dateToUnixTimestamp

    /// 大小写转换组（格式菜单中的第一组）。
    static let caseGroup: [TextTransform] = [.uppercase, .lowercase, .titlecase, .togglecase]
    /// 编码/解码组（第 2 组）。
    static let encodingGroup: [TextTransform] = [.urlEncode, .urlDecode, .base64Encode, .base64Decode, .htmlEncode, .htmlDecode]
    /// 日期和时间转换组（第 3 组）。
    static let dateTimeGroup: [TextTransform] = [.unixTimestampToDate, .dateToUnixTimestamp]
    /// 行操作组（第 4 组）。序列号带有参数，因此在菜单中……
    /// 此项目位于一个单独的部分，带有对话框 (`LineNumberer`)，因此不会在此处列出。
    static let lineGroup: [TextTransform] = [
        .sortAscending, .sortDescending,
        .uniqueLines, .duplicateLinesOnly, .removeEmptyLines,
        .reverseLines, .joinLines,
        .indent, .outdent, .tabsToSpaces, .spacesToTabs,
    ]

    /// 缩进/提升单位（一个制表符。提升文本是通过删除一行前导制表符或相同宽度的前导空格来实现的，这对应于此单位）。
    static let indentUnit = "\t"
    /// 增加字符数时，从没有制表符的行中删除的前导空格的上限（典型制表符宽度）。
    static let outdentSpaceWidth = 4

    /// 菜单项本地化键。
    var localizationKey: String {
        switch self {
        case .uppercase:           return "menu.format.uppercase"
        case .lowercase:           return "menu.format.lowercase"
        case .titlecase:           return "menu.format.titlecase"
        case .togglecase:          return "menu.format.togglecase"
        case .urlEncode:           return "menu.format.urlEncode"
        case .urlDecode:           return "menu.format.urlDecode"
        case .base64Encode:        return "menu.format.base64Encode"
        case .base64Decode:        return "menu.format.base64Decode"
        case .htmlEncode:          return "menu.format.htmlEncode"
        case .htmlDecode:          return "menu.format.htmlDecode"
        case .sortAscending:       return "menu.format.sortAscending"
        case .sortDescending:      return "menu.format.sortDescending"
        case .uniqueLines:         return "menu.format.uniqueLines"
        case .duplicateLinesOnly:  return "menu.format.duplicateLinesOnly"
        case .removeEmptyLines:    return "menu.format.removeEmptyLines"
        case .reverseLines:        return "menu.format.reverseLines"
        case .numberLines:         return "menu.format.numberLines"
        case .joinLines:           return "menu.format.joinLines"
        case .indent:              return "menu.format.indent"
        case .outdent:             return "menu.format.outdent"
        case .tabsToSpaces:        return "menu.format.tabsToSpaces"
        case .spacesToTabs:        return "menu.format.spacesToTabs"
        case .unixTimestampToDate: return "menu.format.unixTimestampToDate"
        case .dateToUnixTimestamp: return "menu.format.dateToUnixTimestamp"
        }
    }

    /// 对选定的字符串应用转换并返回转换结果。`nil` 无法转换（输入无效等）= 调用方发出哔声，且不更改正文。
    func apply(_ s: String) -> String? {
        switch self {
        case .uppercase:  return s.uppercased()
        case .lowercase:  return s.lowercased()
        case .titlecase:  return s.capitalized
        case .togglecase: return String(s.map { c in
            c.isUppercase ? Character(c.lowercased()) :
            c.isLowercase ? Character(c.uppercased()) : c
        })
        case .urlEncode:  return s.addingPercentEncoding(withAllowedCharacters: Self.urlUnreserved)
        case .urlDecode:  return s.removingPercentEncoding
        case .base64Encode: return Data(s.utf8).base64EncodedString()
        case .base64Decode:
            // 允许换行和自动换行（Base64）（忽略未知字符）。如果解码结果不是 UTF-8，则变为 nil。
            guard let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        case .htmlEncode: return Self.htmlEncode(s)
        case .htmlDecode: return Self.htmlDecode(s)
        case .sortAscending:      return Self.sortLines(s, by: <)
        case .sortDescending:     return Self.sortLines(s, by: >)
        case .uniqueLines:        return Self.uniqueLines(s)
        case .duplicateLinesOnly: return Self.duplicateLinesOnly(s)
        case .removeEmptyLines:   return Self.removeEmptyLines(s)
        case .reverseLines:       return Self.mapLines(s) { Array($0.reversed()) }
        case .numberLines:        return Self.numberLines(s)
        case .joinLines:          return Self.joinLines(s)
        case .indent:             return Self.indent(s)
        case .outdent:            return Self.outdent(s)
        case .tabsToSpaces:       return Self.tabsToSpaces(s)
        case .spacesToTabs:       return Self.spacesToTabs(s)
        case .unixTimestampToDate: return Self.unixTimestampToDate(s)
        case .dateToUnixTimestamp: return Self.dateToUnixTimestamp(s)
        }
    }

    /// RFC 3986 为 unreserved（所有其他值均以 % 编码）。
    private static let urlUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: - HTML 实体

    private static func htmlEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(ch)
            }
        }
        return out
    }

    /// 一次性解密数字引用（十进制/十六进制）和主要命名实体。
    /// 保持未知实体不变（不要销毁它们）。
    private static func htmlDecode(_ s: String) -> String {
        let ns = s as NSString
        let matches = htmlEntityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))   // 的内容（不包括 & 和 ;
            out += decodeEntityBody(body) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return out
    }

    private static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let num = body.dropFirst()
            let scalar: UInt32? = (num.first == "x" || num.first == "X")
                ? UInt32(num.dropFirst(), radix: 16) : UInt32(num, radix: 10)
            guard let value = scalar, let u = Unicode.Scalar(value) else { return nil }
            return String(u)
        }
        return htmlNamed[body].map(String.init)
    }

    private static let htmlEntityRegex =
        try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")

    private static let htmlNamed: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "hellip": "\u{2026}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "middot": "\u{00B7}", "bull": "\u{2022}",
    ]

    // MARK: - 行操作

    /// 分割成行，同时保留末尾的换行符（删除分割后产生的末尾空元素）。
    private static func splitLines(_ s: String) -> (lines: [String], trailingNewline: Bool) {
        let hasTrailing = s.hasSuffix("\n")
        var lines = s.components(separatedBy: "\n")
        if hasTrailing { lines.removeLast() }
        return (lines, hasTrailing)
    }

    private static func joinLines(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    private static func sortLines(_ s: String, by areInIncreasingOrder: (String, String) -> Bool) -> String {
        let (lines, trailing) = splitLines(s)
        return joinLines(lines.sorted(by: areInIncreasingOrder), trailingNewline: trailing)
    }

    /// 删除重复行（同时保留首次出现的顺序）。
    private static func uniqueLines(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        var seen = Set<String>()
        let unique = lines.filter { seen.insert($0).inserted }
        return joinLines(unique, trailingNewline: trailing)
    }

    private static func mapLines(_ s: String, _ transform: ([String]) -> [String]) -> String {
        let (lines, trailing) = splitLines(s)
        return joinLines(transform(lines), trailingNewline: trailing)
    }

    /// 在每行的开头添加一个从 1 开始的顺序编号，后面跟着一个制表符（默认参数 `LineNumberer` 本身）。
    private static func numberLines(_ s: String) -> String {
        LineNumberer.number(s, options: .init())
    }

    /// 将多行连接成一行（将换行符合并为一个空格，并删除每行的前导和尾随空格）。
    /// 删除空行。保留尾随换行符（附加到连接行）。
    private static func joinLines(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        let joined = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joinLines([joined], trailingNewline: trailing)
    }

    /// 在每行开头插入一个缩进单位（制表符）。空行将不缩进（不会留下额外的空格）。
    private static func indent(_ s: String) -> String {
        mapLines(s) { lines in
            lines.map { $0.isEmpty ? $0 : indentUnit + $0 }
        }
    }

    /// 删除每行开头的一个缩进。删除一个制表符，如果没有制表符，则删除最多 `outdentSpaceWidth` 个前导空格。
    private static func outdent(_ s: String) -> String {
        mapLines(s) { lines in
            lines.map { line in
                if line.hasPrefix(indentUnit) { return String(line.dropFirst(indentUnit.count)) }
                var dropped = 0
                var idx = line.startIndex
                while dropped < outdentSpaceWidth, idx < line.endIndex, line[idx] == " " {
                    idx = line.index(after: idx); dropped += 1
                }
                return String(line[idx...])
            }
        }
    }

    /// 仅提取出现多次的重复行，一次提取一行，按首次出现的顺序提取（重复删除的补充）。
    private static func duplicateLinesOnly(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        var counts: [String: Int] = [:]
        for line in lines { counts[line, default: 0] += 1 }
        var seen = Set<String>()
        var duplicates: [String] = []
        for line in lines {
            if (counts[line] ?? 0) >= 2 && seen.insert(line).inserted {
                duplicates.append(line)
            }
        }
        return joinLines(duplicates, trailingNewline: trailing && !duplicates.isEmpty)
    }

    /// 删除所有空白行（包括仅包含空格字符的行）。
    private static func removeEmptyLines(_ s: String) -> String {
        let (lines, trailing) = splitLines(s)
        let nonEmpties = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return joinLines(nonEmpties, trailingNewline: trailing && !nonEmpties.isEmpty)
    }

    /// 将制表符替换为半角空格（默认 `outdentSpaceWidth` = 4）。
    private static func tabsToSpaces(_ s: String) -> String {
        let spaces = String(repeating: " ", count: outdentSpaceWidth)
        return s.replacingOccurrences(of: "\t", with: spaces)
    }

    /// 将每行开头的连续空格（以 `outdentSpaceWidth` 为单位）转换为制表符。
    private static func spacesToTabs(_ s: String) -> String {
        let unitSpaces = String(repeating: " ", count: outdentSpaceWidth)
        return mapLines(s) { lines in
            lines.map { line in
                var res = ""
                var idx = line.startIndex
                while idx < line.endIndex {
                    if line[idx...].hasPrefix(unitSpaces) {
                        res.append("\t")
                        idx = line.index(idx, offsetBy: outdentSpaceWidth)
                    } else if line[idx] == "\t" {
                        res.append("\t")
                        idx = line.index(after: idx)
                    } else {
                        res.append(contentsOf: line[idx...])
                        break
                    }
                }
                return res
            }
        }
    }

    // MARK: - 日時・時刻変換

    /// UNIX 将时间戳（秒或毫秒的整数）转换为本地日期和时间字符串（yyyy-MM-dd HH:mm:ss）。
    private static func unixTimestampToDate(_ s: String) -> String? {
        let (lines, trailing) = splitLines(s)
        guard !lines.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var convertedCount = 0
        let result = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let val = Double(trimmed), val > 0 else { return line }
            let date: Date
            if val > 1_000_000_000_000 {
                // 13 位数字 毫秒
                date = Date(timeIntervalSince1970: val / 1000.0)
            } else if val > 100_000_000 {
                // 9〜11 桁秒
                date = Date(timeIntervalSince1970: val)
            } else {
                return line
            }
            convertedCount += 1
            return formatter.string(from: date)
        }
        guard convertedCount > 0 else { return nil }
        return joinLines(result, trailingNewline: trailing)
    }

    /// 将日期和时间字符串（ISO8601、yyyy-MM-dd、HH:mm:ss、syslog、Apache 等）转换为以秒为单位的 UNIX 时间戳。
    private static func dateToUnixTimestamp(_ s: String) -> String? {
        let (lines, trailing) = splitLines(s)
        guard !lines.isEmpty else { return nil }

        guard let detector = TimestampDetector.detect(sampleLines: lines) else { return nil }

        var convertedCount = 0
        let result = lines.map { line -> String in
            if let date = detector.parse(line) {
                convertedCount += 1
                return String(Int64(date.timeIntervalSince1970))
            }
            return line
        }
        guard convertedCount > 0 else { return nil }
        return joinLines(result, trailingNewline: trailing)
    }
}

/// 分割行（与连接 `TextTransform` 的操作相反）。接受一个名为分隔符的参数。
/// 此函数不包含在 `TextTransform` 中，需要提供参数；设置通过对话框接收，然后调用此函数。
enum LineSplitter {
    /// 拆分设置（对话框中的每个项目都一一对应）。
    struct Options: Equatable {
        /// 分隔符（用于对 `\t`、`\n`、`\\` 进行转义后）。
        var delimiter: String
        /// 删除每个分割元素的前导和尾随空格。
        var trimEach: Bool
        /// 丢弃空元素（`a,,b` → 2 行）。
        var dropEmpty: Bool

        init(delimiter: String, trimEach: Bool = false, dropEmpty: Bool = false) {
            self.delimiter = delimiter
            self.trimEach = trimEach
            self.dropEmpty = dropEmpty
        }
    }

    /// 将选定文本的每一行按分隔符拆分，并以换行符分隔返回它们。
    /// 如果分隔符为空（转义后的结果也为空），则 nil = 不可转换。
    static func split(_ s: String, options: Options) -> String? {
        let delimiter = unescape(options.delimiter)
        guard !delimiter.isEmpty else { return nil }

        let hasTrailingNewline = s.hasSuffix("\n")
        var lines = s.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        var out: [String] = []
        for line in lines {
            var parts = line.components(separatedBy: delimiter)
            if options.trimEach { parts = parts.map { $0.trimmingCharacters(in: .whitespaces) } }
            if options.dropEmpty { parts = parts.filter { !$0.isEmpty } }
            out.append(contentsOf: parts)
        }
        return out.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
    }

    /// 无法在输入字段中输入的字符通过转义符（`TextEscape` 本身）接收。
    static func unescape(_ s: String) -> String { TextEscape.unescape(s) }
}

/// 使用转义表示法接收对话框输入字段中的“不可输入字符”的通用逻辑。
/// 将行分隔符和顺序编号分隔符放在同一个位置，以便可以用相同的方式书写（`\t` / `\n`）。
enum TextEscape {
    /// 转义字符。在日文键盘上，同一个键用于输入 `¥`（半角/全角）。
    /// 处理方式与反斜杠相同（即使您输入 `¥t`，它也会被识别为制表符）。
    private static let leaders: Set<Character> = ["\\", "¥", "￥"]

    /// `\t` = 制表符，`\n` = 换行符，`\\` = 字符本身。
    /// 保留两个未知的转义字符（不要吃掉它们）。
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.startIndex
        while it < s.endIndex {
            let ch = s[it]
            let next = s.index(after: it)
            guard leaders.contains(ch), next < s.endIndex else { out.append(ch); it = next; continue }
            switch s[next] {
            case "t":  out.append("\t"); it = s.index(after: next)
            case "n":  out.append("\n"); it = s.index(after: next)
            case let c where leaders.contains(c): out.append(c); it = s.index(after: next)
            default:   out.append(ch);   it = next
            }
        }
        return out
    }
}

/// 为选定的行分配顺序编号。接受起始编号、增量编号、填充编号和分隔符作为参数。
/// (`TextTransform.numberLines` 不带参数表示“从 1 开始，递增 1，无数字填充，制表符分隔”= 默认值)。
enum LineNumberer {
    /// 顺序编号设置（对话框中的每个项目一一对应）。
    struct Options: Equatable {
        /// 要分配给第一行的编号。
        var start: Int
        /// 每行递增一个值（负值表示减少；0 表示所有行的编号相同）。
        var step: Int
        /// 要用零填充的数字位数（0 = 不填充）。对于负数，在符号后填充（`-007`）。
        var padWidth: Int
        /// 要放在数字和文本之间的字符串（在对 `\t` `\n` 进行转义后使用）。
        var separator: String

        init(start: Int = 1, step: Int = 1, padWidth: Int = 0, separator: String = "\t") {
            self.start = start
            self.step = step
            self.padWidth = padWidth
            self.separator = separator
        }
    }

    /// 在选定文本的每一行开头添加顺序编号。保留行尾换行符。
    static func number(_ s: String, options: Options) -> String {
        let separator = TextEscape.unescape(options.separator)
        let hasTrailingNewline = s.hasSuffix("\n")
        var lines = s.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        var n = options.start
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            out.append(pad(n, width: options.padWidth) + separator + line)
            // 使用饱和加法防止溢出和崩溃（即使输入极端增量也不会崩溃）。
            n = n.addingReportingOverflow(options.step).partialValue
        }
        return out.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
    }

    /// 将数字用零填充到 `width` 位（负数用 `-` 填充）。
    private static func pad(_ n: Int, width: Int) -> String {
        let digits = String(n.magnitude)
        let sign = n < 0 ? "-" : ""
        guard width > digits.count else { return sign + digits }
        return sign + String(repeating: "0", count: width - digits.count) + digits
    }
}
