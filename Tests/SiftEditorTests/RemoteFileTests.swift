import XCTest
@testable import SiftEditorCore

/// 这是  / `RemoteFile` 中无需连接即可确定的部分。**所有无需设置服务器即可修复的问题都在这里修复。**
/// 如果在另一端执行的字符串不正确，则损坏之处不是“无法打开”，而是“文本主体显示时有 1 字节的偏移”。
final class RemoteFileTests: XCTestCase {

    // MARK: - 如何分配目的地

    func testParsesSshPrefixedTarget() {
        XCTAssertEqual(
            RemoteFile.parse("ssh web01:/var/log/app.log"),
            RemoteFile.Target(host: "web01", path: "/var/log/app.log")
        )
    }

    func testParsesBareHostColonPath() {
        XCTAssertEqual(
            RemoteFile.parse("user@web01:/var/log/app.log"),
            RemoteFile.Target(host: "user@web01", path: "/var/log/app.log")
        )
    }

    /// 不接受相对路径。用户无法看到另一端的当前目录，也无法展开 `~`。
    /// 由于 shell 操作导致的失控行为 = “您打算打开的位置”与实际位置不同。
    func testRejectsRelativeRemotePath() {
        XCTAssertNil(RemoteFile.parse("web01:var/log/app.log"))
        XCTAssertNil(RemoteFile.parse("web01:~/app.log"))
    }

    /// 我不认为驱动器盘符  / Windows 是远程的。
    func testRejectsWindowsDriveLetter() {
        XCTAssertNil(RemoteFile.parse("C:/Users/hitoshi/app.log"))
    }

    func testLocalPathIsNotRemote() {
        XCTAssertNil(RemoteFile.parse("/var/log/app.log"))
        XCTAssertNil(RemoteFile.parse("app.log"))
    }

    // MARK: - 一串字符在那里运行

    /// 如果不换行，路径将变成命令。
    ///
    /// **在真正的 shell 中来回传递它。** 即使你目测确认它有“引号”，
    /// `sh` 的实际拆分方式是另一个故事。另一边还有 POSIX 和 sh，所以这些信息应该足够了。
    func testShellQuoteSurvivesRealShellRoundTrip() throws {
        let nasty = [
            "/tmp/a'; rm -rf /tmp/should-not-exist; echo '",
            "/var/log/my app.log",
            "/tmp/$(whoami)/x.log",
            "/tmp/`id`/x.log",
            "/tmp/a\"b\"c.log",
            "/tmp/a\\b.log",
            "/tmp/tab\tsep.log",
        ]
        for path in nasty {
            let out = try shell("printf '%s' \(RemoteFile.shellQuote(path))")
            XCTAssertEqual(out, path, "引用が壊れた: \(path)")
        }
    }

