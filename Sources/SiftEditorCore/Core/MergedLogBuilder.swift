import Foundation

/// 读取多个日志文件，并根据时间戳将它们合并成一个文本文件。
///
/// `TimestampDetector` / `LogMerger`（均为纯函数）用于文件读取和
/// 仅用于增强显示效果的图层。这是唯一一个包含 I/O 的图层。
///
/// **结果将写入临时文件，并通过正常的“打开”路径进行路由。** 需要专用查看器。
/// 由于不创建新文件，搜索、筛选、结构化视图、另存为和行跳转功能均保持不变。
/// 运行正常。如果打包后的文件较大，将自动放置在现有的大文件路径 (`PieceTableViewer`) 中。
/// 由于已经包含在内，因此无需修改显示侧的内存设计。
///
/// **每个文件的格式各不相同。** nginx（Apache 格式）和应用程序日志（ISO）
/// 实际上，它们是捆绑在一起的，如果您坚持整体采用单一格式，那么其中一个就会成为整体。
/// 序列变为延续，时间顺序被打乱。
struct MergedLogBuilder {

    /// 捆绑商品的来源（将在标题中显示）。
    struct SourceInfo {
        let label: String
        let url: URL
        let format: TimestampFormat?
        let lineCount: Int
        let timestampedCount: Int
    }

    struct Result {
        /// 已写入的临时文件。
        let url: URL
        let sources: [SourceInfo]
        let totalLines: Int
        /// 告知用户的信息，例如“我无法阅读”或“时间缺失”。
        let warnings: [String]
    }

