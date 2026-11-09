import XCTest
@testable import SiftEditorCore

/// Markdown 正文文本划分（标题、强调、代码、链接等）。
/// 着色方法（颜色和字体）由 `EditableViewer` 负责，因此这里我们将询问“范围是多少……”
/// 我们只会验证“它将发挥什么作用”。
final class MarkdownSyntaxTests: XCTestCase {
    private func spans(_ text: String) -> [MarkdownSyntax.Span] {
        let ns = text as NSString
        let lines = MarkdownSyntax.lineRanges(ns)
        let fenced = MarkdownSyntax.fencedLineNumbers(lines.map { ns.substring(with: $0) })
        return MarkdownSyntax.spans(text: ns, lineRanges: lines, fenced: fenced)
    }

    private func role(_ spans: [MarkdownSyntax.Span], _ role: MarkdownSyntax.Role) -> [NSRange] {
        spans.filter { $0.role == role }.map { $0.range }
    }

    // MARK: - 标题

    func testHeadingCoversWholeLine() {
        let text = "# Title"
        let r = role(spans(text), .heading)
        XCTAssertEqual(r, [NSRange(location: 0, length: (text as NSString).length)])
    }

    func testHeadingUpToSixHashes() {
        XCTAssertEqual(role(spans("###### six"), .heading).count, 1)
        // ：请勿将第 7 个及后续条目用作标题（与 CommonMark 相同）。
        XCTAssertEqual(role(spans("####### seven"), .heading).count, 0)
    }

    func testHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(role(spans("#hashtag"), .heading).count, 0)
    }

    // MARK: - 粗体、斜体、删除线

    func testBoldRangeIncludesAsterisks() {
        let text = "before **bold** after"
        let r = role(spans(text), .bold)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual((text as NSString).substring(with: r[0]), "**bold**")
    }

    func testUnderscoreBold() {
        let text = "a __strong__ b"
        XCTAssertEqual(role(spans(text), .bold).count, 1)
    }

    func testItalicDoesNotStealFromBold() {
        let text = "**bold** and *italic*"
        let spans = self.spans(text)
        XCTAssertEqual(role(spans, .bold).count, 1)
        XCTAssertEqual(role(spans, .italic).count, 1)
        let italic = role(spans, .italic)[0]
        XCTAssertEqual((text as NSString).substring(with: italic), "*italic*")
    }

    func testUnderscoreInsideWordIsNotItalic() {
        // 不要将  snake_case_word 之类的拼写误认为是斜体。
        XCTAssertEqual(role(spans("snake_case_word"), .italic).count, 0)
    }

    func testStrikethrough() {
        let text = "~~gone~~"
        XCTAssertEqual(role(spans(text), .strikethrough).count, 1)
    }

    // MARK: - 内联代码（优先级高于强调）

    func testInlineCodeSuppressesEmphasisInside() {
        let text = "`a**b**c` and **real**"
        let spans = self.spans(text)
        XCTAssertEqual(role(spans, .inlineCode).count, 1)
        XCTAssertEqual(role(spans, .bold).count, 1)
        let bold = role(spans, .bold)[0]
        XCTAssertEqual((text as NSString).substring(with: bold), "**real**")
    }

    // MARK: - 代码块（围栏）

    func testFencedBlockLinesAreCodeBlock() {
        let text = "before\n```\ncode **not bold**\n```\nafter"
        let spans = self.spans(text)
        // ：粗体文本未应用于围栏内。
        XCTAssertEqual(role(spans, .bold).count, 0)
        XCTAssertTrue(role(spans, .codeBlock).count >= 3)   // 開始行・中身・終了行
    }

    func testUnterminatedFenceRunsToEndOfDocument() {
        let text = "```\na\nb"
        let ns = text as NSString
        let lines = MarkdownSyntax.lineRanges(ns)
        let fenced = MarkdownSyntax.fencedLineNumbers(lines.map { ns.substring(with: $0) })
        XCTAssertEqual(fenced, Set(0..<lines.count))
    }

    // MARK: - 报价单、分隔符行、列表

    func testBlockquoteCoversWholeLine() {
        let text = "> quoted text"
        XCTAssertEqual(role(spans(text), .blockquote).count, 1)
    }

    func testHorizontalRuleVariants() {
        for line in ["---", "***", "___", "- - -"] {
            XCTAssertEqual(role(spans(line), .horizontalRule).count, 1, "failed for \(line)")
        }
    }

    func testDashListIsNotHorizontalRule() {
        let text = "- item one"
        XCTAssertEqual(role(spans(text), .horizontalRule).count, 0)
        XCTAssertEqual(role(spans(text), .listMarker).count, 1)
    }

    func testListMarkerIsJustTheMarker() {
        let text = "1. first item"
        let r = role(spans(text), .listMarker)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual((text as NSString).substring(with: r[0]), "1.")
    }

    // MARK: - 链接表

    func testLinkWholeRange() {
        let text = "see [docs](https://example.com) now"
        let r = role(spans(text), .link)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual((text as NSString).substring(with: r[0]), "[docs](https://example.com)")
    }

    func testImageIsAlsoLinkRole() {
        XCTAssertEqual(role(spans("![alt](img.png)"), .link).count, 1)
    }

    func testTablePipesCounted() {
        let text = "| a | b |"
        XCTAssertEqual(role(spans(text), .tablePipe).count, 3)
    }
}
