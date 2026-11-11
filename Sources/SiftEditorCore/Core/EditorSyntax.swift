import Foundation
import SwiftHighlight

/// Languages offered by the lightweight SwiftHighlight adapter.
enum EditorSyntax: String, CaseIterable {
    case text, markdown, python, swift, javascript, typescript, tsx, shell
    case yaml, json, sql, css, java, php, go, ruby, perl
    case c, cpp, csharp, objectiveC = "objective-c", kotlin, dart, rust
    case html, xml, scss, graphql, lua, toml, ini, protobuf, dockerfile, makefile, diff

    var title: String {
        if self == .text { return L("syntax.textFile") }
        if self == .perl { return "Perl" }
        return Grammar.builtin(rawValue)?.name ?? rawValue
    }

    static func forFile(_ url: URL?) -> EditorSyntax {
        guard let url, !url.pathExtension.isEmpty else { return .text }
        let ext = url.pathExtension.lowercased()
        if let override = AppSettings.syntaxLanguage(forExtension: ext) { return override }
        if ext == "pl" || ext == "pm" { return .perl }
        guard let id = LanguageRegistry.shared.language(forPath: url.lastPathComponent)?.id else { return .text }
        return EditorSyntax(rawValue: id) ?? .text
    }
}
