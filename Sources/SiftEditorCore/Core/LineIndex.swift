import Foundation

/// 稀疏索引，每行开头有一个字节偏移量。
///
/// 如果我们有所有行的偏移量，那么 1 亿行的偏移量将是 800MB，因此每行大约为 `stride`。
/// 仅保存一个“（行号，该行的第一个字节）”实例。对于任意行，保存“最接近的”
/// 通过“从索引点向前扫描”到达（最大扫描长度约为 2*stride 行）。
///
/// 构造是通过跨多个核心并行扫描来完成的（减少等待时间，直到使用 10GB 类打开）。
/// 为了并行化处理，在每个数据块边界处抽取一个独立样本，因此样本的行号为
/// 它不是 stride 的整数倍。因此，使用行号/字节的二分查找进行搜索。
///
/// 行分割仅使用字节 0x0A (`\n`)。UTF-8 / Shift-JIS / EUC-JP
/// 在任何情况下，0x0A 都不会出现在任何多字节字符的中间，因此是安全的。
final class LineIndex: OriginalLineLocator {
    let stride: Int

    /// 稀疏索引示例。第 `sampleLines[j]` 行的第一个元素为 `sampleOffsets[j]` 字节。
    /// 两者均按升序排列。第一个条目始终为 (0, 0)。
    private var sampleLines: [Int] = [0]
    private var sampleOffsets: [Int] = [0]
    /// 稀疏索引实际占用的字节数。每个样本有两个 Int 值（行号和偏移量）。
    /// 这样做是为了验证“ / README / LP 的索引非常小”的说法（已用 BigFileIndexBenchTests 验证）。
    var indexBytes: Int {
        (sampleLines.count + sampleOffsets.count) * MemoryLayout<Int>.size
    }

    /// 整个索引完成后确认的行数。
    private(set) var exactLineCount: Int = 0
    /// 从第一个样本中获得的估计行数（在索引完成之前显示）。
    private(set) var estimatedLineCount: Int = 1
    /// 索引是否已全部完成？
    private(set) var isComplete: Bool = false

    /// 扫描的字节数（增量扩展的起始点 = tail - f）。
    private var scannedBytes = 0
    /// 目前统计到的换行符 (0x0A) 数。
    private var nlCount = 0

    private let buffer: ByteSource
    /// 并行扫描中单个数据块的字节宽度。在测试中，该值设置得较小，以便处理多个数据块并跨越边界。
    private let chunkSize: Int

    init(buffer: ByteSource, stride: Int = 2000, chunkSize: Int = 16 << 20) {
        self.buffer = buffer
        self.stride = stride
        self.chunkSize = max(1, chunkSize)
    }

    /// 当前用于显示的最佳行数（已确认 > 已估计）。
    var displayLineCount: Int {
        isComplete ? exactLineCount : estimatedLineCount
    }

    /// 原始文档中包含的换行符 (0x0A) 数（待整个索引完成后确定）。
    /// PieceTable 用于在初始化期间跳过对原始文档的完整扫描（仅在 `isComplete` 之后生效）。
    var originalNewlines: Int { nlCount }

