import Foundation

/// 已检索到多少稀疏缓存？
///
/// 远程文件以稀疏文件的形式保存在本地，并且只填充查看的部分（范围读取）。
/// 当 **mmap** 时，稀疏文件中的空洞可以读取为零，
/// 这用于区分“我还没有服用”和“它确实包含 0x00”。
///
/// **如果出错，造成的损害不是“无法打开”，而是“部分文本会被静默地填充为零”。**
/// 即使  / 10GB 的日志中心填充了零，屏幕仍会像显示真实日志一样显示它。
/// 因此，读取路径总是经过这里，如果这里缺失，则会去检索它。
///
/// 区间已**规范化**（无重叠，按升序排列，相邻元素连接）。连接过程如下：
/// 当通过滚动一次填充 4KB 时，区间数增加到数万个，搜索变得线性有效。
struct FetchedRanges: Equatable {

    /// 无重叠，升序排列，相邻连接。无空区间。
    private(set) var ranges: [Range<Int>] = []

    init() {}

    init(_ initial: [Range<Int>]) {
        for r in initial { insert(r) }
    }

    /// 已记录为已获取。重叠和相邻的项目将被合并。
    mutating func insert(_ range: Range<Int>) {
        guard !range.isEmpty else { return }

        var merged = range
        var out: [Range<Int>] = []
        out.reserveCapacity(ranges.count + 1)

        for r in ranges {
            if r.upperBound < merged.lowerBound {
                out.append(r)                 // 仍然就在前方
            } else if merged.upperBound < r.lowerBound {
                out.append(merged)            // 它卡在这里了
                merged = r
            } else {
                // 重叠或相邻（关系为 `<=` 而非 `<`）= 折叠
                merged = min(r.lowerBound, merged.lowerBound)..<max(r.upperBound, merged.upperBound)
            }
        }
        out.append(merged)
        ranges = out
    }

    /// 该范围是否已被全部收购？
    func contains(_ range: Range<Int>) -> Bool {
        missing(in: range).isEmpty
    }

    /// 该范围内**尚未被占用**的部分。按升序排列，无重叠。
    ///
    /// 您只需要检索已返回的部分；不要重新获取您已经拥有的部分。
    /// （如果每次来回滚动时都重新计算同一个字节，则范围读取的意义就会降低）。
    func missing(in range: Range<Int>) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }

        var gaps: [Range<Int>] = []
        var cursor = range.lowerBound

        for r in ranges {
            if r.upperBound <= cursor { continue }        // 仍在前方
            if r.lowerBound >= range.upperBound { break }  // 继续前进

            if r.lowerBound > cursor {
                gaps.append(cursor..<min(r.lowerBound, range.upperBound))
            }
            cursor = max(cursor, r.upperBound)
            if cursor >= range.upperBound { return gaps }
        }

        if cursor < range.upperBound { gaps.append(cursor..<range.upperBound) }
        return gaps
    }

    /// 已检索的总字节数。这是为了向某人显示“10GB 中仅检索到 3MB”。
    var fetchedBytes: Int {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// 当缓存因文件扩展、替换等原因被丢弃时。
    mutating func removeAll() { ranges.removeAll() }
}
