import Foundation

/// 行的哈希值。**128 位**。
///
/// 64 位将产生 8600 万行，生日冲突的概率约为 10^-4。如果 diff 处发生冲突……
/// “说不同的台词是一样的” = **默默地忽略差异**，这比观众“什么都不掉”更糟糕。
/// 这是一个坏的。销毁数据需要 16 字节/行（10GB，1.4GB 为 86,420,337 行）。
struct LineHash: Hashable {
    let a: UInt64
    let b: UInt64
}

/// diff 的一次移动。以行表示。
enum DiffOp: Equatable {
    /// 两侧出现同一行，后面跟着 count 行。
    case equal(left: Int, right: Int, count: Int)
    /// 仅在左侧（已删除）。
    case delete(left: Int, count: Int)
    /// 仅在右侧（附加）。
    case insert(right: Int, count: Int)
    /// 替换（左侧代码块变为右侧代码块）。行内差异取自该代码块内部。
    case replace(left: Int, leftCount: Int, right: Int, rightCount: Int)
}

/// 每行  / diff。
///
/// 代码为  / **patience diff**（找到两侧都只出现一次的行 = 锚点，并在它们之间递归）。
/// 如果直接运行 Myers 并输出一个非常大的日志，O (ND) 将会崩溃，但 patience 不会。
/// - 删除公共的开头和结尾（大部分日志通常在此处删除）
/// - 仅详细查看锚点之间的微小间隔
/// 因此，内存使用量和时间都与行数大致呈线性关系。
///
/// 没有锚点的节（例如，所有行都是重复的）如果节很小，则将为 Myers。
/// 如果很大，请将整个内容折叠成 replace（**表示你已经放弃，但并不撒谎**）。
enum LineDiff {

    /// 旋转 Myers 的上限（左侧和右侧行数的乘积），适用于没有锚点的节。
    /// 如果超过此值，则合并为一个 replace。
    static let myersCellBudget = 4_000_000

    static func compute(_ left: [LineHash], _ right: [LineHash]) -> [DiffOp] {
        var ops: [DiffOp] = []
        diff(left, right, 0..<left.count, 0..<right.count, into: &ops)
        return coalesce(ops)
    }

    // MARK: - 本体

    private static func diff(_ l: [LineHash], _ r: [LineHash],
                            _ lr: Range<Int>, _ rr: Range<Int>,
                            into ops: inout [DiffOp]) {
        var lo = lr, ro = rr

        // 普通上衣
        var prefix = 0
        while lo.lowerBound + prefix < lo.upperBound,
              ro.lowerBound + prefix < ro.upperBound,
              l[lo.lowerBound + prefix] == r[ro.lowerBound + prefix] {
            prefix += 1
        }
        if prefix > 0 {
            ops.append(.equal(left: lo.lowerBound, right: ro.lowerBound, count: prefix))
            lo = (lo.lowerBound + prefix)..<lo.upperBound
            ro = (ro.lowerBound + prefix)..<ro.upperBound
        }

        // 通用结尾
        var suffix = 0
        while lo.upperBound - suffix - 1 >= lo.lowerBound,
              ro.upperBound - suffix - 1 >= ro.lowerBound,
              l[lo.upperBound - suffix - 1] == r[ro.upperBound - suffix - 1] {
            suffix += 1
        }
        let lMid = lo.lowerBound..<(lo.upperBound - suffix)
        let rMid = ro.lowerBound..<(ro.upperBound - suffix)

        emitMiddle(l, r, lMid, rMid, into: &ops)

        if suffix > 0 {
            ops.append(.equal(left: lo.upperBound - suffix, right: ro.upperBound - suffix, count: suffix))
        }
    }

    private static func emitMiddle(_ l: [LineHash], _ r: [LineHash],
                                   _ lr: Range<Int>, _ rr: Range<Int>,
                                   into ops: inout [DiffOp]) {
        if lr.isEmpty && rr.isEmpty { return }
        if lr.isEmpty { ops.append(.insert(right: rr.lowerBound, count: rr.count)); return }
        if rr.isEmpty { ops.append(.delete(left: lr.lowerBound, count: lr.count)); return }

        // 锚点 = 在左侧和右侧都只出现一次的公共线。
        guard let anchors = uniqueAnchors(l, r, lr, rr), !anchors.isEmpty else {
            // 无锚点。如果锚点较小，请使用 Myers；如果锚点较大，则放弃锚点，使用 replace。
            if lr.count * rr.count <= myersCellBudget {
                myers(l, r, lr, rr, into: &ops)
            } else {
                ops.append(.replace(left: lr.lowerBound, leftCount: lr.count,
                                    right: rr.lowerBound, rightCount: rr.count))
            }
            return
        }

        // 由锚列分隔（使用 LIS 选择，以便左右列都按升序排列），并递归。
        var lPos = lr.lowerBound
        var rPos = rr.lowerBound
        for (li, ri) in anchors {
            diff(l, r, lPos..<li, rPos..<ri, into: &ops)
            ops.append(.equal(left: li, right: ri, count: 1))
            lPos = li + 1
            rPos = ri + 1
        }
        diff(l, r, lPos..<lr.upperBound, rPos..<rr.upperBound, into: &ops)
    }

