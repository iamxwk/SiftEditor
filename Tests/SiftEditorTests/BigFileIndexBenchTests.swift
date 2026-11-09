import XCTest
@testable import SiftEditorCore

/// 10GB 用于测量使用实际文件构建索引所需的时间。README / LP 中包含的数字来源。
/// 我通常使用 skip。我骑车时使用 `SIFTEDITOR_BENCH=1 swift test --filter BigFileIndexBench`。
///
/// 测量是为了避免根据猜测写入已发布的数值。如果数值发生变化，请在此处重新测量并更正 README。
final class BigFileIndexBenchTests: XCTestCase {

    func testIndexBuildTimeOn10GB() throws {
        guard ProcessInfo.processInfo.environment["SIFTEDITOR_BENCH"] == "1" else {
            throw XCTSkip("SIFTEDITOR_BENCH=1 で 10GB の索引ベンチを実行")
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("testdata/test_10gb.log")
        guard let buffer = FileBuffer(url: url) else {
            throw XCTSkip("testdata/test_10gb.log がない（scripts/gen_testdata.py で作る）")
        }

        let index = LineIndex(buffer: buffer)
        let done = expectation(description: "索引完了")
        let t0 = Date()
        index.buildInBackground(progress: { _ in }, completion: { done.fulfill() })
        wait(for: [done], timeout: 600)
        let sec = Date().timeIntervalSince(t0)

        let gb = Double(buffer.count) / 1_073_741_824
        print(String(format: "索引: %.2f 秒 / %.2f GB / %d 行 (%.2f GB/s)",
                     sec, gb, index.displayLineCount, gb / sec))

        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.displayLineCount, 86_420_337)

        // 查找到最后一行。索引完成后，我们只需从最近的稀疏索引点开始计数，即 O (stride)。
        var seekWorst = 0.0
        for _ in 0..<20 {
            let t = Date()
            _ = index.byteOffset(ofLineStart: 86_420_336)
            seekWorst = max(seekWorst, Date().timeIntervalSince(t))
        }
        print(String(format: "最終行へのシーク: 最悪 %.3f ms（20回）", seekWorst * 1000))

        // 索引本身的大小。LP 的“即使有 1 亿行，N KB”就是由此推导出来的。
        let kb = Double(index.indexBytes) / 1024
        let per100M = kb / Double(index.displayLineCount) * 100_000_000
        print(String(format: "疎索引: %.0f KB（%d 行・stride %d）→ 1 億行なら %.0f KB",
                     kb, index.displayLineCount, index.stride, per100M))
    }

    /// “从打开到出现第一行”对应的路径：mmap，估计行数，
    /// 仅能阅读屏幕上显示的最初几十行文字。不包含 AppKit 的实际图形。
    func testTimeToFirstScreenOn10GB() throws {
        guard ProcessInfo.processInfo.environment["SIFTEDITOR_BENCH"] == "1" else {
            throw XCTSkip("SIFTEDITOR_BENCH=1 で 10GB の初期表示ベンチを実行")
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("testdata/test_10gb.log")

        let t0 = Date()
        guard let buffer = FileBuffer(url: url) else { throw XCTSkip("testdata/test_10gb.log がない") }
        let index = LineIndex(buffer: buffer)          // 在这里，我们对开头进行采样并估计行数。
        // 阅读屏幕上出现的前 50 行。
        let end = index.byteOffset(ofLineStart: 50)
        _ = buffer.data(in: 0..<max(1, end))
        let ms = Date().timeIntervalSince(t0) * 1000

        print(String(format: "最初の画面まで: %.1f ms（mmap + 行数見積もり + 先頭50行の読み出し）", ms))
        XCTAssertGreaterThan(index.displayLineCount, 0)
    }
}
