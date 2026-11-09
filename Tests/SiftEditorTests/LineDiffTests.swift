import XCTest
@testable import SiftEditorCore

/// 线路 diff。**切勿忽略差异**，这才是关键。
/// 使用不变条件“将 op 应用于左侧得到右侧”，我们验证即使随机选择也不会破坏它。
final class LineDiffTests: XCTestCase {

    private func hashes(_ lines: [String]) -> [LineHash] {
        lines.map { line in
            var h = LineHasher()
            for b in line.utf8 { h.feed(b) }
            return h.value
        }
    }

    /// 我们能否将  / ops 应用于左侧矩阵以重建右侧矩阵？
    /// 只要接受这一点，就不会出现“疏忽差异”或“编造故事”的情况。
    private func apply(_ ops: [DiffOp], to left: [String], expecting right: [String]) -> [String] {
        var out: [String] = []
        for op in ops {
            switch op {
            case let .equal(l, _, c):            out.append(contentsOf: left[l..<(l + c)])
            case .delete:                        break
            case let .insert(r, c):              out.append(contentsOf: right[r..<(r + c)])
            case let .replace(_, _, r, rc):      out.append(contentsOf: right[r..<(r + rc)])
            }
        }
        return out
    }

    private func check(_ a: [String], _ b: [String], file: StaticString = #filePath, line: UInt = #line) {
        let ops = LineDiff.compute(hashes(a), hashes(b))
        XCTAssertEqual(apply(ops, to: a, expecting: b), b, "適用結果が右と一致しない", file: file, line: line)
    }

    func testIdentical() {
        let a = ["x", "y", "z"]
        let ops = LineDiff.compute(hashes(a), hashes(a))
        XCTAssertEqual(ops, [.equal(left: 0, right: 0, count: 3)])
    }

    func testInsertInMiddle() {
        check(["a", "b", "d"], ["a", "b", "c", "d"])
    }

    func testDeleteInMiddle() {
        check(["a", "b", "c", "d"], ["a", "d"])
    }

    func testReplaceIsCoalesced() {
        // 不是删除了又添加了，而是“覆盖”了（因为这里应用了内联差异）。
        let ops = LineDiff.compute(hashes(["a", "x", "c"]), hashes(["a", "y", "c"]))
        XCTAssertEqual(ops, [
            .equal(left: 0, right: 0, count: 1),
            .replace(left: 1, leftCount: 1, right: 1, rightCount: 1),
            .equal(left: 2, right: 2, count: 1),
        ])
    }

    func testEmptySides() {
        check([], ["a", "b"])
        check(["a", "b"], [])
        check([], [])
    }

    func testNothingInCommon() {
        check(["a", "b", "c"], ["x", "y", "z"])
    }

    /// 同一行重复多次的情况，导致无法创建锚点（这种情况在日志中经常发生）。
    func testHighlyRepetitiveLines() {
        let a = [String](repeating: "same", count: 200) + ["tail"]
        let b = ["head"] + [String](repeating: "same", count: 200)
        check(a, b)
    }

    /// 巨大的非锚定部分折叠成 replace（即使你放弃了，它也不会说谎 = 它可以恢复）。
    func testHugeUnanchoredBlockFoldsToReplace() {
        let a = (0..<3000).map { _ in "dup" }
        let b = (0..<3000).map { _ in "other" }
        let ops = LineDiff.compute(hashes(a), hashes(b))
        XCTAssertEqual(apply(ops, to: a, expecting: b), b)
        XCTAssertEqual(ops.count, 1)
        guard case .replace = ops[0] else { return XCTFail("replace に畳まれていない: \(ops)") }
    }

    /// 随机选择。像写日志一样，通过“重写、插入和删除一些行”来创建右侧，并观察来回变化。
    func testRandomEdits() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<200 {
            let n = Int.random(in: 0...80, using: &rng)
            let a = (0..<n).map { "line \($0 % 17)" }   // 故意创建重复项
            var b = a
            for _ in 0..<Int.random(in: 0...10, using: &rng) {
                guard !b.isEmpty else { b.append("new"); continue }
                switch Int.random(in: 0...2, using: &rng) {
                case 0: b.insert("ins \(Int.random(in: 0...99, using: &rng))", at: Int.random(in: 0...b.count, using: &rng))
                case 1: b.remove(at: Int.random(in: 0..<b.count, using: &rng))
                default: b[Int.random(in: 0..<b.count, using: &rng)] = "mod \(Int.random(in: 0...99, using: &rng))"
                }
            }
            let ops = LineDiff.compute(hashes(a), hashes(b))
            XCTAssertEqual(apply(ops, to: a, expecting: b), b, "trial \(trial): a=\(a) b=\(b) ops=\(ops)")
        }
    }

    /// 不要因为  / CRLF 和 LF 之间存在差异就说“所有线路都不同”。
    func testCRLFAndLFHashTheSame() {
        let lf = Array("a\nb\n".utf8)
        let crlf = Array("a\r\nb\r\n".utf8)
        let h1 = lf.withUnsafeBytes { LineHasher.hashLines($0) }
        let h2 = crlf.withUnsafeBytes { LineHasher.hashLines($0) }
        XCTAssertEqual(h1, h2)
    }
}

/// 行内字符差异。
final class CharDiffTests: XCTestCase {

    func testSingleCharChange() {
        let (l, r) = CharDiff.ranges(left: "status=200", right: "status=500")
        XCTAssertEqual(l, [7..<8])
        XCTAssertEqual(r, [7..<8])
    }

    func testInsertionOnly() {
        let (l, r) = CharDiff.ranges(left: "abc", right: "abXc")
        XCTAssertEqual(l, [])
        XCTAssertEqual(r, [2..<3])
    }

    func testIdenticalHasNoRanges() {
        let (l, r) = CharDiff.ranges(left: "同じ行", right: "同じ行")
        XCTAssertTrue(l.isEmpty && r.isEmpty)
    }

    /// 表情符号和组合字符不拆分（以 Character 为单位计数）。
    func testGraphemeSafety() {
        let (l, r) = CharDiff.ranges(left: "あ👨‍👩‍👦い", right: "あ👨‍👩‍👦う")
        XCTAssertEqual(l, [2..<3])
        XCTAssertEqual(r, [2..<3])
    }

    /// 对于过长的行，跳过行内差异（不要运行 DP）。
    func testVeryLongLineFallsBack() {
        let a = String(repeating: "a", count: CharDiff.maxLineLength + 1)
        let b = String(repeating: "b", count: CharDiff.maxLineLength + 1)
        let (l, r) = CharDiff.ranges(left: a, right: b)
        XCTAssertEqual(l, [0..<a.count])
        XCTAssertEqual(r, [0..<b.count])
    }
}
