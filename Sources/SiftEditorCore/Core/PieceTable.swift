import Foundation

/// piece table 字节源（原始文件 or 内存测试）。
/// 为了避免将整个文本加载到内存中，仅使用 `read` 检索必要的部分。
protocol PieceSource {
    var count: Int { get }
    /// 返回文件内限制的范围 `r`（以原始字节形式）。
    func read(_ r: Range<Int>) -> [UInt8]
}

/// 使用 O (stride) 解决原始（不可变、大的）行到字节转换的快捷方式。
/// `LineIndex` 的稀疏索引即为实际数据。如果该索引不存在，则 `PieceTable` 将对原始数据执行线性扫描。
/// (这足以满足小型 `InMemorySource` 的测试需求)。
protocol OriginalLineLocator: AnyObject {
    /// 原始 `[0, x)` 中包含的 0x0A 的数量。
    func newlineCount(upTo x: Int) -> Int
    /// 0x0A 的字节偏移量，即原始数据中的第 `m` 个（从 0 开始）字节。
    func newlineOffset(ordinal m: Int) -> Int
}

/// 内存字节源（用于测试和小缓冲区）。
struct InMemorySource: PieceSource {
    private let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var count: Int { bytes.count }
    func read(_ r: Range<Int>) -> [UInt8] {
        let lo = max(0, r.lowerBound), hi = min(bytes.count, r.upperBound)
        guard lo < hi else { return [] }
        return Array(bytes[lo..<hi])
    }
}

/// 一个包装器，使用现有的 mmap 处理的 `FileBuffer` 作为 piece 和 table（在 B1 中使用）的字节源。
/// 不要将整个文本加载到内存中；仅通过 `FileBuffer` 读取请求的部分。
struct FileBufferSource: PieceSource {
    private let buffer: ByteSource
    init(_ buffer: ByteSource) { self.buffer = buffer }
    var count: Int { buffer.count }
    func read(_ r: Range<Int>) -> [UInt8] {
        let lo = max(0, r.lowerBound), hi = min(buffer.count, r.upperBound)
        guard lo < hi else { return [] }
        return [UInt8](buffer.data(in: lo..<hi))
    }
}

/// 确定性伪随机数（用于 treap 中的优先级。仅影响树结构，与正确性无关）。
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 表示字节空间中的文档：piece table。
///
/// 两个来源：原始（不可更改，mmap 等）和追加缓冲区（输入），作为一系列片段。
/// 排列以表示逻辑文档。插入操作只需“分割并插入片段”即可完成。
/// 从此点开始不要移动任何字节。该片段在 treap (split / merge) 处保持平衡。
/// 通过跟踪子树每个节点中的字节数和换行符数，可以执行逐字节转换。
/// 使用  / O(log n) 求解。
///
/// 行分割仅使用字节 0x0A（UTF-8 / Shift-JIS / EUC-JP 均为 0x0A）
/// （不会出现在多字节字符的中间）。计算行数的方法是 `LineIndex.displayLineCount`
/// 是一致的（空文档 = 0，如果末尾没有换行符，则该行也算作一行）。
final class PieceTable {
    private enum Source { case original, add }

    private struct Piece {
        var source: Source
        var start: Int      // 源中的起始字节
        var length: Int     // 兼职经理
        var newlines: Int   // 此范围内的 0x0A 的数量（在生成时确定）
    }

    private final class Node {
        var piece: Piece
        var priority: UInt64
        var left: Node?
        var right: Node?
        var subtreeBytes: Int
        var subtreeNewlines: Int
        init(_ piece: Piece, priority: UInt64) {
            self.piece = piece
            self.priority = priority
            self.subtreeBytes = piece.length
            self.subtreeNewlines = piece.newlines
        }
    }

