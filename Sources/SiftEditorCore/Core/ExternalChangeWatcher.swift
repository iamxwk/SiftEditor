import Foundation

/// 磁盘上文件的“版本”。用于识别外部更改的最小指纹。
///
/// **将不会读取此文件的内容。** 每秒重新读取 10GB 文件是不切实际的。
/// 判断某事物是否“改变”完全取决于大小、修改时间和  / `stat(2)` 返回的 inode。
/// 包含  / inode 的原因是许多编辑器**将其写入并替换为单独的文件**（atomic save）。
/// 在替换过程中，尺寸和修改时间可能相同，但 inode 始终会改变。
struct FileStamp: Equatable {
    var size: Int64
    /// 更新时间（自 1970 年以来的秒数。视图精确到纳秒 = 不会错过 1 秒内的连续更改）。
    var modified: TimeInterval
    var inode: UInt64

    /// 读取当前磁盘状态。如果未找到任何文件，则返回 nil。
    static func read(_ url: URL) -> FileStamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let mtime = TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileStamp(size: Int64(st.st_size), modified: mtime, inode: UInt64(st.st_ino))
    }
}

/// 监控状态：1 项。
struct FileWatchEntry: Equatable {
    var url: URL
    /// 这是此应用已导入的版本（即现在应该显示的内容）。
    var known: FileStamp?
    /// 已发现更改，但情况尚未稳定。
    var pending: FileStamp?
    /// `pending` 连续出现的次数。
    var pendingTicks: Int = 0
}

/// 监控打开的文件是否在应用程序外部被修改。
///
/// 每个文件 1 个 tick，`stat` 一次。即使 10GB 打开，内容也不会被读取。
/// 费用微不足道。**不会就是否纳入做出任何决定**（由呼叫者决定谁做什么）。
final class ExternalChangeWatcher {
    /// 检测到更改时。在主线程上调用。
    var onChange: ((ObjectIdentifier) -> Void)?
    /// 检查间隔。由于使用 2 个 tick 进行稳定性检查，因此感知间隔约为 1 秒。
    var interval: TimeInterval = 0.5

    /// 由于它无法捕捉写入过程，**请等待您连续两次看到相同的版本**。
    /// 但是，由于像日志这样不断写入的文件令人不安，经过这么多次尝试后，我就接受它吧。
    static let forceAfterTicks = 4

    private(set) var entries: [ObjectIdentifier: FileWatchEntry] = [:]
    private var timer: Timer?

    deinit { stop() }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // 不要停止滚动或显示菜单。
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 注册/更新受监控目标为“当前磁盘状态：数据已导入”。
    /// 打开、保存或重新加载文件后立即调用。
    /// (**防止将您自己的帖子误认为外部修改的唯一机制**)。
    func note(key: ObjectIdentifier, url: URL) {
        entries[key] = FileWatchEntry(url: url, known: FileStamp.read(url))
    }

    func forget(key: ObjectIdentifier) {
        entries.removeValue(forKey: key)
    }

    /// 将监控列表与打开的文件列表进行匹配。
    /// **请勿修改您已查看过的版本**（如果您在此处重新创建版本，导入前所做的更改将会丢失）
    ///（他们将其升级到“已知版本”并压制了更改）。
    func sync(_ items: [(key: ObjectIdentifier, url: URL)]) {
        let live = Set(items.map(\.key))
        for key in entries.keys where !live.contains(key) { entries.removeValue(forKey: key) }
        for item in items {
            if entries[item.key]?.url != item.url { note(key: item.key, url: item.url) }
        }
    }

    /// 一轮巡逻。直接从测试中呼叫（不要等待计时器）。
    func tick() {
        for (key, var entry) in entries {
            let changed = Self.decide(&entry, current: FileStamp.read(entry.url))
            entries[key] = entry
            if changed { onChange?(key) }
        }
    }

    /// 1 项，1 个 tick 分钟确定（纯功能，不涉及时钟或文件）。如果需要导入，请选择 true。
    ///
    /// - 文件缺失 (`current == nil`) 时不执行任何操作。非 atomic 写入器
    /// 在我写作时它会暂时消失，所以如果我在这里大惊小怪，它可能会加载空白内容。
    /// 我会保留  / `known`，以便在我写完之后出现差异时能够发现它。
    static func decide(_ entry: inout FileWatchEntry,
                       current: FileStamp?,
                       forceAfter: Int = ExternalChangeWatcher.forceAfterTicks) -> Bool {
        guard let current else {
            entry.pending = nil
            entry.pendingTicks = 0
            return false
        }
        if current == entry.known {
            entry.pending = nil
            entry.pendingTicks = 0
            return false
        }
        entry.pendingTicks += 1
        // 要么同一个版本已经出现两次（即，写入完成），要么等待时间延长（即，仍在写入中）。
        if current == entry.pending || entry.pendingTicks >= forceAfter {
            entry.known = current
            entry.pending = nil
            entry.pendingTicks = 0
            return true
        }
        entry.pending = current
        return false
    }
}