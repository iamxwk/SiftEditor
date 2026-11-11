import Foundation
import SwiftHighlight

/// Thin adapter from SwiftHighlight's UTF-8 tokens to NSTextView's UTF-16 ranges.
enum SwiftSyntaxEngine {
    struct Span {
        let range: NSRange
        let scope: Scope
    }

    static func language(for syntax: EditorSyntax) -> Language {
        if syntax == .perl { return perlLanguage }
        return Language.named(syntax.rawValue)
    }

    static func spans(text: String, syntax: EditorSyntax) -> [Span] {
        let tokens = language(for: syntax).tokenize(text)
        let utf8 = text.utf8
        let utf16 = text.utf16
        var index = text.startIndex
        var byteOffset = 0
        var characterOffset = 0
        var result: [Span] = []
        result.reserveCapacity(tokens.count)
        for token in tokens {
            let start = utf8.index(index, offsetBy: token.range.lowerBound - byteOffset)
            characterOffset += utf16.distance(from: index, to: start)
            let end = utf8.index(start, offsetBy: token.range.count)
            let length = utf16.distance(from: start, to: end)
            result.append(Span(range: NSRange(location: characterOffset, length: length), scope: token.scope))
            index = end
            byteOffset = token.range.upperBound
            characterOffset += length
        }
        return result
    }

    /// Tokens are ordered by location. Only hand AppKit the tokens intersecting its viewport.
    static func spans(_ spans: [Span], intersecting range: NSRange) -> ArraySlice<Span> {
        guard range.length > 0, !spans.isEmpty else { return [] }
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(spans[middle].range) <= range.location { low = middle + 1 }
            else { high = middle }
        }
        let first = low
        let end = NSMaxRange(range)
        while low < spans.count && spans[low].range.location < end { low += 1 }
        return spans[first..<low]
    }

    /// SwiftHighlight has no built-in Perl grammar. Keep the previously supported
    /// language in the same lightweight engine with a deliberately small grammar.
    private static let perlLanguage: Language = {
        let grammar = Grammar(name: "Perl", id: "perl", aliases: ["pl", "pm"], fileExtensions: ["pl", "pm"], states: [
            "root": [
                .match(#"#.*"#, .commentLine),
                .match(#"[$@%][A-Za-z_]\w*"#, .variable),
                .match(#"\b\d+(?:\.\d+)?\b"#, .number),
                .words(["use", "my", "our", "sub", "if", "else", "elsif", "while", "foreach", "return", "package"], .keyword),
                .push("\"", "double", scope: .string),
                .push("'", "single", scope: .string),
            ],
            "double": GrammarState(scope: .string, popAtLineEnd: true, rules: [.match(#"\\."#, .escape), .pop("\"")]),
            "single": GrammarState(scope: .string, popAtLineEnd: true, rules: [.match(#"\\."#, .escape), .pop("'")]),
        ])
        return (try? Language(grammar)) ?? .plainText
    }()
}