    private let original: PieceSource
    /// 用于加快原始文档中行到字节转换速度的快捷方式（避免对大型原始文档进行线性扫描）。如果此快捷方式不存在，请使用传统扫描方式。
    private let originalLocator: OriginalLineLocator?
    private var add: [UInt8] = []
    private var root: Node?
    private var rng = SplitMix64(seed: 0x1234_5678_9ABC_DEF0)

    /// 换行扫描和部分读取的块宽度（避免一次读取大块内容）。
    private let scanChunk = 64 * 1024

    /// 从原始数据初始化。提供 `originalNewlines` 将跳过初始扫描（与 B1 一起使用）。
    /// 如果传递  / `locator` (=`LineIndex`)，则原始文件的行到字节转换将为 O (stride)（对于大型原始文件至关重要）。
    init(original: PieceSource, originalNewlines: Int? = nil, locator: OriginalLineLocator? = nil) {
        self.original = original
        self.originalLocator = locator
        if original.count > 0 {
            let nl = originalNewlines ?? countNewlines(in: .original, 0..<original.count)
            let piece = Piece(source: .original, start: 0, length: original.count, newlines: nl)
            root = Node(piece, priority: rng.next())
        }
    }

    /// 用于测试：直接从字节序列创建。
    convenience init(bytes: [UInt8]) {
        self.init(original: InMemorySource(bytes))
    }

    // MARK: - 集計

    var byteCount: Int { root?.subtreeBytes ?? 0 }

    /// 逻辑行数（空行 = 0，如果行尾没有换行符，则最后一行也计入）。
    var lineCount: Int {
        let n = byteCount
        guard n > 0 else { return 0 }
        let nl = root?.subtreeNewlines ?? 0
        let lastIsNewline = bytes(in: (n - 1)..<n).first == 0x0A
        return nl + (lastIsNewline ? 0 : 1)
    }

    private func bytesOf(_ n: Node?) -> Int { n?.subtreeBytes ?? 0 }
    private func newlinesOf(_ n: Node?) -> Int { n?.subtreeNewlines ?? 0 }

    private func update(_ n: Node) {
        n.subtreeBytes = bytesOf(n.left) + n.piece.length + bytesOf(n.right)
        n.subtreeNewlines = newlinesOf(n.left) + n.piece.newlines + newlinesOf(n.right)
    }

    // MARK: - 編集

    /// 在字节位置  / `offset` 处插入 `bytes`。
    func insert(_ bytes: [UInt8], at offset: Int) {
        guard !bytes.isEmpty else { return }
        let clamped = min(max(0, offset), byteCount)
        let addStart = add.count
        add.append(contentsOf: bytes)
        let piece = Piece(source: .add, start: addStart,
                          length: bytes.count, newlines: countNewlines(bytes))
        let (l, r) = split(root, at: clamped)
        let mid = Node(piece, priority: rng.next())
        root = merge(merge(l, mid), r)
    }

    /// 删除 `range` 范围内的字节。
    func delete(_ range: Range<Int>) {
        let lo = max(0, range.lowerBound), hi = min(byteCount, range.upperBound)
        guard lo < hi else { return }
        let (l, rest) = split(root, at: lo)
        let (_, r) = split(rest, at: hi - lo)
        root = merge(l, r)
    }

    // MARK: - 读取

