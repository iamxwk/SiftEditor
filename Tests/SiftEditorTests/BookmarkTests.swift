import XCTest
@testable import SiftEditorCore

/// 书签。**调查过程需要反复推敲**——从你缩小范围找到的线索跳转到正文，阅读其周围的内容，
/// 再返回一次。我只能记住一两个返回目的地；如果超过这个数量，我会把线路编号记在笔记里。
/// 它将被复制下来。副本将放置在工具内部。
final class BookmarkTests: XCTestCase {

    private func viewer(_ text: String) -> EditableViewer {
        let v = EditableViewer()
        v.newDocument()
        v._testSetText(text)
        v._testSelect(NSRange(location: 0, length: 0))
        return v
    }

    func testTogglingTwiceLeavesNoBookmark() {
        let v = viewer("a\nb\nc\n")
        v.toggleBookmark()
        XCTAssertEqual(v.bookmarkedLines, [0])
        v.toggleBookmark()
        XCTAssertTrue(v.bookmarkedLines.isEmpty)
    }

    func testBookmarksLandOnTheCaretLine() {
        let v = viewer("a\nb\nc\n")
        v._testSelect(NSRange(location: 2, length: 0))   // 2 行目
        v.toggleBookmark()
        XCTAssertEqual(v.bookmarkedLines, [1])
    }

    func testJumpMovesToTheNextBookmarkNotTheCurrentLine() {
        // 如果跳转到当前行，按下按钮时按钮将变为非活动状态。
        let v = viewer("a\nb\nc\nd\n")
        v._testSelect(NSRange(location: 0, length: 0)); v.toggleBookmark()   // 1 行目
        v._testSelect(NSRange(location: 4, length: 0)); v.toggleBookmark()   // 3 行目
        v._testSelect(NSRange(location: 0, length: 0))
        v.goToBookmark(forward: true)
        XCTAssertEqual(v._testSelection.location, 4)
    }

    func testJumpBackwardFindsTheEarlierBookmark() {
        let v = viewer("a\nb\nc\nd\n")
        v._testSelect(NSRange(location: 0, length: 0)); v.toggleBookmark()
        v._testSelect(NSRange(location: 6, length: 0))                       // 4 行目
        v.goToBookmark(forward: false)
        XCTAssertEqual(v._testSelection.location, 0)
    }

    func testNothingToJumpToLeavesThePositionAlone() {
        // 如果没有目的地，则不会移动（菜单也会被禁用）。如果您静默返回起点，
        // 我找不到我正在看的地方了。
        let v = viewer("a\nb\n")
        v._testSelect(NSRange(location: 2, length: 0))
        v.goToBookmark(forward: true)
        XCTAssertEqual(v._testSelection.location, 2)
    }
}
