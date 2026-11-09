import XCTest
@testable import SiftEditorCore

/// 这是从传入的字节序列中提取完整行的地方。
///
/// **块边界位于行的中间。** 如果按原样输出，则一行将被拆分为两行并显示。
/// 此外，在跟踪过程中，可能会被解读为“日志里是这么说的”。请修复边界处理问题。
final class LineAccumulatorTests: XCTestCase {

    func testCompleteLinesComeOutWhole() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data("a\nb\nc\n".utf8)), ["a", "b", "c"])
    }

    /// **除非出现换行符，否则不要创建新行。**
    func testPartialTailIsHeldBack() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data("a\nb".utf8)), ["a"])
        XCTAssertEqual(acc.take(Data("cd\n".utf8)), ["bcd"])
    }

    /// 即使逐字节到达，也不会出错。
    func testByteByByteDeliveryStillYieldsWholeLines() {
        var acc = LineAccumulator()
        var out: [String] = []
        for byte in Data("hello\nworld\n".utf8) {
            out += acc.take(Data([byte]))
        }
        XCTAssertEqual(out, ["hello", "world"])
    }

    /// 在只收到换行符的事件中，出现了一个空行（这是一个真正的空行，所以不要删除它）。
    func testEmptyLinesArePreserved() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data("\n\n".utf8)), ["", ""])
    }

    func testEmptyChunkYieldsNothing() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data()), [])
    }

    /// CRLF 中的 `\r` 将被删除。如果保留，则会在行尾添加不可见字符。
    /// 只有将它们进行比较时才会发现区别，这使得理解变得困难。
    func testCarriageReturnIsStripped() {
        var acc = LineAccumulator()
        XCTAssertEqual(acc.take(Data("a\r\nb\r\n".utf8)), ["a", "b"])
    }

    /// 流程结束后，提取最后一行不以换行符结尾的行。
    func testFlushYieldsTheUnterminatedTail() {
        var acc = LineAccumulator()
        _ = acc.take(Data("done\nhalf".utf8))
        XCTAssertEqual(acc.flush(), ["half"])
        XCTAssertEqual(acc.flush(), [], "2 回目は空（無理に 1 行を作らない）")
    }

    func testFlushOnCleanEndYieldsNothing() {
        var acc = LineAccumulator()
        _ = acc.take(Data("done\n".utf8))
        XCTAssertEqual(acc.flush(), [])
    }

    /// 即使你向它提供不包含换行符的连续数据流，它也不会消耗内存。
    func testHugePendingWithoutNewlineIsDropped() {
        var acc = LineAccumulator()
        let chunk = Data(repeating: 0x41, count: 1 << 20)
        for _ in 0..<5 { _ = acc.take(chunk) }
        XCTAssertLessThanOrEqual(acc.flush().first?.count ?? 0, LineAccumulator.maxPending)
    }

    /// 与一种简单的实现方式进行比较。**无论采用何种分割方法，结果都必须相同。**
    func testAnyChunkingProducesTheSameLines() {
        let text = "one\ntwo\n\nthree\nfour\r\nfive\n"
        let expected = ["one", "two", "", "three", "four", "five"]
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<200 {
            var acc = LineAccumulator()
            var out: [String] = []
            let bytes = Array(text.utf8)
            var i = 0
            while i < bytes.count {
                let n = Int.random(in: 1...7, using: &rng)
                let hi = min(i + n, bytes.count)
                out += acc.take(Data(bytes[i..<hi]))
                i = hi
            }
            out += acc.flush()
            XCTAssertEqual(out, expected)
        }
    }
}
