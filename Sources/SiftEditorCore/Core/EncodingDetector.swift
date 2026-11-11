import Foundation

/// 已确定的字符代码。
public enum DetectedEncoding: Sendable {
    case utf8
    case utf16LE
    case utf16BE
    case shiftJIS
    case eucJP

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .shiftJIS: return .shiftJIS
        case .eucJP: return .japaneseEUC
        }
    }

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .shiftJIS: return "Shift-JIS"
        case .eucJP: return "EUC-JP"
        }
    }

    /// 编码选择菜单中要显示的候选编码（按日语地区的使用顺序排列）。
    static let selectable: [DetectedEncoding] = [.utf8, .shiftJIS, .eucJP, .utf16LE, .utf16BE]
}

/// 文件换行符。插入或粘贴的换行符将与此对齐（加载期间检测）。
enum LineEnding {
    case lf      // \n（Unix / macOS）
    case crlf    // \r\n（Windows）
    case cr      // \r（旧 Mac）

    var displayName: String {
        switch self {
        case .lf: return L("status.ending.lf")
        case .crlf: return L("status.ending.crlf")
        case .cr: return L("status.ending.cr")
        }
    }

    var bytes: [UInt8] {
        switch self {
        case .lf: return [0x0A]
        case .crlf: return [0x0D, 0x0A]
        case .cr: return [0x0D]
        }
    }

    var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }

    /// 将插入文本中的换行符（\r\n / \r / \n 的混合格式）对齐到 EOL。如果没有换行符，则保持原样。
    func normalize(_ text: String) -> String {
        guard text.contains("\r") || text.contains("\n") else { return text }
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n")
                     .replacingOccurrences(of: "\r", with: "\n")
        return self == .lf ? lf : lf.replacingOccurrences(of: "\n", with: string)
    }

    /// 查找第一个字节序列中的第一个换行符并确定结果（如果没有换行符，则默认值为 LF）。
    static func detect(_ data: Data, encoding: DetectedEncoding) -> LineEnding {
        // UTF-16 由 CR/LF 以 2 字节为单位重复组成，因此它是逐个字符解码和评估的。
        if encoding == .utf16LE || encoding == .utf16BE,
           let s = String(data: data, encoding: encoding.stringEncoding) {
            // 在  Swift 中，“\r\n”被视为单个 Character，因此按字符本身进行分类。
            if let i = s.firstIndex(where: { $0.isNewline }) {
                switch s[i] {
                case "\r\n": return .crlf
                case "\r": return .cr
                default: return .lf
                }
            }
            return .lf
        }
        // ASCII 向后兼容（UTF-8 / Shift-JIS / EUC-JP），并且可以通过字节扫描进行处理。
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 0x0D: return (i + 1 < bytes.count && bytes[i + 1] == 0x0A) ? .crlf : .cr
            case 0x0A: return .lf
            default: i += 1
            }
        }
        return .lf
    }
}

/// 编码转换和保存的核心。字节序列 `source` 在**行边界**处被分割（直至最后一个 0x0A）。
/// 转换为  / `target`。0x0A 不出现在 UTF-8 / Shift-JIS / EUC-JP 的多字节字符中。
/// 如果在那里将其分开，它将成为一个安全的边界，不会分割字符（您可以将原始内容分成任意大小的切片）。
enum EncodingTranscoder {
    /// 原始切片按顺序传递给提供给  / `feed` 的消费函数，转换后的字节传递给 `emit`。
    /// 当目标编码无法表示的字符被替换为替代字符时，返回 (lossy)true。
    @discardableResult
    static func stream(from source: DetectedEncoding, to target: DetectedEncoding,
                       feed: ((ArraySlice<UInt8>) throws -> Void) throws -> Void,
                       emit: @escaping (Data) throws -> Void) throws -> Bool {
        var carry = [UInt8]()
        var lossy = false
        func flush(_ bytes: [UInt8]) throws {
            guard !bytes.isEmpty else { return }
            let s = String(data: Data(bytes), encoding: source.stringEncoding)
                ?? String(decoding: bytes, as: UTF8.self)
            if let d = s.data(using: target.stringEncoding) {
                try emit(d)
            } else {
                lossy = true
                try emit(s.data(using: target.stringEncoding, allowLossyConversion: true) ?? Data(s.utf8))
            }
        }
        try feed { slice in
            carry.append(contentsOf: slice)
            if let nl = carry.lastIndex(of: 0x0A) {
                try flush(Array(carry[...nl]))
                carry.removeSubrange(...nl)
            }
        }
        try flush(carry)                                    // 结束（最后一行没有换行符）
        return lossy
    }
}

