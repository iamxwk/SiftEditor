import XCTest
@testable import SiftEditorCore

/// 仅扫描扩展文件 (`tail -f`) 的后续部分，并将其添加到改进中。
final class SearchEngineResumeTests: XCTestCase {

    private func run(_ engine: SearchEngine, resume: SearchEngine.Result? = nil) -> SearchEngine.Result {
        let done = expectation(description: "search")
        var out = SearchEngine.Result()
        engine.search(.terms(["ERROR"]), resume: resume, progress: { _, _ in }, completion: { res in
            out = res; done.fulfill()
        })
        wait(for: [done], timeout: 5)
        return out
    }

    func testResumeAddsOnlyTheGrownPartAndRecountsTheUnterminatedTail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-\(UUID().uuidString).log")
        // 最后一行没有换行符（仍不完整）。包含 ERROR。
        try "ok\nERROR a\nok\nERROR b".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try XCTUnwrap(FileBuffer(url: url))
        let engine = SearchEngine(buffer: buffer, encoding: .utf8)

        let first = run(engine)
        XCTAssertEqual(first.lines, [1, 3])          // 统计仍在写入的偶数行。
        XCTAssertEqual(first.resumeLine, 3)           // 从以换行符结尾的行重新开始。

        // 正在写入的行已完成，并添加了两行。
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(" more\nok\nERROR c\n".utf8))
        try h.close()
        XCTAssertNotNil(buffer.remapIfGrownTry())

        let second = run(engine, resume: first)
        XCTAssertEqual(second.lines, [1, 3, 5])       // 不要重复计算 3。
        XCTAssertEqual(second.lineCount, 3)
        XCTAssertEqual(second.resumeLine, 6)
    }
}
