import XCTest
import AppKit
@testable import SiftEditorCore

/// 简单的剪贴板历史记录 (B6)。无法测试其是否持久化（该进程）。
/// 这只关乎你活着的时候发生的事情，所以这里的限制是记录的判断——你记得什么，你演奏什么。
final class ClipboardHistoryTests: XCTestCase {
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    func testRecordsPlainText() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "hello")
        XCTAssertEqual(h.entries.map(\.text), ["hello"])
    }

    func testNewestFirst() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "one")
        h.record(types: [.string], text: "two")
        XCTAssertEqual(h.entries.map(\.text), ["two", "one"])
    }

    /// 1Password 等是复制密码时设置的标志。如果忽略……
    /// “在其历史记录中显示密码的应用程序”——必须严格遵守的条件。
    func testSkipsConcealedType() {
        let h = ClipboardHistory()
        h.record(types: [.string, concealed], text: "s3cr3t")
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testSkipsEmptyOrMissingText() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "")
        h.record(types: [.string], text: nil)
        XCTAssertTrue(h.entries.isEmpty)
    }

    /// 即使相同的内容被重复复制（由于轮询错误等），它仍然只作为一个条目。
    func testConsecutiveDuplicateDoesNotGrowList() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "same")
        h.record(types: [.string], text: "same")
        XCTAssertEqual(h.entries.count, 1)
    }

    /// 即使内容相同，在中间插入其他内容也会使其成为一个单独的条目（但不会消除再次复制的感觉）。
    func testSameTextAfterSomethingElseIsRecordedAgain() {
        let h = ClipboardHistory()
        h.record(types: [.string], text: "a")
        h.record(types: [.string], text: "b")
        h.record(types: [.string], text: "a")
        XCTAssertEqual(h.entries.map(\.text), ["a", "b", "a"])
    }

    func testOldestIsDroppedPastLimit() {
        let h = ClipboardHistory()
        h.limit = 3
        for s in ["1", "2", "3", "4"] { h.record(types: [.string], text: s) }
        XCTAssertEqual(h.entries.map(\.text), ["4", "3", "2"])
    }

    func testOnChangeFiresOnRecordAndClear() {
        let h = ClipboardHistory()
        var hits = 0
        h.onChange = { hits += 1 }
        h.record(types: [.string], text: "x")
        XCTAssertEqual(hits, 1)
        h.clear()
        XCTAssertEqual(hits, 2)
        XCTAssertTrue(h.entries.isEmpty)
    }

    /// 被拒绝的记录不会触发 onChange 声音（防止不必要的菜单重新排列）。
    func testOnChangeDoesNotFireWhenSkipped() {
        let h = ClipboardHistory()
        var hits = 0
        h.onChange = { hits += 1 }
        h.record(types: [.string, concealed], text: "s3cr3t")
        h.record(types: [.string], text: "")
        XCTAssertEqual(hits, 0)
    }

    func testClearOnEmptyHistoryDoesNotFireOnChange() {
        let h = ClipboardHistory()
        var hits = 0
        h.onChange = { hits += 1 }
        h.clear()
        XCTAssertEqual(hits, 0)
    }

    // MARK: - tick（通过实际的 NSPasteboard）

    /// `tick` 仅在 changeCount 激活时读取 pasteboard。
    func testTickOnlyRecordsWhenChangeCountMoves() {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }

        let h = ClipboardHistory()
        h.tick()
        XCTAssertTrue(h.entries.isEmpty)   // 未复制任何内容

        pb.clearContents()
        pb.setString("picked up by tick", forType: .string)
        h.tick()
        XCTAssertEqual(h.entries.map(\.text), ["picked up by tick"])

        h.tick()
        XCTAssertEqual(h.entries.count, 1)   // 如果没有变化，则不会增加。
    }

    // MARK: - 菜单标题 (AppDelegate.clipboardMenuTitle)

    func testMenuTitleReplacesNewlinesWithAGlyph() {
        XCTAssertEqual(AppDelegate.clipboardMenuTitle(for: "a\nb"), "a⏎ b")
    }

    func testMenuTitleTruncatesLongText() {
        let long = String(repeating: "x", count: 100)
        let title = AppDelegate.clipboardMenuTitle(for: long, maxLength: 20)
        XCTAssertEqual(title.count, 21) // 20 文字 + "…"
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testMenuTitleKeepsShortTextAsIs() {
        XCTAssertEqual(AppDelegate.clipboardMenuTitle(for: "short"), "short")
    }
}
