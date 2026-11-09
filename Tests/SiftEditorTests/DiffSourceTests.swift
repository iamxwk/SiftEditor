import XCTest
@testable import SiftEditorCore

/// diff 的输入（内存中的文件/文本）。
/// **能够读懂这些行**至关重要。左侧有空格的 diff 毫无意义。
final class DiffSourceTests: XCTestCase {

    private func tempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("difftest-\(UUID().uuidString).log")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// FileDiffSource 无法在主线程上创建（在等待索引完成时会冻结），因此在后台创建。
    private func makeFileSource(_ url: URL) throws -> FileDiffSource {
        var result: FileDiffSource?
        let done = expectation(description: "source")
        DispatchQueue.global().async {
            result = FileDiffSource(url: url)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result)
    }

    func testFileSourceReadsLines() throws {
        let url = try tempFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try makeFileSource(url)

        XCTAssertEqual(src.lineCount, 3)
        XCTAssertEqual(src.line(at: 0), "one")
        XCTAssertEqual(src.line(at: 1), "two")
        XCTAssertEqual(src.line(at: 2), "three")
        XCTAssertEqual(src.lineHashes().count, 3)
    }

    func testFileSourceWithJapaneseAndCRLF() throws {
        let url = try tempFile("あいう\r\nかきく\r\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try makeFileSource(url)
        XCTAssertEqual(src.line(at: 0), "あいう")   // CR 将不会保留。
        XCTAssertEqual(src.line(at: 1), "かきく")
    }

    func testTextSourceReadsLines() {
        let src = TextDiffSource(text: "one\ntwo\nthree\n", displayName: "clip")
        XCTAssertEqual(src.lineCount, 3)
        XCTAssertEqual(src.line(at: 0), "one")
        XCTAssertEqual(src.line(at: 2), "three")
    }

    /// 文件和剪贴板中的相同内容将产生相同的哈希值（即，差异为零）。
    /// 如果此项未对齐，则会显示“即使我比较的是相同的项目，所有行也都不同”。
    func testFileAndTextAgreeOnIdenticalContent() throws {
        let text = "alpha\nbravo\ncharlie\n"
        let url = try tempFile(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try makeFileSource(url)
        let t = TextDiffSource(text: text, displayName: "clip")

        XCTAssertEqual(f.lineCount, t.lineCount)
        XCTAssertEqual(f.lineHashes(), t.lineHashes())

        let ops = LineDiff.compute(f.lineHashes(), t.lineHashes())
        XCTAssertEqual(ops, [.equal(left: 0, right: 0, count: 3)])
    }
}

/// 用于重现应用程序中左侧列变为空白的问题。
/// 能否读取日志（4,000 行）中间的行？
extension DiffSourceTests {
    func testFileSourceReadsMiddleLineOfLargerFile() throws {
        let lines = (0..<4000).map { "2026-06-26 12:00:00.\(String(format: "%03d", $0 % 1000)) [INFO] request_id=\($0)" }
        let url = try tempFile(lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try makeFileSource(url)

        XCTAssertEqual(src.lineCount, 4000)
        XCTAssertEqual(src.line(at: 0), lines[0])
        XCTAssertEqual(src.line(at: 117), lines[117])     // 应用程序中空白的部分
        XCTAssertEqual(src.line(at: 3999), lines[3999])
    }
}

/// URL 对比入口点。下载本身（网络）不予测量。
/// **不要信任输入** 转换，并完善创建标题的方法。
extension DiffSourceTests {
    func testCompareURLNormalizeAcceptsHTTPS() {
        XCTAssertEqual(CompareURL.normalize("https://example.com/a.log")?.absoluteString,
                       "https://example.com/a.log")
        // 删除开头和结尾的空格和换行符（源自复制粘贴）。
        XCTAssertEqual(CompareURL.normalize("  https://example.com/a.log\n")?.absoluteString,
                       "https://example.com/a.log")
    }

    func testCompareURLNormalizeRejectsNonHTTPS() {
        XCTAssertNil(CompareURL.normalize(""))
        XCTAssertNil(CompareURL.normalize("   "))
        // ，纯文本 http，被实际的 ATS 拒绝。它在入口点被拒绝（以避免重现测量值 -1022）。
        XCTAssertNil(CompareURL.normalize("http://example.com/a.log"))
        XCTAssertNil(CompareURL.normalize("example.com/a.log"))          // 无方案
        XCTAssertNil(CompareURL.normalize("file:///etc/passwd")) // 本地 file 已被阻止
        XCTAssertNil(CompareURL.normalize("javascript:alert(1)"))
        XCTAssertNil(CompareURL.normalize("https://"))                   // 无主机
        XCTAssertNil(CompareURL.normalize("ftp://example.com/x"))
    }

    func testCompareURLDisplayName() {
        XCTAssertEqual(CompareURL.displayName(for: URL(string: "https://example.com/logs/app.log")!),
                       "app.log")
        // 如果路径没有尾随后缀，则主机名将用作标头。
        XCTAssertEqual(CompareURL.displayName(for: URL(string: "https://example.com/")!),
                       "example.com")
        XCTAssertEqual(CompareURL.displayName(for: URL(string: "https://example.com")!),
                       "example.com")
    }

    /// URL 的源代码显示了原始标题，而不是临时文件名（重命名为 FileDiffSource）。
    func testFileSourceHonorsDisplayNameOverride() throws {
        let url = try tempFile("a\nb\n")
        defer { try? FileManager.default.removeItem(at: url) }
        var result: FileDiffSource?
        let done = expectation(description: "source")
        DispatchQueue.global().async {
            result = FileDiffSource(url: url, displayName: "app.log")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(try XCTUnwrap(result).displayName, "app.log")
    }
}
