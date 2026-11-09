import AppKit

/// 用于将显示状态传达给状态栏的信息。
struct ViewerState {
    var encodingName: String
    var lineCount: Int
    var lineCountIsExact: Bool
    var fileSize: Int
    var indexProgress: Double // 0...1
    /// 插入符位置（起始行和列）。在没有插入符的显示方式（筛选式、结构化、diff）中，插入符位置为 nil。
    var caret: (line: Int, column: Int)?
    /// 字符数（视觉字符 = 字形单位。换行符也算作一个字符）。`selected` 表示选定范围；如果未选择任何内容，则为 0。
    /// 只能进入包含全部文本的编辑窗格（大文件，diff，为 nil = 不显示）。
    var charCount: (total: Int, selected: Int)?
}

/// 一个通用界面，其中 1 个文档等于 1 个窗格。
///
/// 大文件为只读 `LargeFileViewer` (mmap + 稀疏索引)，
/// 小文件由 `EditableViewer` (NSTextView) 处理，该程序读取和编辑所有文件。
/// `MainWindowController` 通过此协议处理，而无需了解其具体类型。
///
/// 搜索、跟随和跳转是 `LargeFileViewer` 特有的功能。在编辑窗格中……
/// 保留默认实现 (no-op)，并使用 `supportsSearch` / `supportsFollow` 声明功能。
protocol DocumentPane: NSView {
    /// 打开文件（用于侧边栏/标题显示）。
    var fileURL: URL? { get }

    /// 状态栏更新通知。
    var onStateChange: ((ViewerState) -> Void)? { get set }
    /// 搜索状态通知（用于在搜索栏中显示结果数量）。
    /// 参数为（当前、总计、扫描、进度% 无效的正则表达式、**总计已达到限制并已截断**）。
    /// 如果最后一个标记为真，则总数为下限 = 搜索栏将显示“N 或更多结果”（不进行四舍五入）。
    var onSearchState: ((Int, Int, Bool, Int, Bool, Bool) -> Void)? { get set }
    /// 当文件被拖放时（控制器将其作为新文档打开）。
    var onDropFiles: (([URL]) -> Void)? { get set }

    /// 打开文件。如果失败，输出 false。
    @discardableResult func open(url: URL) -> Bool

    /// 重新导入磁盘内容（如果已被其他应用程序覆盖，则重新读取）。
    /// **保持您当前的位置**（由于它是自动运行的，如果您每次都跳到前面，它将失去跟踪位置的记录）。
    @discardableResult func reloadFromDisk() -> Bool

    /// 缓冲区（显示）字符编码（用于检查“重新打开”菜单）。
    var currentEncoding: DetectedEncoding { get }
    /// 保存时要使用的字符编码（用于检查“文本编码”菜单并显示状态）。
    var currentSaveEncoding: DetectedEncoding { get }
    /// 设置保存编码（暂不导出。设置为 dirty 并在下次保存时应用）。
    func setSaveEncoding(_ encoding: DetectedEncoding)
    /// 使用指定的编码重新打开当前文件（纠正自动编码错误导致的乱码）。成功：true。
    @discardableResult func reopen(withEncoding encoding: DetectedEncoding) -> Bool
    /// 将当前状态重新发送至 `onStateChange`（用于在切换文档时更新状态栏）。
    func reEmitState()
    /// 返回主文本焦点。
    func focusContent()
    /// 确保页面激活后立即呈现主要文本（防止错过初始布局元素）。
    func ensureVisibleLayout()
    /// 将当前全局字体大小反映到您自己的显示器上。
    func applyCurrentFontSize()
    /// 将长行换行设置 (AppSettings.lineWrap) 应用于其自身的显示。
    func applyLineWrap()
    /// 将显示设置（制表符宽度、行间距、当前行高亮显示、光标形状）应用到用户的显示器。
    func applyDisplaySettings()

    /// 是否应支持搜索（是否应显示搜索栏）？
    var supportsSearch: Bool { get }
    /// 是否支持“仅显示匹配的行”（筛选）？如果不支持，请隐藏窗格中的漏斗按钮。
    var supportsSearchFilter: Bool { get }
    /// 是否支持替换？**已找到但尚未写入**（结构化显示正在进行中/已筛选），因此应与搜索分开处理。
    /// 如果在保持文本格式不变的情况下替换文本，则您看到的内容与替换后的内容之间将存在差异。
    var supportsReplace: Bool { get }
    /// 是否支持后缀跟踪（tail -f）？
    var supportsFollow: Bool { get }

    // MARK: - 结构化显示（CSV/TSV/NDJSON 的只读格式。两个查看器都支持此格式。）

