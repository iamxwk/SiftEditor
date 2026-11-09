import AppKit

/// 仅在应用程序运行时记住最近的剪贴板内容（简化版，免费核心）。
///
/// **非持久性操作。**完成后将消失——内容是从密码管理器复制的。
/// 将其以纯文本格式保存到磁盘上是企业使用中最糟糕的格式。
/// **请遵守 `org.nspasteboard.ConcealedType` 格式（复制密码时会设置 1Password 等格式）
/// 标志。（行业惯例，对应 nspasteboard.org）。忽略此标志会导致应用程序中“密码会列在历史记录中”。
///
/// 由于它只是轻度轮询  / `NSPasteboard.general.changeCount`，因此在运行时它将保持驻留状态。
/// 可以检索从其他应用复制的文件（无需特殊权限）。功能有限。
/// 仅限文本，限制项目数量，不支持搜索或置顶（只需简单地“点击一下即可全部列出”即可）。
/// 按照  / 内存 `clipboard-history-corporate-angle` 的约定。
public final class ClipboardHistory {
    public struct Entry: Equatable {
        public let text: String
        public let date: Date
        public init(text: String, date: Date) {
            self.text = text
            self.date = date
        }
    }

    /// 要记住的项目最大数量。首先丢弃最旧的项目。
    public var limit = 20
    public private(set) var entries: [Entry] = []
    /// 添加或删除项目时调用（主线程）。
    public var onChange: (() -> Void)?

    private var lastChangeCount: Int
    private var timer: Timer?
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    public init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    deinit { stop() }

    public func start(interval: TimeInterval = 0.5) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // 即使菜单显示或滚动时也不要停止。
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 一次实际的轮询操作。仅对 `NSPasteboard.general` 进行简短读取。
    /// 判决主体传递给 `record`（测试直接调用 `record`，不会污染真正的 pasteboard）。
    func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        record(types: pb.types ?? [], text: pb.string(forType: .string))
    }

    /// 纯判断+记录。被测主机。
    func record(types: [NSPasteboard.PasteboardType], text: String?) {
        guard !types.contains(Self.concealedType) else { return }
        guard let text, !text.isEmpty else { return }
        guard entries.first?.text != text else { return }   // 请勿创建同一内容的多个副本。
        entries.insert(Entry(text: text, date: Date()), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        onChange?()
    }

    public func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        onChange?()
    }
}
