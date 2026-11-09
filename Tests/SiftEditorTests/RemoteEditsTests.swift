import XCTest
@testable import SiftEditorCore

/// 已收到远程更正的线路 (B12)。关键在于**不要将无法更正的线路标记为正确**。
final class RemoteEditsTests: XCTestCase {

    func testStageKeepsTheFirstOpenedTextAsTheBaseline() {
        var e = RemoteEdits()
        e.stage(line: 3, original: "old", edited: "mid")
        e.stage(line: 3, original: "mid", edited: "new")   // 第二个 original 是一个屏幕值，但其基数与第一个相同。
        XCTAssertEqual(e.edit(at: 3)?.original, "old")
        XCTAssertEqual(e.edit(at: 3)?.edited, "new")
        XCTAssertEqual(e.count, 1)
    }

    func testRestoringTheOriginalTextDropsTheEdit() {
        var e = RemoteEdits()
        e.stage(line: 1, original: "a", edited: "b")
        XCTAssertFalse(e.stage(line: 1, original: "a", edited: "a"))
        XCTAssertTrue(e.isEmpty)
    }

    func testAllIsSortedByLineAndCommitRemoves() {
        var e = RemoteEdits()
        e.stage(line: 9, original: "x", edited: "y")
        e.stage(line: 2, original: "x", edited: "yy")
        XCTAssertEqual(e.all.map(\.line), [2, 9])
        e.commit(line: 2)
        XCTAssertEqual(e.all.map(\.line), [9])
    }

    /// 长度变化的编辑次数，按字节计算（假名改为 "a" 时字符数相同，但字节长度不同）。
    func testRewriteCountIsByBytes() {
        var e = RemoteEdits()
        e.stage(line: 1, original: "abc", edited: "xyz")      // 相同
        e.stage(line: 2, original: "あ", edited: "a")          // 3B → 1B
        e.stage(line: 3, original: "a", edited: "ab")
        XCTAssertEqual(e.rewriteCount, 2)
    }

    // MARK: - 可修正的行

    func testLineWithoutNumberIsNotEditable() {
        XCTAssertFalse(RemoteEdits.isEditable(RemoteLine(number: nil, isMatch: false, text: "x")))
        XCTAssertTrue(RemoteEdits.isEditable(RemoteLine(number: 1, isMatch: false, text: "x")))
    }

    /// 当更正被替换字符替换的不可读字节所在的行时，原始字节会丢失。
    func testLineWithReplacementCharacterIsNotEditable() {
        let bad = String(decoding: [0x61, 0xFF, 0x62], as: UTF8.self)
        XCTAssertTrue(bad.contains("\u{FFFD}"))
        XCTAssertFalse(RemoteEdits.isEditable(RemoteLine(number: 1, isMatch: false, text: bad)))
    }

    func testVeryLongLineIsNotEditable() {
        let long = String(repeating: "a", count: RemoteEdits.maxLineBytes + 1)
        XCTAssertFalse(RemoteEdits.isEditable(RemoteLine(number: 1, isMatch: false, text: long)))
    }

    // MARK: - CRLF 和一个换行符

    func testCarriageReturnIsHiddenAndRestored() {
        XCTAssertEqual(RemoteEdits.display("abc\r"), "abc")
        XCTAssertEqual(RemoteEdits.raw(display: "xyz", original: "abc\r"), "xyz\r")
        XCTAssertEqual(RemoteEdits.raw(display: "xyz", original: "abc"), "xyz")
    }

    func testNewlineInInputIsRejected() {
        XCTAssertNil(RemoteEdits.raw(display: "a\nb", original: "x"))
        XCTAssertNil(RemoteEdits.raw(display: "a\rb", original: "x"))
    }

    func testTextForShowsTheEditedText() {
        var e = RemoteEdits()
        e.stage(line: 4, original: "a", edited: "b")
        XCTAssertEqual(e.text(for: RemoteLine(number: 4, isMatch: false, text: "a")), "b")
        XCTAssertEqual(e.text(for: RemoteLine(number: 5, isMatch: false, text: "a")), "a")
        XCTAssertEqual(e.text(for: RemoteLine(number: nil, isMatch: false, text: "a")), "a")
    }
}