    /// 支持结构化显示（启用 View 菜单）。
    var supportsStructured: Bool { get }
    /// JSON 是否支持格式化（缩进整个文档）？此操作会将整个文本加载到内存中。
    /// 仅编辑小文件。大文件路径由面向行的 NDJSON 处理。
    var supportsJsonReformat: Bool { get }
    /// 当前结构化显示模式（nil = 关闭）。
    var structuredMode: StructuredMode? { get }
    /// 结构化视图中的列名（如果结构化视图已关闭，则为空）。
    var structuredColumnNames: [String] { get }
    /// 结构化视图中的列宽 (key → 宽度)。
    var structuredColumnWidths: [String: Int] { get }
    /// 结构化显示中的列最初指的是哪个原始单元格位置（从 0 开始，除以分隔符后的位置）？
    /// （与 `structuredColumnNames` 顺序相同）。**即使排序后显示顺序发生变化（B19），
    /// 此信息可防止列顺序改变后，原始列号与显示列号混淆。
    /// 只有 CSV/TSV 有意义（NDJSON 通过键检索，而固定宽度列不可排序）。
    var structuredColumnOriginalIndices: [Int] { get }
    /// 在“仅显示匹配行”中找到匹配行（**从 0 开始**）。如果未筛选，则为 nil。
    /// 如有筛选，后续按匹配行处理时应使用此列表。
    var filterMatchLines: [Int]? { get }
    /// 设置结构化显示模式（nil 可关闭 = 返回正常显示）。
    func setStructuredMode(_ mode: StructuredMode?)
    /// 将列顺序和宽度应用于当前结构化视图。
    /// 数据映射到  / 列名 (key)。如果未启用结构化视图，则不会发生任何操作。
    func applyStructuredLayout(order: [String], widths: [String: Int])

    /// 结构化显示中列计数不匹配的行数。
    var columnMismatchCount: Int { get }
    /// 不匹配列数发生变化时的回调函数。
    var onColumnMismatchChange: ((Int) -> Void)? { get set }
    /// 将光标移动到下一行，但列数不匹配并滚动。
    func jumpToNextMismatchLine()
    /// 将光标移动到列数不匹配的上一行并滚动。
    func jumpToPrevMismatchLine()

    /// JSON：是否支持即时查询（相当于 jmespath，结果会瞬时消失）？仅限小文件窗格。
    var supportsJsonQuery: Bool { get }
    /// 查询栏当前是否打开？（已检查菜单显示）
    var jsonQueryIsActive: Bool { get }
    /// 打开和关闭查询栏。
    func toggleJsonQuery()

    // MARK: - 编辑/保存（仅限编辑窗格。默认情况下，只读模式为 no-op）

    /// 是否可以编辑和保存？（启用保存菜单并确定只读横幅）。
    var canEdit: Bool { get }
    /// 是否有未保存的更改？
    var isDirty: Bool { get }
    /// 会话恢复的正文（用于保存/恢复未保存的新文档）。
    /// 用于存储不支持恢复的大文件和其他项目的窗格为 nil（默认）。
    var restorableText: String? { get }

    // MARK: - 未保存文本的保护 (DraftStore)

    /// id 中的 draft，包含未保存的新文档的正文（已保存但无法恢复的窗格为 nil）。
    var draftID: String? { get }
    /// 立即将累积的文本写入 draft（在终止/停用时调用此函数）。
    func flushDraft()
    /// 丢弃  / draft。**仅当用户关闭（丢弃）文档时调用。**
    func discardDraft()
    /// 未保存状态更改时的通知（标题栏中的已编辑点）。
    var onDirtyChange: ((Bool) -> Void)? { get set }
    /// 保存完成时的通知（用于与外部更改监视器同步和侧边栏更新）。
    var onSaveCompleted: (() -> Void)? { get set }
    /// 保存到现有路径。成功：true。
    @discardableResult func save() -> Bool
    /// 选择保存位置并保存（Save As）。如果成功，则保存为 true。
    @discardableResult func saveAs() -> Bool

    /// 可以打印吗？（也可以从打印对话框中将其另存为 PDF 吗？）
    /// 巨型文件可能达到数百万页，毫无意义，因此默认设置为 false。
    var canPrint: Bool { get }
    /// 显示打印对话框。
    func printDocument()

    // 搜索/跟随/跳转到行（在编辑窗格中默认值为 no-op）。
    func setSearchQuery(_ q: String)
    func setCaseSensitive(_ on: Bool)
    func setRegexMode(_ on: Bool)
    func setFilterMode(_ on: Bool)
    /// 通过在匹配行前后各添加一行来显示的行数（相当于 `grep -C`）。0 = 仅显示匹配的行。
    func setFilterContextLines(_ n: Int)
    /// 当前设置的前一行和后一行的数量（用于在搜索栏和菜单中显示）。
    var filterContextLines: Int { get }
    /// **独立于搜索**，仅显示指定的行（从 0 开始，升序排列）。
    /// 用于在时间分布中拖动时区的容器。如果数组为空，则将其清空。
    func showOnlyLines(_ lines: [Int])
    func findNext()
    func findPrev()
    func setFollowMode(_ on: Bool)
    /// 输入完成：导入最后接收到的数据后停止跟踪。
    func endFollow()
    var isFollowing: Bool { get }
    func goToLine(_ line1Based: Int)