    /// 实际验证组装好的命令是否只会查看另一端的**特定路径**。
    /// ssh 也是 sh，因此在我的 sh 上运行相同的字符串将具有相同的含义。
    func testReadCommandReadsTheRightBytesThroughRealShell() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-read-\(UUID().uuidString).log")
        let body = "0123456789abcdefghij"
        try Data(body.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try shell(RemoteFile.readCommand(url.path, offset: 0, length: 5)), "01234")
        XCTAssertEqual(try shell(RemoteFile.readCommand(url.path, offset: 10, length: 5)), "abcde")
        // 即使您请求的数量超过最后一位数字，您也将收到所有可用的数量（它不会谎称数量不足）。
        XCTAssertEqual(try shell(RemoteFile.readCommand(url.path, offset: 18, length: 99)), "ij")
    }

    func testSizeCommandReturnsRealByteCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-size-\(UUID().uuidString).log")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(RemoteFile.parseSize(try shell(RemoteFile.sizeCommand(url.path))), 4096)
    }

    /// **`wc` 或 BSD 应在开头添加空格，并在结尾添加换行符。** GNU 不应添加空格。
    /// 只有在通过真正的 shell 运行后，这种差异才变得明显，所以我将两者都保持固定。
    func testParseSizeAcceptsBothBsdAndGnuFormats() {
        XCTAssertEqual(RemoteFile.parseSize("    4096\n"), 4096)   // BSD
        XCTAssertEqual(RemoteFile.parseSize("4096\n"), 4096)       // GNU
        XCTAssertEqual(RemoteFile.parseSize("4096"), 4096)
    }

    /// 如果无法读取，请写入“未知”。**请勿写入 0**（无法检索和 0 字节是不同的情况）。
    func testParseSizeReturnsNilRatherThanZero() {
        XCTAssertNil(RemoteFile.parseSize(""))
        XCTAssertNil(RemoteFile.parseSize("wc: /nope: No such file\n"))
        XCTAssertNil(RemoteFile.parseSize("4096 /var/log/app.log\n"))  // 如果您忘记了  `<`，它将被赋予一个名称。
    }

    /// 和那边运行的 `/bin/sh -c` 一样。
    private func shell(_ command: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testShellQuoteHandlesSpaces() {
        XCTAssertEqual(RemoteFile.shellQuote("/var/log/my app.log"), "'/var/log/my app.log'")
    }

    /// `tail -c +N` 是从 1 开始计数的。**如果输入错误，文本将向右移动一个字节。**
    func testReadCommandOffsetIsOneBased() {
        XCTAssertEqual(
            RemoteFile.readCommand("/var/log/app.log", offset: 100, length: 4096),
            "tail -c +101 < '/var/log/app.log' | head -c 4096"
        )
    }

    /// 如果从头开始，请勿插入 tail（以防止在大文件中重复计数）。
    func testReadCommandFromStartSkipsTail() {
        XCTAssertEqual(
            RemoteFile.readCommand("/var/log/app.log", offset: 0, length: 65_536),
            "head -c 65536 < '/var/log/app.log'"
        )
    }

    func testSizeCommandUsesWcNotStat() {
        // stat 的格式与 BSD 和 GNU 不同。wc 至 c 为 POSIX。
        let cmd = RemoteFile.sizeCommand("/var/log/app.log")
        XCTAssertEqual(cmd, "wc -c < '/var/log/app.log'")
        XCTAssertFalse(cmd.contains("stat"))
    }

    // MARK: - 能力検出

    func testCapabilitiesParsesPresentCommands() {
        let caps = RemoteFile.Capabilities.parse("wc\nhead\ntail\ngrep\n")
        XCTAssertTrue(caps.canRead)
        XCTAssertTrue(caps.canSize)
        XCTAssertTrue(caps.canFollow)
        XCTAssertTrue(caps.canFilter)
        XCTAssertTrue(caps.degraded.isEmpty)
    }

    /// BusyBox，或在受限 shell 中缺失。**请折叠，但务必提供理由。**
    func testCapabilitiesReportsWhatItFoldedAndWhy() {
        let caps = RemoteFile.Capabilities.parse("head\n")
        XCTAssertTrue(caps.canRead)          // 可读取。
        XCTAssertFalse(caps.canSize)
        XCTAssertFalse(caps.canFollow)
        XCTAssertFalse(caps.canFilter)
        XCTAssertEqual(caps.degraded.count, 3)
        XCTAssertEqual(caps.degraded, [L("remote.degraded.noWc"), L("remote.degraded.noTail"), L("remote.degraded.noGrep")])
    }

    /// 如果没有  / `head`，就无法检索到任何字节 = 无法打开。
    func testCapabilitiesWithoutHeadCannotRead() {
        XCTAssertFalse(RemoteFile.Capabilities.parse("wc\ntail\n").canRead)
    }

    func testCapabilityCommandAsksEverythingInOneRoundTrip() {
        let cmd = RemoteFile.capabilityCommand()
        for name in ["wc", "head", "tail", "grep"] {
            XCTAssertTrue(cmd.contains("command -v \(name)"), "\(name) を訊いていない")
        }
        XCTAssertFalse(cmd.contains("\n"), "1 回の接続で訊く（改行で分けない）")
    }

    // MARK: - ssh 的参数

    /// **不要因套接字路径长度而导致程序崩溃。** macOS 的 `sun_path` 为 104，
    /// `NSTemporaryDirectory()` (`/var/folders/…`) + `%C` 实际上溢出了
    /// -- 由于这是它第一次通过实际的 ssh 出现，我们将在这里修复长度条件。
    func testControlPathFitsInAUnixSocket() {
        let path = RemoteFile.controlPath()
        XCTAssertTrue(
            RemoteFile.controlPathFits(path),
            "ControlPath が長すぎる（\(path.utf8.count) + 展開分 > \(RemoteFile.socketPathLimit)）: \(path)"
        )
        XCTAssertFalse(path.hasPrefix("/var/folders"), "長い一時ディレクトリを使っている")
    }

    /// 如果长度过长，则会放弃多路复用。**这是一种加速机制；即使没有它，也能读取。**
    func testTooLongControlPathDisablesMultiplexingRatherThanFailing() {
        XCTAssertFalse(RemoteFile.controlPathFits(String(repeating: "x", count: 100)))
    }

    /// 不要终止  / `ssh_config` 进程。唯一需要添加的是冗余设置和“不请求终端”。
    func testSshArgumentsMultiplexAndDoNotKillUserConfig() {
        let args = RemoteFile.sshArguments(host: "web01", remoteCommand: "wc -c < '/a'")
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("-T"))
        XCTAssertEqual(args.last, "wc -c < '/a'")
        XCTAssertEqual(args[args.count - 2], "web01")
        // 添加  BatchMode 会导致立即崩溃，原因是密码验证和未知主机密钥（询问 SSH_ASKPASS）。
        XCTAssertFalse(args.contains { $0.contains("BatchMode") })
        // 请勿忽略用户设置。
        XCTAssertFalse(args.contains("-F"))
    }

    // MARK: - 把它挤到那边去

    /// 中奖号码为 `:` 和 `-C`，附带号码为 `-`。
    func testParseGrepSeparatesMatchesFromContext() {
        let out = "10-before\n11:hit\n12-after\n--\n99:another\n"
        let m = RemoteFile.parseGrep(out)
        XCTAssertEqual(m.map(\.line), [10, 11, 12, 99])
        XCTAssertEqual(m.map(\.isMatch), [false, true, false, true])
        XCTAssertEqual(m[1].text, "hit")
    }

    /// **`:` 也可以包含在正文中。** 如果您不仅以第一个分隔符分隔，
    /// 包含  / URL 或时间戳的行已损坏。
    func testParseGrepSplitsOnFirstSeparatorOnly() {
        let m = RemoteFile.parseGrep("42:12:34:56 GET https://x/y?a=1\n")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].line, 42)
        XCTAssertEqual(m[0].text, "12:34:56 GET https://x/y?a=1")
    }

    func testParseGrepIgnoresGroupSeparatorsAndBlanks() {
        XCTAssertTrue(RemoteFile.parseGrep("--\n\n").isEmpty)
    }

    /// 丢弃没有行号的输出（例如，如果忘记了 `-n`，则没有意义）。
    func testParseGrepDropsLinesWithoutNumbers() {
        XCTAssertTrue(RemoteFile.parseGrep("grep: /nope: No such file or directory\n").isEmpty)
    }

    /// 默认值为固定字符串。您可以直接搜索包含 `.` 或 `*` 的单词。
    func testGrepCommandDefaultsToFixedStrings() {
        let cmd = RemoteFile.grepCommand("/a.log", pattern: "a.b*c")
        XCTAssertTrue(cmd.contains(" -F "))
        XCTAssertFalse(cmd.contains(" -E "))
        XCTAssertTrue(cmd.contains("-n"))
    }

    func testGrepCommandRegexAndContextAndCase() {
        let cmd = RemoteFile.grepCommand("/a.log", pattern: "ERR(OR)?", context: 3, ignoreCase: true, regex: true)
        XCTAssertTrue(cmd.contains(" -E "))
        XCTAssertTrue(cmd.contains("-i"))
        XCTAssertTrue(cmd.contains("-C 3"))
    }

    /// 如果没有匹配项，grep 返回 1。**“未找到”并非失败**，所以请稍等。
    func testGrepCommandSwallowsNoMatchExitCode() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("grep-exit-\(UUID().uuidString).log")
        try "alpha\nbeta\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        func status(_ cmd: String) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(try status(RemoteFile.grepCommand(file.path, pattern: "zzz")), 0, "無かったは失敗ではない")
        XCTAssertEqual(try status(RemoteFile.grepCommand(file.path, pattern: "alpha")), 0)
        // 无效的正则表达式应作为失败返回（而不是转换为“无匹配项”）。
        XCTAssertNotEqual(try status(RemoteFile.grepCommand(file.path, pattern: "a(", regex: true)), 0)
    }

    /// 也支持图案换行。由于它使用 `-e`，因此像 `-v` 这样的单词不会被误认为是国旗。
    func testGrepCommandQuotesPatternAndUsesDashE() {
        let cmd = RemoteFile.grepCommand("/a.log", pattern: "'; rm -rf /; echo '")
        XCTAssertTrue(cmd.contains("-e '"))
        XCTAssertFalse(cmd.contains("; rm -rf /; echo ") && !cmd.contains("'\\''"))
    }

    func testTailCommand() {
        XCTAssertEqual(RemoteFile.tailCommand("/a.log", bytes: 65536), "tail -c 65536 < '/a.log'")
    }


    /// **原始 `tail -f` 数据在输出最后 10 行后开始跟踪。**
    /// 将此添加到已经显示行尾的屏幕会导致同一行出现两次，因此我们明确指定 `-n 0`。
    func testFollowCommandEmitsNothingBeforeFollowing() {
        let cmd = RemoteFile.followCommand("/a.log", bytes: 0)
        XCTAssertTrue(cmd.contains("-n 0"), "既定の 10 行が再送される: \(cmd)")
        XCTAssertTrue(cmd.contains("-f"))
    }

    /// 保留在发布最新数据后跟踪的选项（如果您在打开后立即跟踪）。
    func testFollowCommandCanPrimeWithBytes() {
        XCTAssertTrue(RemoteFile.followCommand("/a.log", bytes: 4096).hasPrefix("tail -c 4096 -f '/a.log'"))
    }

    /// **如果断开连接，另一端也会停止。** 由于 PTY 未被分配，SIGHUP 将不会飞行。
    /// 除非在实际硬件上写入 -- 3，否则  / `tail -f` 将不会注意到 EPIPE。
    /// 我把它落下了。我会让它监听标准输入，然后用 EOF 自杀。
    func testFollowCommandKillsItselfWhenTheConnectionCloses() {
        let cmd = RemoteFile.followCommand("/a.log", bytes: 0)
        XCTAssertTrue(cmd.contains("cat > /dev/null"), "標準入力を見張っていない: \(cmd)")
        XCTAssertTrue(cmd.contains("kill $p"), "見張った後に殺していない: \(cmd)")
    }
}
