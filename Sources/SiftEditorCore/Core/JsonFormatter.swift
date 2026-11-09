import Foundation

/// 纯逻辑（UI 无关）缩进单个 JSON 文档（pretty-print）。
///
/// `JSONSerialization` 未保留字典键的顺序，因此**使用分词器扫描原始文本。**
/// 重新缩进**（不改变键的顺序或数字/字符串的表示方式）。格式化之前
/// `JSONSerialization` 仅用于验证其有效性，如果无效，则返回 `nil`（即，调用者返回 no-op/beep）。
///
/// NDJSON（每行 1 个对象）是一个多级值，因此验证失败，变为 `nil`。
/// 这是面向行的 `StructuredMode.ndjson` 的职责，而这个仅限于单个文档的格式设置。
enum JsonFormatter {
    /// 如果是有效的单个 JSON，则为缩进字符串；否则，为 `nil`。
    /// - Parameter indent: 用于缩进一行的字符串（默认值：2 个空格）。
    static func pretty(_ text: String, indent: String = "  ") -> String? {
        // 验证（允许顶级标量）。
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return nil
        }
        return reindent(text, indent: indent)
    }

    /// 使用分词器重新缩进。按原样复制字符串内容，并丢弃结构字符之外的空白字符。
    private static func reindent(_ text: String, indent: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count + chars.count / 4)
        var depth = 0
        var i = 0
        let n = chars.count

        func newline(_ d: Int) {
            out.append("\n")
            for _ in 0..<d { out.append(indent) }
        }
        // 向前查找下一个非空白字符（用于空容器检测）。
        func nextNonSpace(from k: Int) -> Character? {
            var j = k
            while j < n {
                let c = chars[j]
                if c == " " || c == "\t" || c == "\n" || c == "\r" { j += 1; continue }
                return c
            }
            return nil
        }

        while i < n {
            let c = chars[i]
            switch c {
            case " ", "\t", "\n", "\r":
                i += 1   // 丢弃结构体外部的空格。
            case "\"":
                // 字符串被原样复制，包括转义字符。
                out.append(c); i += 1
                while i < n {
                    let s = chars[i]
                    out.append(s)
                    if s == "\\" && i + 1 < n { out.append(chars[i + 1]); i += 2; continue }
                    i += 1
                    if s == "\"" { break }
                }
            case "{", "[":
                if let nxt = nextNonSpace(from: i + 1), nxt == (c == "{" ? "}" : "]") {
                    // 空容器应放在一行。
                    out.append(c); out.append(nxt)
                    // 跳至结束。
                    var j = i + 1
                    while j < n, chars[j] != nxt { j += 1 }
                    i = j + 1
                } else {
                    depth += 1
                    out.append(c)
                    newline(depth)
                    i += 1
                }
            case "}", "]":
                depth = max(0, depth - 1)
                newline(depth)
                out.append(c)
                i += 1
            case ",":
                // ：删除末尾的逗号（后跟右括号）。Foundation 格式可以接受，但并非必要。
                if let nxt = nextNonSpace(from: i + 1), nxt == "}" || nxt == "]" {
                    i += 1
                } else {
                    out.append(c)
                    newline(depth)
                    i += 1
                }
            case ":":
                out.append(": ")
                i += 1
            default:
                out.append(c); i += 1
            }
        }
        return out
    }
}
