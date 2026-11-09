import XCTest
@testable import SiftEditorCore

/// 验证  / `FetchedRanges`。
///
/// 如果这是错误的，损坏之处不在于“无法打开”，而在于**“部分文本将被默默地填充为零”**。
/// 稀疏文件中的空洞可以用 mmap 读取为零，因此简单的实现需要与之匹配。
/// 随机匹配（边界、邻接和包含的组合不能手动排列）。
final class FetchedRangesTests: XCTestCase {

    /// 参考端：一个毋庸置疑的实现，它只是检查每个字节是否已被检索。
    private struct Naive {
        var have: Set<Int> = []
        mutating func insert(_ r: Range<Int>) { for i in r { have.insert(i) } }
        func missing(in r: Range<Int>) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var run: Int? = nil
            for i in r {
                if have.contains(i) {
                    if let s = run { out.append(s..<i); run = nil }
                } else if run == nil {
                    run = i
                }
            }
            if let s = run { out.append(s..<r.upperBound) }
            return out
        }
    }

    // MARK: - 基本

    func testEmptyHasEverythingMissing() {
        XCTAssertEqual(FetchedRanges().missing(in: 0..<100), [0..<100])
        XCTAssertFalse(FetchedRanges().contains(0..<1))
    }

    func testInsertThenContains() {
        var f = FetchedRanges()
        f.insert(10..<20)
        XCTAssertTrue(f.contains(10..<20))
        XCTAssertTrue(f.contains(12..<15))
        XCTAssertFalse(f.contains(9..<20))
        XCTAssertFalse(f.contains(10..<21))
    }

    func testMissingReportsGapsOnly() {
        var f = FetchedRanges()
        f.insert(10..<20)
        f.insert(30..<40)
        XCTAssertEqual(f.missing(in: 0..<50), [0..<10, 20..<30, 40..<50])
        XCTAssertEqual(f.missing(in: 15..<35), [20..<30])
        XCTAssertEqual(f.missing(in: 10..<20), [])
    }

    /// 相邻元素是连通的。填充 4KB 区间可将区间数量增加到数万个，搜索效率将呈线性增长。
    func testAdjacentRangesAreCoalesced() {
        var f = FetchedRanges()
        f.insert(0..<10)
        f.insert(10..<20)
        f.insert(20..<30)
        XCTAssertEqual(f.ranges, [0..<30])
    }

    func testOverlappingRangesAreMerged() {
        var f = FetchedRanges()
        f.insert(0..<10)
        f.insert(5..<25)
        f.insert(20..<30)
        XCTAssertEqual(f.ranges, [0..<30])
    }

    /// 即使以任何顺序输入字符，也能得到相同的形状（前瞻功能在两个方向上延伸）。
    func testInsertionOrderDoesNotMatter() {
        var a = FetchedRanges()
        for r in [(30..<40), (0..<10), (10..<20)] { a.insert(r) }
        var b = FetchedRanges()
        for r in [(10..<20), (30..<40), (0..<10)] { b.insert(r) }
        XCTAssertEqual(a.ranges, b.ranges)
        XCTAssertEqual(a.ranges, [0..<20, 30..<40])
    }

    func testEmptyRangeIsIgnored() {
        var f = FetchedRanges()
        f.insert(10..<10)
        XCTAssertTrue(f.ranges.isEmpty)
        XCTAssertEqual(f.missing(in: 5..<5), [])
    }

    func testFetchedBytes() {
        var f = FetchedRanges()
        f.insert(0..<10)
        f.insert(100..<130)
        XCTAssertEqual(f.fetchedBytes, 40)
        f.insert(5..<105)          // 所有设备均已连接
        XCTAssertEqual(f.fetchedBytes, 130)
    }

    func testRemoveAll() {
        var f = FetchedRanges([0..<10])
        f.removeAll()
        XCTAssertEqual(f.missing(in: 0..<10), [0..<10])
    }

    // MARK: - 随机化并与简单实现进行比较

    /// 边界、邻接和包含关系的组合无法手动排列。**即使漏掉一个字节的间隙……
    /// 它将在那里显示为零，因此请检查直到它与简单的基于字节的实现相匹配。
    func testMatchesNaiveImplementationUnderRandomInserts() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<200 {
            var fast = FetchedRanges()
            var slow = Naive()

            for _ in 0..<12 {
                let lo = Int.random(in: 0..<80, using: &rng)
                let len = Int.random(in: 0..<20, using: &rng)
                fast.insert(lo..<(lo + len))
                slow.insert(lo..<(lo + len))
            }

            for _ in 0..<12 {
                let lo = Int.random(in: 0..<80, using: &rng)
                let len = Int.random(in: 0..<30, using: &rng)
                let query = lo..<(lo + len)
                XCTAssertEqual(
                    fast.missing(in: query), slow.missing(in: query),
                    "trial \(trial) query \(query) ranges \(fast.ranges)"
                )
            }

            // 规范化的不变条件：升序，无重叠，无相邻元素，非空。
            for r in fast.ranges { XCTAssertFalse(r.isEmpty) }
            for (a, b) in zip(fast.ranges, fast.ranges.dropFirst()) {
                XCTAssertLessThan(a.upperBound, b.lowerBound, "隣接か重なりが残っている")
            }
        }
    }
}
