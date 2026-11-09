import XCTest
import AppKit
@testable import SiftEditorCore

/// 验证其他应用程序对文件修改的检测（版本指纹识别、稳定等待、导入）。
final class ExternalChangeWatcherTests: XCTestCase {
    private func tempURL(_ ext: String = "txt") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-watch-\(UUID().uuidString).\(ext)")
    }

    private func stamp(size: Int64 = 1, modified: TimeInterval = 1, inode: UInt64 = 7) -> FileStamp {
        FileStamp(size: size, modified: modified, inode: inode)
    }

    private func entry() -> FileWatchEntry {
        FileWatchEntry(url: URL(fileURLWithPath: "/tmp/x"), known: stamp())
    }

    // MARK: 指紋（FileStamp）

    func testStampReflectsWrites() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "one\n".write(to: url, atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(FileStamp.read(url))

        try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(FileStamp.read(url))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.size, 8)
    }

    /// atomic save（已写入另一个文件并被替换）可能具有相同的大小和修改时间。
    /// 自从我看到  / inode 以来，我仍然能看出它已经“改变了”。
    func testStampCatchesAtomicReplaceOfIdenticalContent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "same\n".write(to: url, atomically: true, encoding: .utf8)
        let before = try XCTUnwrap(FileStamp.read(url))

        let tmp = tempURL()
        try "same\n".write(to: tmp, atomically: true, encoding: .utf8)
        // 替换 ，同时确保更新时间也匹配（这样大小和内容就相同，只有 inode 不同）。
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.modified)],
                                              ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)

        let after = try XCTUnwrap(FileStamp.read(url))
        XCTAssertEqual(after.size, before.size)
        XCTAssertNotEqual(after.inode, before.inode)
        XCTAssertNotEqual(after, before)
    }

    func testStampIsNilForMissingFile() {
        XCTAssertNil(FileStamp.read(tempURL()))
    }

    // MARK: 等待事态平静下来 (decide)

    func testUnchangedNeverFires() {
        var e = entry()
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: stamp()))
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: stamp()))
        XCTAssertNil(e.pending)
    }

    /// 为避免捕获写入过程，请在导入前查看同一版本两次。
    func testFiresOnlyAfterStamperSettles() {
        var e = entry()
        let changed = stamp(size: 99, modified: 2)
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: changed))   // 第一次：观察结果。
        XCTAssertTrue(ExternalChangeWatcher.decide(&e, current: changed))    // 平静
        XCTAssertEqual(e.known, changed)
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: changed))   // 与同一版本不兼容。
    }

    /// 即使日志一直在写入（每次大小都不同），如果等待时间太长，我也会放弃并导入它们。
    func testFiresEventuallyWhileFileKeepsGrowing() {
        var e = entry()
        var fired = false
        for i in 1...ExternalChangeWatcher.forceAfterTicks {
            fired = ExternalChangeWatcher.decide(&e, current: stamp(size: Int64(100 + i), modified: Double(i)))
        }
        XCTAssertTrue(fired)
        XCTAssertEqual(e.pendingTicks, 0)
    }

    /// 不可见时不执行任何操作（非 atomic 写入器在写入时会短暂消失）。
    /// 你知道的版本会保留下来，所以当你写完后，它出现时，你可以把它当作一个差异来识别。
    func testVanishedFileIsIgnoredButRemembered() {
        var e = entry()
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: nil))
        XCTAssertEqual(e.known, stamp())

        let rewritten = stamp(size: 42, modified: 9, inode: 8)
        XCTAssertFalse(ExternalChangeWatcher.decide(&e, current: rewritten))
        XCTAssertTrue(ExternalChangeWatcher.decide(&e, current: rewritten))
    }

    // MARK: 监控（手动访问实际文件 tick）

    func testWatcherReportsExternalWriteOnce() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "before\n".write(to: url, atomically: true, encoding: .utf8)

        let watcher = ExternalChangeWatcher()
        let key = ObjectIdentifier(self)
        var hits = 0
        watcher.onChange = { _ in hits += 1 }
        watcher.note(key: key, url: url)

        watcher.tick()
        XCTAssertEqual(hits, 0)                     // 什么也没发生。

        try "after\n".write(to: url, atomically: true, encoding: .utf8)
        watcher.tick()                              // 第一次：观察结果。
        watcher.tick()                              // 我已经冷静下来了，所以通知你。
        XCTAssertEqual(hits, 1)

        watcher.tick()
        watcher.tick()
        XCTAssertEqual(hits, 1)                     // 无法继续以相同版本播放。
    }

    /// 如果您在保存后立即输入 `note`，您的帖子将不会被标记为外部修改。
    func testNoteAfterOwnWriteSuppressesChange() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "v1\n".write(to: url, atomically: true, encoding: .utf8)

        let watcher = ExternalChangeWatcher()
        let key = ObjectIdentifier(self)
        var hits = 0
        watcher.onChange = { _ in hits += 1 }
        watcher.note(key: key, url: url)

        try "v2\n".write(to: url, atomically: true, encoding: .utf8)   // 等同于我的存档
        watcher.note(key: key, url: url)                               // 保存后立即导入
        watcher.tick()
        watcher.tick()
        XCTAssertEqual(hits, 0)
    }

    /// 列表匹配功能不会重新记录正在查看的项目的版本（它不会抑制导入之前所做的更改）。
    func testSyncKeepsKnownVersionOfWatchedFiles() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\n".write(to: url, atomically: true, encoding: .utf8)

        let watcher = ExternalChangeWatcher()
        let key = ObjectIdentifier(self)
        var hits = 0
        watcher.onChange = { _ in hits += 1 }
        watcher.note(key: key, url: url)

        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)
        watcher.sync([(key: key, url: url)])        // 当打开另一个文档时运行，等等。
        watcher.tick()
        watcher.tick()
        XCTAssertEqual(hits, 1)                     // 未压碎

        watcher.sync([])                            // 如果你关闭它，你就看不到它了。
        XCTAssertTrue(watcher.entries.isEmpty)
    }

    // MARK: 导入（编辑窗格）

    /// 即使加载外部更改，光标位置也应该保留（如果光标跳转到开头，就会出现问题，因为它是自动运行的）。
    func testReloadFromDiskKeepsCaret() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "1行目\n2行目\n3行目\n".write(to: url, atomically: true, encoding: .utf8)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v._testSelect(NSRange(location: 8, length: 0))

        try "1行目\n2行目 追記\n3行目\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(v.reloadFromDisk())

        XCTAssertEqual(v._testText, "1行目\n2行目 追記\n3行目\n")
        XCTAssertEqual(v._testSelection.location, 8)
        XCTAssertFalse(v.isDirty)                   // 内容与光盘相同 = 未保存
    }

    /// 即使在读取缩短的文件时，光标也会四舍五入到文本的长度（不会超出范围）。
    func testReloadFromDiskClampsCaretWhenFileShrinks() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "aaaa\nbbbb\ncccc\n".write(to: url, atomically: true, encoding: .utf8)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v._testSelect(NSRange(location: 12, length: 3))

        try "aa\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(v.reloadFromDisk())
        XCTAssertEqual(v._testSelection.location, 3)
        XCTAssertEqual(v._testSelection.length, 0)
    }

    /// “使用指定编码重新打开”时选择的字符编码即使在重新加载后也会保留。
    /// （当我切换回自动检测时，我以为已经修复的字符编码问题又自行出现了）。
    func testReloadFromDiskKeepsUserChosenEncoding() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "日本語\n".data(using: .shiftJIS)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url, forcedEncoding: .utf8))    // 误打开
        XCTAssertTrue(v.reopen(withEncoding: .shiftJIS))          // 指定编码后重新打开

        try "日本語 追記\n".data(using: .shiftJIS)!.write(to: url)
        XCTAssertTrue(v.reloadFromDisk())
        XCTAssertEqual(v._testEncoding, .shiftJIS)
        XCTAssertEqual(v._testText, "日本語 追記\n")
    }

    func testReloadFromDiskFailsWithoutFile() {
        let v = EditableViewer()
        v.newDocument()
        XCTAssertFalse(v.reloadFromDisk())
    }

    // MARK: 导入（大文件窗格 = 仅追加扩展索引）

    /// 即使在将添加的数据导入日志并进行编辑后，添加的数据也不会消失。
    ///
    /// piece table 在生成时已将原始文档的长度写入其中，因此如果您仅扩展索引……
    /// **添加的文本会在您开始编辑时立即从正文中消失**（保存时也会从磁盘中消失）。
    /// 在添加过程中重新粘贴 piece 和 table 的原因是阻止该区域。
    func testGrowthReloadKeepsAppendedLinesAfterEdit() throws {
        let url = tempURL("log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "a\nb\n".write(to: url, atomically: true, encoding: .utf8)

        let v = PieceTableViewer()
        XCTAssertTrue(v.open(url: url))
        // 当索引完成后，将创建 piece 和 table（将可以编辑）。
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in v._testLineCount > 0 },
                                              object: nil)
        wait(for: [ready], timeout: 5)

        // 另一个应用程序附加到末尾（它继续扩展，同时保持相同的 inode = 与以下相同的形式）。
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("c\n".utf8))
        try handle.close()

        XCTAssertTrue(v.reloadFromDisk())

        v._testSetCaret(0)
        v._testInsert("X")                       // 此处显示的真实信息变为 piece table
        XCTAssertEqual(v._testDocString, "Xa\nb\nc\n")
    }
}
