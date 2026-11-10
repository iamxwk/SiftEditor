import Foundation
import SiftDigitScanner

/// 搜索表达式。**它是字面值 AND 还是正则表达式？**
///
/// `SearchEngine`（搜索单个文件）和后续跨文件夹搜索
/// **通过传递相同类型**，“在搜索栏中输入的表达式”和“在交叉搜索中输入的表达式”的含义
/// 我正在确保它不会移动。
public enum SearchMode {
    /// 文字 AND（包含所有单词的行）。每个单词之间用空格分隔。
    case terms([String])
    /// 正则表达式（逐行匹配）。
    case regex(NSRegularExpression)

    /// 将搜索字段中的字符串拆分成单词，以空格分隔。
    /// **仅输入空格将被视为一个单词而不分隔**（以便系统可以自行找到半角空格）。
    /// 空字符串保留为零个单词（不进行任何搜索）。
    public static func splitTerms(_ query: String) -> [String] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if terms.isEmpty && !query.isEmpty { return [query] }
        return terms
    }
}

/// 1 用于判断此行是否与搜索表达式匹配。**此处只有一个匹配规则。**
///
/// 最初直接写入 `SearchEngine` 的扫描循环中。后续跨文件夹搜索
/// 我提取这个是因为我再次需要相同的规则——**最糟糕的情况是相同的公式会得出不同的结果**
/// 此外，用户绝对不可能知道（没有办法验证哪个是正确的）。
///
/// ## 请勿增加每行分配的金额
///
/// 由于我们正在处理  / 8642 万行数据，因此准备工作（将单词转换为字节序列并执行大/小卷积）只需使用 `init` 完成一次。
/// 扫描期间，仅查看现有字节序列。
///
/// ## Shift-JIS / EUC 仍在兼职人员招聘中（2026-09-05）
///
/// 最初，只有非 UTF-8 字符“从行中解码，然后作为字符串进行匹配”。
/// 这个决定是正确的，因为/第二个字节被错误解读了。然而，**代价太大了**。
///
/// 对  / 1.06GB 的 Shift-JIS 和 CSV（581 万行）进行完整扫描耗时 26.0 秒。
/// 内容与 UTF-8 版本 (1.26GB) 相同，耗时 1.2 秒
/// 只需舔一下  / mmap，数一数 0.13 秒内的换行符数量。
///
/// 26 秒几乎全部时间都花在了调用 `String(data:encoding:)` 581 万次上，即使使用 release 版本也是如此。
/// 它不会缩小（因为成本在 Foundation 那边，而不是我的代码）。
///
/// 因此，**将单词转换为目标编码并以字节形式搜索**。误报
/// 检查冲击点是否位于字母之间的断点上，然后轻弹 (`isCharBoundary`)。
/// 断点检查仅在接触点运行，扫描位置单调递增，因此总结果为 O (n)。
///
/// **如果不包含在字节路径中**（返回 `decode`）：
/// - 该单词无法转换为目标编码。
/// - 不区分大小写，该单词包含**非 ASCII 区分大小写的字符**（例如，全角 A）。
/// `.caseInsensitive` 将全角 A 和 а 视为相同，但这无法通过字节比较来确定。
public struct LineMatcher {

    private let regex: NSRegularExpression?
    private let useDigitByteSearch: Bool
    /// 对  / UTF-8 进行字节查找（不区分大小写，已转换为小写）。
    private let termBytes: [[UInt8]]
    /// 用于匹配非 UTF-8 字符串。
    private let termStrings: [String]
    private let useByteSearch: Bool
    private let fold: Bool
    private let stringOptions: NSString.CompareOptions
    private let encoding: DetectedEncoding

