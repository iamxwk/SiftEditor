import Foundation

/// Markdown 根据句法作用将正文分成若干部分（纯逻辑，AppKit 独立）。
///
/// 在这里，我们只决定“每个区域扮演什么角色”。颜色和字体（bold/italic 字体，
/// 指定和实际应用强调色 () 是绘图端 (`EditableViewer`) 的工作。
/// 由于  / `NSLayoutManager` 被着色为 temporary attribute，因此每次都对整个文本进行此判断。
/// 即使经过审查，它仍然很便宜（它完全不影响 undo/dirty/ 的保存，因为它不会重写 textStorage）。
enum MarkdownSyntax {
    enum Role: Equatable {
        case heading
        case bold
        case italic
        case strikethrough
        case inlineCode
        case codeBlock
        case blockquote
        case horizontalRule
        case listMarker
        case link
        case tablePipe
    }

    struct Span: Equatable {
        let range: NSRange
        let role: Role
    }

    // MARK: - 围栏（用 ```/~~~ 包围的代码块）

    /// 每一行是否“在开放的围栏内”（包括分隔符行本身，从第 0 行开始）。
    /// 如果它一直延续到文档末尾而没有闭合，则会被视为内部文本的一部分，直到末尾（与 CommonMark 相同）。
    static func fencedLineNumbers(_ lines: [String]) -> Set<Int> {
        var result = Set<Int>()
        var openMarker: Character?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = openMarker {
                result.insert(i)
                if trimmed.hasPrefix(String(repeating: marker, count: 3)) { openMarker = nil }
                continue
            }
            if trimmed.hasPrefix("```") { openMarker = "`"; result.insert(i) }
            else if trimmed.hasPrefix("~~~") { openMarker = "~"; result.insert(i) }
        }
        return result
    }

    // MARK: - 线提取

    /// 将  / `text` 按实际换行位置逐行划分（不包括末尾的换行符）。
    /// 即使结尾是换行符，也不会在其后添加空行（如果行数为 0，则会生成一个空数组）。
    static func lineRanges(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        let len = text.length
        var idx = 0
        while idx < len {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: idx, length: 0))
            ranges.append(NSRange(location: start, length: contentsEnd - start))
            idx = end
        }
        return ranges
    }

    // MARK: - 行首的块元素

    private static let headingRegex = try! NSRegularExpression(
        pattern: "^ {0,3}#{1,6}(?:\\s|$)", options: [.anchorsMatchLines])
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: "^ {0,3}>", options: [.anchorsMatchLines])
    private static let horizontalRuleRegex = try! NSRegularExpression(
        pattern: "^ {0,3}(?:(?:-\\s*){3,}|(?:\\*\\s*){3,}|(?:_\\s*){3,})$", options: [.anchorsMatchLines])
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: "^ {0,3}([-*+]|\\d{1,9}[.)])(?:\\s|$)", options: [.anchorsMatchLines])

    // MARK: - 行内元素

    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let linkRegex = try! NSRegularExpression(pattern: "!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)")
    private static let boldRegex = try! NSRegularExpression(
        pattern: "\\*\\*[^*\\n]+?\\*\\*|__[^_\\n]+?__")
    private static let italicRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*(?!\\*)[^*\\n]+?\\*(?!\\*)|(?<![_\\w])_(?!_)[^_\\n]+?_(?![_\\w])")
    private static let strikethroughRegex = try! NSRegularExpression(pattern: "~~[^~\\n]+?~~")

    /// 将整个  / `text`（每行以 `lineRanges` 分隔）根据其各自的角色转换为范围。
    /// `fenced` 是代码围栏内的行号（`fencedLineNumbers` 的结果）。
    static func spans(text: NSString, lineRanges: [NSRange], fenced: Set<Int>) -> [Span] {
        let whole = text as String
        var spans: [Span] = []
        for (i, lineRange) in lineRanges.enumerated() where lineRange.length > 0 {
            if fenced.contains(i) {
                spans.append(Span(range: lineRange, role: .codeBlock))
                continue
            }
            if headingRegex.firstMatch(in: whole, range: lineRange) != nil {
                spans.append(Span(range: lineRange, role: .heading))
                continue
            }
            if horizontalRuleRegex.firstMatch(in: whole, range: lineRange) != nil {
                spans.append(Span(range: lineRange, role: .horizontalRule))
                continue
            }
            if blockquoteRegex.firstMatch(in: whole, range: lineRange) != nil {
                spans.append(Span(range: lineRange, role: .blockquote))
            }
            if let m = listMarkerRegex.firstMatch(in: whole, range: lineRange) {
                let marker = m.range(at: 1)
                if marker.location != NSNotFound {
                    spans.append(Span(range: marker, role: .listMarker))
                }
            }
            spans.append(contentsOf: pipeSpans(in: text, range: lineRange))
            spans.append(contentsOf: inlineSpans(in: whole, range: lineRange))
        }
        return spans
    }

    /// 每行中的每个 `|` 字符（表格分隔符）。
    private static func pipeSpans(in text: NSString, range: NSRange) -> [Span] {
        var spans: [Span] = []
        var searchFrom = range.location
        let end = range.location + range.length
        while searchFrom < end {
            let r = text.range(of: "|", options: [], range: NSRange(location: searchFrom, length: end - searchFrom))
            guard r.location != NSNotFound else { break }
            spans.append(Span(range: r, role: .tablePipe))
            searchFrom = r.location + 1
        }
        return spans
    }

    /// 行内高亮显示、代码和链接。优先匹配第一个找到的范围，并丢弃任何重叠的后续匹配项。
    /// （例如，不要将内联代码中的 `**` 误认为是粗体文本）。
    private static func inlineSpans(in text: String, range: NSRange) -> [Span] {
        var occupied: [NSRange] = []
        var spans: [Span] = []
        func add(_ regex: NSRegularExpression, role: Role) {
            for m in regex.matches(in: text, range: range) {
                let r = m.range
                guard !occupied.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
                occupied.append(r)
                spans.append(Span(range: r, role: role))
            }
        }
        add(inlineCodeRegex, role: .inlineCode)
        add(linkRegex, role: .link)
        add(boldRegex, role: .bold)
        add(italicRegex, role: .italic)
        add(strikethroughRegex, role: .strikethrough)
        return spans
    }
}
