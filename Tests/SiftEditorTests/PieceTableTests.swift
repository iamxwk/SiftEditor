import XCTest
@testable import SiftEditorCore

/// 用于测试的原始定位器（一个简单的实现，它线性扫描原始字节，而不是使用 `LineIndex` 的稀疏索引）。
/// 这是用来验证  / `PieceTable` 与 fuzz 的定位路径。
private final class ByteLocator: OriginalLineLocator {
    private let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    func newlineCount(upTo x: Int) -> Int {
        let hi = min(max(0, x), bytes.count)
        var c = 0
        for i in 0..<hi where bytes[i] == 0x0A { c += 1 }
        return c
    }
    func newlineOffset(ordinal m: Int) -> Int {
        var seen = 0
        for i in 0..<bytes.count where bytes[i] == 0x0A {
            if seen == m { return i }
            seen += 1
        }
        return bytes.count   // 假设不会到达（ordinal < 换行符数量）
    }
}

/// piece table 参考实现（一个直接编辑普通 `[UInt8]` 的简单模型）。
/// fuzz 是测试中与 `PieceTable` 结果进行比较的正确答案。
private struct NaiveDoc {
    var bytes: [UInt8] = []

    mutating func insert(_ b: [UInt8], at off: Int) {
        bytes.insert(contentsOf: b, at: min(max(0, off), bytes.count))
    }
    mutating func delete(_ r: Range<Int>) {
        let lo = max(0, r.lowerBound), hi = min(bytes.count, r.upperBound)
        if lo < hi { bytes.removeSubrange(lo..<hi) }
    }

    private var starts: [Int] {
        var s = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { s.append(i + 1) }
        return s
    }
    private var newlineCount: Int { starts.count - 1 }

    var lineCount: Int {
        guard !bytes.isEmpty else { return 0 }
        return newlineCount + (bytes.last == 0x0A ? 0 : 1)
    }

    func byteRange(ofLine line: Int) -> Range<Int> {
        let lc = lineCount
        guard line >= 0, line < lc else { return 0..<0 }
        let s = starts
        let start = s[line]
        let end = (line < newlineCount) ? s[line + 1] - 1 : bytes.count
        return start..<max(start, end)
    }

    func byteOffset(ofLineStart line: Int) -> Int {
        let lc = lineCount
        let clamped = min(max(0, line), lc)
        if clamped == 0 { return 0 }
        let s = starts
        return (clamped - 1 < newlineCount) ? s[clamped] : bytes.count
    }

    func line(ofByteOffset off: Int) -> Int {
        let t = min(max(0, off), bytes.count)
        var c = 0
        for i in 0..<t where bytes[i] == 0x0A { c += 1 }
        return c
    }
}

