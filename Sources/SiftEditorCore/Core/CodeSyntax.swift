import Foundation

/// 对于除  / Markdown 之外的代码语言（纯逻辑，与 AppKit 无关），语法高亮显示非常轻微。
///
/// 它没有完整的特定语言语法。仅支持注释、字符串、数字和保留字。
/// 一次线性扫描即可获取（即使字符串中存在注释符号，也可能不正确）
/// 它不被视为注释，这一点很容易通过简单的正则表达式组合来打破。
/// 此部分从头开始读取，保持其状态。
enum CodeSyntax {
    /// `definition` 是“声明名称”（紧随 `def`/`class`/`func` 等之后的标识符）。在 YAML 中，
    /// `key:` (key)。此角色并非附加到保留字本身，而仅附加到紧随保留字之后的名称。
    enum Role { case comment, string, number, keyword, definition }
    struct Span { let range: NSRange; let role: Role }

    struct LanguageSpec {
        /// 行注释起始符号（`#`、`//`、`--` 等）。虽然假设没有任何语言允许多个 ID，但它仍然以数组形式存储。
        let lineComments: [String]
        /// 块注释 (`/* ... */`)。如果没有可用语言，请使用 nil。
        let blockComment: (open: String, close: String)?
        /// 不跨越换行符的普通字符串的引号。
        let stringQuotes: [Character]
        /// 可跨行的三重引号（例如 Python 的 `"""` 和 `'''`）；不支持的语言使用空数组。
        let tripleQuotes: [String]
        /// 保留字。语言 `caseInsensitiveKeywords` 和 true 必须全部以大写字母传递。
        let keywords: Set<String>
        let caseInsensitiveKeywords: Bool
        /// 这是一个保留字，它将紧随其后的标识符标记为“声明名称”（例如，`def`、`class`、`func`）。
        /// 以下仅以空格分隔的标识符是目标标识符（例如，`func (r *T) Name()` 和接收标识符）
        /// 该声明被排除，因为它在名称之前包含一个非空白字符 (`(`) = 它具有安全性。
        let declarationKeywords: Set<String>

        init(lineComments: [String] = [], blockComment: (open: String, close: String)? = nil,
             stringQuotes: [Character] = ["\"", "'"], tripleQuotes: [String] = [],
             keywords: Set<String> = [], caseInsensitiveKeywords: Bool = false,
             declarationKeywords: Set<String> = []) {
            self.lineComments = lineComments
            self.blockComment = blockComment
            self.stringQuotes = stringQuotes
            self.tripleQuotes = tripleQuotes
            self.keywords = keywords
            self.caseInsensitiveKeywords = caseInsensitiveKeywords
            self.declarationKeywords = declarationKeywords
        }
    }

    enum Language: CaseIterable {
        case python, swift, javascript, shell, yaml, json, sql, css
        case java, php, go, ruby, perl

        /// 语言由文件扩展名（小写）决定。不支持的扩展名包括 nil。
        static func detect(extension ext: String) -> Language? {
            switch ext {
            case "py": return .python
            case "swift": return .swift
            case "js", "mjs", "cjs", "jsx", "ts", "tsx": return .javascript
            case "sh", "bash", "zsh": return .shell
            case "yml", "yaml": return .yaml
            case "json": return .json
            case "sql": return .sql
            case "css", "scss": return .css
            case "java": return .java
            case "php": return .php
            case "go": return .go
            case "rb": return .ruby
            case "pl", "pm": return .perl
            default: return nil
            }
        }