    // MARK: 书签
    //
    // 调查过程需要反复进行。你先将搜索范围缩小到某一行，然后跳转到正文，阅读周围的文本，然后再返回去查找。
    // 你只能记住一到两个返程目的地；如果超过这个数量，请将线路编号写在备忘录中。
    // 。书签是将副本添加到工具中的功能。
    //
    // 仅限会话内使用（不保存）。它不是将标记写入文件的工具。
    // 每次重新打开时都会显示之前的条目，这在使用时也造成了不便，尤其是在将其用作研究工具时。

    /// 带有书签的行（**绝对行号，从 0 开始**）。用于装订线标记和列表。
    var bookmarkedLines: Set<Int> { get }
    /// 在光标所在行（大文件中显示的第一行）添加/删除书签。
    func toggleBookmark()
    /// 下一页 (`forward`) / 跳转到上一个书签。如果没有书签，则不执行任何操作。
    func goToBookmark(forward: Bool)
    /// 目前是否只显示书签行？
    var isBookmarkView: Bool { get }
    /// 仅显示/返回书签行。如果由于书签数量为 0 或正在编辑而无法切换，请使用 false。
    @discardableResult func setBookmarkView(_ on: Bool) -> Bool
    /// 替换当前匹配项并继续（重复替换）。
    func replaceCurrent(with replacement: String)
    /// 替换所有匹配项（撤销 1）。
    func replaceAll(with replacement: String)

    /// 当前选定文本（仅当可编辑窗格中有选定内容时）。输入来自编辑工具箱。
    var selectedText: String? { get }
    /// Short selection for Find prefill; implementations must check length before reading bytes.
    var selectedTextForFind: String? { get }
    /// 将当前选定内容替换为 `text`（1 撤销 / 替换后保留选定文本）。
    func replaceSelection(with text: String)

    /// 检索指定行（从第 1 行开始）的主要文本（不包括末尾的换行符）。
    func lineText(_ line1Based: Int) -> String?
    /// 将指定行（从 1 开始）的文本替换为 `newText`（撤销 1）。
    func replaceLine(_ line1Based: Int, with newText: String) -> Bool

    // MARK: - 多光标（仅限小文件编辑窗格）

    /// 支持多光标（启用菜单）。用于查看大文件的窗格仍为单个光标。
    var supportsMultiCursor: Bool { get }
    /// 将插入符号添加到上一行/下一行的相同数字上。
    func addCaret(above: Bool)
    /// 将与当前选定单词相同的下一个单词添加到选择中（如果没有选择，则选择光标位置的单词）。
    func selectNextOccurrence()

    /// 替换时是否保留原始单词的大小写（在搜索栏中切换）。
    func setPreserveCase(_ on: Bool)

    // MARK: - 数字尺 (A) 和数字导轨 (B)
    //
    // 用于统计固定长度数据中“哪个数字对应哪个数字”的工具。
    // 结构化显示可以处理带分隔符的格式，但这对于固定长度的格式不起作用。

    /// 支持数字标尺（启用菜单）。
    var supportsColumnRuler: Bool { get }
    /// 数字标尺是否显示（在菜单中已勾选）？
    var columnRulerVisible: Bool { get }
    /// 切换数字标尺的显示。**显示时，请剪断换行符**（如果换行，一行将被分割，数字将无法固定）。
    func setColumnRulerVisible(_ on: Bool)
    /// 是否有至少一条数字引导线（启用“隐藏引导线”）。
    var hasColumnGuides: Bool { get }
    /// 移除所有数字引导线。
    func clearColumnGuides()

    // MARK: - 固定长度项目定义 (C)

    /// 当前绘制的指南数字（从 1 开始，升序排列）= 项目之间的间隔。
    var columnGuideColumns: [Int] { get }
    /// 一次性替换项目定义（边界数字）。可通过数字输入对话框和文件进行操作。
    /// 内存检索通过此处。**空数组 = 未定义。**
    func setColumnGuides(_ columns: [Int])
}

extension DocumentPane {
    var supportsSearch: Bool { true }
    var supportsSearchFilter: Bool { true }
    var supportsReplace: Bool { true }
    var supportsFollow: Bool { true }

