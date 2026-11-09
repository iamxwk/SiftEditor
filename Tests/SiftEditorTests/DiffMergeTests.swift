import XCTest
@testable import SiftEditorCore

/// 合并导出。**此处操作失误会损坏其他人的文件。**
///
/// 箭头方向为**→**（将左侧内容向右移动）。因此，**右侧是结果**。
/// 只有应用的代码块才会包含左侧的内容。逐字节检查结果。
final class DiffMergeTests: XCTestCase {

    private let lf: [UInt8] = [0x0A]

    private func hashes(_ lines: [String]) -> [LineHash] {
        lines.map { line in
            var h = LineHasher()
            for b in line.utf8 { h.feed(b) }
            return h.value
        }
    }

    /// 从左右行创建 diff，采用指定的块，并返回合并结果。
    private func merged(_ leftLines: [String], _ rightLines: [String],
                        adopt: (DiffModel) -> Set<Int>) throws -> String {
        let l = TextDiffSource(text: leftLines.joined(separator: "\n") + "\n", displayName: "L")
        let r = TextDiffSource(text: rightLines.joined(separator: "\n") + "\n", displayName: "R")
        let model = DiffModel(ops: LineDiff.compute(hashes(leftLines), hashes(rightLines)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        try model.writeMerged(left: l, right: r, applied: adopt(model), eol: lf, to: out)
        try out.close()
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 如果什么都不应用，**右侧将保持原样**（不会破坏底座）。
    func testApplyNothingReproducesRight() throws {
        let left = ["a", "b", "c", "d"]
        let right = ["a", "X", "d", "e"]
        let out = try merged(left, right) { _ in [] }
        XCTAssertEqual(out, "a\nX\nd\ne\n")
    }

    /// 如果全部应用，**左侧将保持原样**（左侧的所有内容将移至右侧）。
    func testApplyEverythingReproducesLeft() throws {
        let left = ["a", "b", "c", "d"]
        let right = ["a", "X", "d", "e"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nb\nc\nd\n")
    }

    /// 应用  / 更改 (replace) 将把右侧的内容更改为左侧的内容。
    func testApplyReplace() throws {
        let left = ["a", "b", "c"]
        let right = ["a", "B", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    /// 应用仅存在于左侧的行 (delete) 将导致该行**向右移动**。
    func testApplyDeleteAddsTheLineToRight() throws {
        let left = ["a", "b", "c"]
        let right = ["a", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    /// 应用仅存在于右侧的行 (insert) 将导致该行**从右侧消失**（与左侧对齐）。
    func testApplyInsertRemovesTheLineFromRight() throws {
        let left = ["a", "c"]
        let right = ["a", "b", "c"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "a\nc\n")
    }

    /// 如果未应用，则仅存在于右侧的行将保持不变。
    func testRejectInsertKeepsTheLine() throws {
        let left = ["a", "c"]
        let right = ["a", "b", "c"]
        let out = try merged(left, right) { _ in [] }
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    /// 选择 Hank（仅适用于第一个）。合并的正确用法。
    func testApplySomeHunksOnly() throws {
        let left  = ["h", "old", "m", "keep", "t"]
        let right = ["h", "new", "m", "t"]          // 1) old↔new 2) keep 仅在左侧
        let out = try merged(left, right) { m in
            let hunks = m.hunkOpIndices
            XCTAssertEqual(hunks.count, 2)
            return [hunks[0]]                        // 仅应用第一个。
        }
        // 将  old 向右移动。不要移动 keep。
        XCTAssertEqual(out, "h\nold\nm\nt\n")
    }

    /// 不拆分日语（多字节）字符。
    func testJapaneseLines() throws {
        let left = ["あいう", "かきく", "さしす"]
        let right = ["あいう", "KAKIKU", "さしす"]
        let out = try merged(left, right) { m in Set(m.hunkOpIndices) }
        XCTAssertEqual(out, "あいう\nかきく\nさしす\n")
    }

    /// 使用文件（通过 mmap）也能得到相同的结果。这是实际操作中使用的路径。
    func testMergeFromFileSource() throws {
        let dir = FileManager.default.temporaryDirectory
        let lURL = dir.appendingPathComponent("mL-\(UUID().uuidString).log")
        let rURL = dir.appendingPathComponent("mR-\(UUID().uuidString).log")
        try "a\nb\nc\n".write(to: lURL, atomically: true, encoding: .utf8)
        try "a\nB\nc\nd\n".write(to: rURL, atomically: true, encoding: .utf8)   // 右图：B 和 d
        defer { try? FileManager.default.removeItem(at: lURL); try? FileManager.default.removeItem(at: rURL) }

        var srcs: (FileDiffSource, FileDiffSource)?
        let done = expectation(description: "sources")
        DispatchQueue.global().async {
            if let l = FileDiffSource(url: lURL), let r = FileDiffSource(url: rURL) { srcs = (l, r) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let (l, r) = try XCTUnwrap(srcs)

        let model = DiffModel(ops: LineDiff.compute(l.lineHashes(), r.lineHashes()))
        let outURL = dir.appendingPathComponent("mOut-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        try model.writeMerged(left: l, right: r, applied: Set(model.hunkOpIndices), eol: lf, to: out)
        try out.close()
        defer { try? FileManager.default.removeItem(at: outURL) }

        // 全部应用 = 左侧的内容移到右侧（B → b，d 将被删除）。
        XCTAssertEqual(try String(contentsOf: outURL, encoding: .utf8), "a\nb\nc\n")
    }
}

/// 重现保存的结果与实际设备上的结果不符的情况。
/// 左侧 a.log、右侧 b.log，只应用第一个（replace）操作后的输出。
extension DiffMergeTests {
    func testRealCaseApplyFirstHunkOnly() throws {
        let left  = ["header", "old-line", "middle", "keep-me", "tail"]
        let right = ["header", "new-line", "middle", "tail", "extra"]
        // ops: equal / replace / equal / delete(keep-me) / equal / insert(extra)
        let out = try merged(left, right) { m in
            let hunks = m.hunkOpIndices
            XCTAssertEqual(hunks.count, 3, "差分は 3 箇所のはず: \(m.ops)")
            return [hunks[0]]                   // 仅第一个（replace）适用。
        }
        // 右侧是基数。只有 replace 取左侧 → new-line 变为 old-line。
        // keep-me 将不会被占用（不会移至右侧）。extra 将保持不变。
        XCTAssertEqual(out, "header\nold-line\nmiddle\ntail\nextra\n")
    }
}
