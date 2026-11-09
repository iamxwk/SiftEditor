import Foundation

/// 并排查看时，一行（左侧或右侧，或两者）。
struct DiffRow {
    enum Kind { case equal, delete, insert, replace }
    let kind: Kind
    /// 左侧文件的行号（从 0 开始计数）。对于仅存在于右侧的行，请使用 nil，并在左侧填充空格。
    let left: Int?
    /// 右侧文件的行号（从 0 开始计数）。对于仅存在于左侧的行，请使用 nil。
    let right: Int?
}

/// diff 的显示模型。
///
/// **不要实例化行。**使用 8600 万行 diff 创建 `[DiffRow]` 将超出 1GB 的范围。
/// 这与“不包含正文”的设计相矛盾。它只包含差值（ops）及其累计行数。
/// 仅屏幕上显示的行使用二分查找进行原地组装。ops 的数量是差分块的数量，因此并不大。
struct DiffModel {
    let ops: [DiffOp]
    /// 累计显示行数，直至  / ops[i]。采用二分查找法。
    private let cumulative: [Int]
    /// 排序后的总行数。
    let rowCount: Int
    /// 差异块的第一行（单击“下一个差异”时的目标位置）。
    let hunkStarts: [Int]

    init(ops: [DiffOp]) {
        self.ops = ops
        var cum: [Int] = []
        var hunks: [Int] = []
        var total = 0
        var prevWasDiff = false
        cum.reserveCapacity(ops.count)
        for op in ops {
            let isDiff: Bool
            let rows: Int
            switch op {
            case let .equal(_, _, c):                       rows = c; isDiff = false
            case let .delete(_, c):                         rows = c; isDiff = true
            case let .insert(_, c):                         rows = c; isDiff = true
            case let .replace(_, lc, _, rc):                rows = max(lc, rc); isDiff = true
            }
            if isDiff && !prevWasDiff { hunks.append(total) }
            prevWasDiff = isDiff
            total += rows
            cum.append(total)
        }
        self.cumulative = cum
        self.rowCount = total
        self.hunkStarts = hunks
    }

    var isIdentical: Bool { ops.count == 1 && ops.first.map { if case .equal = $0 { return true } else { return false } } == true }

    /// 存在差异的行数（更改、添加和删除的总和。用于状态显示）。
    var changedRowCount: Int {
        ops.reduce(0) { acc, op in
            switch op {
            case .equal: return acc
            case let .delete(_, c): return acc + c
            case let .insert(_, c): return acc + c
            case let .replace(_, lc, _, rc): return acc + max(lc, rc)
            }
        }
    }

