import XCTest
@testable import SiftEditorCore

/// **测试是否能够实际通过 ssh**。仅可在可使用密钥访问 localhost 的环境中运行。
/// 如果不输入，则整个程序将为 skip（以防止它因 CI 或其他人的机器而变红）。
///
/// 我们只想看到一件事——**组装好的字符串超出了真正的 ssh
/// 它是否按预期工作？** 在我于 `/bin/sh` (`RemoteFileTests`) 上进行的测试中，
/// 无法验证  / ssh 的参数解释、多路复用和二进制数据传输。
final class RemoteSessionTests: XCTestCase {

    private var fixture: URL!
    private var body: Data!

    override func setUpWithError() throws {
        try skipUnlessLocalSSHWorks()

        // 混合非文本字节。当它通过字符串传递时会损坏，因此请务必注意它是否损坏。
        var bytes = [UInt8]()
        bytes.reserveCapacity(200_000)
        for i in 0..<200_000 {
            let v: Int = (i &* 37 &+ 11) & 0xFF
            bytes.append(UInt8(v))
        }
        body = Data(bytes)

        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-ssh-\(UUID().uuidString).bin")
        try body.write(to: fixture)
    }

    override func tearDown() {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
        super.tearDown()
    }

    private func skipUnlessLocalSSHWorks() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "localhost", "true"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        try XCTSkipUnless(proc.terminationStatus == 0, "localhost へ鍵で ssh できないので飛ばす")
    }

    private func session() throws -> RemoteSession {
        let target = try XCTUnwrap(RemoteFile.parse("ssh localhost:\(fixture.path)"))
        return try RemoteSession.connect(to: target)
    }

    /// 一次往返即可连接并检查另一端的情况。
    func testConnectDetectsCapabilities() throws {
        let s = try session()
        XCTAssertTrue(s.capabilities.canRead)
        XCTAssertTrue(s.capabilities.canSize)
        XCTAssertTrue(s.capabilities.canFollow)
        XCTAssertTrue(s.capabilities.canFilter)
        XCTAssertTrue(s.capabilities.degraded.isEmpty)
    }

    func testSizeMatchesTheRealFile() throws {
        XCTAssertEqual(try session().size(), body.count)
    }

    /// **哪怕只差一个字节也不行。** 如果 `tail -c +N` 的起始字节 1 写错了，
    /// 这是我第一次注意到这个问题（虽然我用 sh 也能注意到，但这是经由 ssh 的不同路径）。
    func testRangeReadsAreByteExactOverSSH() throws {
        let s = try session()
        for probe in [0..<64, 1..<65, 100_000..<100_064, (body.count - 32)..<body.count] {
            let got = try XCTUnwrap(s.read(offset: probe.lowerBound, length: probe.count))
            XCTAssertEqual(got, body.subdata(in: probe), "範囲 \(probe) がズレた")
        }
    }

    /// 未传递字符串。如果将非文本字节替换为替换字符，程序将崩溃。
    func testBinaryBytesSurviveTheRoundTrip() throws {
        let s = try session()
        let got = try XCTUnwrap(s.read(offset: 0, length: 256))
        XCTAssertEqual(got.count, 256)
        XCTAssertEqual(got, body.subdata(in: 0..<256))
        XCTAssertTrue(got.contains(0x00) || got.contains(0xFF) || got.contains(0x80))
    }

    /// 即使您请求的字符超过最后一个字符，它也只会返回它拥有的内容（并且不会返回任何不可用的内容）。
    func testReadingPastTheEndReturnsWhatExists() throws {
        let s = try session()
        let got = try XCTUnwrap(s.read(offset: body.count - 10, length: 500))
        XCTAssertEqual(got, body.subdata(in: (body.count - 10)..<body.count))
    }

    /// 文件不存在时会失败。**它会保留 stderr 不变**，以便人能够理解原因。
    func testMissingRemoteFileFailsLoudly() throws {
        let target = RemoteFile.Target(host: "localhost", path: "/nope/definitely/missing.log")
        let s = try RemoteSession.connect(to: target)
        XCTAssertNil(s.size())
        XCTAssertThrowsError(try RemoteSession.run(
            host: "localhost",
            command: RemoteFile.sizeCommand("/nope/definitely/missing.log"),
            timeout: 10
        )) { error in
            guard case RemoteSession.Failure.failed(_, let stderr) = error else {
                return XCTFail("failed(status:stderr:) を期待した: \(error)")
            }
            XCTAssertFalse(stderr.isEmpty, "理由を握り潰している")
        }
    }

    /// 引号工作正常。**包含空格的路径不能拆分为两个参数。**
    func testPathsWithSpacesWorkOverSSH() throws {
        let spaced = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor ssh \(UUID().uuidString).bin")
        try Data("hello world".utf8).write(to: spaced)
        defer { try? FileManager.default.removeItem(at: spaced) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: spaced.path))
        XCTAssertEqual(s.size(), 11)
        XCTAssertEqual(s.read(offset: 6, length: 5), Data("world".utf8))
    }

    // MARK: - 允许通行至缓冲区。

    /// **从头到尾。** 从 ssh → 范围读取 → 稀疏缓存 → mmap 的完整路径，
    /// 内容必须与原内容完全一致，精确到最后一个字节。
    func testBufferOverSSHMatchesTheOriginal() throws {
        let s = try session()
        let buf = try XCTUnwrap(s.openBuffer())
        XCTAssertEqual(buf.count, body.count)

        XCTAssertEqual(buf.data(in: 0..<100), body.subdata(in: 0..<100))
        XCTAssertEqual(buf.data(in: 150_000..<150_100), body.subdata(in: 150_000..<150_100))

        // 只拍了我看到的 = 我什么都没掉。
        XCTAssertLessThan(buf.fetchedBytes, body.count, "全部引いてしまっている")
    }

    // MARK: - 挤到那边去（实际为 ssh）

    /// **这是远程操作的主要目的。** 返回匹配的行和行号；不转发正文。
    func testGrepOverSSHReturnsLineNumbers() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-grep-\(UUID().uuidString).log")
        var text = ""
        for i in 1...5000 {
            text += (i == 1234 || i == 4321) ? "line \(i) ERROR boom\n" : "line \(i) ok\n"
        }
        try Data(text.utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let hits = try XCTUnwrap(s.grep(pattern: "ERROR"))
        XCTAssertEqual(hits.filter(\.isMatch).map(\.line), [1234, 4321])
        XCTAssertTrue(hits[0].text.contains("ERROR boom"))
    }

    /// **“命中”的含义通常在前一行。** `-C` 在那边工作。
    func testGrepWithContextOverSSH() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-ctx-\(UUID().uuidString).log")
        let text = (1...20).map { $0 == 10 ? "line 10 NEEDLE\n" : "line \($0)\n" }.joined()
        try Data(text.utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let hits = try XCTUnwrap(s.grep(pattern: "NEEDLE", context: 2))
        XCTAssertEqual(hits.map(\.line), [8, 9, 10, 11, 12])
        XCTAssertEqual(hits.filter(\.isMatch).map(\.line), [10])
    }

    /// 零匹配表示“空”，而不是“失败”。
    func testGrepWithNoMatchesIsEmptyNotFailure() throws {
        let s = try session()
        XCTAssertEqual(s.grep(pattern: "この語は絶対に無い-\(UUID().uuidString)")?.count, 0)
    }

    /// 默认值为固定字符串——包含 `.` 的单词不会作为正则表达式运行。
    func testGrepTreatsPatternAsFixedStringByDefault() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-fixed-\(UUID().uuidString).log")
        try Data("aXc\na.c\n".utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let hits = try XCTUnwrap(s.grep(pattern: "a.c"))
        XCTAssertEqual(hits.map(\.line), [2], "固定文字列のはずが aXc にも当たった")
    }


    // MARK: - 结束符和行号（实际为 ssh）

    /// **结尾部分先显示。**它甚至还有一个真实的行号（`wc -l` 在那里运行）。
    func testTailLinesOverSSHCarryRealLineNumbers() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-tail-\(UUID().uuidString).log")
        let text = (1...10_000).map { "line \($0)\n" }.joined()
        try Data(text.utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let total = try XCTUnwrap(s.lineCount())
        XCTAssertEqual(total, 10_000)

        let lines = s.tailLines(bytes: 200, totalLines: total)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(lines.last?.text, "line 10000")
        XCTAssertEqual(lines.last?.number, 10_000)
        // 这些数字从末尾开始按顺序排列。
        for (a, b) in zip(lines, lines.dropFirst()) {
            XCTAssertEqual((a.number ?? 0) + 1, b.number ?? 0)
        }
    }

    /// 要获取文件的末尾，不要减去整个文件。
    func testTailDoesNotTransferTheWholeFile() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-tailsize-\(UUID().uuidString).log")
        let text = (1...200_000).map { "line \($0)\n" }.joined()
        try Data(text.utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let lines = s.tailLines(bytes: 4096)
        XCTAssertLessThan(lines.count, 500, "末尾だけのはずが \(lines.count) 行来た")
        XCTAssertTrue(lines.last?.text.hasPrefix("line 200000") ?? false)
    }

    /// 筛选结果可以直接粘贴（剪贴板充当界面）。
    func testSearchLinesCanBeCopiedAsPlainBody() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-copy-\(UUID().uuidString).log")
        try Data("a\nNEEDLE one\nb\nNEEDLE two\n".utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }

        let s = try RemoteSession.connect(to: RemoteFile.Target(host: "localhost", path: log.path))
        let lines = try XCTUnwrap(s.searchLines(pattern: "NEEDLE"))
        XCTAssertEqual(RemoteLines.plainText(lines), "NEEDLE one\nNEEDLE two")
    }

}
