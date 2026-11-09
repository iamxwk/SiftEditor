import Foundation

/// “修改后的行内发生了什么变化”。
///
/// 主要目标是找到对数 (status=200 → status=500, latency=42ms → 43ms) 中的一个字符差异，。
/// 仅仅用红色高亮显示该行是不够的。**我们需要逐个字符地比较差异，但仅限于已更改的行。**
///
/// 目标只是屏幕上显示的已更改行（几十行），因此简单的 DP 就足够了。
/// 放弃过长的行，并将整行视为一次更改（每行 100,000 个字符地循环遍历 DP 更有害）。
enum CharDiff {

    /// 超过此长度的行将不会计算其行内差异（整行将被视为已更改）。
    static let maxLineLength = 2_000

    /// 比较左侧行和右侧行，并返回从左侧删除的范围和添加到右侧的范围。
    /// 范围以 Character 为单位（不分割表情符号或组合字符）。
    static func ranges(left: String, right: String) -> (left: [Range<Int>], right: [Range<Int>]) {
        let a = Array(left), b = Array(right)
        if a.count > maxLineLength || b.count > maxLineLength {
            return (a.isEmpty ? [] : [0..<a.count], b.isEmpty ? [] : [0..<b.count])
        }

        // 删除公共的开头和结尾。由于大多数日志行都是相同的，仅此一项就能几乎完全消除 DP。
        var p = 0
        while p < a.count && p < b.count && a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }

        let aMid = Array(a[p..<(a.count - s)])
        let bMid = Array(b[p..<(b.count - s)])
        if aMid.isEmpty && bMid.isEmpty { return ([], []) }
        if aMid.isEmpty { return ([], [p..<(p + bMid.count)]) }
        if bMid.isEmpty { return ([p..<(p + aMid.count)], []) }

        // 仅限中心 LCS。
        let n = aMid.count, m = bMid.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = aMid[i] == bMid[j] ? dp[i + 1][j + 1] + 1
                                              : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        var lOut: [Range<Int>] = [], rOut: [Range<Int>] = []
        var i = 0, j = 0
        var lRun: Int? = nil, rRun: Int? = nil
        func closeL(_ end: Int) { if let s0 = lRun { lOut.append((p + s0)..<(p + end)); lRun = nil } }
        func closeR(_ end: Int) { if let s0 = rRun { rOut.append((p + s0)..<(p + end)); rRun = nil } }

        while i < n && j < m {
            if aMid[i] == bMid[j] {
                closeL(i); closeR(j)
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                if lRun == nil { lRun = i }
                i += 1
            } else {
                if rRun == nil { rRun = j }
                j += 1
            }
        }
        closeL(i); closeR(j)
        if i < n { lOut.append((p + i)..<(p + n)) }
        if j < m { rOut.append((p + j)..<(p + m)) }
        return (lOut, rOut)
    }
}
