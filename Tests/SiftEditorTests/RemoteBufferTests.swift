import XCTest
@testable import SiftEditorCore

/// 验证  / `RemoteBuffer`。**由于我们将本地文件视为“远程”文件，**因此不需要服务器。
///
/// 我正在看 3 件事。
/// 1. 读取的内容与原始内容完全相同，甚至精确到最后一个字节。
/// 2. **请勿尝试拾取您未曾查看过的区域内的物品**（这与指示阅读范围的标志相同）
/// 3. **无法获取零时，不要显示零**（即使有空格，也可以使文本看起来合理）
final class RemoteBufferTests: XCTestCase {

    private var origin: Data!
    private var cacheURL: URL!
    /// 发送到“远程”位置的请求记录。用于统计之后检索到的数据量。
    private var asked: [Range<Int>] = []

    override func setUp() {
        super.setUp()
        // 内容物由其位置决定，因此您可以立即判断它们是否错位。
        var bytes = [UInt8]()
        bytes.reserveCapacity(256 * 1024)
        for i in 0..<(256 * 1024) {
            let v: Int = (i &* 31 &+ 7) & 0xFF
            bytes.append(UInt8(v))
        }
        origin = Data(bytes)
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-buffer-\(UUID().uuidString).cache")
        asked = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
        super.tearDown()
    }

    /// 从原始文档中提取并返回数据的“远程”服务。记录请求。
    private func makeBuffer(failAfter: Int = .max) -> RemoteBuffer? {
        var served = 0
        return RemoteBuffer(count: origin.count, cacheURL: cacheURL) { [weak self] offset, length in
            self?.asked.append(offset..<(offset + length))
            served += 1
            if served > failAfter { return nil }
            let lo = min(offset, self?.origin.count ?? 0)
            let hi = min(offset + length, self?.origin.count ?? 0)
            guard lo < hi else { return Data() }
            return self?.origin.subdata(in: lo..<hi)
        }
    }

    // MARK: - 内容是否正确？

    func testReadsMatchTheOriginExactly() throws {
        let buf = try XCTUnwrap(makeBuffer())
        for probe in [0..<10, 1000..<2000, 65_000..<66_000, (origin.count - 5)..<origin.count] {
            XCTAssertEqual(buf.data(in: probe), origin.subdata(in: probe), "範囲 \(probe) がズレた")
        }
    }

    func testReadingTheWholeFileMatches() throws {
        let buf = try XCTUnwrap(makeBuffer())
        XCTAssertEqual(buf.data(in: 0..<origin.count), origin)
    }

    func testOutOfRangeIsClampedNotCrashed() throws {
        let buf = try XCTUnwrap(makeBuffer())
        XCTAssertEqual(buf.data(in: -50..<10), origin.subdata(in: 0..<10))
        XCTAssertTrue(buf.data(in: origin.count..<(origin.count + 100)).isEmpty)
        XCTAssertTrue(buf.data(in: 10..<10).isEmpty)
    }

    // MARK: - 不要去取回你没见过的东西。

    /// **这才是“不丢弃”的真正含义。** 如果你只读取了 10 个字节，然后减去整个字节，那就不是范围读取。
    func testReadingASliceDoesNotFetchTheWholeFile() throws {
        let buf = try XCTUnwrap(makeBuffer())
        _ = buf.data(in: 100..<110)

        let total = asked.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, RemoteBuffer.chunk, "10 バイトのために \(total) バイト引いた")
        XCTAssertLessThan(buf.fetchedBytes, origin.count)
    }

    /// 即使我重读同一部分，我也不会查找两次。
    func testSecondReadOfTheSameRangeCostsNothing() throws {
        let buf = try XCTUnwrap(makeBuffer())
        _ = buf.data(in: 100..<110)
        let afterFirst = asked.count
        _ = buf.data(in: 100..<110)
        _ = buf.data(in: 102..<108)
        XCTAssertEqual(asked.count, afterFirst, "持っているものを引き直した")
    }

    /// 读取相邻字符时，不要重绘任何重叠的字符。
    func testAdjacentReadOnlyFetchesTheGap() throws {
        let buf = try XCTUnwrap(makeBuffer())
        _ = buf.data(in: 0..<100)
        let before = asked.reduce(0) { $0 + $1.count }
        _ = buf.data(in: 50..<(RemoteBuffer.chunk + 100))
        let after = asked.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(after - before, RemoteBuffer.chunk * 2 + 1)
    }

    func testPrefetchWarmsTheNeighbourhood() throws {
        let buf = try XCTUnwrap(makeBuffer())
        buf.prefetch(around: 100_000..<100_100)
        let asksBefore = asked.count
        _ = buf.data(in: 100_000..<100_100)
        XCTAssertEqual(asked.count, asksBefore, "先読みしたのに引き直した")
    }

    // MARK: - 当无法获取时

    /// **不要显示零。** 带有孔洞的文字可以写得看起来很逼真，这比完全没有孔洞的文字更危险。
    func testFailedFetchYieldsEmptyNotZeros() throws {
        let buf = try XCTUnwrap(makeBuffer(failAfter: 0))
        let got = buf.data(in: 0..<100)
        XCTAssertTrue(got.isEmpty, "取れなかったのに \(got.count) バイト返した")
        XCTAssertTrue(buf.lastFetchFailed)
        // ：该值不是零填充（它不会返回 100 个 0x00 实例）。
        XCTAssertNotEqual(got, Data(repeating: 0, count: 100))
    }

    func testFailureDoesNotPoisonLaterReads() throws {
        var failNext = true
        let buf = try XCTUnwrap(RemoteBuffer(count: origin.count, cacheURL: cacheURL) { offset, length in
            if failNext { failNext = false; return nil }
            let hi = min(offset + length, self.origin.count)
            guard offset < hi else { return Data() }
            return self.origin.subdata(in: offset..<hi)
        })
        XCTAssertTrue(buf.data(in: 0..<100).isEmpty)     // 首次尝试失败
        XCTAssertEqual(buf.data(in: 0..<100), origin.subdata(in: 0..<100))  // 你可以第二次获得它。
    }

    // MARK: - 後始末

    /// 关闭时删除。日志包含机密信息，因此请勿在启动周期内保留该日志。
    func testCacheFileIsRemovedOnDeinit() throws {
        let url = cacheURL!
        do {
            let buf = try XCTUnwrap(makeBuffer())
            _ = buf.data(in: 0..<10)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "キャッシュが残った")
    }

    /// 由于这是一个稀疏文件，如果您不查看它，它不会占用磁盘空间。
    func testCacheStaysSparseUntilRead() throws {
        let buf = try XCTUnwrap(makeBuffer())
        _ = buf.data(in: 0..<10)
        let attrs = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual(attrs[.size] as? Int, origin.count, "見かけの大きさは原本と同じ")
        XCTAssertLessThan(buf.fetchedBytes, origin.count, "実体は見たぶんだけ")
    }
}
