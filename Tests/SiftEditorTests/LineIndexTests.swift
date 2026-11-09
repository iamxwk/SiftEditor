import XCTest
@testable import SiftEditorCore

/// 这验证了  / `LineIndex` 的并行构造与朴素参考计算相同。
/// 最小化块宽度，并确保路径始终包含多个块，且块边界位于行的中间。
final class LineIndexTests: XCTestCase {

    /// 参考侧：从字节序列中预先计算行起始偏移量和前缀换行符的数量，并将每个查询返回为 O(1)。
    private struct Naive {
        let bytes: [UInt8]
        let newlineCount: Int
        /// prefixNL[i] = [0, i)] 换行符数 (size = count+1)。
        private let prefixNL: [Int]
        /// lineStarts[line] = 行 line 的第一个字节（size = newlineCount+1，结尾紧跟在最后一个换行符之后）。
        private let lineStarts: [Int]

        init(bytes: [UInt8]) {
            self.bytes = bytes
            var pfx = [Int](repeating: 0, count: bytes.count + 1)
            var starts = [0]
            var nl = 0
            for (i, b) in bytes.enumerated() {
                pfx[i + 1] = pfx[i] + (b == 0x0A ? 1 : 0)
                if b == 0x0A { nl += 1; starts.append(i + 1) }
            }
            self.prefixNL = pfx
            self.lineStarts = starts
            self.newlineCount = nl
        }

        var lineCount: Int {
            guard !bytes.isEmpty else { return 0 }
            return newlineCount + (bytes.last == 0x0A ? 0 : 1)
        }
        /// 行 line（从 0 开始）的第一个字节。
        func lineStart(_ line: Int) -> Int {
            line < lineStarts.count ? lineStarts[line] : bytes.count
        }
        /// [0, x) 中的换行符数量。
        func newlines(upTo x: Int) -> Int {
            prefixNL[min(max(0, x), bytes.count)]
        }
        /// 行 line 的内容范围（不包括末尾的 0x0A。CRLF 中的 CR 以与 LineIndex 相同的方式删除）。
        func lineRange(_ line: Int) -> Range<Int> {
            let start = lineStart(line)
            var end = start
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            if end > start && bytes[end - 1] == 0x0D { end -= 1 }
            return start..<end
        }
    }

    private func buildIndex(_ content: [UInt8], stride: Int, chunkSize: Int) -> LineIndex {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("lineindex-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: Data(content))
        defer { try? FileManager.default.removeItem(at: url) }

        let buffer = FileBuffer(url: url)!
        let idx = LineIndex(buffer: buffer, stride: stride, chunkSize: chunkSize)
        let done = expectation(description: "index built")
        idx.buildInBackground(progress: { _ in }, completion: { done.fulfill() })
        wait(for: [done], timeout: 5)
        return idx
    }

    private func check(_ content: [UInt8], stride: Int, chunkSize: Int) {
        let naive = Naive(bytes: content)
        let idx = buildIndex(content, stride: stride, chunkSize: chunkSize)
        let label = "len=\(content.count) stride=\(stride) chunk=\(chunkSize)"

        XCTAssertTrue(idx.isComplete, label)
        XCTAssertEqual(idx.exactLineCount, naive.lineCount, "lineCount \(label)")
        XCTAssertEqual(idx.originalNewlines, naive.newlineCount, "newlines \(label)")

        // 行起始偏移（所有行）。
        for line in 0...naive.lineCount {
            XCTAssertEqual(idx.byteOffset(ofLineStart: line), naive.lineStart(line),
                           "lineStart(\(line)) \(label)")
        }
        // 每个字节边界处的换行符数（=行号）。
        for x in 0...content.count {
            XCTAssertEqual(idx.newlineCount(upTo: x), naive.newlines(upTo: x),
                           "newlineCount(upTo:\(x)) \(label)")
        }
        // 显示行范围（连续窗口）。
        let ranges = idx.lineRanges(from: 0, count: max(1, naive.lineCount))
        XCTAssertEqual(ranges.count, naive.lineCount, "lineRanges count \(label)")
        for (line, r) in ranges.enumerated() {
            XCTAssertEqual(r, naive.lineRange(line), "lineRange(\(line)) \(label)")
        }
    }

    func testParallelIndexMatchesNaive() {
        // 混合换行符，无论末尾是否有换行符，CRLF 和空行（用小块覆盖边界交叉点）。
        let smallVariants: [[UInt8]] = [
            Array("".utf8),
            Array("no newline".utf8),
            Array("a\nb\nc\n".utf8),
            Array("a\nb\nc".utf8),
            Array("\n\n\n".utf8),
            Array("crlf\r\nmixed\nlf\r\n".utf8),
        ]
        for v in smallVariants {
            for chunk in [1, 2, 3, 7, 64] {
                for stride in [1, 3, 8] {
                    check(v, stride: stride, chunkSize: chunk)
                }
            }
        }

        // 多块合并路径用于中等大小的输入（块应该比行大，以减少块的数量）。
        let big1 = Array((0..<400).map { "line \($0) の内容テスト\n" }.joined().utf8)
        let big2 = Array((0..<400).map { $0 % 5 == 0 ? "x\r\n" : "yy\n" }.joined().utf8)
        for v in [big1, big2] {
            for chunk in [16, 64, 256] {
                for stride in [1, 7] {
                    check(v, stride: stride, chunkSize: chunk)
                }
            }
        }
    }
}
