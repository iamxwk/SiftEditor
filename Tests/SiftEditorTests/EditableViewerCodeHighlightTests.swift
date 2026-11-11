import XCTest
import AppKit
@testable import SiftEditorCore

/// 接线检查，以确保代码语言根据文件扩展名突出显示开关。
/// 每个角色的范围确定由 `CodeSyntaxTests` 处理。
final class EditableViewerCodeHighlightTests: XCTestCase {
    func testVisibleSpanSelectionIncludesCrossingToken() {
        let spans = SwiftSyntaxEngine.spans(text: "SELECT 'long string' FROM t", syntax: .sql)
        let quote = ("SELECT 'long string' FROM t" as NSString).range(of: "string").location
        let selected = SwiftSyntaxEngine.spans(spans, intersecting: NSRange(location: quote, length: 3))
        XCTAssertTrue(selected.contains { NSIntersectionRange($0.range, NSRange(location: quote, length: 3)).length > 0 })
        XCTAssertFalse(selected.contains { $0.range.location == 0 })
    }

    func testSQLLargerThanOldHighlightLimitIsScanned() throws {
        let sql = String(repeating: "SELECT 1 FROM t; -- note\n", count: 335_000)
        XCTAssertGreaterThan(sql.utf8.count, 7 * 1024 * 1024)
        XCTAssertLessThan(sql.utf8.count, EditableViewer.sizeThreshold)
        let (viewer, url) = try open(sql, ext: "sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = Date().addingTimeInterval(10)
        while viewer._testSyntaxTokenCount == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThan(viewer._testSyntaxTokenCount ?? 0, 0)
        XCTAssertLessThan(viewer._testPaintedSyntaxRange?.length ?? 0, sql.utf16.count)
    }

    func testEveryOfferedSyntaxHasGrammar() {
        for syntax in EditorSyntax.allCases where syntax != .text {
            XCTAssertEqual(SwiftSyntaxEngine.language(for: syntax).id, syntax.rawValue)
        }
    }

    func testUTF8TokenOffsetsMapToUTF16TextRanges() {
        let spans = SwiftSyntaxEngine.spans(text: "😀 SELECT", syntax: .sql)
        XCTAssertTrue(spans.contains { $0.range.location == 3 && $0.range.length == 6 })
    }

    private func open(_ text: String, ext: String) throws -> (EditableViewer, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-code-\(UUID().uuidString).\(ext)")
        try text.data(using: .utf8)!.write(to: url)
        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        return (v, url)
    }

    func testSQLUsesSwiftHighlight() throws {
        XCTAssertFalse(SwiftSyntaxEngine.spans(text: "SELECT 42", syntax: .sql).isEmpty)
        let (viewer, url) = try open("SELECT 42 FROM users; -- comment\n", ext: "sql")
        defer { try? FileManager.default.removeItem(at: url) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(viewer._testMarkdownColor(at: 0))
        viewer._testSetText("DROP TABLE IF EXISTS `sample`;\n")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(viewer._testMarkdownColor(at: 0))
    }

    func testLeavingSQLRestoresOtherLanguageHighlighting() throws {
        let (viewer, sqlURL) = try open("SELECT 1;", ext: "sql")
        defer { try? FileManager.default.removeItem(at: sqlURL) }
        let pythonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-code-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: pythonURL) }
        try "def f(): pass".write(to: pythonURL, atomically: true, encoding: .utf8)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(viewer.open(url: pythonURL))
        XCTAssertEqual(viewer._testCodeLanguage, .python)
        XCTAssertNotNil(viewer._testMarkdownColor(at: 0))
    }

    func testPythonFileDetectedAndKeywordColored() throws {
        let (v, url) = try open("def f():\n    return 1", ext: "py")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(v._testCodeLanguage, .python)
        XCTAssertFalse(v._testIsMarkdownFile)
        XCTAssertNotNil(v._testMarkdownColor(at: 0))   // “def” 涂在上面。
    }

    func testUnknownExtensionSkipsHighlighting() throws {
        let (v, url) = try open("def f(): return 1", ext: "xyz")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(v._testCodeLanguage)
        XCTAssertNil(v._testMarkdownColor(at: 0))
    }

    func testSwitchingLanguageOnReopenRefreshesHighlight() throws {
        // 切换文件时必须使用新文件的语言，而不是保留先前 Python 的颜色。
        let (v, pyURL) = try open("import os", ext: "py")
        defer { try? FileManager.default.removeItem(at: pyURL) }
        XCTAssertNotNil(v._testMarkdownColor(at: 0))

        let cssURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-code-\(UUID().uuidString).css")
        defer { try? FileManager.default.removeItem(at: cssURL) }
        try "body { color: red; }".data(using: .utf8)!.write(to: cssURL)
        XCTAssertTrue(v.open(url: cssURL))
        XCTAssertEqual(v._testCodeLanguage, .css)
        XCTAssertNotNil(v._testMarkdownColor(at: 0))

        let plainURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-code-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: plainURL) }
        try "plain text".write(to: plainURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(v.open(url: plainURL))
        XCTAssertNil(v._testMarkdownColor(at: 0))
    }

    /// 声明名称（def 之后的函数名称、YAML 中的键等）应该用颜色来区分，而不是用 Bold 来区分。
    /// (如果字体没有物理表示，Bold 将会出错，所以我从 Monaco 等选项中选择了一个更可靠的颜色)。
    func testDefinitionNameUsesColorNotBold() throws {
        let text = "def greet():\n    pass"
        let (v, url) = try open(text, ext: "py")
        defer { try? FileManager.default.removeItem(at: url) }
        let nameLocation = (text as NSString).range(of: "greet").location
        XCTAssertNotNil(v._testMarkdownColor(at: nameLocation))
        XCTAssertFalse(v._testMarkdownFontTraits(at: nameLocation).contains(.bold))
    }

    func testYamlKeyUsesColorNotBold() throws {
        let text = "image: nginx"
        let (v, url) = try open(text, ext: "yml")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(v._testMarkdownColor(at: 0))
        XCTAssertFalse(v._testMarkdownFontTraits(at: 0).contains(.bold))
    }
}
