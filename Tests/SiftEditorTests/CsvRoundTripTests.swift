import XCTest
@testable import SiftEditorCore

/// byte 表示是否可以“缩小范围、更正并**以原始格式**保存”。
///
/// 由 Threads 于 2026-09-05 提问：
/// “我能否在使用此编辑器保存的同时，保留 CSV 的滤镜、处理和格式？”
/// 如果您只是想打开并查看它，似乎有很多选项。
///
/// 实际数据（所有公司记录 CSV）为 **Shift-JIS + CRLF + 报价**，这三者容易出错。
/// 打开并保存  / Excel 的文件会更改字符编码、换行符，并重新添加引号。
///
/// 这表明的并非“不会出错”，而是“没有一个字节会经过未被触及的部分”。
/// piece table 以原始字节的形式保存原始数据，其存储结构会将原始数据的片段原样写入。
/// 编辑行之外的文本**不进行转换**。因此，无需对 BOM、CRLF 或引号进行“保留处理”。
final class CsvRoundTripTests: XCTestCase {

    /// Shift-JIS + CRLF + 引号 CSV 组合在一起（与实际形式相同）。
    private func makeSjisCsv(rows: Int) -> [UInt8] {
        var out: [UInt8] = []
        let prefectures = ["北海道", "青森県", "東京都", "大阪府", "沖縄県"]
        let names = ["釧路検察審査会", "伊達簡易裁判所", "株式会社テスト", "有限会社サンプル"]
        for i in 0..<rows {
            let line = "\(i + 1),100001216\(i % 10)153,01,1,2018-04-02,2015-10-05,"
                + "\"\(names[i % names.count])\",,101,\"\(prefectures[i % prefectures.count])\","
                + "\"釧路市\",\"柏木町４−７\",,01,206,0850824\r\n"
            out += Array(line.data(using: .shiftJIS)!)
        }
        return out
    }

    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-csv-\(UUID().uuidString).csv")
        try Data(bytes).write(to: url)
        return url
    }

    /// 该行“内容”的范围。`PieceTable.byteRange(ofLine:)` 不包括 LF，但包括 **CR**。
    /// 与应用程序类似，最后一位数字 CR 被丢弃（与 `PieceTableViewer.contentRange(ofLine:)` 的规则相同）。
    /// **CRLF 被保留，因为 CR 超出了编辑范围**，而不是因为在保存期间添加了它。
    private func contentRange(_ pt: PieceTable, line: Int) -> Range<Int> {
        var r = pt.byteRange(ofLine: line)
        if r.upperBound > r.lowerBound,
           pt.bytes(in: (r.upperBound - 1)..<r.upperBound).first == 0x0D {
            r = r.lowerBound..<(r.upperBound - 1)
        }
        return r
    }

    /// 通过与  / piece table 相同的保存路径 (`writeAll`) 写入数据。
    private func save(_ pt: PieceTable, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".sifteditor-save-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: tmp.path, contents: nil))
        let handle = try FileHandle(forWritingTo: tmp)
        try pt.writeAll { try handle.write(contentsOf: Data($0)) }
        try handle.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// 筛选 → 重写匹配的行之一 → 保存。
    /// 除了重写的行之外，它与原版完全相同，甚至连一个字节都没有差别。
    func testFilterEditSaveKeepsEveryOtherByte() throws {
        let original = makeSjisCsv(rows: 2_000)
        let url = try write(original)
        defer { try? FileManager.default.removeItem(at: url) }

        // 打开（与实际应用程序相同的 mmap 路由）。
        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }
        let encoding = EncodingDetector.detect(Data(original.prefix(64 << 10)))
        XCTAssertEqual(encoding, .shiftJIS, "実物と同じく Shift-JIS と判定される")

        let pt = PieceTable(original: FileBufferSource(buffer))

        // ── 1. 缩小搜索范围（使用搜索引擎匹配 Shift-JIS） ──────────────
        let engine = SearchEngine(buffer: buffer, encoding: encoding)
        var matched: [Int] = []
        let done = expectation(description: "search")
        engine.search(SearchMode.terms(["東京都"]), progress: { _, _ in }, completion: { result in
            matched = result.lines
            done.fulfill()
        })
        wait(for: [done], timeout: 30)
        XCTAssertEqual(matched.count, 400, "5 県を回しているので 2000 行中 400 行が東京都")

        // ── 2. 重写其中一行匹配的文本 ────────────────────────────────
        let target = matched[10]
        let range = contentRange(pt, line: target)
        let before = pt.bytes(in: range)
        XCTAssertTrue(String(data: Data(before), encoding: .shiftJIS)!.contains("東京都"))

        // 也使用 Shift-JIS 字节输入（与应用程序的输入路径相同）。
        let replacement = Array("\"東京都\",\"千代田区\"".data(using: .shiftJIS)!)
        pt.delete(range)
        pt.insert(replacement, at: range.lowerBound)

        // ── 3. 保存 ──────────────────────────────────────────────────
        try save(pt, to: url)
        let saved = [UInt8](try Data(contentsOf: url))

        // ── 4. 未修改的部分没有一个字节发生变化 ──────────────
        let head = range.lowerBound
        let tailFrom = range.upperBound                       // 原文件的续篇
        let savedTailFrom = range.lowerBound + replacement.count
        XCTAssertEqual(Array(saved[0..<head]), Array(original[0..<head]),
                       "書き換えた行より前が原本と一致する")
        XCTAssertEqual(Array(saved[savedTailFrom...]), Array(original[tailFrom...]),
                       "書き換えた行より後ろが原本と一致する")

        // ── 5. 格式保持不变（结果已确认） ────────────────────
        XCTAssertEqual(EncodingDetector.detect(Data(saved.prefix(64 << 10))), .shiftJIS,
                       "Shift-JIS のまま（UTF-8 に化けない）")
        XCTAssertEqual(saved.filter { $0 == 0x0D }.count, original.filter { $0 == 0x0D }.count,
                       "CRLF の CR が減っていない（LF だけに落ちていない）")
        XCTAssertEqual(saved.filter { $0 == 0x22 }.count,
                       original.filter { $0 == 0x22 }.count - before.filter { $0 == 0x22 }.count
                           + replacement.filter { $0 == 0x22 }.count,
                       "引用符が付け直されていない（書き換えた行のぶんだけ増減する）")
        XCTAssertNil(String(data: Data(saved.prefix(3)), encoding: .utf8).flatMap {
                        $0.hasPrefix("\u{FEFF}") ? $0 : nil },
                     "無かった BOM が足されていない")
    }

    /// BOM 与 UTF-8 相同。BOM 不是一个“存储进程”，而是原始进程的前 3 个字节。
    /// 直接通过即可。
    func testUtf8BomSurvivesAnEdit() throws {
        var original: [UInt8] = [0xEF, 0xBB, 0xBF]
        original += Array("id,name\r\n1,\"あ\"\r\n2,\"い\"\r\n".utf8)
        let url = try write(original)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }
        let pt = PieceTable(original: FileBufferSource(buffer))
        let range = contentRange(pt, line: 2)                  // ，第 3 行（从 0 开始计数）
        pt.delete(range)
        pt.insert(Array("2,\"う\"".utf8), at: range.lowerBound)
        try save(pt, to: url)

        let saved = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(saved.prefix(3)), [0xEF, 0xBB, 0xBF], "BOM がそのまま残る")
        XCTAssertEqual(saved.filter { $0 == 0x0D }.count, 3, "CRLF が 3 本のまま")
        // 匹配对象为 byte。`String(data:encoding:.utf8)` **消耗 BOM**。
        // 将  转换为字符串并不能使其成为检查“BOM”是否仍然存在的测试。
        var expected: [UInt8] = [0xEF, 0xBB, 0xBF]
        expected += Array("id,name\r\n1,\"あ\"\r\n2,\"う\"\r\n".utf8)
        XCTAssertEqual(saved, expected)
    }

    /// 对  / 实际数据（所有公司记录，例如 1.06GB 和 CSV）执行相同的操作。如果 testdata 不存在，则使用 skip。
    ///   SIFTEDITOR_REAL_CSV_TEST=1 swift test --filter CsvRoundTripTests
    func testRealHoujinCsvSlice() throws {
        guard ProcessInfo.processInfo.environment["SIFTEDITOR_REAL_CSV_TEST"] == "1" else {
            throw XCTSkip("SIFTEDITOR_REAL_CSV_TEST=1 のときだけ走る（実ファイルが要る）")
        }
        let source = URL(fileURLWithPath: "testdata/houjin_zenken_sjis.csv")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("testdata/houjin_zenken_sjis.csv が無い")
        }
        // 提取  的第一部分，64MB（注意不要在行中间切断，直到最后一个 CRLF）。
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var slice = [UInt8](handle.readData(ofLength: 64 << 20))
        while let last = slice.last, last != 0x0A { slice.removeLast() }

        let url = try write(slice)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }

        XCTAssertEqual(EncodingDetector.detect(Data(slice.prefix(64 << 10))), .shiftJIS)
        let pt = PieceTable(original: FileBufferSource(buffer))
        let range = contentRange(pt, line: 1_000)
        pt.delete(range)
        pt.insert(Array("EDITED".utf8), at: range.lowerBound)
        try save(pt, to: url)

        let saved = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(saved[0..<range.lowerBound]), Array(slice[0..<range.lowerBound]))
        XCTAssertEqual(Array(saved[(range.lowerBound + 6)...]), Array(slice[range.upperBound...]))
        XCTAssertEqual(saved.filter { $0 == 0x0D }.count, slice.filter { $0 == 0x0D }.count)
    }

    /// 可以使用与应用程序相同的流程对整个实际项目进行筛选、更正和保存。
    /// 匹配由调用方 (scripts/prove_csv_roundtrip.sh) 使用 cmp / xxd 完成，
    /// 此部分**实际上重写了工作副本**，并且仅显示所用时间。
    ///   SIFTEDITOR_CSV_WORK=<副本路径> swift test --filter testRealHoujinCsvWhole
    func testRealHoujinCsvWhole() throws {
        guard let path = ProcessInfo.processInfo.environment["SIFTEDITOR_CSV_WORK"] else {
            throw XCTSkip("需要 SIFTEDITOR_CSV_WORK（由 scripts/prove_csv_roundtrip.sh 调用）")
        }
        let url = URL(fileURLWithPath: path)
        let term = ProcessInfo.processInfo.environment["SIFTEDITOR_CSV_TERM"] ?? "東京都"

        func stamp(_ label: String, _ seconds: Double, _ extra: String = "") {
            print(String(format: "  %-28s %7.2f s  %@", (label as NSString).utf8String!, seconds, extra))
        }

        // ── 打开（mmap。无需阅读全文） ──────────────────────────────
        var t = Date()
        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失败") }
        let head = try FileHandle(forReadingFrom: url)
        let encoding = EncodingDetector.detect(head.readData(ofLength: 64 << 10))
        try? head.close()
        let pt = PieceTable(original: FileBufferSource(buffer))
        stamp("打开", Date().timeIntervalSince(t), "\(buffer.count) byte / \(encoding.displayName)")

        // -- 缩小范围（全扫描） --------------------------------------------------
        t = Date()
        let engine = SearchEngine(buffer: buffer, encoding: encoding)
        var matched: [Int] = []
        let done = expectation(description: "search")
        engine.search(SearchMode.terms([term]), progress: { _, _ in }, completion: {
            matched = $0.lines; done.fulfill()
        })
        wait(for: [done], timeout: 600)
        stamp("筛选(\(term))", Date().timeIntervalSince(t), "匹配 \(matched.count) 行")
        XCTAssertFalse(matched.isEmpty)

        // -- 正确（添加到匹配行的末尾） ----------------------------------
        t = Date()
        let target = matched[matched.count / 2]
        let range = contentRange(pt, line: target)
        pt.insert(Array(",\"SiftEditor で直した\"".data(using: .shiftJIS)!), at: range.upperBound)
        stamp("修改", Date().timeIntervalSince(t), "第 \(target + 1) 行")

        // -- 保存 --------------------------------------------------
        t = Date()
        try save(pt, to: url)
        stamp("保存", Date().timeIntervalSince(t), "\(pt.byteCount) byte")
    }

    /// 仅测量筛选所花费的时间（不包括保存时间）。结果将写入 SIFTEDITOR_CSV_LOG。
    /// ── swift test 的标准输出难以捕获，因此写入文件。
    ///   SIFTEDITOR_CSV_MEASURE=<CSV> swift test --filter testMeasureFilterOnly
    func testMeasureFilterOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["SIFTEDITOR_CSV_MEASURE"] else {
            throw XCTSkip("需要 SIFTEDITOR_CSV_MEASURE")
        }
        let url = URL(fileURLWithPath: path)
        let term = ProcessInfo.processInfo.environment["SIFTEDITOR_CSV_TERM"] ?? "東京都"
        guard let buffer = FileBuffer(url: url) else { return XCTFail("mmap 失敗") }
        let head = try FileHandle(forReadingFrom: url)
        let encoding = EncodingDetector.detect(head.readData(ofLength: 64 << 10))
        try? head.close()

        let t = Date()
        let engine = SearchEngine(buffer: buffer, encoding: encoding)
        var matched = 0
        let done = expectation(description: "search")
        engine.search(SearchMode.terms([term]), progress: { _, _ in }, completion: {
            matched = $0.lineCount; done.fulfill()
        })
        wait(for: [done], timeout: 900)
        let secs = Date().timeIntervalSince(t)

        let line = "\(encoding.displayName)\t\(buffer.count) byte\t\(term)\t"
            + "\(matched) 行\t\(String(format: "%.2f", secs)) s\n"
        if let log = ProcessInfo.processInfo.environment["SIFTEDITOR_CSV_LOG"] {
            FileManager.default.createFile(atPath: log, contents: nil)
            try? line.write(toFile: log, atomically: true, encoding: .utf8)
        }
        print(line)
    }
}
