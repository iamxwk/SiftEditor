import XCTest
import AppKit
@testable import SiftEditorCore

/// 显示设置的持久性和通知（制表符宽度、行间距、当前行高亮显示、光标形状），
/// 验证反映这些的 `EditorStyle` 的派生。
/// 要访问  / UserDefaults.standard，请在每次测试中将其恢复为原始值。
final class DisplaySettingsTests: XCTestCase {

    private var saved: (tab: Int, spacing: LineSpacing, hl: Bool, cursor: CursorShape)!

    override func setUp() {
        super.setUp()
        saved = (AppSettings.tabWidth, AppSettings.lineSpacing,
                 AppSettings.highlightCurrentLine, AppSettings.cursorShape)
    }

    override func tearDown() {
        AppSettings.tabWidth = saved.tab
        AppSettings.lineSpacing = saved.spacing
        AppSettings.highlightCurrentLine = saved.hl
        AppSettings.cursorShape = saved.cursor
        super.tearDown()
    }

    func testDefaults() {
        // 默认值为 tab=4 / 标准 / 高亮 on / 条形图。
        AppSettings.tabWidth = 4
        XCTAssertEqual(AppSettings.tabWidth, 4)
        AppSettings.lineSpacing = .standard
        XCTAssertEqual(AppSettings.lineSpacing, .standard)
    }

    func testPersistRoundTrip() {
        AppSettings.tabWidth = 8
        AppSettings.lineSpacing = .wider
        AppSettings.highlightCurrentLine = false
        AppSettings.cursorShape = .block
        XCTAssertEqual(AppSettings.tabWidth, 8)
        XCTAssertEqual(AppSettings.lineSpacing, .wider)
        XCTAssertFalse(AppSettings.highlightCurrentLine)
        XCTAssertEqual(AppSettings.cursorShape, .block)
    }

    func testEachChangePostsDisplayNotification() {
        for change in [{ AppSettings.tabWidth = 2 },
                       { AppSettings.lineSpacing = .wide },
                       { AppSettings.highlightCurrentLine = true },
                       { AppSettings.cursorShape = .underline }] {
            let exp = expectation(forNotification: .siftEditorDisplayChanged, object: nil)
            change()
            wait(for: [exp], timeout: 1)
        }
    }

    func testTabIntervalScalesWithWidth() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        AppSettings.tabWidth = 2
        let two = EditorStyle.tabInterval(for: font)
        AppSettings.tabWidth = 8
        let eight = EditorStyle.tabInterval(for: font)
        XCTAssertGreaterThan(eight, two)
        // 8 宽度正好是宽度 2 的 4 倍（相同的空间宽度 × 字符数）。
        XCTAssertEqual(eight, two * 4, accuracy: 0.5)
    }

    func testLineHeightScalesWithSpacing() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        AppSettings.lineSpacing = .standard
        let base = EditorStyle.lineHeight(for: font)
        AppSettings.lineSpacing = .wider
        let wider = EditorStyle.lineHeight(for: font)
        XCTAssertGreaterThan(wider, base)
    }

    func testParagraphStyleUsesEqualLineHeightsAndTabInterval() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        AppSettings.tabWidth = 4
        AppSettings.lineSpacing = .standard
        let p = EditorStyle.paragraphStyle(for: font)
        XCTAssertEqual(p.minimumLineHeight, p.maximumLineHeight)
        XCTAssertEqual(p.minimumLineHeight, EditorStyle.lineHeight(for: font), accuracy: 0.5)
        XCTAssertEqual(p.defaultTabInterval, EditorStyle.tabInterval(for: font), accuracy: 0.5)
        XCTAssertTrue(p.tabStops.isEmpty)
    }
}