    enum Failure: LocalizedError {
        case needsTwoFiles
        case tooLarge(bytes: Int, limit: Int)
        case unreadable(URL)
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .needsTwoFiles:
                return L("merge.error.needsTwoFiles")
            case let .tooLarge(bytes, limit):
                return String(format: L("merge.error.tooLarge"),
                              ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file),
                              ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))
            case let .unreadable(url):
                return String(format: L("merge.error.unreadable"), url.lastPathComponent)
            case let .writeFailed(e):
                return e.localizedDescription
            }
        }
    }

    /// 输入总量最大。
    ///
    /// 要将它们捆绑在一起，**您需要事先知道所有行的时间戳**，所以您不能直接传递 10GB。
    /// 这行不通（第一行数据只有在所有项目都查看完毕进行排序后才能最终确定）。咱们实事求是地设定一个上限吧。
    /// 设定限额然后拒绝。最糟糕的做法是默默地将超出限额的物品捆绑在一起。
    static let inputSizeLimit = 512 * 1024 * 1024

    /// UTC 用于显示的偏移量（秒）。默认值为本地值。
    let displayOffset: Int
    /// 未写入行时假定的 UTC 偏移量（秒）。
    let assumedOffset: Int
    /// 假定年份，格式为无年份 (syslog)。
    let assumedYear: Int

    init(displayOffset: Int = TimeZone.current.secondsFromGMT(),
         assumedOffset: Int = TimeZone.current.secondsFromGMT(),
         assumedYear: Int = Calendar(identifier: .gregorian).component(.year, from: Date())) {
        self.displayOffset = displayOffset
        self.assumedOffset = assumedOffset
        self.assumedYear = assumedYear
    }

    // MARK: - 本体

    func build(urls: [URL], into directory: URL? = nil) throws -> Result {
        guard urls.count >= 2 else { throw Failure.needsTwoFiles }

        let total = urls.reduce(0) { sum, u in
            sum + ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0)
        }
        guard total <= Self.inputSizeLimit else {
            throw Failure.tooLarge(bytes: total, limit: Self.inputSizeLimit)
        }

        var warnings: [String] = []
        var infos: [SourceInfo] = []
        var texts: [[String]] = []
        var sources: [LogMerger.Source] = []

        for (i, url) in urls.enumerated() {
            guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url) }
            let encoding = EncodingDetector.detect(data)
            guard let text = String(data: data, encoding: encoding.stringEncoding) else {
                throw Failure.unreadable(url)
            }
            // 接受换行符以及 CRLF/CR 格式。显示屏将与 LF 对齐。
            var lines = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            // 仅删除由换行符在文本末尾产生的一个虚空行。文本文件默认使用换行符进行格式化。
            // 通常情况下，它会在这里结束，所以留下这些空白行会导致**空白行数与文件数一样多**。
            // ：因为它延续了前一个条目的时间，所以它显示为只包含标签的行。
            if lines.last == "" { lines.removeLast() }

            let label = Self.label(for: url, index: i, among: urls)
            let sample = Array(lines.prefix(500))
            let detector = TimestampDetector.detect(sampleLines: sample,
                                                    timeZoneOffset: assumedOffset,
                                                    assumedYear: assumedYear)
            let times = detector?.parseAll(lines) ?? [Date?](repeating: nil, count: lines.count)
            let hits = times.reduce(0) { $0 + ($1 == nil ? 0 : 1) }

            if detector == nil {
                warnings.append(String(format: L("merge.warn.noTimestamp"), url.lastPathComponent))
            }
            infos.append(SourceInfo(label: label, url: url, format: detector?.format,
                                    lineCount: lines.count, timestampedCount: hits))
            texts.append(lines)
            sources.append(LogMerger.Source(label: label, times: times))
        }

        let merged = LogMerger.merge(sources)
        let labelWidth = infos.map { $0.label.count }.max() ?? 0

        var out = header(infos: infos, totalLines: merged.count, warnings: warnings)
        out.reserveCapacity(merged.count * 96)
        var lastStamp = ""
        for e in merged {
            let stamp = e.hasOwnTimestamp ? Self.format(e.time, offset: displayOffset) : ""
            // 续行的时间字段留空。因为它会直接继承父行的时间。
            // 如果你在那里输入一个数字，它看起来就像“该行本身所拥有的时间”，但这其实是谎言。
            out += stamp.isEmpty ? String(repeating: " ", count: lastStamp.count) : stamp
            if !stamp.isEmpty { lastStamp = stamp }
            out += " │ "
            out += infos[e.source].label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            out += " │ "
            out += texts[e.source][e.line]
            out += "\n"
        }

        let dir = directory ?? FileManager.default.temporaryDirectory
        let name = "merged-\(urls.count)files-\(Self.stamp()).log"
        let dest = dir.appendingPathComponent(name)
        do {
            try out.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.writeFailed(error)
        }
        return Result(url: dest, sources: infos, totalLines: merged.count, warnings: warnings)
    }

    // MARK: - 标题

    private func header(infos: [SourceInfo], totalLines: Int, warnings: [String]) -> String {
        var s = "# " + String(format: L("merge.header.title"), infos.count, totalLines) + "\n"
        for i in infos {
            let fmt = i.format?.rawValue ?? L("merge.header.noFormat")
            s += "#   \(i.label)  \(i.url.lastPathComponent)  (\(fmt), "
            s += String(format: L("merge.header.lines"), i.lineCount, i.timestampedCount) + ")\n"
        }
        for w in warnings { s += "# ⚠️ \(w)\n" }
        s += "#\n"
        return s
    }

    // MARK: - 小道具

    /// 显示名称。当同名文件混杂在一起时（例如 `web-1/app.log` 和 `web-2/app.log`）。
    /// 添加父目录。如果主机收集的日志中没有出现此操作，则无法区分它们。
    static func label(for url: URL, index: Int, among urls: [URL]) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let duplicated = urls.filter { $0.deletingPathExtension().lastPathComponent == base }.count > 1
        guard duplicated else { return base }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "\(base)-\(index + 1)" : "\(parent)/\(base)"
    }

    /// `2026-07-30 12:34:56.789`。`DateFormatter` 未使用（每行都会调用一次）。
    static func format(_ date: Date?, offset: Int) -> String {
        guard let date else { return "" }
        let total = date.timeIntervalSince1970 + Double(offset)
        let whole = Int(floor(total))
        let millis = Int(((total - floor(total)) * 1000).rounded())
        let days = Int(floor(Double(whole) / 86_400))
        let rem = whole - days * 86_400
        let c = TimestampDetector.civilFromDays(days)
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2)) "
            + "\(pad(rem / 3600, 2)):\(pad((rem % 3600) / 60, 2)):\(pad(rem % 60, 2))"
            + ".\(pad(millis, 3))"
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func stamp() -> String {
        let now = Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())
        let rem = Int(now) % 86_400
        return "\(pad(rem / 3600, 2))\(pad((rem % 3600) / 60, 2))\(pad(rem % 60, 2))"
    }
}