/// 根据第一个字节序列估算字符代码。
///
/// 判决顺序：BOM → UTF-8 严格 → Shift-JIS / EUC-JP 评分。
/// 如果无法实现，则回退到 UTF-8（策略是即使转换也不会崩溃）。
/// 根据前几十个字符 KB 估算字符代码。
///
/// **使用 public 是因为需要对“每个文件”执行交叉搜索**（在一个文件夹中）
/// UTF-8 和 Shift-JIS 混杂在一起是正常的。判断规则与“打开”功能相同。
public enum EncodingDetector {
    public static func detect(_ data: Data) -> DetectedEncoding {
        let bytes = [UInt8](data)
        let n = bytes.count

        // 1. BOM
        if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return .utf8 }
        if n >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return .utf16LE }
        if n >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return .utf16BE }

        // 2. UTF-8 是否完全正确？
        if isValidUTF8(bytes) { return .utf8 }

        // 3. Shift-JIS / EUC-JP 评分
        let sjis = scoreShiftJIS(bytes)
        let euc = scoreEUCJP(bytes)
        return sjis >= euc ? .shiftJIS : .eucJP
    }

    /// 严格的 UTF-8 有效性检查。允许末尾存在截断的多字节字符。
    private static func isValidUTF8(_ b: [UInt8]) -> Bool {
        let n = b.count
        var i = 0
        while i < n {
            let c = b[i]
            if c < 0x80 {
                i += 1
            } else if c & 0xE0 == 0xC0 {
                if c < 0xC2 { return false } // 冗長符号化
                if i + 1 >= n { return true }
                if b[i + 1] & 0xC0 != 0x80 { return false }
                i += 2
            } else if c & 0xF0 == 0xE0 {
                if i + 2 >= n { return i + 1 >= n || b[i + 1] & 0xC0 == 0x80 }
                if b[i + 1] & 0xC0 != 0x80 || b[i + 2] & 0xC0 != 0x80 { return false }
                i += 3
            } else if c & 0xF8 == 0xF0 {
                if c > 0xF4 { return false }
                if i + 3 >= n { return true }
                if b[i + 1] & 0xC0 != 0x80 || b[i + 2] & 0xC0 != 0x80 || b[i + 3] & 0xC0 != 0x80 {
                    return false
                }
                i += 4
            } else {
                return false
            }
        }
        return true
    }

    private static func scoreShiftJIS(_ b: [UInt8]) -> Int {
        var score = 0
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 {
                i += 1
            } else if (0xA1...0xDF).contains(c) {
                i += 1 // 半角片假名（单字节）
            } else if (0x81...0x9F).contains(c) || (0xE0...0xFC).contains(c) {
                if i + 1 < n {
                    let d = b[i + 1]
                    if (0x40...0x7E).contains(d) || (0x80...0xFC).contains(d) {
                        score += 1
                        i += 2
                        continue
                    }
                }
                score -= 2
                i += 1
            } else {
                score -= 2
                i += 1
            }
        }
        return score
    }

    private static func scoreEUCJP(_ b: [UInt8]) -> Int {
        var score = 0
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 {
                i += 1
            } else if c == 0x8E { // 半角片假名
                if i + 1 < n, (0xA1...0xDF).contains(b[i + 1]) {
                    score += 1
                    i += 2
                    continue
                }
                score -= 2
                i += 1
            } else if (0xA1...0xFE).contains(c) {
                if i + 1 < n, (0xA1...0xFE).contains(b[i + 1]) {
                    score += 1
                    i += 2
                    continue
                }
                score -= 2
                i += 1
            } else {
                score -= 2
                i += 1
            }
        }
        return score
    }
}
