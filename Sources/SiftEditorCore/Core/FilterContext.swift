import Foundation

/// 在显示屏上添加匹配行的前一行和后一行 N（相当于 `grep -C`）。
///
/// 筛选结果显示“只有这一行”，但调查却反复出现。错误行出现之前发生了什么？
/// 紧接着发生的事情通常在下一行。如果您无法分辨前后内容，那么当您缩小范围时……
/// 上下文丢失，您必须移除筛选条件并使用行号重新搜索。
///
/// 输出结果按升序排列，无重复项。由于匹配项接近时窗口会重叠，因此简单地将它们相加是不够的。
/// 仅添加从扫描位置 (`next`) 开始的部分并将其压碎 (`grep` 被 `--` 隔开)
/// （与摘要的思路相同）。不要插入分隔线——原始行号位于行号栏中。
/// 它已列入名单，所以你可以看出它是从那里起飞的。
enum FilterContext {
    /// 前后可显示的最大行数（UI 侧的输入也在此处进行四舍五入）。
    static let maxContext = 100

    /// 展开后显示的最大行数。如果匹配的行本身是 `SearchEngine`，则为 100 万行。
    /// 由于该项目已终止，在后续开发中增加内存不会有任何区别。
    /// (100 万条记录 × 前后各 100 行 = 数组中 2 亿行 = 1.6GB。到此为止。)
    static let displayCap = 1_000_000

    /// 返回显示行的顺序， / `matches`（升序，从 0 开始）加上前面和后面的 `context` 行。
    /// 如果  / `context` 为 0，则按原样返回 `matches`（不要重新创建数组）。
    static func expand(matches: [Int], context: Int, lineCount: Int) -> [Int] {
        guard context > 0, !matches.isEmpty, lineCount > 0 else { return matches }
        var out: [Int] = []
        out.reserveCapacity(min(matches.count * (2 * context + 1), displayCap))
        var next = 0                       // 尚未发布的最小行（用于消除重复项的边界）
        for m in matches {
            let lo = max(m - context, next, 0)
            let hi = min(m + context, lineCount - 1)
            guard lo <= hi else { continue }   // 整个窗口已发布/超出范围。
            for line in lo...hi {
                out.append(line)
                if out.count >= displayCap { return out }
            }
            next = hi + 1
        }
        return out
    }
}
