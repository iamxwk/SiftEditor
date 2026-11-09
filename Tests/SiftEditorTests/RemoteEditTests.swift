import XCTest
@testable import SiftEditorCore

/// 将行  / 1 (B12) 通过 **实际的 `/bin/sh`** 进行验证，以确认其重写是否正确。
/// 另一边也是 POSIX sh，因此无需设置服务器即可修复此问题。
/// 当你犯错时造成的损害不是“无法保存”，而是“损坏另一行”，所以要把停止的那一侧加粗。
final class RemoteEditTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(_ content: String, name: String = "app.log") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 在本地计算机上运行已编程的命令并返回退出代码。
    @discardableResult
    private func run(_ path: String, line: Int, old: String, new: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", RemoteFile.replaceLineCommand(path, line: line, old: old, new: new)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 长度相同 = 立即覆盖

    func testSameLengthOverwritesInPlaceAndKeepsInode() throws {
        let url = try make("alpha\nbravo\ncharlie\n")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        let status = try run(url.path, line: 2, old: "bravo", new: "BRAVO")

        XCTAssertEqual(status, RemoteFile.EditOutcome.overwrote.rawValue)
        XCTAssertEqual(try read(url), "alpha\nBRAVO\ncharlie\n")
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "その場の上書きなので inode は変わらない")
    }

    /// 按字节长度比较。日文假名占 3 个字节，因此字符数相同也可能有不同字节长度。
    func testSameByteLengthWithMultibyteText() throws {
        let url = try make("あいう\nxyz\n")
        XCTAssertEqual(try run(url.path, line: 1, old: "あいう", new: "かきく"), 0)
        XCTAssertEqual(try read(url), "かきく\nxyz\n")
    }

    // MARK: - 长度更改 = 重制

    func testLongerReplacementRewrites() throws {
        let url = try make("alpha\nbravo\ncharlie\n")
        let status = try run(url.path, line: 2, old: "bravo", new: "bravo-and-more")
        XCTAssertEqual(status, RemoteFile.EditOutcome.rewrote.rawValue)
        XCTAssertEqual(try read(url), "alpha\nbravo-and-more\ncharlie\n")
    }

    func testShorterReplacementRewrites() throws {
        let url = try make("alpha\nbravo\ncharlie\n")
        XCTAssertEqual(try run(url.path, line: 3, old: "charlie", new: "c"), 20)
        XCTAssertEqual(try read(url), "alpha\nbravo\nc\n")
    }

    func testRewriteKeepsPermissionsAndLeavesNoTempFile() throws {
        let url = try make("a\nb\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        XCTAssertEqual(try run(url.path, line: 1, old: "a", new: "longer"), 20)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o640)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["app.log"], "一時ファイルを残さない")
    }

    func testFirstLineAndLastLineWithoutTrailingNewline() throws {
        let url = try make("first\nmiddle\nlast")
        XCTAssertEqual(try run(url.path, line: 1, old: "first", new: "1st"), 20)
        XCTAssertEqual(try read(url), "1st\nmiddle\nlast")
        XCTAssertEqual(try run(url.path, line: 3, old: "last", new: "the very last"), 20)
        XCTAssertEqual(try read(url), "1st\nmiddle\nthe very last", "末尾に改行が無いファイルに改行を足さない")
    }

    func testClearingALineKeepsTheNewline() throws {
        let url = try make("a\nbb\nc\n")
        XCTAssertEqual(try run(url.path, line: 2, old: "bb", new: ""), 20)
        XCTAssertEqual(try read(url), "a\n\nc\n")
    }

    func testFillingAnEmptyLine() throws {
        let url = try make("a\n\nc\n")
        XCTAssertEqual(try run(url.path, line: 2, old: "", new: "b"), 20)
        XCTAssertEqual(try read(url), "a\nb\nc\n")
    }

    /// 引号、`$`、反引号、`%` 和反斜杠应按原样写入，而不是作为命令执行。
    func testHostileTextIsWrittenLiterally() throws {
        let url = try make("x\nplaceholder\n")
        let nasty = "it's $(rm -rf /tmp/never) `id` 100% \\n \"q\" ; echo hi"
        XCTAssertEqual(try run(url.path, line: 2, old: "placeholder", new: nasty), 20)
        XCTAssertEqual(try read(url), "x\n\(nasty)\n")
    }

    // MARK: - 停止（请勿写入）

    /// 打开后，另一面已经改变。立即停止，以免损坏其他行。
    func testConflictWhenLineDiffersFromWhatWasOpened() throws {
        let url = try make("alpha\nCHANGED\ncharlie\n")
        let status = try run(url.path, line: 2, old: "bravo", new: "x")
        XCTAssertEqual(status, RemoteFile.EditOutcome.conflict.rawValue)
        XCTAssertEqual(try read(url), "alpha\nCHANGED\ncharlie\n")
    }

    /// 如果行未对齐（上方添加了一行），则当主文本不匹配时，程序将停止。
    func testConflictWhenLinesShifted() throws {
        let url = try make("new first line\nalpha\nbravo\n")
        XCTAssertEqual(try run(url.path, line: 2, old: "bravo", new: "x"), 10)
        XCTAssertEqual(try read(url), "new first line\nalpha\nbravo\n")
    }

    /// 即使只有开头部分匹配，旧文本也不会通过（允许向前匹配会破坏长行的后半部分）。
    func testPrefixOfLongerLineIsNotAMatch() throws {
        let url = try make("abcdef\n")
        XCTAssertEqual(try run(url.path, line: 1, old: "abc", new: "xyz"), 10)
        XCTAssertEqual(try read(url), "abcdef\n")
    }

    func testMissingLineIsReported() throws {
        let url = try make("a\n")
        XCTAssertEqual(try run(url.path, line: 5, old: "", new: "x"), RemoteFile.EditOutcome.noSuchLine.rawValue)
        XCTAssertEqual(try read(url), "a\n")
    }

    func testSymlinkIsRefused() throws {
        let real = try make("a\n", name: "real.log")
        let link = dir.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(try run(link.path, line: 1, old: "a", new: "b"), RemoteFile.EditOutcome.notWritable.rawValue)
        XCTAssertEqual(try read(real), "a\n")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "リンクのまま残る")
    }

    func testReadOnlyFileIsRefused() throws {
        let url = try make("a\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        XCTAssertEqual(try run(url.path, line: 1, old: "a", new: "b"), RemoteFile.EditOutcome.notWritable.rawValue)
        XCTAssertEqual(try read(url), "a\n")
    }

    func testMissingFileIsRefused() throws {
        XCTAssertEqual(
            try run(dir.appendingPathComponent("nope.log").path, line: 1, old: "a", new: "b"),
            RemoteFile.EditOutcome.notWritable.rawValue
        )
    }

    /// 当无法在同一文件夹中创建临时文件时，仅拒绝更改长度的编辑。
    /// 允许进行相同长度的编辑。
    func testRewriteIsRefusedWhenDirectoryIsNotWritableButSameLengthStillWorks() throws {
        let url = try make("a\nb\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard !FileManager.default.isWritableFile(atPath: dir.appendingPathComponent("probe").path) else {
            throw XCTSkip("root で動いているため、フォルダの書き込み禁止が効かない")
        }

        XCTAssertEqual(try run(url.path, line: 1, old: "a", new: "longer"), RemoteFile.EditOutcome.cannotCreateTemp.rawValue)
        XCTAssertEqual(try read(url), "a\nb\n")
        XCTAssertEqual(try run(url.path, line: 1, old: "a", new: "z"), 0)
        XCTAssertEqual(try read(url), "z\nb\n")
    }

    // MARK: - 组件

    /// 将整个内容包装在 `sh -c` 中，以便登录 shell 也能与 fish / csh 一起使用。
    func testCommandIsWrappedInShC() {
        XCTAssertTrue(RemoteFile.replaceLineCommand("/a", line: 1, old: "x", new: "y").hasPrefix("sh -c '"))
    }

    func testOutcomeCodesAreStable() {
        // 此值对应于另一侧的脚本。更改此值时，请同时修改两边。
        XCTAssertEqual(RemoteFile.EditOutcome.conflict.rawValue, 10)
        XCTAssertEqual(RemoteFile.EditOutcome.rewrote.rawValue, 20)
    }
}