        var spec: LanguageSpec {
            switch self {
            case .python:
                return LanguageSpec(
                    lineComments: ["#"], stringQuotes: ["\"", "'"], tripleQuotes: ["\"\"\"", "'''"],
                    keywords: ["False", "None", "True", "and", "as", "assert", "async", "await",
                               "break", "class", "continue", "def", "del", "elif", "else", "except",
                               "finally", "for", "from", "global", "if", "import", "in", "is",
                               "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
                               "while", "with", "yield"],
                    declarationKeywords: ["def", "class"])
            case .swift:
                return LanguageSpec(
                    lineComments: ["//"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
                               "func", "import", "init", "inout", "internal", "let", "open", "operator",
                               "private", "protocol", "public", "rethrows", "static", "struct",
                               "subscript", "typealias", "var", "break", "case", "continue", "default",
                               "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
                               "repeat", "return", "switch", "where", "while", "as", "Any", "catch",
                               "false", "is", "nil", "self", "Self", "super", "throw", "throws",
                               "true", "try", "guard"],
                    declarationKeywords: ["func", "class", "struct", "enum", "protocol"])
            case .javascript:
                return LanguageSpec(
                    lineComments: ["//"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["break", "case", "catch", "class", "const", "continue", "debugger",
                               "default", "delete", "do", "else", "export", "extends", "finally",
                               "for", "function", "if", "import", "in", "instanceof", "new", "return",
                               "super", "switch", "this", "throw", "try", "typeof", "var", "void",
                               "while", "with", "yield", "let", "async", "await", "static", "get",
                               "set", "of", "interface", "type", "enum", "implements", "namespace",
                               "declare", "readonly", "as", "from", "true", "false", "null",
                               "undefined"],
                    declarationKeywords: ["function", "class"])
            case .shell:
                return LanguageSpec(
                    lineComments: ["#"],
                    keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do",
                               "done", "case", "esac", "function", "in", "return", "exit", "export",
                               "local", "readonly", "set", "unset", "shift", "break", "continue",
                               "eval", "exec", "source", "alias"],
                    declarationKeywords: ["function"])
            case .yaml:
                return LanguageSpec(
                    lineComments: ["#"],
                    keywords: ["TRUE", "FALSE", "NULL", "YES", "NO", "ON", "OFF"],
                    caseInsensitiveKeywords: true)
            case .json:
                return LanguageSpec(stringQuotes: ["\""], keywords: ["true", "false", "null"])
            case .sql:
                return LanguageSpec(
                    lineComments: ["--"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                               "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW", "JOIN",
                               "INNER", "LEFT", "RIGHT", "OUTER", "ON", "GROUP", "BY", "ORDER",
                               "HAVING", "LIMIT", "OFFSET", "AS", "AND", "OR", "NOT", "NULL", "IS",
                               "IN", "EXISTS", "BETWEEN", "LIKE", "DISTINCT", "UNION", "ALL", "CASE",
                               "WHEN", "THEN", "ELSE", "END", "PRIMARY", "KEY", "FOREIGN",
                               "REFERENCES", "DEFAULT", "UNIQUE", "CONSTRAINT"],
                    caseInsensitiveKeywords: true)
            case .css:
                return LanguageSpec(blockComment: (open: "/*", close: "*/"))
            case .java:
                return LanguageSpec(
                    lineComments: ["//"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch",
                               "char", "class", "const", "continue", "default", "do", "double",
                               "else", "enum", "extends", "final", "finally", "float", "for", "goto",
                               "if", "implements", "import", "instanceof", "int", "interface", "long",
                               "native", "new", "package", "private", "protected", "public", "return",
                               "short", "static", "strictfp", "super", "switch", "synchronized",
                               "this", "throw", "throws", "transient", "try", "void", "volatile",
                               "while", "true", "false", "null"],
                    declarationKeywords: ["class", "interface"])
            case .php:
                return LanguageSpec(
                    lineComments: ["//", "#"], blockComment: (open: "/*", close: "*/"),
                    keywords: ["abstract", "and", "array", "as", "break", "callable", "case", "catch",
                               "class", "clone", "const", "continue", "declare", "default", "do",
                               "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach",
                               "endif", "endswitch", "endwhile", "extends", "final", "finally", "fn",
                               "for", "foreach", "function", "global", "goto", "if", "implements",
                               "include", "include_once", "instanceof", "insteadof", "interface",
                               "isset", "list", "match", "namespace", "new", "or", "print", "private",
                               "protected", "public", "require", "require_once", "return", "static",
                               "switch", "throw", "trait", "try", "unset", "use", "var", "while",
                               "xor", "yield", "true", "false", "null"],
                    declarationKeywords: ["function", "class"])
            case .go:
                return LanguageSpec(
                    lineComments: ["//"], blockComment: (open: "/*", close: "*/"),
                    stringQuotes: ["\"", "'"],
                    keywords: ["break", "case", "chan", "const", "continue", "default", "defer",
                               "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
                               "interface", "map", "package", "range", "return", "select", "struct",
                               "switch", "type", "var", "true", "false", "nil", "iota"],
                    declarationKeywords: ["func"])
            case .ruby:
                return LanguageSpec(
                    lineComments: ["#"],
                    keywords: ["BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
                               "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
                               "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
                               "rescue", "retry", "return", "self", "super", "then", "true", "undef",
                               "unless", "until", "when", "while", "yield"],
                    declarationKeywords: ["def", "class", "module"])
            case .perl:
                return LanguageSpec(
                    lineComments: ["#"],
                    keywords: ["my", "our", "local", "sub", "package", "use", "no", "require", "if",
                               "elsif", "else", "unless", "while", "until", "for", "foreach", "do",
                               "return", "last", "next", "redo", "qw", "print", "say", "defined",
                               "undef", "ref", "bless", "die", "warn"],
                    declarationKeywords: ["sub"])
            }
        }
    }

