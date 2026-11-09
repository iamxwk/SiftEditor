import XCTest
import AppKit
@testable import SiftEditorCore

/// 接线检查，以确保代码语言根据文件扩展名突出显示开关。
/// 每个角色的范围确定由 `CodeSyntaxTests` 处理。
final class EditableViewerCodeHighlightTests: XCTestCase {
    private func open(_ text: String, ext: String) throws -> (EditableViewer, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-code-\(UUID().uuidString).\(ext)")
        try text.data(using: .utf8)!.write(to: url)
        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        return (v, url)
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
        // 当使用 .py 打开文件时应用的颜色编码，在重新打开具有不同扩展名的文件时不会保留。
        let (v, pyURL) = try open("import os", ext: "py")
        defer { try? FileManager.default.removeItem(at: pyURL) }
        XCTAssertNotNil(v._testMarkdownColor(at: 0))

        let cssURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-code-\(UUID().uuidString).css")
        defer { try? FileManager.default.removeItem(at: cssURL) }
        try "plain text, no css keywords here".data(using: .utf8)!.write(to: cssURL)
        XCTAssertTrue(v.open(url: cssURL))
        XCTAssertEqual(v._testCodeLanguage, .css)
        XCTAssertNil(v._testMarkdownColor(at: 0))   // CSS 没有保留字高亮显示。
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
