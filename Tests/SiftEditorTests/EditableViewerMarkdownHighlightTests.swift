import XCTest
import AppKit
@testable import SiftEditorCore

/// Markdown 语法高亮显示接线（仅当使用 `.md` 打开时高亮显示；按下按键时重新高亮显示）。
/// 每个角色的范围确定由 `MarkdownSyntaxTests` 处理。
final class EditableViewerMarkdownHighlightTests: XCTestCase {
    private func tempURL(ext: String = "md") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-md-\(UUID().uuidString).\(ext)")
    }

    private func open(_ text: String, ext: String = "md") throws -> (EditableViewer, URL) {
        let url = tempURL(ext: ext)
        try text.data(using: .utf8)!.write(to: url)
        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        return (v, url)
    }

    // MARK: - 由文件扩展名确定

    func testMarkdownExtensionDetected() throws {
        let (v, url) = try open("# hi")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(v._testIsMarkdownFile)
    }

    func testNonMarkdownExtensionNotHighlighted() throws {
        let (v, url) = try open("# not markdown", ext: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(v._testIsMarkdownFile)
        XCTAssertNil(v._testMarkdownColor(at: 0))
    }

    // MARK: - 实际涂装

    func testHeadingGetsColoredOnOpen() throws {
        let (v, url) = try open("# Title\nbody")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(v._testMarkdownColor(at: 0))
        // 主文本行保留主题的基本颜色（不添加 temporary 或 attribute）。
        let bodyLocation = ("# Title\nbody" as NSString).range(of: "body").location
        XCTAssertNil(v._testMarkdownColor(at: bodyLocation))
    }

    func testBoldGetsBoldFontTrait() throws {
        let text = "plain **bold** plain"
        let (v, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let boldLocation = (text as NSString).range(of: "**bold**").location + 2
        XCTAssertTrue(v._testMarkdownFontTraits(at: boldLocation).contains(.bold))
    }

    func testStrikethroughApplied() throws {
        let text = "~~gone~~"
        let (v, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(v._testHasStrikethrough(at: 2))
    }

    // MARK: - 每次按键后重新绘制

    func testHighlightRefreshesAfterEdit() throws {
        let (v, url) = try open("plain text")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(v._testMarkdownColor(at: 0))

        v._testSetText("# Now a heading")
        v._testRefreshMarkdownHighlight()
        XCTAssertNotNil(v._testMarkdownColor(at: 0))
    }

    // MARK: - 请勿应用于大型文件（以免减慢打字速度）。

    func testOversizedMarkdownSkipsHighlighting() throws {
        // ：正文超过上限 (2MB) 时，即使存在标题，标题也不会突出显示。
        let padding = String(repeating: "x", count: 2 * 1024 * 1024)
        let big = "# heading\n" + padding
        let (v, url) = try open(big)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(v._testMarkdownColor(at: 0))
    }

    // MARK: - Bold 使不存在的字体 (Monaco) 也显示为粗体。

    func testBoldFallsBackToSyntheticStrokeOnFontWithoutBoldFace() throws {
        // 前提检查：Monaco 不存在真正的 Bold 字体（如果不存在，则此测试的前提被破坏）。
        let monaco = NSFont(name: "Monaco", size: 12)!
        var traits = monaco.fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let boldDescriptor = monaco.fontDescriptor.withSymbolicTraits(traits)
        let hasRealBold = NSFont(descriptor: boldDescriptor, size: 12)?
            .fontDescriptor.symbolicTraits.contains(.bold) ?? false
        try XCTSkipIf(hasRealBold, "この環境の Monaco には Bold があるため前提が崩れている")

        let savedName = EditorFont.currentName
        EditorFont.setName("Monaco")
        defer { EditorFont.setName(savedName) }

        let text = "# heading"
        let (v, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(v._testMarkdownFontTraits(at: 0).contains(.bold))
        XCTAssertTrue(v._testHasSyntheticBoldStroke(at: 0))
        XCTAssertNotNil(v._testMarkdownColor(at: 0))   // 即使通过合成，该颜色也能正常应用。
    }

    // MARK: - SF Mono 等。即使在 San Francisco 系列字体中，你也能找到真正的 Bold。

    /// 旧版 NSFontManager 的 `traits(of:)` 对 San Francisco 系列字体的粗体
    /// 有些情况下无法正确识别（这正是我在正文中停止使用 API 的原因）。
    /// 确认是否可以通过  / NSFontDescriptor 使用默认字体（SF Mono → Menlo 回退）找到它。
    func testBoldFindsRealBoldOnDefaultSystemFont() throws {
        let savedName = EditorFont.currentName
        EditorFont.setName(nil)   // 默认回退顺序（SF Mono → Menlo → ...）
        defer { EditorFont.setName(savedName) }

        let text = "# heading"
        let (v, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(v._testMarkdownFontTraits(at: 0).contains(.bold))
        XCTAssertFalse(v._testHasSyntheticBoldStroke(at: 0))   // 它尚未进入合成备用方案。
    }
}