    /// 提取  / `range` 的字节。
    func bytes(in range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound), hi = min(byteCount, range.upperBound)
        guard lo < hi else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(hi - lo)
        collect(root, base: 0, lo: lo, hi: hi, into: &out)
        return out
    }

    /// 整个文档从头开始按顺序传递，以 `chunk` 字节为单位，传递到 `sink`（用于流写入以保存）。
    /// 整个文本未加载到内存中；每个部分都是从源中单独读取的。树的高度为 O (log n)，深度不足。
    func writeAll(chunk: Int = 1 << 20, _ sink: (ArraySlice<UInt8>) throws -> Void) rethrows {
        try writeNode(root, chunk: chunk, sink)
    }

    private func writeNode(_ node: Node?, chunk: Int,
                           _ sink: (ArraySlice<UInt8>) throws -> Void) rethrows {
        guard let node = node else { return }
        try writeNode(node.left, chunk: chunk, sink)
        var pos = 0
        while pos < node.piece.length {
            let len = min(chunk, node.piece.length - pos)
            let bytes = read(node.piece.source,
                             (node.piece.start + pos)..<(node.piece.start + pos + len))
            try sink(bytes[...])
            pos += len
        }
        try writeNode(node.right, chunk: chunk, sink)
    }

    private func collect(_ node: Node?, base: Int, lo: Int, hi: Int, into out: inout [UInt8]) {
        guard let node = node else { return }
        let nodeStart = base + bytesOf(node.left)
        let nodeEnd = nodeStart + node.piece.length
        if lo < nodeStart {
            collect(node.left, base: base, lo: lo, hi: hi, into: &out)
        }
        if lo < nodeEnd && hi > nodeStart {
            let a = max(lo, nodeStart) - nodeStart
            let b = min(hi, nodeEnd) - nodeStart
            out.append(contentsOf: read(node.piece.source,
                                        (node.piece.start + a)..<(node.piece.start + b)))
        }
        if hi > nodeEnd {
            collect(node.right, base: nodeEnd, lo: lo, hi: hi, into: &out)
        }
    }

    // MARK: - 行 ↔ 字节

    /// 行 `line`（从 0 开始）的字节范围（不包括终止符 0x0A）。
    /// 从  / CRLF 中删除 CR 由调用者（出库人）执行。
    func byteRange(ofLine line: Int) -> Range<Int> {
        let total = lineCount
        guard total > 0, line >= 0, line < total else { return 0..<0 }
        let nl = root?.subtreeNewlines ?? 0
        let start = (line == 0) ? 0 : afterNewline(line - 1)
        let end = (line < nl) ? afterNewline(line) - 1 : byteCount
        return start..<max(start, end)
    }

    /// 行 `line`（从 0 开始）的前导字节偏移量。
    func byteOffset(ofLineStart line: Int) -> Int {
        let total = lineCount
        let clamped = min(max(0, line), total)
        if clamped == 0 { return 0 }
        let nl = root?.subtreeNewlines ?? 0
        if clamped - 1 < nl { return afterNewline(clamped - 1) }
        return byteCount
    }

    /// 包含字节偏移量 `off`（从 0 开始）的行中的换行符数量 = `[0, off)`。
    func line(ofByteOffset off: Int) -> Int {
        let target = min(max(0, off), byteCount)
        var node = root
        var count = 0
        var base = 0
        while let n = node {
            let nodeStart = base + bytesOf(n.left)
            let nodeEnd = nodeStart + n.piece.length
            if target <= nodeStart {
                node = n.left
            } else if target >= nodeEnd {
                count += newlinesOf(n.left) + n.piece.newlines
                base = nodeEnd
                node = n.right
            } else {
                count += newlinesOf(n.left)
                let within = target - nodeStart
                count += countNewlines(in: n.piece.source,
                                       n.piece.start..<(n.piece.start + within))
                break
            }
        }
        return count
    }

    /// `j`：紧随换行符之后的字节偏移量（从 0 开始）。前提条件：0 <= j < 换行符的数量。
    private func afterNewline(_ j: Int) -> Int {
        var node = root
        var j = j
        var base = 0
        while let n = node {
            let leftNL = newlinesOf(n.left)
            if j < leftNL {
                node = n.left
            } else {
                let inThisOrRight = j - leftNL
                let nodeStart = base + bytesOf(n.left)
                if inThisOrRight < n.piece.newlines {
                    let local = nthNewlineOffset(in: n.piece, ordinal: inThisOrRight)
                    return nodeStart + local + 1
                }
                j = inThisOrRight - n.piece.newlines
                base = nodeStart + n.piece.length
                node = n.right
            }
        }
        return byteCount   // 未到达
    }

    // MARK: - treap（split / merge）

    /// 在字节位置 `k` 处将树分成两部分。如果 `k` 落在某个部分内，则分割该部分。
    private func split(_ node: Node?, at k: Int) -> (Node?, Node?) {
        guard let node = node else { return (nil, nil) }
        let leftBytes = bytesOf(node.left)
        if k <= leftBytes {
            let (l, r) = split(node.left, at: k)
            node.left = r
            update(node)
            return (l, node)
        } else if k >= leftBytes + node.piece.length {
            let (l, r) = split(node.right, at: k - leftBytes - node.piece.length)
            node.right = l
            update(node)
            return (node, r)
        } else {
            // k 位于此节点的片段内 → 将该片段拆分为两个
            let offsetInPiece = k - leftBytes
            let leftPiece = subPiece(node.piece, 0, offsetInPiece)
            let rightPiece = subPiece(node.piece, offsetInPiece, node.piece.length - offsetInPiece)
            let leftTree = merge(node.left, Node(leftPiece, priority: rng.next()))
            let rightTree = merge(Node(rightPiece, priority: rng.next()), node.right)
            return (leftTree, rightTree)
        }
    }

    /// 按位置顺序合并两个相邻的 treap 元素（`a` 的所有键 < `b` 的所有键）。
    private func merge(_ a: Node?, _ b: Node?) -> Node? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        if a.priority > b.priority {
            a.right = merge(a.right, b)
            update(a)
            return a
        } else {
            b.left = merge(a, b.left)
            update(b)
            return b
        }
    }

    /// 创建片段的子片段（通过扫描子范围来计算换行符的数量）。
    private func subPiece(_ p: Piece, _ from: Int, _ len: Int) -> Piece {
        let r = (p.start + from)..<(p.start + from + len)
        return Piece(source: p.source, start: p.start + from, length: len,
                     newlines: countNewlines(in: p.source, r))
    }

    // MARK: - 字节供应和换行扫描

    private func read(_ s: Source, _ r: Range<Int>) -> [UInt8] {
        switch s {
        case .original:
            return original.read(r)
        case .add:
            let lo = max(0, r.lowerBound), hi = min(add.count, r.upperBound)
            guard lo < hi else { return [] }
            return Array(add[lo..<hi])
        }
    }

    private func countNewlines(_ bytes: [UInt8]) -> Int {
        var c = 0
        for b in bytes where b == 0x0A { c += 1 }
        return c
    }

    /// 在源范围内计数 0x0A。如果存在定位符，则原始值为 O (stride)，否则执行块线性扫描。
    private func countNewlines(in s: Source, _ range: Range<Int>) -> Int {
        if s == .original, let loc = originalLocator {
            return loc.newlineCount(upTo: range.upperBound) - loc.newlineCount(upTo: range.lowerBound)
        }
        var count = 0
        var pos = range.lowerBound
        while pos < range.upperBound {
            let len = min(scanChunk, range.upperBound - pos)
            count += countNewlines(read(s, pos..<(pos + len)))
            pos += len
        }
        return count
    }

    /// 返回部件内第 `ordinal` 个位置（从 0 开始）处 0x0A 的内部偏移量。
    private func nthNewlineOffset(in piece: Piece, ordinal: Int) -> Int {
        // 原图直接使用定位器进行跳转（不从头开始扫描大块区域）。
        if piece.source == .original, let loc = originalLocator {
            let before = loc.newlineCount(upTo: piece.start)
            return loc.newlineOffset(ordinal: before + ordinal) - piece.start
        }
        var remaining = ordinal
        var pos = 0
        while pos < piece.length {
            let len = min(scanChunk, piece.length - pos)
            let chunk = read(piece.source, (piece.start + pos)..<(piece.start + pos + len))
            for (i, b) in chunk.enumerated() where b == 0x0A {
                if remaining == 0 { return pos + i }
                remaining -= 1
            }
            pos += len
        }
        return max(0, piece.length - 1)   // 未到达
    }
}