    /// `caseSensitive` 仅在 terms 模式下有效（正则表达式在 compile 模式下确定）。
    public init(mode: SearchMode, caseSensitive: Bool, encoding: DetectedEncoding) {
        self.encoding = encoding
        self.fold = !caseSensitive
        self.stringOptions = caseSensitive ? [] : .caseInsensitive
        switch mode {
        case .terms(let terms):
            regex = nil
            useDigitByteSearch = false
            termStrings = terms
            let folded = terms.map { caseSensitive ? $0 : $0.lowercased() }
            if encoding == .utf8 {
                termBytes = folded.map { Array($0.utf8) }
                useByteSearch = true
            } else if caseSensitive || !terms.contains(where: Self.hasNonASCIICase),
                      let encoded = Self.encode(folded, to: encoding) {
                termBytes = encoded
                useByteSearch = true
            } else {
                termBytes = []          // 解码并匹配为字符串（与之前相同）。
                useByteSearch = false
            }
        case .regex(let rx):
            regex = rx                  // 逐行解码和比较（所有编码通用）
            useDigitByteSearch = encoding == .utf8 && rx.pattern == #"\d"#
            termBytes = []
            termStrings = []
            useByteSearch = false
        }
    }

    /// 未执行搜索（搜索词为空）。呼叫者完全跳过扫描。
    /// **`termBytes` 未确定** -- 当未进入字节路径时，它将变为空。
    /// 结果为“搜索词存在，但扫描被省略”。
    public var isEmpty: Bool { regex == nil && termStrings.isEmpty }

