import Foundation

/// 将多个日志合并为单个时间序列的纯逻辑（与 UI 无关，与文件 I/O 无关）。
///
/// `sort -m` 不够用的原因正是这种类型存在的原因，所以我就把它写下来。
///
/// - **有些行没有时间戳。**其余的堆栈跟踪和 SQL 的多行转储可用。
/// 没有时间戳。如果逐行排序，这些记录将与父行分离。
/// 散布各处。此处，**继承了前一个时间** (`effectiveTimes`)
/// 确保续行始终紧跟在父行之后。
/// - **出现大量时间相同的条目。** 在仅显示秒的格式中，出现数十行时间相同的条目是正常的。
/// 已排列。如果排序不稳定，每次打开时顺序都会改变。此处
/// (时间 → 源编号 → 行编号) 创建总订单，确保**始终得到相同的结果**。
/// - **每台主机上的时钟都不同步。** 如果有一个 NTP 不同步，则原因和结果看起来会相反。
/// 使用  / `clockOffset` 逐个源进行更正。
///
/// 不包含行正文。`Entry` 仅指示来源和行号；正文可通过调用获取。
/// 将其移至另一侧。此边界用于防止将整个大型文件加载到内存中。
struct LogMerger {
    /// 用于捆绑单个商品。
    struct Source {
        /// 显示名称（例如，`web-1`）。
        let label: String
        /// “该行本身所具有的时间”。没有时间的行用 `nil` 标记。
        let times: [Date?]
        /// 此系统的时间漂移校正（秒）。对于 `+1.5`，将记录时间向前推进 1.5 秒。
        let clockOffset: TimeInterval

        init(label: String, times: [Date?], clockOffset: TimeInterval = 0) {
            self.label = label
            self.times = times
            self.clockOffset = clockOffset
        }
    }

    /// 捆绑后产生的单行。
    struct Entry: Equatable {
        /// `sources` 的下标。
        let source: Int
        /// 该源中的行号（从 0 开始）。
        let line: Int
        /// 用于排序的有效时间（已更正）。对于没有时间信息的数据源，则为 `nil`。
        let time: Date?
        /// 该行本身是否包含时间？`false` 是续行，屏幕上不显示时间。
        let hasOwnTimestamp: Bool
    }

    /// 计算每一行的执行时间。**始终返回与输入行数相同的行数。**
    ///
    /// - 包含时间的行是该时间（+`clockOffset`）。
    /// - 没有时间戳的行**继承上一行的时间**（以防止延续行与其父行分离）。
    /// - 开头没有时间戳的行（标题和横幅）借用**它们首次出现的时间**。
    /// 如果没有这个，文件的前几行就无处可去了。
    /// - 没有时间戳的来源均为 `nil`。
    static func effectiveTimes(_ times: [Date?], clockOffset: TimeInterval = 0) -> [Date?] {
        var out = [Date?](repeating: nil, count: times.count)
        var carried: Date?
        for i in times.indices {
            if let t = times[i] { carried = t.addingTimeInterval(clockOffset) }
            out[i] = carried
        }
        // 请在开头的空白处填写首次发现该物品的时间。
        if let firstIndex = out.firstIndex(where: { $0 != nil }), firstIndex > 0 {
            let first = out[firstIndex]
            for i in 0..<firstIndex { out[i] = first }
        }
        return out
    }

    /// 将多个来源合并到单个时间线中。
    ///
    /// 每个源文件中的行顺序始终保持不变（即使在同一时间也不会改变）。它没有时间戳。
    /// 在所有包含时间戳的行显示完毕后，源行按源顺序和行顺序显示。
    ///
    /// 源文件 k 的数量实际上只有几个，因此它没有使用堆，而是每次都查看第一个文件 k。
    /// k-way 设置为 merge (O(N·k))。当 k 增加到两位数时，请替换此项。
    static func merge(_ sources: [Source]) -> [Entry] {
        let effective = sources.map { effectiveTimes($0.times, clockOffset: $0.clockOffset) }
        var cursor = [Int](repeating: 0, count: sources.count)
        let total = effective.reduce(0) { $0 + $1.count }

        var out: [Entry] = []
        out.reserveCapacity(total)

        for _ in 0..<total {
            var pick = -1
            var pickTime: Date?
            for s in sources.indices where cursor[s] < effective[s].count {
                let t = effective[s][cursor[s]]
                if pick < 0 { pick = s; pickTime = t; continue }
                // nil 的时间未知，因此将被移至最后。对于同一时间点，源编号较小的进程将被移至最前面。
                switch (t, pickTime) {
                case let (a?, b?): if a < b { pick = s; pickTime = t }
                case (_?, nil):    pick = s; pickTime = t
                default:           break
                }
            }
            guard pick >= 0 else { break }
            let line = cursor[pick]
            out.append(Entry(source: pick,
                             line: line,
                             time: effective[pick][line],
                             hasOwnTimestamp: sources[pick].times[line] != nil))
            cursor[pick] += 1
        }
        return out
    }
}
