import XCTest
@testable import SiftEditorCore

/// 测量读取时间的速度。通常情况下，它是 skip。
/// 使用  / `SIFTEDITOR_BENCH=1 swift test --filter TimestampBench` 运行。
///
/// 时间合并“读取并重新排列所有多个日志”，因此每行的成本为
/// 这就是您将直接体验到的。索引 9 秒。点击此处查看此速度是否令人尴尬。
/// 测量以避免根据猜测编写已发布的值。
final class TimestampBenchTests: XCTestCase {

    /// 两位数和三位数数字的零填充。一种避免使用 `String(format:)` 的工具。
    private func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// 构建一个与实际日志非常相似的分布（80% 带有时间戳，20% 带有续行）。
    ///
    /// ⚠️ **请勿使用 `String(format:)`。** 返回值将由 NSString 推导得出。
    /// 字符串 Swift 没有原生连续缓冲区。每次都是 `withUTF8`
    /// 要进行复制，您测量的不是您自己的代码，而是**桥接成本**。
    /// (实际测量 2026-08-04：**1.26 → 11.73 M 线/s**。这就是造成 9 倍差异的原因）。
    /// 实际操作中使用的代码行来自读取自定义文件，因此它们是原生代码。它们是使用插值法组装的。
    private func makeLines(_ count: Int) -> [String] {
        var lines: [String] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            if i % 5 == 4 {
                lines.append("    at com.example.Service.handle(Service.java:\(i % 400))")
            } else {
                let s = 1_785_414_896 + i / 3
                let t = TimestampDetector.civilFromDays(s / 86_400)
                let rem = s % 86_400
                lines.append("\(t.year)-\(pad(t.month, 2))-\(pad(t.day, 2))T"
                             + "\(pad(rem / 3600, 2)):\(pad((rem % 3600) / 60, 2)):\(pad(rem % 60, 2))"
                             + ".\(pad(i % 1000, 3))Z INFO request id=\(i) done in \(i % 900)ms")
            }
        }
        return lines
    }

    func testParseAllThroughput() throws {
        guard ProcessInfo.processInfo.environment["SIFTEDITOR_BENCH"] == "1" else {
            throw XCTSkip("SIFTEDITOR_BENCH=1 で時刻読み取りのベンチを実行")
        }
        let n = 2_000_000
        let lines = makeLines(n)
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)

        let t0 = Date()
        let times = d.parseAll(lines)
        let sec = Date().timeIntervalSince(t0)

        let hits = times.compactMap { $0 }.count
        print(String(format: "parseAll: %.3f 秒 / %d 行 (%.2f M行/s・命中 %d)",
                     sec, n, Double(n) / sec / 1_000_000, hits))
        XCTAssertEqual(times.count, n)
    }

    func testMergeThroughput() throws {
        guard ProcessInfo.processInfo.environment["SIFTEDITOR_BENCH"] == "1" else {
            throw XCTSkip("SIFTEDITOR_BENCH=1 で統合のベンチを実行")
        }
        let per = 500_000
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)
        let sources = (0..<4).map { k in
            LogMerger.Source(label: "host-\(k)",
                             times: d.parseAll(makeLines(per)),
                             clockOffset: Double(k))
        }

        let t0 = Date()
        let merged = LogMerger.merge(sources)
        let sec = Date().timeIntervalSince(t0)

        print(String(format: "merge: %.3f 秒 / %d 行 × %d 本 (%.2f M行/s)",
                     sec, per, sources.count, Double(merged.count) / sec / 1_000_000))
        XCTAssertEqual(merged.count, per * sources.count)
    }

    /// 请使用实际文件进行测量。如有 `testdata/test_50mb_jp.log`，请使用该编号。
    func testRealFileThroughput() throws {
        guard ProcessInfo.processInfo.environment["SIFTEDITOR_BENCH"] == "1" else {
            throw XCTSkip("SIFTEDITOR_BENCH=1 で実ファイルのベンチを実行")
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("testdata/test_50mb_jp.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("testdata/test_50mb_jp.log がない")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let t0 = Date()
        let detector = TimestampDetector.detect(sampleLines: Array(lines.prefix(200)))
        let detectSec = Date().timeIntervalSince(t0)

        guard let detector else {
            print("実ファイル: 時刻形式を検出せず（\(lines.count) 行）")
            return
        }
        let t1 = Date()
        let times = detector.parseAll(lines)
        let sec = Date().timeIntervalSince(t1)
        let hits = times.compactMap { $0 }.count
        print(String(format: "実ファイル(%@): 判定 %.4f 秒 / parseAll %.3f 秒 / %d 行 (%.2f M行/s・命中率 %.1f%%)",
                     detector.format.rawValue, detectSec, sec, lines.count,
                     Double(lines.count) / sec / 1_000_000,
                     Double(hits) / Double(lines.count) * 100))
    }
}