    var supportsStructured: Bool { false }
    var supportsJsonReformat: Bool { false }
    var structuredMode: StructuredMode? { nil }
    var structuredColumnNames: [String] { [] }
    var structuredColumnWidths: [String: Int] { [:] }
    var structuredColumnOriginalIndices: [Int] { [] }
    var filterMatchLines: [Int]? { nil }
    func setStructuredMode(_ mode: StructuredMode?) {}
    func applyStructuredLayout(order: [String], widths: [String: Int]) {}

    var supportsJsonQuery: Bool { false }
    var jsonQueryIsActive: Bool { false }
    func toggleJsonQuery() {}

    /// 默认操作是重新打开（覆盖任何需要保留其位置的窗格）。
    @discardableResult func reloadFromDisk() -> Bool {
        guard let url = fileURL else { return false }
        return open(url: url)
    }

    var currentEncoding: DetectedEncoding { .utf8 }
    var currentSaveEncoding: DetectedEncoding { .utf8 }
    func setSaveEncoding(_ encoding: DetectedEncoding) {}
    @discardableResult func reopen(withEncoding encoding: DetectedEncoding) -> Bool { false }

    // 默认只读窗格（不可编辑或保存）。每个窗格都维护 onDirtyChange。
    var canEdit: Bool { false }
    var isDirty: Bool { false }
    var onSaveCompleted: (() -> Void)? { get { nil } set {} }
    var restorableText: String? { nil }

    // 没有未保存文本的窗格（只读，大文件）与 draft 无关。
    var draftID: String? { nil }
    func flushDraft() {}
    func discardDraft() {}
    @discardableResult func save() -> Bool { false }
    @discardableResult func saveAs() -> Bool { false }

    // 请勿打印巨大的只读文件（8600 万行 = 数百万页）。
    var canPrint: Bool { false }
    func printDocument() {}

    func setSearchQuery(_ q: String) {}
    func setCaseSensitive(_ on: Bool) {}
    func setRegexMode(_ on: Bool) {}
    func setFilterMode(_ on: Bool) {}
    func setFilterContextLines(_ n: Int) {}
    var filterContextLines: Int { 0 }
    func showOnlyLines(_ lines: [Int]) { NSSound.beep() }
    func findNext() {}
    func findPrev() {}
    func setFollowMode(_ on: Bool) {}
    func endFollow() {}
    var isFollowing: Bool { false }
    func goToLine(_ line1Based: Int) {}
    // 默认设置为“无法处理书签”。diff 还有一些方面，例如窗格中的行不属于单个文档。
    var bookmarkedLines: Set<Int> { [] }
    func toggleBookmark() {}
    func goToBookmark(forward: Bool) {}
    var isBookmarkView: Bool { false }
    var columnMismatchCount: Int { 0 }
    var onColumnMismatchChange: ((Int) -> Void)? { get { nil } set {} }
    func jumpToNextMismatchLine() {}
    func jumpToPrevMismatchLine() {}
    func setBookmarkView(_ on: Bool) -> Bool { false }
    func replaceCurrent(with replacement: String) {}
    func replaceAll(with replacement: String) {}

    // 编辑工具箱的默认设置。只读窗格：未选择任何内容 = 不执行任何操作。
    var selectedText: String? { nil }
    var selectedTextForFind: String? { nil }
    func replaceSelection(with text: String) { NSSound.beep() }
    func lineText(_ line1Based: Int) -> String? { nil }
    func replaceLine(_ line1Based: Int, with newText: String) -> Bool { false }

    // 默认多光标（不支持的窗格 = 大文件，diff）。
    var supportsMultiCursor: Bool { false }
    func addCaret(above: Bool) {}
    func selectNextOccurrence() {}
    func setPreserveCase(_ on: Bool) {}

    /// 对选定文本应用纯变换。简单地叠加在 selectedText/replaceSelection 之上。
    func applyTextTransform(_ transform: TextTransform) {
        guard let source = selectedText, !source.isEmpty else { NSSound.beep(); return }
        guard let result = transform.apply(source) else { NSSound.beep(); return }   // 変換不能（不正入力）
        guard result != source else { return }   // 无更改意味着无撤销。
        replaceSelection(with: result)
    }
    // 默认数字标尺（不支持的窗格 = diff）。
    var supportsColumnRuler: Bool { false }
    var columnRulerVisible: Bool { false }
    func setColumnRulerVisible(_ on: Bool) {}
    var hasColumnGuides: Bool { false }
    func clearColumnGuides() {}
    var columnGuideColumns: [Int] { [] }
    func setColumnGuides(_ columns: [Int]) {}

    func applyLineWrap() {}
    func ensureVisibleLayout() {}
}

extension Notification.Name {
    /// 当仅显示书签的最后一行被删除时，显示将恢复到其原始状态（object 是返回的窗格）。
    /// 用于下拉搜索栏按钮。
    static let bookmarkViewEnded = Notification.Name("SiftEditor.bookmarkViewEnded")
}