    /// `text` 从头开始读取整个代码一次，并返回注释、字符串、数字、保留字和声明名称的范围。
    static func spans(text: NSString, language: Language) -> [Span] {
        if language == .yaml { return yamlSpans(text: text) }   // YAML 是一种数据格式，因此应该单独路由。

        let spec = language.spec
        let length = text.length
        guard length > 0 else { return [] }
        var buffer = [unichar](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))

        let lineCommentStarts = spec.lineComments.map { Array($0.utf16) }
        let blockOpen = spec.blockComment.map { Array($0.open.utf16) }
        let blockClose = spec.blockComment.map { Array($0.close.utf16) }
        let tripleQuotes = spec.tripleQuotes.map { Array($0.utf16) }
        let quoteChars = Set(spec.stringQuotes.compactMap { $0.utf16.first })

        func matches(_ pattern: [UInt16], at i: Int) -> Bool {
            guard !pattern.isEmpty, i + pattern.count <= length else { return false }
            for k in 0..<pattern.count where buffer[i + k] != pattern[k] { return false }
            return true
        }
        func isIdentifierStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95   // A-Z a-z _
        }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isIdentifierPart(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) }
        func isInlineWhitespace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 13 }   // space/tab/CR

        var spans: [Span] = []
        var i = 0
        // 在  `def`/`class`/`func` 等之后，下一个标识符（仅用空格分隔）用作声明名称。
        // 如果包含任何非空白字符（例如 `(`），则该方法将放弃（例如，带有接收器的 Go 方法）。
        var expectDefinition = false
        while i < length {
            let c = buffer[i]

            if let open = blockOpen, let close = blockClose, matches(open, at: i) {
                expectDefinition = false
                let start = i
                i += open.count
                while i < length, !matches(close, at: i) { i += 1 }
                i = min(length, i + close.count)
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .comment))
                continue
            }
            if let prefix = lineCommentStarts.first(where: { matches($0, at: i) }) {
                expectDefinition = false
                let start = i
                i += prefix.count
                while i < length, buffer[i] != 10 { i += 1 }   // \n
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .comment))
                continue
            }
            if let triple = tripleQuotes.first(where: { matches($0, at: i) }) {
                expectDefinition = false
                let start = i
                i += triple.count
                while i < length, !matches(triple, at: i) {
                    i += (buffer[i] == 92 && i + 1 < length) ? 2 : 1   // \ 转义
                }
                i = min(length, i + triple.count)
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .string))
                continue
            }
            if quoteChars.contains(c) {
                expectDefinition = false
                let quote = c
                let start = i
                i += 1
                while i < length, buffer[i] != quote, buffer[i] != 10 {
                    i += (buffer[i] == 92 && i + 1 < length) ? 2 : 1
                }
                if i < length, buffer[i] == quote { i += 1 }
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .string))
                continue
            }
            if isDigit(c) {
                expectDefinition = false
                let start = i
                while i < length, isIdentifierPart(buffer[i]) || buffer[i] == 46 { i += 1 }   // '.'
                spans.append(Span(range: NSRange(location: start, length: i - start), role: .number))
                continue
            }
            if isIdentifierStart(c) {
                let start = i
                while i < length, isIdentifierPart(buffer[i]) { i += 1 }
                let range = NSRange(location: start, length: i - start)
                if expectDefinition {
                    spans.append(Span(range: range, role: .definition))
                    expectDefinition = false
                    continue
                }
                if !spec.keywords.isEmpty {
                    let word = text.substring(with: range)
                    let key = spec.caseInsensitiveKeywords ? word.uppercased() : word
                    if spec.keywords.contains(key) {
                        spans.append(Span(range: range, role: .keyword))
                    }
                    if spec.declarationKeywords.contains(word) { expectDefinition = true }
                }
                continue
            }
            if expectDefinition, !isInlineWhitespace(c) { expectDefinition = false }
            i += 1
        }
        return spans
    }

    // MARK: - YAML（数据格式。由于“键”是主要元素而非保留字，因此它是一个单独的路径。）

    private static let yamlKeyRegex = try! NSRegularExpression(
        pattern: "^\\s*(?:-\\s+)?([A-Za-z0-9_.\\-]+)\\s*:(?=\\s|$)", options: [.anchorsMatchLines])
    private static let yamlLiteralRegex = try! NSRegularExpression(
        pattern: "\\b(?:true|false|null|yes|no|on|off)\\b", options: [.caseInsensitive])
    private static let yamlStringRegex = try! NSRegularExpression(pattern: "\"[^\"\\n]*\"|'[^'\\n]*'")

    /// 对于每一行：提取注释（引号外的 `#`）/ 键（key 或 `key:`）/ 字符串 / 布尔值 null。
    private static func yamlSpans(text: NSString) -> [Span] {
        var spans: [Span] = []
        let whole = text as String
        for lineRange in MarkdownSyntax.lineRanges(text) where lineRange.length > 0 {
            // 为避免将引号内的“#”误认为是注释的开始，请通过跟踪引号的开始和结束来进行搜索。
            var commentLength = lineRange.length
            var inQuote: unichar?
            var k = 0
            while k < lineRange.length {
                let c = text.character(at: lineRange.location + k)
                if let q = inQuote {
                    if c == q { inQuote = nil }
                } else if c == 34 || c == 39 {   // " '
                    inQuote = c
                } else if c == 35 {              // #
                    let prev = k == 0 ? 32 : text.character(at: lineRange.location + k - 1)
                    if prev == 32 || prev == 9 { commentLength = k; break }
                }
                k += 1
            }
            if commentLength < lineRange.length {
                spans.append(Span(range: NSRange(location: lineRange.location + commentLength,
                                                  length: lineRange.length - commentLength), role: .comment))
            }
            let contentRange = NSRange(location: lineRange.location, length: commentLength)

            if let m = yamlKeyRegex.firstMatch(in: whole, range: contentRange) {
                let keyRange = m.range(at: 1)
                if keyRange.location != NSNotFound {
                    spans.append(Span(range: keyRange, role: .definition))
                }
            }
            var occupied: [NSRange] = []
            for m in yamlStringRegex.matches(in: whole, range: contentRange) {
                spans.append(Span(range: m.range, role: .string))
                occupied.append(m.range)
            }
            for m in yamlLiteralRegex.matches(in: whole, range: contentRange) {
                let r = m.range
                guard !occupied.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
                spans.append(Span(range: r, role: .keyword))
            }
        }
        return spans
    }
}