/// 用于测试的最终 PRNG（用于可重现的 fuzz）。
private struct LCG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class PieceTableTests: XCTestCase {
    func testSnapshotKeepsUnsavedBytesAfterFurtherEdits() {
        let table = PieceTable(bytes: Array("alpha\nbeta\n".utf8))
        table.insert(Array("new ".utf8), at: 6)
        let frozen = table.snapshot()
        table.delete(0..<6)
        table.insert(Array("other\n".utf8), at: 0)
        var frozenBytes: [UInt8] = []
        frozen.writeAll { frozenBytes.append(contentsOf: $0) }
        XCTAssertEqual(String(decoding: frozenBytes, as: UTF8.self), "alpha\nnew beta\n")
        XCTAssertNotEqual(table.bytes(in: 0..<table.byteCount), frozenBytes)
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: - 単体

    func testEmpty() {
        let t = PieceTable(bytes: [])
        XCTAssertEqual(t.byteCount, 0)
        XCTAssertEqual(t.lineCount, 0)
        XCTAssertEqual(t.bytes(in: 0..<0), [])
        XCTAssertEqual(t.byteRange(ofLine: 0), 0..<0)
    }

    func testInitialContent() {
        let t = PieceTable(bytes: bytes("abc\ndef\nghi"))
        XCTAssertEqual(t.byteCount, 11)
        XCTAssertEqual(t.lineCount, 3)
        XCTAssertEqual(t.bytes(in: 0..<11), bytes("abc\ndef\nghi"))
        XCTAssertEqual(t.byteRange(ofLine: 0), 0..<3)
        XCTAssertEqual(t.byteRange(ofLine: 1), 4..<7)
        XCTAssertEqual(t.byteRange(ofLine: 2), 8..<11)
    }

    func testInsertHeadMidTail() {
        let t = PieceTable(bytes: bytes("Hello"))
        t.insert(bytes(">> "), at: 0)          // head
        t.insert(bytes("-"), at: 5)            // mid: ">> He|llo"
        t.insert(bytes("!"), at: t.byteCount)  // tail
        XCTAssertEqual(t.bytes(in: 0..<t.byteCount), bytes(">> He-llo!"))
    }

    func testInsertNewlinesUpdatesLineCount() {
        let t = PieceTable(bytes: bytes("oneline"))
        XCTAssertEqual(t.lineCount, 1)
        t.insert(bytes("\ntwo\nthree"), at: t.byteCount)
        XCTAssertEqual(t.lineCount, 3)
        XCTAssertEqual(t.byteRange(ofLine: 1), 8..<11)   // "two"
    }

    func testDeleteAcrossPieces() {
        let t = PieceTable(bytes: bytes("abcdef"))
        t.insert(bytes("XYZ"), at: 3)          // "abcXYZdef"
        t.delete(2..<7)                         // remove "cXYZd" → "abef"
        XCTAssertEqual(t.bytes(in: 0..<t.byteCount), bytes("abef"))
        XCTAssertEqual(t.byteCount, 4)
    }

    func testDeleteNewlineMergesLines() {
        let t = PieceTable(bytes: bytes("a\nb\nc"))
        XCTAssertEqual(t.lineCount, 3)
        t.delete(1..<2)                         // remove first "\n" → "ab\nc"
        XCTAssertEqual(t.lineCount, 2)
        XCTAssertEqual(t.byteRange(ofLine: 0), 0..<2)   // "ab"
    }

    func testTrailingNewlineSemantics() {
        XCTAssertEqual(PieceTable(bytes: bytes("a\n")).lineCount, 1)
        XCTAssertEqual(PieceTable(bytes: bytes("a\nb")).lineCount, 2)
        XCTAssertEqual(PieceTable(bytes: bytes("a\n\n")).lineCount, 2)
    }

    func testLineOffsetRoundTrip() {
        let t = PieceTable(bytes: bytes("alpha\nbeta\ngamma\n"))
        for line in 0..<t.lineCount {
            let start = t.byteOffset(ofLineStart: line)
            XCTAssertEqual(t.line(ofByteOffset: start), line)
        }
    }

    // MARK: - 流导出（保存/B3）

    /// writeAll 按顺序读取整个文档，与 `bytes(in:)` 的全空间读取相匹配（包括块边界）。
    func testWriteAllMatchesFullRead() {
        let t = PieceTable(bytes: bytes("abcdef"))
        t.insert(bytes("XYZ"), at: 3)          // "abcXYZdef"
        t.delete(1..<2)                         // "acXYZdef"
        t.insert(bytes("\n123\n"), at: 4)       // 跨越多个部件的配置
        let expected = t.bytes(in: 0..<t.byteCount)
        for chunk in [1, 2, 3, 5, 1024] {       // 用小块越过边界
            var out: [UInt8] = []
            t.writeAll(chunk: chunk) { out.append(contentsOf: $0) }
            XCTAssertEqual(out, expected, "chunk=\(chunk)")
        }
    }

    func testWriteAllEmpty() {
        var out: [UInt8] = []
        PieceTable(bytes: []).writeAll { out.append(contentsOf: $0) }
        XCTAssertEqual(out, [])
    }

    // MARK: - fuzz（与参考实现的比较）

    func testFuzzAgainstNaive() {
        runFuzz(seeds: 1...8) { PieceTable(bytes: $0) }
    }

    /// 保证原始定位器路径（O（stride）快捷方式）与线性扫描路径产生完全相同的结果。
    func testFuzzWithLocatorMatchesNaive() {
        runFuzz(seeds: 1...6) { PieceTable(original: InMemorySource($0), locator: ByteLocator($0)) }
    }

    private func runFuzz(seeds: ClosedRange<UInt64>, make: ([UInt8]) -> PieceTable) {
        let alphabet: [UInt8] = Array("ab\n".utf8)   // 多加换行符。
        for seed in seeds {
            var rng = LCG(seed: seed)
            var naive = NaiveDoc()
            // 初始内容
            let initLen = Int.random(in: 0...40, using: &rng)
            let initBytes = (0..<initLen).map { _ in alphabet.randomElement(using: &rng)! }
            naive.bytes = initBytes
            let table = make(initBytes)

            for _ in 0..<3000 {
                let n = naive.bytes.count
                if n > 0 && Int.random(in: 0...2, using: &rng) == 0 {
                    // delete
                    let lo = Int.random(in: 0..<n, using: &rng)
                    let hi = Int.random(in: lo...n, using: &rng)
                    naive.delete(lo..<hi)
                    table.delete(lo..<hi)
                } else {
                    // insert
                    let off = Int.random(in: 0...n, using: &rng)
                    let len = Int.random(in: 1...6, using: &rng)
                    let b = (0..<len).map { _ in alphabet.randomElement(using: &rng)! }
                    naive.insert(b, at: off)
                    table.insert(b, at: off)
                }

                // 每次检查结构不变量
                XCTAssertEqual(table.byteCount, naive.bytes.count, "byteCount seed=\(seed)")
                XCTAssertEqual(table.bytes(in: 0..<table.byteCount), naive.bytes, "content seed=\(seed)")
                XCTAssertEqual(table.lineCount, naive.lineCount, "lineCount seed=\(seed)")
                for line in 0..<table.lineCount {
                    XCTAssertEqual(table.byteRange(ofLine: line),
                                   naive.byteRange(ofLine: line),
                                   "byteRange line=\(line) seed=\(seed)")
                }
                // 随机偏移行分辨率
                if naive.bytes.count > 0 {
                    let off = Int.random(in: 0...naive.bytes.count, using: &rng)
                    XCTAssertEqual(table.line(ofByteOffset: off),
                                   naive.line(ofByteOffset: off),
                                   "line(ofByteOffset:\(off)) seed=\(seed)")
                }
            }
        }
    }
}
