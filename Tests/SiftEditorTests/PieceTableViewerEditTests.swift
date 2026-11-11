import XCTest
import AppKit
@testable import SiftEditorCore

/// B2b（文本变体 + Undo/Redo + Cut/Paste）将以 document 为单位进行无头验证。
/// 不要设置  / GUI，而是通过 `PieceTableViewer` 的测试接缝驱动编辑管道。
final class PieceTableViewerEditTests: XCTestCase {
    func testSelectAllFindMatchesInLargeViewerAndCopy() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "DROP TABLE one;\nother\nDROP TABLE two;\n".write(to: url, atomically: true, encoding: .utf8)
        let viewer = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertTrue(viewer.open(url: url))
        let loaded = Date().addingTimeInterval(5)
        while viewer._testDocString.isEmpty, Date() < loaded {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        viewer.setRegexMode(true)
        let found = expectation(description: "find both matching lines")
        viewer.onSearchState = { _, total, searching, _, _, _ in
            if !searching && total == 2 { found.fulfill() }
        }
        viewer.setSearchQuery("DROP TABLE.*")
        XCTAssertEqual(viewer.selectAllSearchMatches(), .pending) // 搜索尚未完成时也应在完成后自动选中。
        wait(for: [found], timeout: 5)
        viewer.onSearchState = nil
        XCTAssertTrue(viewer.hasSelectedSearchMatches)
        XCTAssertEqual(viewer._testSelectedSearchRows.count, 2)
        XCTAssertEqual(viewer._testSelectedSearchText, "DROP TABLE one;\nDROP TABLE two;")
        viewer._testCopy()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "DROP TABLE one;\nDROP TABLE two;")
        viewer.findNext()
        XCTAssertFalse(viewer.hasSelectedSearchMatches)
        XCTAssertTrue(viewer._testSelectedSearchRows.isEmpty)
    }
    func testFindSearchesUnsavedLargeViewerSnapshotAndRefreshesAfterEdit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "old\n".write(to: url, atomically: true, encoding: .utf8)
        let viewer = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(viewer.open(url: url))
        let deadline = Date().addingTimeInterval(5)
        while viewer._testDocString != "old\n", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(viewer._testDocString, "old\n")
        viewer._testSetCaret(0)
        viewer._testInsert("DROP TABLE first;\n")
        XCTAssertTrue(viewer.supportsSearch)
        viewer.setRegexMode(true)
        let first = expectation(description: "find first unsaved line")
        viewer.onSearchState = { _, total, searching, _, _, _ in
            if !searching && total == 1 { first.fulfill() }
        }
        viewer.setSearchQuery("DROP TABLE.*")
        wait(for: [first], timeout: 5)
        viewer._testSetCaret(0)
        let second = expectation(description: "refresh after another edit")
        viewer.onSearchState = { _, total, searching, _, _, _ in
            if !searching && total == 2 { second.fulfill() }
        }
        viewer._testInsert("DROP TABLE second;\n")
        wait(for: [second], timeout: 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
    }
    private func makeViewer(_ text: String) -> PieceTableViewer {
        let v = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v._testLoad(Array(text.utf8))
        return v
    }

    // MARK: 挿入

    func testInsertAtCaretAdvancesAndUndoRedo() {
        let v = makeViewer("hello")
        v._testSetCaret(5)
        v._testInsert(" world")
        XCTAssertEqual(v._testDocString, "hello world")
        XCTAssertEqual(v._testCaret, 11)

        v._testUndo()
        XCTAssertEqual(v._testDocString, "hello")
        XCTAssertEqual(v._testCaret, 5)

        v._testRedo()
        XCTAssertEqual(v._testDocString, "hello world")
        XCTAssertEqual(v._testCaret, 11)
    }

    func testInsertInMiddle() {
        let v = makeViewer("abcd")
        v._testSetCaret(2)
        v._testInsert("XY")
        XCTAssertEqual(v._testDocString, "abXYcd")
        XCTAssertEqual(v._testCaret, 4)
    }

    func testTypingOverSelectionReplaces() {
        let v = makeViewer("abcdef")
        v._testSelect(1..<4)          // "bcd"
        v._testInsert("Z")
        XCTAssertEqual(v._testDocString, "aZef")
        XCTAssertEqual(v._testCaret, 2)
        v._testUndo()
        XCTAssertEqual(v._testDocString, "abcdef")
    }

    // MARK: 编辑工具箱（转换）

    func testTransformUppercasesSelectionAndKeepsItSelected() {
        let v = makeViewer("abcdef")
        v._testSelect(1..<4)                 // "bcd"
        v.applyTextTransform(.uppercase)
        XCTAssertEqual(v._testDocString, "aBCDef")
        XCTAssertEqual(v._testCaret, 4)      // 转换后保留在末尾（选择保持不变）
        v._testUndo()
        XCTAssertEqual(v._testDocString, "abcdef")
        v._testRedo()
        XCTAssertEqual(v._testDocString, "aBCDef")
    }

    func testTransformNoSelectionIsNoOp() {
        let v = makeViewer("abc")
        v._testSetCaret(1)                   // 未选择
        v.applyTextTransform(.uppercase)
        XCTAssertEqual(v._testDocString, "abc")
    }

    func testTransformMultibyteReencodes() {
        let v = makeViewer("xAbc")           // 仅提供拉丁文选项。
        v._testSelect(1..<4)                 // "Abc"
        v.applyTextTransform(.lowercase)
        XCTAssertEqual(v._testDocString, "xabc")
    }

    func testSelectedTextNilWithoutSelection() {
        let v = makeViewer("abc")
        v._testSetCaret(1)
        XCTAssertNil(v.selectedText)
    }

    /// 外部命令过滤路由（selectedText → ShellFilter → replaceSelection）
    /// 通过大文件窗格。流式传输到 sort 并重新排列所选内容。
    func testFilterPipelineSortsSelection() throws {
        let v = makeViewer("gamma\nalpha\nbeta")   // 16 字节
        v._testSelect(0..<16)
        let sel = try XCTUnwrap(v.selectedText)
        let filtered = try ShellFilter.run(command: "sort", input: sel)
        v.replaceSelection(with: filtered)
        XCTAssertEqual(v._testDocString, "alpha\nbeta\ngamma\n")
        v._testUndo()
        XCTAssertEqual(v._testDocString, "gamma\nalpha\nbeta")
    }

    // MARK: 改行

    func testInsertNewlineSplitsLine() {
        let v = makeViewer("abcd")
        XCTAssertEqual(v._testLineCount, 1)
        v._testSetCaret(2)
        v._testCommand("insertNewline:")
        XCTAssertEqual(v._testDocString, "ab\ncd")
        XCTAssertEqual(v._testLineCount, 2)
        XCTAssertEqual(v._testCaret, 3)
    }

    // MARK: EOL 跟随（根据文件的换行符插入）

    /// 在  / CRLF 文件中输入 Return 将插入 CRLF（不会包含 LF）。
    func testInsertNewlineFollowsCRLF() {
        let v = makeViewer("ab\r\ncd")
        v._testSetCaret(2)                 // 紧接在“ab”之后（在 CR 之前）
        v._testCommand("insertNewline:")
        // 插入的换行符为 CRLF。原有的 CRLF 保持不变。
        XCTAssertEqual(Array(v._testDocBytes), Array("ab\r\n\r\ncd".utf8))
    }

    /// 当包含 CRLF 的字符串被粘贴到  / LF 文件中时，它会被规范化为 LF。
    func testPasteNormalizesCRLFToLF() {
        let v = makeViewer("abcd")
        v._testSetCaret(2)
        v._testInsert("X\r\nY\rZ")
        XCTAssertEqual(v._testDocString, "abX\nY\nZcd")
    }

    /// 当您将包含 LF 的字符串粘贴到  / CRLF 文件中时，它将被规范化为 CRLF。
    func testPasteNormalizesLFToCRLF() {
        let v = makeViewer("ab\r\ncd")
        v._testSetCaret(4)                 // 2 行目行頭
        v._testInsert("X\nY")
        XCTAssertEqual(Array(v._testDocBytes), Array("ab\r\nX\r\nYcd".utf8))
    }

    // MARK: 削除

    func testDeleteBackwardChar() {
        let v = makeViewer("abc")
        v._testSetCaret(3)
        v._testCommand("deleteBackward:")
        XCTAssertEqual(v._testDocString, "ab")
        XCTAssertEqual(v._testCaret, 2)
    }

    func testDeleteBackwardAtLineStartMergesLF() {
        let v = makeViewer("ab\ncd")
        v._testSetCaret(3)            // 第二行的开头（紧接 \n 之后）
        v._testCommand("deleteBackward:")
        XCTAssertEqual(v._testDocString, "abcd")
        XCTAssertEqual(v._testCaret, 2)
    }

    func testDeleteBackwardAtLineStartMergesCRLF() {
        let v = makeViewer("ab\r\ncd")
        v._testSetCaret(4)            // 第二行的开头（紧接在 \r\n 之后）
        v._testCommand("deleteBackward:")
        XCTAssertEqual(v._testDocString, "abcd")   // CR 和 LF 都消失了。
        XCTAssertEqual(v._testCaret, 2)
    }

    func testDeleteForwardChar() {
        let v = makeViewer("abc")
        v._testSetCaret(1)
        v._testCommand("deleteForward:")
        XCTAssertEqual(v._testDocString, "ac")
        XCTAssertEqual(v._testCaret, 1)
    }

    func testDeleteForwardAtLineEndMergesCRLF() {
        let v = makeViewer("ab\r\ncd")
        v._testSetCaret(2)            // 第一行结束（内容结束，CR 之前）
        v._testCommand("deleteForward:")
        XCTAssertEqual(v._testDocString, "abcd")
        XCTAssertEqual(v._testCaret, 2)
    }

    func testDeleteWordBackward() {
        let v = makeViewer("foo bar baz")
        v._testSetCaret(11)
        v._testCommand("deleteWordBackward:")
        XCTAssertEqual(v._testDocString, "foo bar ")
        XCTAssertEqual(v._testCaret, 8)
    }

    // MARK: 剪切/粘贴

    func testCutThenPaste() {
        let v = makeViewer("hello world")
        v._testSelect(0..<5)          // "hello"
        v._testCut()
        XCTAssertEqual(v._testDocString, " world")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")

        v._testSetCaret(v._testDocBytes.count)   // 到结尾
        v._testPaste()
        XCTAssertEqual(v._testDocString, " worldhello")
    }

    func testCutIsUndoable() {
        let v = makeViewer("hello world")
        v._testSelect(0..<6)          // "hello "
        v._testCut()
        XCTAssertEqual(v._testDocString, "world")
        v._testUndo()
        XCTAssertEqual(v._testDocString, "hello world")
    }

    // MARK: 多字节 (UTF-8 Graphme)

    func testInsertAndDeleteMultibyte() {
        let v = makeViewer("あい")            // ，每3字节
        v._testSetCaret(6)                    // 末尾
        v._testInsert("う")
        XCTAssertEqual(v._testDocString, "あいう")
        v._testCommand("deleteBackward:")     // 1 个字素（3 字节）
        XCTAssertEqual(v._testDocString, "あい")
        XCTAssertEqual(v._testCaret, 6)
    }

    // MARK: IME（marked text / 変換中・B2c）

    func testMarkedTextIsNotInDocumentUntilCommitted() {
        let v = makeViewer("ab")
        v._testSetCaret(2)
        v._testSetMarked("ん", sel: NSRange(location: 1, length: 0))
        XCTAssertTrue(v._testHasMarked)
        XCTAssertEqual(v._testMarkedText, "ん")
        XCTAssertEqual(v._testDocString, "ab")     // 尚未包含在文档中
        XCTAssertEqual(v._testCaret, 2)            // 插入符位置（合成的起始点）是固定的。

        v._testInsert("引")                         // 確定
        XCTAssertFalse(v._testHasMarked)
        XCTAssertEqual(v._testDocString, "ab引")
        XCTAssertEqual(v._testCaret, 5)            // “引” 为 3 字节
    }

    func testMarkedTextReplacesSelectionOnStart() {
        let v = makeViewer("abcXYZ")
        v._testSelect(1..<4)                        // "bcX"
        v._testSetMarked("ん", sel: NSRange(location: 1, length: 0))
        XCTAssertEqual(v._testDocString, "aYZ")     // 选择将在转换开始时被删除。
        XCTAssertTrue(v._testHasMarked)
        v._testInsert("変")
        XCTAssertEqual(v._testDocString, "a変YZ")
    }

    func testUnmarkCommitsMarkedText() {
        let v = makeViewer("ab")
        v._testSetCaret(2)
        v._testSetMarked("ん", sel: NSRange(location: 1, length: 0))
        v._testUnmark()
        XCTAssertFalse(v._testHasMarked)
        XCTAssertEqual(v._testDocString, "abん")
    }

    func testEmptyCommitCancelsComposition() {
        let v = makeViewer("ab")
        v._testSetCaret(1)
        v._testSetMarked("ん", sel: NSRange(location: 1, length: 0))
        v._testInsert("")                           // 转换已取消（确认为空）
        XCTAssertFalse(v._testHasMarked)
        XCTAssertEqual(v._testDocString, "ab")      // 未插入任何内容。
    }

    // MARK: 置換（B5）

    func testReplaceAllLiteralIsOneUndo() {
        let v = makeViewer("foo bar\nfoo baz\n")
        v._testSetSearch(terms: ["foo"], matchLines: [0, 1])
        v._testReplaceAll("X")
        XCTAssertEqual(v._testDocString, "X bar\nX baz\n")
        XCTAssertTrue(v._testIsDirty)
        v._testUndo()                                   // 1 撤销操作以返回到上一个状态
        XCTAssertEqual(v._testDocString, "foo bar\nfoo baz\n")
    }

    func testReplaceAllMultiplePerLine() {
        let v = makeViewer("foo foo foo\n")
        v._testSetSearch(terms: ["foo"], matchLines: [0])
        v._testReplaceAll("X")
        XCTAssertEqual(v._testDocString, "X X X\n")
    }

    func testReplaceCurrentIterative() {
        let v = makeViewer("a foo b foo c")
        v._testSetSearch(terms: ["foo"], matchLines: [0])
        v._testSetCaret(0)
        v._testReplaceCurrent("X")                      // 首先选择以下匹配项
        XCTAssertEqual(v._testSelection, 2..<5)
        v._testReplaceCurrent("X")                      // 替换所选内容 → 选择下一个
        XCTAssertEqual(v._testDocString, "a X b foo c")
        v._testReplaceCurrent("X")
        XCTAssertEqual(v._testDocString, "a X b X c")
    }

    func testReplaceAllRegexTemplate() {
        let v = makeViewer("id=1 id=2\n")
        let rx = try! NSRegularExpression(pattern: "id=(\\d)")
        v._testSetSearch(terms: [], regex: rx, matchLines: [0])
        v._testReplaceAll("[$1]")
        XCTAssertEqual(v._testDocString, "[1] [2]\n")
    }

    // MARK: 双击/三击选择 (B7)

    func testDoubleClickSelectsWord() {
        let v = makeViewer("foo bar_baz qux")
        v._testSelectWord(at: 5)                    // "bar_baz"
        XCTAssertEqual(v._testSelection, 4..<11)    // "bar_baz" (_ 为字母)
    }

    func testDoubleClickAtWordEnd() {
        let v = makeViewer("foo bar")
        v._testSelectWord(at: 3)                    // 紧跟在“foo”之后（空格）
        XCTAssertEqual(v._testSelection, 0..<3)     // 前面的单词是“foo”
    }

    func testDoubleClickMultibyteWord() {
        let v = makeViewer("あいう bbb")            // "aiu" = 9 字节
        v._testSelectWord(at: 3)                    // 2文字目
        XCTAssertEqual(v._testSelection, 0..<9)
    }

    func testTripleClickSelectsLine() {
        let v = makeViewer("line one\nline two\nthree")
        v._testSelectLine(at: 11)                   // 2行目内
        XCTAssertEqual(v._testSelection, 9..<18)    // "line two\n"（行頭〜次行頭）
    }

    /// Shift+ 单击将选择从现有光标（锚点）扩展到单击位置。
    func testShiftClickExtendsSelection() {
        let v = makeViewer("hello world")
        v._testClick(at: 2)                         // 普通点击将锚点设置为 2
        XCTAssertNil(v._testSelection)              // 未选择
        v._testClick(at: 8, extend: true)           // Shift+点击
        XCTAssertEqual(v._testSelection, 2..<8)     // 选择  2-8
        // 此外，通过按下 Shift + 单击，只有端点会移动，而锚点会保持原位（反向操作也是可能的）。
        v._testClick(at: 0, extend: true)
        XCTAssertEqual(v._testSelection, 0..<2)
    }

    // MARK: 保存（B3）

    func testEditMarksDirtySaveClears() throws {
        let v = makeViewer("hello")
        XCTAssertFalse(v._testIsDirty)
        v._testSetCaret(5); v._testInsert(" world")
        XCTAssertTrue(v._testIsDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-b3-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(v._testWrite(to: url))
        XCTAssertFalse(v._testIsDirty)              // 保存以解锁 dirty

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "hello world")      // 编辑后的内容将包含在光盘中。
    }

    func testSaveOverExistingFileReplacesAtomically() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-b3-\(UUID().uuidString).txt")
        try "original content\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let v = makeViewer("")
        v._testLoad(Array("edited\nlines\n".utf8))
        XCTAssertTrue(v._testWrite(to: url))
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "edited\nlines\n")
    }

    func testAsyncSaveWritesAndClearsDirtyAndBlocksEditWhileSaving() throws {
        let v = makeViewer("hello")
        v._testSetCaret(5); v._testInsert(" world")
        XCTAssertTrue(v._testIsDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-async-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let began = expectation(description: "onBegin")
        let done = expectation(description: "completion")
        v._testSaveAsync(to: url,
                         onBegin: {
                             // 保存时编辑功能被阻止（因为后台正在读取全文）。
                             XCTAssertTrue(v._testIsSaving)
                             v._testInsert("XXX")            // 将被忽略。
                             began.fulfill()
                         },
                         progress: { _ in },
                         completion: { ok in XCTAssertTrue(ok); done.fulfill() })
        wait(for: [began, done], timeout: 5)

        XCTAssertFalse(v._testIsDirty)
        XCTAssertFalse(v._testIsSaving)
        XCTAssertEqual(v._testDocString, "hello world")     // 未包含已保存的“XXX”。
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello world")
    }

    func testCancelledSaveLeavesDocumentDirtyAndNoFile() throws {
        let v = makeViewer("hello")
        v._testSetCaret(5); v._testInsert(" world")
        XCTAssertTrue(v._testIsDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-cancel-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let done = expectation(description: "completion")
        v._testSaveAsync(to: url,
                         onBegin: { v.cancelSave() },       // 写作开始前安排中断
                         progress: { _ in },
                         completion: { ok in
                             XCTAssertFalse(ok)              // 取消操作被视为失败（无警报）
                             done.fulfill()
                         })
        wait(for: [done], timeout: 5)

        XCTAssertTrue(v._testIsDirty)                        // 未保存，因此仍为 dirty。
        XCTAssertFalse(v._testIsSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))   // 不要留下输出
    }

    /// 大文件路径：如果将保存编码更改为 Shift-JIS 来保存文件，则实际文件将是 Shift-JIS。
    /// （这涉及到将 setSaveEncoding 替换为 saveAsync，然后替换为 transcode 和 atomic，最后重新打开页面。）
    func testSetSaveEncodingThenSaveReencodesLargePath() throws {
        let text = "日本語のログ\nエラー: 発生\n最終行"    // 多行，无尾随换行符，多字节
        let v = makeViewer("")
        v._testLoad(Array(text.utf8))                       // source = UTF-8
        v._testSetSaveEncoding(.shiftJIS)                   // 储备转换
        XCTAssertEqual(v._testSaveEncoding, .shiftJIS)
        XCTAssertTrue(v._testIsDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-convert-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let done = expectation(description: "completion")
        v._testSaveAsync(to: url,
                         onBegin: {}, progress: { _ in },
                         completion: { ok in XCTAssertTrue(ok); done.fulfill() })
        wait(for: [done], timeout: 5)

        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, text.data(using: .shiftJIS))  // 实际磁盘为 Shift-JIS
    }

    func testSaveLargerDocumentRoundTrips() throws {
        // 即使多次插入导致片段数量增加，流导出也能保留所有内容。
        let v = makeViewer("")
        v._testLoad(Array("start\n".utf8))
        for i in 0..<200 { v._testSetCaret(v._testDocBytes.count); v._testInsert("line \(i)\n") }
        let expected = v._testDocString

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-b3-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(v._testWrite(to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
    }

    // MARK: LineEnding 検出

    func testLineEndingDetect() {
        func detect(_ s: String, _ enc: DetectedEncoding = .utf8) -> LineEnding {
            LineEnding.detect(s.data(using: enc.stringEncoding)!, encoding: enc)
        }
        XCTAssertEqual(detect("a\nb"), .lf)
        XCTAssertEqual(detect("a\r\nb"), .crlf)
        XCTAssertEqual(detect("a\rb"), .cr)          // 旧版 Mac（不含 LF 的 CR）
        XCTAssertEqual(detect("no newline"), .lf)    // 如果没有换行符，则默认值为 LF
        // UTF-16 即使在 2 字节单位下也能正确分类。
        XCTAssertEqual(detect("a\r\nb", .utf16LE), .crlf)
        XCTAssertEqual(detect("a\nb", .utf16BE), .lf)
    }

    func testLineEndingNormalize() {
        XCTAssertEqual(LineEnding.crlf.normalize("a\nb\r\nc\rd"), "a\r\nb\r\nc\r\nd")
        XCTAssertEqual(LineEnding.lf.normalize("a\r\nb\rc"), "a\nb\nc")
        XCTAssertEqual(LineEnding.cr.normalize("a\r\nb\nc"), "a\rb\rc")
        XCTAssertEqual(LineEnding.crlf.normalize("no newline"), "no newline")
    }
}
