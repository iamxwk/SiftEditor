import XCTest
import AppKit
@testable import SiftEditorCore

/// 数字标尺在两个窗格中的行为方式相同。
///
/// 小文件（`NSTextView`）和大文件（自绘）的机制完全不同，
/// 只修复一侧很容易满足。这里，我们将相应的验证并排展示。
/// 如果“仅存在于两个位置中的一个”，则测试设计为失败。
final class ColumnRulerPaneTests: XCTestCase {

    private func smallPane(_ text: String = "1234567890abcdefghij\n") -> EditableViewer {
        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testSetText(text)
        return v
    }

    private func largePane(_ text: String = "1234567890abcdefghij\n") -> PieceTableViewer {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(text.utf8))
        return v
    }

    // MARK: - 两个窗格均受支持。

    func testBothPanesSupportColumnRuler() {
        XCTAssertTrue(smallPane().supportsColumnRuler)
        XCTAssertTrue(largePane().supportsColumnRuler)
    }

    func testRulerIsHiddenByDefault() {
        XCTAssertFalse(smallPane().columnRulerVisible)
        XCTAssertFalse(largePane().columnRulerVisible)
    }

    func testToggleVisibility() {
        let small = smallPane(), large = largePane()
        small.setColumnRulerVisible(true)
        large.setColumnRulerVisible(true)
        XCTAssertTrue(small.columnRulerVisible)
        XCTAssertTrue(large.columnRulerVisible)
        small.setColumnRulerVisible(false)
        large.setColumnRulerVisible(false)
        XCTAssertFalse(small.columnRulerVisible)
        XCTAssertFalse(large.columnRulerVisible)
    }

    // MARK: - 撕掉外包装（外包装会将线路分割，导致数字位数不固定）

    func testShowingRulerDisablesWrapInSmallPane() {
        let v = smallPane()
        XCTAssertTrue(v._testWrapsText, "既定は折り返し")
        v.setColumnRulerVisible(true)
        XCTAssertFalse(v._testWrapsText, "ルーラーを出したら横スクロールへ切り替わる")
    }

    func testHidingRulerRestoresWrapInSmallPane() {
        let v = smallPane()
        v.setColumnRulerVisible(true)
        v.setColumnRulerVisible(false)
        XCTAssertTrue(v._testWrapsText, "しまったら元の折り返しに戻る")
    }

    func testShowingRulerDisablesWrapInLargePane() {
        let v = largePane()
        v.setColumnRulerVisible(true)
        XCTAssertFalse(v._testWrapEnabled)
    }

    /// 如果已启用水平滚动（例如，在结构化视图中），则在关闭页面时不要自动恢复为换行。
    func testHidingRulerDoesNotForceWrapWhenItWasAlreadyOff() {
        let v = largePane("a,b,c\n1,2,3\n")
        v.setStructuredMode(.csv)          // 结构化 = 固定水平滚动
        XCTAssertFalse(v._testWrapEnabled)
        v.setColumnRulerVisible(true)
        v.setColumnRulerVisible(false)
        XCTAssertFalse(v._testWrapEnabled, "構造化の都合を壊さない")
    }

    /// 即使您在标尺显示时在首选项中启用换行符，标尺和正文也不会错位。
    /// 请勿启用回调。**关闭窗口后，新设置将生效。**
    func testLineWrapSettingIsDeferredWhileRulerIsVisible() {
        let saved = AppSettings.lineWrap
        defer { AppSettings.lineWrap = saved }

        AppSettings.lineWrap = false
        let v = largePane()
        v.setColumnRulerVisible(true)

        AppSettings.lineWrap = true
        v.applyLineWrap()
        XCTAssertFalse(v._testWrapEnabled, "ルーラー中に折り返しが効いてしまっている")

        v.setColumnRulerVisible(false)
        XCTAssertTrue(v._testWrapEnabled, "しまったあとに新しい設定が反映されていない")
    }

    // MARK: - 指南在两个窗格中以数字数组的形式显示。

    func testGuidesToggleInBothPanes() {
        let small = smallPane(), large = largePane()
        small._testToggleColumnGuide(9)
        large._testToggleColumnGuide(9)
        XCTAssertEqual(small._testColumnGuides, [9])
        XCTAssertEqual(large._testColumnGuides, [9])
        XCTAssertTrue(small.hasColumnGuides)
        XCTAssertTrue(large.hasColumnGuides)

        small._testToggleColumnGuide(9)
        large._testToggleColumnGuide(9)
        XCTAssertTrue(small._testColumnGuides.isEmpty)
        XCTAssertTrue(large._testColumnGuides.isEmpty)
    }

    func testGuidesStaySortedInBothPanes() {
        let small = smallPane(), large = largePane()
        for col in [15, 9, 40, 1] {
            small._testToggleColumnGuide(col)
            large._testToggleColumnGuide(col)
        }
        XCTAssertEqual(small._testColumnGuides, [1, 9, 15, 40])
        XCTAssertEqual(large._testColumnGuides, [1, 9, 15, 40])
    }

    func testClearGuidesInBothPanes() {
        let small = smallPane(), large = largePane()
        small._testToggleColumnGuide(9); large._testToggleColumnGuide(9)
        small.clearColumnGuides(); large.clearColumnGuides()
        XCTAssertFalse(small.hasColumnGuides)
        XCTAssertFalse(large.hasColumnGuides)
    }

    /// 即使尺子不显示，指南也会保留（即使你把它收起来，当你再次显示它时，它也会在同一位置）。
    func testGuidesSurviveHidingTheRuler() {
        let v = smallPane()
        v.setColumnRulerVisible(true)
        v._testToggleColumnGuide(9)
        v.setColumnRulerVisible(false)
        v.setColumnRulerVisible(true)
        XCTAssertEqual(v._testColumnGuides, [9])
    }

    // MARK: - 刻度盘的起始位置与正文相同。
    //
    // 这是这次最有效的测试。当我把原点写成一个公式，加上“间距宽度 + 容器边距”时，
    // 行号被装订线向右偏移（通过实际设备的屏幕截图发现）。主文本没有显示公式。
    // x 的第一个字符实际上是由 AppKit 绘制并展示出来的，并进行了比较。

    func testRulerOriginMatchesTextOriginInSmallPane() throws {
        let v = smallPane()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = v
        v.setColumnRulerVisible(true)
        v.layoutSubtreeIfNeeded()

        let glyphX = try XCTUnwrap(v._testFirstGlyphX)
        XCTAssertEqual(v._testRulerColumnOneX, glyphX, accuracy: 0.5,
                       "1 桁目の目盛りが本文の 1 文字目と同じ x から始まっていない")
    }

    func testRulerOriginMatchesTextOriginInLargePane() {
        let v = largePane()
        v.setColumnRulerVisible(true)
        XCTAssertEqual(v._testRulerColumnOneX, v._testFirstGlyphX, accuracy: 0.5)
    }

    /// 即使删除行号间距，原点也不会移动（如果手动添加间距宽度，则会在此处断开）。
    func testRulerOriginFollowsLineNumberGutterVisibility() throws {
        let v = smallPane()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = v
        v.setColumnRulerVisible(true)
        v.layoutSubtreeIfNeeded()

        let before = try XCTUnwrap(v._testFirstGlyphX)
        XCTAssertEqual(v._testRulerColumnOneX, before, accuracy: 0.5)

        let saved = AppSettings.showLineNumbers
        defer { AppSettings.showLineNumbers = saved; v.applyDisplaySettings() }
        AppSettings.showLineNumbers = !saved
        v.applyDisplaySettings()
        v.layoutSubtreeIfNeeded()

        let after = try XCTUnwrap(v._testFirstGlyphX)
        XCTAssertEqual(v._testRulerColumnOneX, after, accuracy: 0.5,
                       "ガターの出し入れに原点が追従していない")
    }

    // MARK: - 抓取和移动 (C)
    //
    // 由于没有拖放功能，移动一位数字需要“删除并替换”（这是我在 B 的实践中学到的）。

    func testDragMovesGuideInBothPanes() {
        let small = smallPane(), large = largePane()
        small._testToggleColumnGuide(9); large._testToggleColumnGuide(9)
        XCTAssertTrue(small._testMoveColumnGuide(9, to: 10))
        XCTAssertTrue(large._testMoveColumnGuide(9, to: 10))
        XCTAssertEqual(small._testColumnGuides, [10])
        XCTAssertEqual(large._testColumnGuides, [10])
    }

    func testDragOntoAnotherGuideIsRefusedInBothPanes() {
        let small = smallPane(), large = largePane()
        for col in [9, 15] { small._testToggleColumnGuide(col); large._testToggleColumnGuide(col) }
        XCTAssertFalse(small._testMoveColumnGuide(9, to: 15))
        XCTAssertFalse(large._testMoveColumnGuide(9, to: 15))
        XCTAssertEqual(small._testColumnGuides, [9, 15])
        XCTAssertEqual(large._testColumnGuides, [9, 15])
    }

    // MARK: - 输入一个数字 (C)

    func testSetColumnGuidesReplacesTheWholeDefinition() {
        let small = smallPane(), large = largePane()
        small._testToggleColumnGuide(4); large._testToggleColumnGuide(4)
        small.setColumnGuides([9, 15]); large.setColumnGuides([9, 15])
        XCTAssertEqual(small.columnGuideColumns, [9, 15])
        XCTAssertEqual(large.columnGuideColumns, [9, 15])
        small.setColumnGuides([]); large.setColumnGuides([])
        XCTAssertFalse(small.hasColumnGuides)
        XCTAssertFalse(large.hasColumnGuides)
    }

    // MARK: - 记住每个文件 (C)

    private func tempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-fields-\(UUID().uuidString).txt")
        try text.data(using: .utf8)!.write(to: url)
        return url
    }

    /// 当我重新打开它时，**物品定义仍然和以前一样**。尺子也出现了。
    /// （如果只画一条竖线而没有任何解释，就无法知道这条线代表什么。）
    func testFieldsAreRememberedPerFile() throws {
        let a = try tempFile("00012345TOKYO 20260815\n")
        let b = try tempFile("plain text\n")
        defer {
            AppSettings.setColumnGuides([], for: a)
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(v.open(url: a))
        v.setColumnGuides([9, 15])

        XCTAssertTrue(v.open(url: b))
        XCTAssertTrue(v.columnGuideColumns.isEmpty, "別のファイルに前のファイルの定義を当てない")

        XCTAssertTrue(v.open(url: a))
        XCTAssertEqual(v.columnGuideColumns, [9, 15])
        XCTAssertTrue(v.columnRulerVisible, "覚えていた定義はルーラーごと戻す")
    }

    func testClearingGuidesForgetsThem() throws {
        let url = try tempFile("00012345TOKYO\n")
        defer { AppSettings.setColumnGuides([], for: url); try? FileManager.default.removeItem(at: url) }

        let v = EditableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(v.open(url: url))
        v.setColumnGuides([9])
        v.clearColumnGuides()
        XCTAssertTrue(AppSettings.columnGuides(for: url).isEmpty)
    }

    // MARK: - 第五个结构化显示 = 固定长度 (C)

    func testFixedWidthStructuredViewInSmallPane() {
        let v = smallPane("00012345TOKYO 20260815\n00000007OSAKA 20260101\n")
        v.setColumnGuides([9, 15])
        v.setStructuredMode(.fixedWidth)
        XCTAssertEqual(v.structuredMode, .fixedWidth)
        XCTAssertEqual(v.structuredColumnNames, ["1-8", "9-14", "15-22"])
        XCTAssertTrue(v._testText.contains("00012345 │ TOKYO │ 20260815"))
        XCTAssertFalse(v.canEdit, "構造化中は読み取り専用")

        v.setStructuredMode(nil)
        XCTAssertEqual(v._testText, "00012345TOKYO 20260815\n00000007OSAKA 20260101\n", "元の本文に戻る")
    }

    func testFixedWidthStructuredViewInLargePane() {
        let v = largePane("00012345TOKYO 20260815\n00000007OSAKA 20260101\n")
        v.setColumnGuides([9, 15])
        v.setStructuredMode(.fixedWidth)
        XCTAssertEqual(v.structuredMode, .fixedWidth)
        XCTAssertEqual(v.structuredColumnNames, ["1-8", "9-14", "15-22"])
    }

    /// 如果没有定义，则不会将其放置在固定长度中（因为没有分隔符，无法从内容确定列）。
    func testFixedWidthNeedsADefinitionInBothPanes() {
        let small = smallPane("00012345TOKYO\n"), large = largePane("00012345TOKYO\n")
        small.setStructuredMode(.fixedWidth)
        large.setStructuredMode(.fixedWidth)
        XCTAssertNil(small.structuredMode)
        XCTAssertNil(large.structuredMode)
    }

    /// 如果在固定长度格式下查看时移动边界，列本身会发生变化 = 它会重新排列。
    func testMovingAGuideRebuildsTheFixedWidthView() {
        let v = smallPane("00012345TOKYO 20260815\n")
        v.setColumnGuides([9, 15])
        v.setStructuredMode(.fixedWidth)
        v._testMoveColumnGuide(9, to: 8)
        XCTAssertEqual(v.structuredColumnNames, ["1-7", "8-14", "15-22"])
        XCTAssertTrue(v._testText.contains("0001234 │ 5TOKYO │ 20260815"))
    }

    /// 格式化显示中不要保留参考线（定义是**原始文本的列**，因此它指的是不同的位置）。
    /// 定义本身不会被删除；一旦结构被移除，它就会返回。
    func testGuidesAreHiddenWhileStructuredInBothPanes() {
        let small = smallPane("00012345TOKYO 20260815\n")
        let large = largePane("00012345TOKYO 20260815\n")
        for v in [small as DocumentPane, large as DocumentPane] { v.setColumnGuides([9, 15]) }
        XCTAssertFalse(small._testColumnGuidesHidden)
        XCTAssertFalse(large._testColumnGuidesHidden)

        small.setStructuredMode(.fixedWidth)
        large.setStructuredMode(.fixedWidth)
        XCTAssertTrue(small._testColumnGuidesHidden)
        XCTAssertTrue(large._testColumnGuidesHidden)
        XCTAssertEqual(small.columnGuideColumns, [9, 15], "描画だけ止める（定義は保つ）")
        XCTAssertEqual(large.columnGuideColumns, [9, 15])

        small.setStructuredMode(nil)
        large.setStructuredMode(nil)
        XCTAssertFalse(small._testColumnGuidesHidden)
        XCTAssertFalse(large._testColumnGuidesHidden)
    }

    // MARK: - 不支持的窗格

    func testDiffViewerDoesNotSupportColumnRuler() {
        let v = DiffViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(v.supportsColumnRuler)
        XCTAssertFalse(v.columnRulerVisible)
        v.setColumnRulerVisible(true)               // 默认实现 no-op（不会崩溃）
        XCTAssertFalse(v.columnRulerVisible)
    }
}