    /// 找出在左侧和右侧部分都出现一次的行，
    /// 仅保留右侧索引递增的最长列 (LIS) = 不相交的锚列。
    private static func uniqueAnchors(_ l: [LineHash], _ r: [LineHash],
                                      _ lr: Range<Int>, _ rr: Range<Int>) -> [(Int, Int)]? {
        var lCount: [LineHash: Int] = [:]
        var lWhere: [LineHash: Int] = [:]
        lCount.reserveCapacity(lr.count)
        for i in lr {
            lCount[l[i], default: 0] += 1
            lWhere[l[i]] = i
        }
        var rCount: [LineHash: Int] = [:]
        var rWhere: [LineHash: Int] = [:]
        rCount.reserveCapacity(rr.count)
        for i in rr {
            rCount[r[i], default: 0] += 1
            rWhere[r[i]] = i
        }

        var pairs: [(Int, Int)] = []
        for (h, c) in lCount where c == 1 {
            if rCount[h] == 1, let li = lWhere[h], let ri = rWhere[h] {
                pairs.append((li, ri))
            }
        }
        if pairs.isEmpty { return nil }
        pairs.sort { $0.0 < $1.0 }

        // 右索引 LIS（严格单调递增）。
        var tails: [Int] = []          // tails[k] = 长度为 k+1 的列末尾的“右侧 index”。
        var tailIdx: [Int] = []        // 该位置在 pairs
        var prev = [Int](repeating: -1, count: pairs.count)
        for (i, p) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if tails[mid] < p.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tailIdx[lo - 1] }
            if lo == tails.count { tails.append(p.1); tailIdx.append(i) }
            else { tails[lo] = p.1; tailIdx[lo] = i }
        }
        var out: [(Int, Int)] = []
        var k = tails.isEmpty ? -1 : tailIdx[tails.count - 1]
        while k >= 0 { out.append(pairs[k]); k = prev[k] }
        out.reverse()
        return out
    }

    /// Myers (O (ND)) 仅用于小段内容，不会超出段的范围。
    private static func myers(_ l: [LineHash], _ r: [LineHash],
                              _ lr: Range<Int>, _ rr: Range<Int>,
                              into ops: inout [DiffOp]) {
        let n = lr.count, m = rr.count
        // 一个简单的 LCS (DP) 结构。通过使用 myersCellBudget 来减少面积，使其更实用。
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = (l[lr.lowerBound + i] == r[rr.lowerBound + j])
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        while i < n && j < m {
            if l[lr.lowerBound + i] == r[rr.lowerBound + j] {
                ops.append(.equal(left: lr.lowerBound + i, right: rr.lowerBound + j, count: 1))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.delete(left: lr.lowerBound + i, count: 1)); i += 1
            } else {
                ops.append(.insert(right: rr.lowerBound + j, count: 1)); j += 1
            }
        }
        if i < n { ops.append(.delete(left: lr.lowerBound + i, count: n - i)) }
        if j < m { ops.append(.insert(right: rr.lowerBound + j, count: m - j)) }
    }

    // MARK: - 整形

    /// 合并连续相同的移动，并将相邻的 delete+insert 折叠成 replace。
    /// （如果用“重写”而不是“删除和添加”来表示，会更容易阅读。行内差异也可以用这种方式表示。）
    static func coalesce(_ ops: [DiffOp]) -> [DiffOp] {
        var merged: [DiffOp] = []
        for op in ops {
            guard let last = merged.last else { merged.append(op); continue }
            switch (last, op) {
            case let (.equal(l1, r1, c1), .equal(l2, r2, c2)) where l1 + c1 == l2 && r1 + c1 == r2:
                merged[merged.count - 1] = .equal(left: l1, right: r1, count: c1 + c2)
            case let (.delete(l1, c1), .delete(l2, c2)) where l1 + c1 == l2:
                merged[merged.count - 1] = .delete(left: l1, count: c1 + c2)
            case let (.insert(r1, c1), .insert(r2, c2)) where r1 + c1 == r2:
                merged[merged.count - 1] = .insert(right: r1, count: c1 + c2)
            default:
                merged.append(op)
            }
        }

        var out: [DiffOp] = []
        var k = 0
        while k < merged.count {
            if case let .delete(l, lc) = merged[k], k + 1 < merged.count,
               case let .insert(r, rc) = merged[k + 1] {
                out.append(.replace(left: l, leftCount: lc, right: r, rightCount: rc))
                k += 2
            } else if case let .insert(r, rc) = merged[k], k + 1 < merged.count,
                      case let .delete(l, lc) = merged[k + 1] {
                out.append(.replace(left: l, leftCount: lc, right: r, rightCount: rc))
                k += 2
            } else {
                out.append(merged[k])
                k += 1
            }
        }
        return out
    }
}