    /// 它是否与字节序列中的一行匹配？**这是主路径**（通过 10GB 的路径）。
    public func matches(_ p: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        if useDigitByteSearch { return sift_contains_decimal_digit(p, length) != 0 }
        if let regex {
            let s = decode(p, length)
            return regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        if useByteSearch {
            if encoding == .utf8 {
                return termBytes.allSatisfy { Self.containsBytes(p, length, $0, fold: fold) }
            }
            return termBytes.allSatisfy {
                Self.containsAligned(p, length, $0, fold: fold, encoding: encoding)
            }
        }
        let s = decode(p, length)
        return termStrings.allSatisfy { s.range(of: $0, options: stringOptions) != nil }
    }

    public func matches(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = line.baseAddress, !line.isEmpty else { return matchesEmptyLine() }
        return matches(base, line.count)
    }

    /// 它是否与单行文本匹配（包含主文本的小文件的路径）？
    public func matches(_ line: String) -> Bool {
        if let regex {
            return regex.firstMatch(in: line,
                                    range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
        return termStrings.allSatisfy { line.range(of: $0, options: stringOptions) != nil }
    }

    private func matchesEmptyLine() -> Bool {
        if let regex {
            return regex.firstMatch(in: "", range: NSRange(location: 0, length: 0)) != nil
        }
        return termStrings.allSatisfy(\.isEmpty)
    }

    private func decode(_ p: UnsafePointer<UInt8>, _ length: Int) -> String {
        let data = Data(bytes: p, count: length)
        return String(data: data, encoding: encoding.stringEncoding)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// 该单词是否在字节序列中出现过一次？`fold=true` 和 ASCII，不区分大小写（假设该单词已经是小写）。
    /// **UTF-8 独占**（下一个字节是 0x80..0xBF，因此单词的开头不会落在字符的中间）。
    static func containsBytes(_ p: UnsafePointer<UInt8>, _ len: Int, _ q: [UInt8], fold: Bool) -> Bool {
        let m = q.count
        guard m > 0, len >= m else { return false }
        var i = 0
        let limit = len - m
        while i <= limit {
            var k = 0
            while k < m {
                var a = p[i + k]
                if fold, a >= 65, a <= 90 { a += 32 }   // ASCII 大文字→小文字
                if a != q[k] { break }
                k += 1
            }
            if k == m { return true }
            i += 1
        }
        return false
    }

    /// 搜索非 UTF-8 (Shift-JIS / EUC-JP) 字节字符。**仅从字符分隔符处开始。**
    ///
    /// 对兼职工作进行简单比较，可以发现两种类型的事故。这两种事故都实际发生过：
    ///
    /// 1. **提取第二个字节。** Shift-JIS 中的“a”是 `83 41`，因此单词 `"A"` (`41`) 是
    /// 它击中了字符的中间。→ 通过将起始点限制在字符的末尾，它会消失。
    /// 2. **第二个字节转换为小写。** `41` 在 'A' 的范围内，因此执行不区分大小写的卷积。
    /// 我将  / `83 41` 更改为 `83 61`，现在**找不到“A”了**（在 2026 年 9 月 5 日的随机测试中）
    /// 已找到）。→ 仅当它是 1 字节字符时才进行折叠。
    ///
    /// 该单词也已转换为与目标相同的编码，因此如果起始点匹配，则字符顺序也会匹配。
    static func containsAligned(_ p: UnsafePointer<UInt8>, _ len: Int, _ q: [UInt8],
                                fold: Bool, encoding: DetectedEncoding) -> Bool {
        let m = q.count
        guard m > 0, len >= m else { return false }
        var i = 0
        let limit = len - m
        while i <= limit {
            if matchesAt(p, len, i, q, fold: fold, encoding: encoding) { return true }
            i += charLength(p[i], encoding)      // 仅使用字符之间的分隔符作为下一个字符的起始点。
        }
        return false
    }

    /// 该单词是否直接从  / `i`（字符分隔符）继续？如果是单字节字符，则对 ASCII 进行卷积。
    private static func matchesAt(_ p: UnsafePointer<UInt8>, _ len: Int, _ i: Int,
                                  _ q: [UInt8], fold: Bool, encoding: DetectedEncoding) -> Bool {
        var li = i, qi = 0
        let m = q.count
        while qi < m {
            guard li < len else { return false }
            let clen = charLength(p[li], encoding)
            if clen == 1 {
                var a = p[li]
                if fold, a >= 65, a <= 90 { a += 32 }
                if a != q[qi] { return false }
                li += 1; qi += 1
            } else {
                guard qi + clen <= m, li + clen <= len else { return false }
                for k in 0..<clen where p[li + k] != q[qi + k] { return false }
                li += clen; qi += clen
            }
        }
        return true
    }

    /// 单个字符中的字节数，从第一个字节开始（无效字节计为 1，如果计算未继续，则继续执行）
    /// 扫描停止）。
    static func charLength(_ b: UInt8, _ encoding: DetectedEncoding) -> Int {
        switch encoding {
        case .shiftJIS:
            // 是一个双字节字符，其第一个字节为 0x81..0x9F 和 0xE0..0xFC。
            // 0xA0..0xDF 是一个半角片假名字符（1 字节）。
            return ((b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC)) ? 2 : 1
        case .eucJP:
            if b == 0x8F { return 3 }                       // 補助漢字
            if b == 0x8E || (b >= 0xA1 && b <= 0xFE) { return 2 }
            return 1
        case .utf8, .utf16LE, .utf16BE:
            return 1
        }
    }

    /// 将单词转换为目标编码的字节序列。如果有一个字节序列无法转换，则返回 nil。
    /// （在这种情况下，像以前一样解码并将其作为字符串进行匹配）。
    static func encode(_ terms: [String], to encoding: DetectedEncoding) -> [[UInt8]]? {
        var out: [[UInt8]] = []
        out.reserveCapacity(terms.count)
        for t in terms {
            if t.isEmpty { out.append([]); continue }
            guard let d = t.data(using: encoding.stringEncoding) else { return nil }
            out.append([UInt8](d))
        }
        return out
    }

    /// 它是否包含非 ASCII 且区分大小写的字符（例如，全角 A）？
    /// 如果包含此 ID，则字节比较将不会产生与 `.caseInsensitive` 相同的结果，
    /// 忽略大小时，不要将其包含在字节路径中。
    static func hasNonASCIICase(_ term: String) -> Bool {
        term.unicodeScalars.contains { scalar in
            guard !scalar.isASCII else { return false }
            let s = String(scalar)
            return s.lowercased() != s || s.uppercased() != s
        }
    }
}
