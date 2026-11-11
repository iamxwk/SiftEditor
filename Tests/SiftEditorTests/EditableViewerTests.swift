import XCTest
import AppKit
@testable import SiftEditorCore

/// 验证小文件编辑窗格中的字符编码规范和 EOL 后续（NSTextView 返回）。
final class EditableViewerTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-ev-\(UUID().uuidString).txt")
    }

    func testChosenSyntaxPersistsForSameExtension() throws {
        let key = "SiftEditor.syntax.extensionOverrides"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let ext = "module"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-ev-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        try "<?php echo 1;".write(to: url, atomically: true, encoding: .utf8)

        let first = EditableViewer()
        XCTAssertTrue(first.open(url: url))
        first.setSyntax(.php)
        let second = EditableViewer()
        XCTAssertTrue(second.open(url: url))
        XCTAssertEqual(second.currentSyntax, .php)
        XCTAssertNotNil(second._testMarkdownColor(at: 2))
    }

    // MARK: 以指定编码重新打开

    /// 即使以  / Shift-JIS 写入的文件被错误地以 UTF-8 的形式打开，也可以通过指定重新打开方法正确读取。
    func testReopenWithEncodingFixesDecode() throws {
        let text = "日本語のログ\nエラー発生"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .shiftJIS)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url, forcedEncoding: .utf8))   // 以故意错误的编码打开
        XCTAssertNotEqual(v._testText, text)                    // 已乱码。

        XCTAssertTrue(v.reopen(withEncoding: .shiftJIS))        // 请使用正确的编码重新打开
        XCTAssertEqual(v._testEncoding, .shiftJIS)
        XCTAssertEqual(v._testText, text)                       // 可以正确读取
    }

    func testReopenWithoutFileFails() {
        let v = EditableViewer()
        v.newDocument()                                         // 未保存 = fileURL 无
        XCTAssertFalse(v.reopen(withEncoding: .shiftJIS))
    }

    // MARK: 保存编码已更改（转换将在下次保存时生效）

    /// 将保存编码更改为 Shift-JIS 会导致 dirty，而保存实际磁盘则变为 Shift-JIS。
    func testSetSaveEncodingThenSaveReencodes() throws {
        let text = "変換テスト\n二行目"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        XCTAssertEqual(v.currentSaveEncoding, .utf8)

        v.setSaveEncoding(.shiftJIS)                            // 唯一的转换选项是“预订”。
        XCTAssertEqual(v.currentSaveEncoding, .shiftJIS)
        XCTAssertTrue(v.isDirty)                                // 已发生需要保存的更改。

        XCTAssertTrue(v._testWrite(to: url))                    // 这是第一次将其写出来（=转换）。
        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, text.data(using: .shiftJIS))      // 实际实体为 Shift-JIS
    }

    // MARK: EOL 关注（保存时，所有文本将与文件 EOL 对齐）

    /// 当您编辑并保存  / CRLF 文件时，NSTextView 放置的 LF 也将替换为 CRLF。
    func testSavePreservesCRLF() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\r\nb\r\nc".data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        XCTAssertEqual(v._testLineEnding, .crlf)
        v._testSetText("x\ny\nz")                               // 这模拟了  LF 编辑后的状态。
        XCTAssertTrue(v._testWrite(to: url))

        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, "x\r\ny\r\nz".data(using: .utf8)) // 全行 CRLF
    }

    func testStatusBarLineEndingChoiceConvertsWholeSmallDocumentOnSave() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
        let viewer = EditableViewer()
        XCTAssertTrue(viewer.open(url: url))
        viewer.setLineEnding(.crlf)
        XCTAssertEqual(viewer.currentLineEnding, .crlf)
        XCTAssertTrue(viewer.isDirty)
        XCTAssertTrue(viewer._testWrite(to: url))
        XCTAssertEqual(try Data(contentsOf: url), Data("a\r\nb\r\n".utf8))
    }

    // MARK: 结构化显示是一种仅用于显示的转换（保存时不会损坏内容）。

    /// 即使您在使用结构化显示（CSV 对齐）时保存，输出也将是原始的 CSV，而不是格式化的外观。
    func testSaveWhileStructuredWritesOriginalCSV() throws {
        let text = "name,age\nAlice,30\nBob,7\n"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.csv)                    // 列对齐显示
        XCTAssertEqual(v.structuredMode, .csv)
        XCTAssertTrue(v.canEdit)                     // CSV 表格可编辑。
        XCTAssertFalse(v.supportsReplace)            // 原始文本的替换功能不能修改隐藏的文本视图。
        XCTAssertFalse(v.supportsMultiCursor)
        XCTAssertTrue(v.subviews.contains(where: { $0 is CSVGridView }))

        XCTAssertTrue(v._testWrite(to: url))         // close → 保存等，即使调用了 write() 也是如此……
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(saved, text)                  // ……仍然是原装 CSV
        XCTAssertFalse(saved.contains("│"))          // 未包含分隔符。
    }

    func testCSVCellEditUpdatesSourceAndSavedFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "name,note\r\nalpha,plain\r\n".write(to: url, atomically: true, encoding: .utf8)
        let viewer = EditableViewer()
        XCTAssertTrue(viewer.open(url: url))
        viewer.setStructuredMode(.csv)
        guard let grid = viewer.subviews.compactMap({ $0 as? CSVGridView }).first,
              let top = grid.subviews.first,
              let editor = top.subviews.compactMap({ ($0 as? NSScrollView)?.documentView as? NSTextView }).first else {
            return XCTFail("CSV cell editor is missing")
        }
        editor.string = "a,\"b\""
        XCTAssertTrue(grid.flushPendingEdit())
        XCTAssertEqual(viewer.restorableText, "name,note\r\n\"a,\"\"b\"\"\",plain\r\n")
        XCTAssertTrue(viewer._testWrite(to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), viewer.restorableText)
        viewer.setStructuredMode(nil)
        XCTAssertEqual(viewer._testText, viewer.restorableText)
    }

    func testGeneratedCSVReportUsesNumberedEditableColumns() throws {
        let viewer = EditableViewer(frame: NSRect(x: 0, y: 0, width: 900, height: 570))
        viewer.setGeneratedCSVText("alpha,3\nbeta,2\n", hasHeader: false)
        viewer.setStructuredMode(.csv)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 570),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = viewer
        viewer.layoutSubtreeIfNeeded()
        guard let grid = viewer.subviews.compactMap({ $0 as? CSVGridView }).first else {
            return XCTFail("CSV grid is missing")
        }
        XCTAssertEqual(grid.document.columnNames, ["1", "2"])
        XCTAssertEqual(grid.document.rowCount, 2)
        XCTAssertTrue(viewer.canEdit)
        XCTAssertGreaterThan(grid.bounds.width, 800)
        XCTAssertGreaterThan(grid.bounds.height, 500)
    }

    /// 关闭结构化视图将恢复为可编辑模式，并且主文本也将恢复到其原始状态。
    func testExitStructuredRestoresText() throws {
        let text = "name,age\nAlice,30\n"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.csv)
        XCTAssertTrue(v.subviews.contains(where: { $0 is CSVGridView }))
        XCTAssertEqual(v._testText, text)             // 表格视图不改写原始文本。
        v.setStructuredMode(nil)
        XCTAssertNil(v.structuredMode)
        XCTAssertTrue(v.canEdit)
        XCTAssertEqual(v._testText, text)            // 已恢复为原文
    }

    /// CSV 表格视图不应为隐藏的原始文本留下格式化属性。
    func testCSVGridDoesNotAlterRawTextFont() throws {
        let text = "name,age\nAlice,30\nBob,7\n"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.csv)
        XCTAssertFalse(v._testStoredFontTraits(at: 0).contains(.bold))
        v.setStructuredMode(nil)
        XCTAssertFalse(v._testStoredFontTraits(at: 0).contains(.bold))  // 恢复后的文本不是粗体。
        XCTAssertFalse(v._testStoredFontTraits(at: v._testText.utf16.count - 1).contains(.bold))
    }

    /// JSON 格式转换仅用于显示目的，仅供读取。关闭此功能将恢复为原始文本，保存后将写入原始的 JSON。
    func testJsonPrettyIsDisplayOnlyAndReversible() throws {
        let text = #"{"b":2,"a":1}"#
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.json)
        XCTAssertEqual(v.structuredMode, .json)
        XCTAssertFalse(v.canEdit)                        // 格式化期间为只读。
        XCTAssertTrue(v._testText.contains("\n"))        // 缩进（原为 1 行）
        XCTAssertTrue(v._testText.hasPrefix("{\n  \"b\": 2"))  // 维护钥匙顺序

        XCTAssertTrue(v._testWrite(to: url))             // 保存的是原始的 JSON，而不是重新塑形后的版本。
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)

        v.setStructuredMode(nil)
        XCTAssertNil(v.structuredMode)
        XCTAssertTrue(v.canEdit)
        XCTAssertEqual(v._testText, text)                // 恢复原文
    }

    /// 无效的 JSON 将不会切换到格式化（仍可编辑，且正文保持不变）。
    func testJsonPrettyRejectsInvalid() throws {
        let text = "not json at all"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.json)
        XCTAssertNil(v.structuredMode)                   // 不切换
        XCTAssertTrue(v.canEdit)
        XCTAssertEqual(v._testText, text)
    }

    // MARK: JSON 原地查询（结果为易失性，只读且不保存）

    /// 当查询打开时，它将变为只读，并且显示内容会被表达式的结果替换。关闭时，它将恢复到原始文本。
    func testJsonQueryRunsAndCloses() throws {
        let text = #"{"items":[{"name":"a","age":30},{"name":"b","age":7},{"name":"c","age":50}]}"#
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.toggleJsonQuery()
        XCTAssertTrue(v._testJsonQueryActive)
        XCTAssertTrue(v.jsonQueryIsActive)
        XCTAssertFalse(v.canEdit)                        // 查询期间只读

        v._testRunJsonQuery("items[?age >= 30].name")
        let shown = v._testText
        XCTAssertTrue(shown.contains("a"))
        XCTAssertTrue(shown.contains("c"))
        XCTAssertFalse(shown.contains("\"b\""))          // age 7 被排除在外。

        v.toggleJsonQuery()                              // 关闭
        XCTAssertFalse(v.jsonQueryIsActive)
        XCTAssertTrue(v.canEdit)
        XCTAssertEqual(v._testText, text)                // 恢复原始文本（结果可能随时更改）
    }

    /// 无法在非 JSON 文件（beep，无状态更改）中打开查询。
    func testJsonQueryRejectsNonJson() throws {
        let text = "hello, not json"
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.toggleJsonQuery()
        XCTAssertFalse(v.jsonQueryIsActive)
        XCTAssertTrue(v.canEdit)
        XCTAssertEqual(v._testText, text)
    }

    // MARK: 编辑工具箱（转换）

    /// 将选定的文本转换为大写，转换后保留选定内容。结果为 dirty。
    func testTransformUppercasesSelection() {
        let v = EditableViewer()
        v._testSetText("hello world")
        v._testSelect(NSRange(location: 0, length: 5))   // "hello"
        v.applyTextTransform(.uppercase)
        XCTAssertEqual(v._testText, "HELLO world")
        XCTAssertTrue(v.isDirty)
    }

    /// 如果未进行任何选择，则不执行任何操作（beep，文本保持不变）。
    func testTransformNoSelectionIsNoOp() {
        let v = EditableViewer()
        v._testSetText("hello")
        v._testSelect(NSRange(location: 2, length: 0))
        v.applyTextTransform(.uppercase)
        XCTAssertEqual(v._testText, "hello")
    }

    /// 编辑后，状态的字节计数会实时更新，无需等待保存（不仅是行数，还有大小）。
    func testStatusByteSizeUpdatesLiveAfterEdit() {
        let v = EditableViewer()
        var last: ViewerState?
        v.onStateChange = { last = $0 }
        v._testSetText("ab")
        v._testSelect(NSRange(location: 0, length: 2))
        v.applyTextTransform(.base64Encode)           // "ab"(2B) → "YWI="(4B)
        XCTAssertEqual(v._testText, "YWI=")
        XCTAssertEqual(last?.fileSize, 4)             // 将不再保持 2，而是更新为 4。
    }

    // MARK: 打印（打印对话框中的“另存为 PDF”选项也支持 PDF 输出）

    /// 小文件编辑面板可以打印。大文件查看器面板不能打印。
    ///（这将达到 8600 万行 = 数百万页，这是禁用菜单的依据）。
    func testPrintOnlyAvailableForSmallFilePane() {
        XCTAssertTrue(EditableViewer().canPrint)

        let big = PieceTableViewer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(big.canPrint)
    }
}
