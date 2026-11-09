import XCTest
@testable import SiftEditorCore

/// 读取和捆绑文件 (`MergedLogBuilder`)。
///
/// 实际上每个文件的格式都不同，所以这是重点。
/// 当  / nginx（Apache 格式）、应用程序日志（ISO）和 DB（syslog）捆绑在一起时，
/// 如果我们坚持对整个内容采用单一格式，其中一行将变成连续的一行，时间顺序将被打乱。
final class MergedLogBuilderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("merge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ name: String, _ body: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try body.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    /// 使用  / JST 进行汇编（因为结果不会受到执行环境时区的影响）。
    private var builder: MergedLogBuilder {
        MergedLogBuilder(displayOffset: 9 * 3600, assumedOffset: 9 * 3600, assumedYear: 2026)
    }

    private let nginx = """
    10.0.1.4 - - [30/Jul/2026:12:34:55 +0900] "GET /health HTTP/1.1" 200 2
    10.0.1.9 - alice [30/Jul/2026:12:34:57 +0900] "POST /api/checkout HTTP/1.1" 500 512
    """

    private let app = """
    2026-07-30T12:34:56.120+09:00 INFO  checkout start order=88213
    2026-07-30T12:34:57.004+09:00 ERROR NullPointerException in Checkout.pay
        at com.example.Checkout.pay(Checkout.java:88)
    """

    private let db = """
    Jul 30 12:34:56 db-1 postgres[812]: LOG:  duration: 41.2 ms
    Jul 30 12:34:58 db-1 postgres[812]: LOG:  duration: 3208.9 ms
    """

    /// 即使混合了三种格式，每个文件都会被评判并合并成一个时间线。
    func testMergesThreeDifferentFormats() throws {
        let a = try write("nginx-access.log", nginx)
        let b = try write("app.log", app)
        let c = try write("db-syslog.log", db)

        let r = try builder.build(urls: [a, b, c], into: dir)
        XCTAssertEqual(r.sources.map { $0.format },
                       [.apache, .iso8601, .syslog],
                       "形式はファイルごとに決めること")
        XCTAssertTrue(r.warnings.isEmpty)

        let body = try String(contentsOf: r.url, encoding: .utf8)
        let rows = body.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)

        // 12:34:55 nginx → 12:34:56.120 app → 12:34:56 db … 按此顺序列出。
        let labels = rows.map { row -> String in
            let parts = row.split(separator: "│", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count >= 2 ? parts[1] : ""
        }
        XCTAssertEqual(labels, ["nginx-access", "db-syslog", "app", "nginx-access", "app", "app", "db-syslog"])
    }

    /// 输出中的时间列单调递增（= 排序正常工作的最短可能确认时间）。
    func testOutputTimestampsAreMonotonic() throws {
        let a = try write("nginx-access.log", nginx)
        let b = try write("app.log", app)
        let r = try builder.build(urls: [a, b], into: dir)

        let stamps = try String(contentsOf: r.url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { String($0.prefix(23)) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(stamps, stamps.sorted(), "束ねた結果の時刻は増加していること")
    }

    /// 续行时间字段留空。因为它会直接继承父行的时间。
    /// 如果你在那里输入一个数字，它看起来就像“该行本身的运行时间”，但这是不实的。
    func testContinuationLinesHaveBlankTimeColumn() throws {
        let a = try write("app.log", app)
        let b = try write("db-syslog.log", db)
        let r = try builder.build(urls: [a, b], into: dir)

        let stackLine = try String(contentsOf: r.url, encoding: .utf8)
            .split(separator: "\n")
            .first { $0.contains("Checkout.java:88") }
        XCTAssertNotNil(stackLine)
        XCTAssertTrue(String(stackLine!.prefix(23)).trimmingCharacters(in: .whitespaces).isEmpty,
                      "継続行の時刻欄は空であること")
    }

    /// 所有行都将始终输出（标题行除外）。
    func testEveryInputLineAppears() throws {
        let a = try write("nginx-access.log", nginx)
        let b = try write("app.log", app)
        let c = try write("db-syslog.log", db)
        let r = try builder.build(urls: [a, b, c], into: dir)

        let expected = nginx.split(separator: "\n").count
            + app.split(separator: "\n").count
            + db.split(separator: "\n").count
        XCTAssertEqual(r.totalLines, expected)
    }

    /// 同名文件通过目录名进行区分。这种情况总是出现在主机收集的日志中。
    func testDuplicateBaseNamesGetParentDirectoryInLabel() throws {
        for host in ["web-1", "web-2"] {
            let sub = dir.appendingPathComponent(host)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try app.write(to: sub.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)
        }
        let urls = ["web-1", "web-2"].map { dir.appendingPathComponent($0).appendingPathComponent("app.log") }
        let r = try builder.build(urls: urls, into: dir)
        XCTAssertEqual(r.sources.map { $0.label }, ["web-1/app", "web-2/app"])
    }

    /// 没有时间戳的文件会被移到文件末尾，并发出相应的警告（它们不会被默默地混入其中）。
    func testTimestamplessFileIsReportedAndPlacedLast() throws {
        let a = try write("app.log", app)
        let b = try write("notes.txt", "just some notes\nno timestamps at all\n")
        let r = try builder.build(urls: [a, b], into: dir)

        XCTAssertNil(r.sources[1].format)
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertTrue(r.warnings[0].contains("notes.txt"))

        let rows = try String(contentsOf: r.url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertTrue(rows.suffix(2).allSatisfy { $0.contains("notes") },
                      "時刻を持たない行は末尾に並ぶ")
    }

    /// 文本文件通常以换行符结尾。如果您保留由末尾换行符创建的空白行……
    /// **其中混杂着仅包含标签的空行，对应于文件数量**（在实际硬件上发现）。
    func testTrailingNewlineDoesNotAddPhantomLine() throws {
        let a = try write("app.log", app + "\n")            // 以换行符结尾
        let b = try write("db-syslog.log", db + "\n")
        let r = try builder.build(urls: [a, b], into: dir)

        XCTAssertEqual(r.sources[0].lineCount, 3, "app.log は3行（幻の空行を数えない）")
        XCTAssertEqual(r.sources[1].lineCount, 2)
        XCTAssertEqual(r.totalLines, 5)

        let rows = try String(contentsOf: r.url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
        // 缺少包含“时间 | 标签 | 空”的行。
        for row in rows {
            let parts = row.split(separator: "│", maxSplits: 2, omittingEmptySubsequences: false)
            XCTAssertFalse(parts.count == 3 && parts[2].trimmingCharacters(in: .whitespaces).isEmpty,
                           "本文が空の行が残っている: \(row)")
        }
    }

    func testRefusesSingleFile() throws {
        let a = try write("app.log", app)
        XCTAssertThrowsError(try builder.build(urls: [a], into: dir))
    }

    /// 也可以读取  / Shift-JIS 的日志（通过绕过现有的字符编码检测）。
    func testReadsShiftJISInput() throws {
        let u = dir.appendingPathComponent("sjis.log")
        let text = "2026-07-30T12:34:56+09:00 エラー 在庫が足りません\n"
        try text.data(using: .shiftJIS)!.write(to: u)
        let b = try write("app.log", app)

        let r = try builder.build(urls: [u, b], into: dir)
        let body = try String(contentsOf: r.url, encoding: .utf8)
        XCTAssertTrue(body.contains("在庫が足りません"), "Shift-JIS が文字化けせず読めること")
    }
}