    /// 根据第一个样本估算行数（用于立即显示、同步和高速）。
    func estimatePrefix() {
        let sample = min(buffer.count, 1 << 20) // 先頭 1MB
        guard sample > 0 else {
            estimatedLineCount = 0
            return
        }
        var newlines = 0
        buffer.withBytes(in: 0..<sample) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            while i < n {
                if let found = memchr(base + i, 0x0A, n - i) {
                    let off = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    newlines += 1
                    i = off + 1
                } else {
                    break
                }
            }
        }
        let avg = newlines > 0 ? Double(sample) / Double(newlines) : 80.0
        estimatedLineCount = max(1, Int(Double(buffer.count) / avg))
    }

    /// 1 块扫描结果（块内每个 stride 倍数的换行符数和（块行号，绝对偏移量））。
    private struct ChunkResult {
        var newlines: Int = 0
        var samples: [(localLine: Int, offset: Int)] = []
    }

    /// 使用多个核心并行扫描整个系统，以构建稀疏索引（背景）。
    /// 在主线程中调用  / progress / completion。
    func buildInBackground(progress: @escaping (Double) -> Void,
                           completion: @escaping () -> Void) {
        let total = buffer.count
        let stride = self.stride
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard total > 0 else {
                DispatchQueue.main.async {
                    self.sampleLines = [0]; self.sampleOffsets = [0]
                    self.nlCount = 0; self.scannedBytes = 0
                    self.exactLineCount = 0; self.isComplete = true
                    progress(1.0); completion()
                }
                return
            }

            // 无论核心数量多少，都会将数据块分成更小的单元，以实现负载均衡和细粒度的进度跟踪。
            let chunkSize = self.chunkSize
            let chunkCount = (total + chunkSize - 1) / chunkSize
            var results = [ChunkResult](repeating: ChunkResult(), count: chunkCount)

            let progressLock = NSLock()
            var completedChunks = 0
            let reportEvery = max(1, chunkCount / 50)

            results.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: chunkCount) { ci in
                    let cs = ci * chunkSize
                    let ce = min(total, cs + chunkSize)
                    var nl = 0
                    var samples: [(Int, Int)] = []
                    self.buffer.withBytes(in: cs..<ce) { raw in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                        let n = raw.count
                        var i = 0
                        while i < n {
                            guard let f = memchr(base + i, 0x0A, n - i) else { break }
                            let off = UnsafeRawPointer(f) - UnsafeRawPointer(base)
                            nl += 1
                            if nl % stride == 0 {
                                // 这紧接在该块中的第 nl 个换行符之后 = 行的开头。
                                samples.append((nl, cs + off + 1))
                            }
                            i = off + 1
                        }
                    }
                    // 写入不同的 index 不会重复，因此不需要锁定。
                    buf[ci] = ChunkResult(newlines: nl, samples: samples)

                    progressLock.lock()
                    completedChunks += 1
                    let done = completedChunks
                    progressLock.unlock()
                    if done % reportEvery == 0 {
                        DispatchQueue.main.async { progress(Double(done) / Double(chunkCount)) }
                    }
                }
            }

            // ：按顺序连接块结果并将其转换为全局行号。
            var lines: [Int] = [0]
            var offs: [Int] = [0]
            lines.reserveCapacity(total / (stride * 64) + chunkCount)
            offs.reserveCapacity(lines.capacity)
            var base = 0
            for r in results {
                for (localLine, offset) in r.samples {
                    lines.append(base + localLine)
                    offs.append(offset)
                }
                base += r.newlines
            }
            let nl = base
            let trailing = self.buffer.withBytes(in: (total - 1)..<total) { ($0.first ?? 0x0A) != 0x0A }

            DispatchQueue.main.async {
                self.sampleLines = lines
                self.sampleOffsets = offs
                self.nlCount = nl
                self.scannedBytes = total
                self.exactLineCount = nl + (trailing ? 1 : 0)
                self.isComplete = true
                progress(1.0)
                completion()
            }
        }
    }

    /// 将文件的扩展部分追加到索引（tail -f）。在主线程中调用。
    /// `newCount` 是新的文件大小。`buffer` 表示该文件已被重新映射。
    func extend(toByte newCount: Int) {
        guard isComplete, newCount > scannedBytes else { return }
        let from = scannedBytes
        let stride = self.stride
        var nl = nlCount

        buffer.withBytes(in: from..<newCount) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            while i < n {
                guard let found = memchr(base + i, 0x0A, n - i) else { break }
                let off = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                nl += 1
                if nl % stride == 0 {
                    sampleLines.append(nl)                // 全球线路编号
                    sampleOffsets.append(from + off + 1)  // 文件起始位置的绝对偏移量
                }
                i = off + 1
            }
        }
        nlCount = nl
        scannedBytes = newCount
        let trailing = buffer.withBytes(in: (newCount - 1)..<newCount) { ($0.first ?? 0x0A) != 0x0A }
        exactLineCount = nl + (trailing ? 1 : 0)
    }

    // MARK: - 正在搜索稀疏索引

    /// 找到满足  / `sampleOffsets[j] <= x` 的最大 `j`（升序，二分查找）。
    private func sampleIndex(forByte x: Int) -> Int {
        var lo = 0, hi = sampleOffsets.count - 1, best = 0
        while lo <= hi {
            let m = (lo + hi) / 2
            if sampleOffsets[m] <= x { best = m; lo = m + 1 } else { hi = m - 1 }
        }
        return best
    }

    /// 找到满足  / `sampleLines[j] <= line` 的最大 `j`（升序，二分查找）。
    private func sampleIndex(forLine line: Int) -> Int {
        var lo = 0, hi = sampleLines.count - 1, best = 0
        while lo <= hi {
            let m = (lo + hi) / 2
            if sampleLines[m] <= line { best = m; lo = m + 1 } else { hi = m - 1 }
        }
        return best
    }

    // MARK: - OriginalLineLocator

    /// 原始 `[0, x)` 中包含的换行符 (0x0A) 的数量 = 字节 `x` 之前的行数。
    /// O (stride) 用于从最近的稀疏索引点到 `x` 进行计数，使用 memchr。仅在 `isComplete` 之后有效。
    func newlineCount(upTo x: Int) -> Int {
        let target = min(max(0, x), buffer.count)
        guard target > 0 else { return 0 }
        let j = sampleIndex(forByte: target)
        let startPos = sampleOffsets[j]
        var count = sampleLines[j]
        if startPos < target {
            buffer.withBytes(in: startPos..<target) { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let n = raw.count
                var i = 0
                while i < n {
                    guard let f = memchr(base + i, 0x0A, n - i) else { break }
                    count += 1
                    i = (UnsafeRawPointer(f) - UnsafeRawPointer(base)) + 1
                }
            }
        }
        return count
    }

    /// 行 `line`（从 0 开始）的前导字节偏移量。通过从最近的稀疏索引点 (O(stride)) 向前扫描计算得出。
    func byteOffset(ofLineStart line: Int) -> Int {
        guard line > 0 else { return 0 }
        let total = buffer.count
        let j = sampleIndex(forLine: line)
        var pos = sampleOffsets[j]
        var skip = line - sampleLines[j]
        guard skip > 0 else { return pos }
        buffer.withBytes(in: pos..<total) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            while skip > 0 && i < n {
                guard let f = memchr(base + i, 0x0A, n - i) else { i = n; break }
                i = (UnsafeRawPointer(f) - UnsafeRawPointer(base)) + 1
                skip -= 1
            }
            pos += i
        }
        return pos
    }

    /// 0x0A 的字节偏移量，即原始数据中的第 `m` 个字节（从 0 开始计数）。第 `m+1` 行紧随其后。
    func newlineOffset(ordinal m: Int) -> Int {
        byteOffset(ofLineStart: m + 1) - 1
    }

    // MARK: - 显示行范围

    /// 通过一次向前扫描求出行区间 [start, start+count) 的字节范围。
    /// 未构建索引的区域（距离最近的索引点太远）将返回空数组。
    func lineRanges(from start: Int, count: Int) -> [Range<Int>] {
        guard count > 0, start >= 0 else { return [] }
        let j = sampleIndex(forLine: start)
        let startLine = sampleLines[j]
        // 如果索引完整，则采样间隔约为 2*stride 行或更少。对于超过此间隔的前向扫描，
        // 被视为不完整的索引区域，并返回空值（以避免大规模扫描）。
        guard start - startLine <= 4 * stride else { return [] }
        let startPos = sampleOffsets[j]

        let total = buffer.count
        var result: [Range<Int>] = []
        result.reserveCapacity(count)

        buffer.withBytes(in: startPos..<total) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var i = 0
            // 跳过换行符直到目标起始行。
            var skip = start - startLine
            while skip > 0 && i < n {
                if let found = memchr(base + i, 0x0A, n - i) {
                    i = (UnsafeRawPointer(found) - UnsafeRawPointer(base)) + 1
                    skip -= 1
                } else {
                    i = n
                    break
                }
            }
            if skip > 0 { return } // 到此为止没有线路。

            var produced = 0
            while produced < count && i < n {
                let lineStartByte = startPos + i
                if let found = memchr(base + i, 0x0A, n - i) {
                    let off = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                    var end = startPos + off
                    if end > lineStartByte, base[off - 1] == 0x0D { // 从  CRLF 中移除 CR。
                        end -= 1
                    }
                    result.append(lineStartByte..<end)
                    i = off + 1
                } else {
                    // 最后一行未以换行符结尾
                    result.append(lineStartByte..<(startPos + n))
                    produced += 1
                    break
                }
                produced += 1
            }
        }
        return result
    }
}