    /// 显示的行 row 对应于哪一行（左侧或右侧）？O（log ops）。
    func row(at row: Int) -> DiffRow? {
        guard row >= 0, row < rowCount else { return nil }
        // cumulative 单调递增。求最小的 i，使得 row < cumulative[i]。
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= row { lo = mid + 1 } else { hi = mid }
        }
        let base = lo == 0 ? 0 : cumulative[lo - 1]
        let offset = row - base
        switch ops[lo] {
        case let .equal(l, r, _):
            return DiffRow(kind: .equal, left: l + offset, right: r + offset)
        case let .delete(l, _):
            return DiffRow(kind: .delete, left: l + offset, right: nil)
        case let .insert(r, _):
            return DiffRow(kind: .insert, left: nil, right: r + offset)
        case let .replace(l, lc, r, rc):
            return DiffRow(kind: .replace,
                           left: offset < lc ? l + offset : nil,
                           right: offset < rc ? r + offset : nil)
        }
    }

    /// 滚动条上绘图的差异位置 (0...1) 和类型。
    /// 如果存在成千上万个差异，全部绘制出来会使图像变得难以辨认，所以我们将其减少到上限。
    func markers(limit: Int = 600) -> [(position: Double, kind: DiffRow.Kind)] {
        guard rowCount > 0 else { return [] }
        var out: [(Double, DiffRow.Kind)] = []
        var acc = 0
        var diffs: [(Int, DiffRow.Kind)] = []
        for op in ops {
            switch op {
            case let .equal(_, _, c):        acc += c
            case let .delete(_, c):          diffs.append((acc, .delete)); acc += c
            case let .insert(_, c):          diffs.append((acc, .insert)); acc += c
            case let .replace(_, lc, _, rc): diffs.append((acc, .replace)); acc += max(lc, rc)
            }
        }
        let step = max(1, diffs.count / limit)
        for i in Swift.stride(from: 0, to: diffs.count, by: step) {
            out.append((Double(diffs[i].0) / Double(rowCount), diffs[i].1))
        }
        return out
    }

    /// 排版选定的文本（以便复制）。
    ///
    /// `line(row)` 是“该列该行中的字符串。该行仅存在于屏幕的另一侧（屏幕上填充空白的行）。”
    /// 如果  / 则返回“nil”。**跳过填充行** -- 如果您复制不存在的行并混入空白行，
    /// 根据粘贴位置的不同，它会变成谎言。
    func selectedText(from start: (row: Int, idx: Int),
                      to end: (row: Int, idx: Int),
                      line: (Int) -> String?) -> String {
        guard start.row <= end.row, start.row >= 0, end.row < rowCount else { return "" }
        var parts: [String] = []
        for row in start.row...end.row {
            guard let text = line(row) else { continue }      // 跳过填充帖子
            let u = Array(text.utf16)
            let from = (row == start.row) ? min(max(0, start.idx), u.count) : 0
            let to   = (row == end.row)   ? min(max(0, end.idx), u.count)   : u.count
            guard from <= to else { continue }
            parts.append(String(utf16CodeUnits: Array(u[from..<to]), count: to - from))
        }
        return parts.joined(separator: "\n")
    }

    /// 显示行以  / op `i` 开头。
    func startRow(ofOp i: Int) -> Int {
        guard i > 0, i <= cumulative.count else { return 0 }
        return cumulative[i - 1]
    }

    /// 块 `op` 之后的下一个块（下标 op）。如果不存在，则为 nil。
    ///
    /// **请勿按滚动位置搜索。** 我以前这样做过，但尺寸太小，无法适应屏幕。
    /// 在文件  中，topRow 始终为 0 且没有改变，无论我按多少次，它都会恢复到相同的差值（实际上它恢复到了相同的值）。
    /// 评判标准是“你当前选择的汉克”。
    func hunk(after op: Int?) -> Int? {
        let hunks = hunkOpIndices
        guard let op else { return hunks.first }
        return hunks.first { $0 > op }
    }

    /// Hank `op` 的 **前一个** Hank（下标为 op）。
    func hunk(before op: Int?) -> Int? {
        let hunks = hunkOpIndices
        guard let op else { return hunks.last }
        return hunks.last { $0 < op }
    }

    // MARK: - 合并

    /// 差异块（hanks）列表。`ops` 是上面的索引（它用作采用状态的键）。
    var hunkOpIndices: [Int] {
        ops.enumerated().compactMap { i, op in
            if case .equal = op { return nil }
            return i
        }
    }

    /// 包含显示行 row 的 op 的下标。
    func opIndex(at row: Int) -> Int? {
        guard row >= 0, row < rowCount else { return nil }
        var acc = 0
        for (i, op) in ops.enumerated() {
            let rows: Int
            switch op {
            case let .equal(_, _, c):        rows = c
            case let .delete(_, c):          rows = c
            case let .insert(_, c):          rows = c
            case let .replace(_, lc, _, rc): rows = max(lc, rc)
            }
            if row < acc + rows { return i }
            acc += rows
        }
        return nil
    }

    /// 导出合并结果。
    ///
    /// **右侧为基准。** 箭头（→）表示“将左侧内容移至右侧”。
    /// 结果将显示在右侧。只有包含在 `applied` 中的 op 的内容将从左侧获取。
    /// - equal：保持右侧不变（=与左侧相同）
    /// - replace：如果适用则为左侧，否则为右侧。
    /// - delete：仅存在于左侧的行。要应用，请**添加**（将左侧的行移动到右侧）。
    /// - insert：仅存在于右侧的行。如果适用，则**删除**（左对齐），否则保留。
    ///
    /// **不要将主文本加载到内存中。** 由于字节直接从源流传输，因此 10GB 也可以工作。
    func writeMerged(left: DiffSource, right: DiffSource, applied: Set<Int>,
                     eol: [UInt8], to out: FileHandle) throws {
        for (i, op) in ops.enumerated() {
            let take = applied.contains(i)
            switch op {
            case let .equal(_, r, c):
                try right.writeLines(from: r, count: c, eol: eol, to: out)
            case let .replace(l, lc, r, rc):
                if take { try left.writeLines(from: l, count: lc, eol: eol, to: out) }
                else    { try right.writeLines(from: r, count: rc, eol: eol, to: out) }
            case let .delete(l, c):
                if take { try left.writeLines(from: l, count: c, eol: eol, to: out) }
            case let .insert(r, c):
                if !take { try right.writeLines(from: r, count: c, eol: eol, to: out) }
            }
        }
    }
}
