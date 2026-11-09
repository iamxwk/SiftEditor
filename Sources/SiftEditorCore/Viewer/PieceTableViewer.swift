import AppKit

/// 一个自定义查看器，可以处理从显示、编辑、保存、搜索到跟踪大型文件的所有操作（1.0 版本中大型文件的默认设置）。
///
/// 使用“固定大小 `DocumentView` + 自定义 `NSScroller`（每行）”缩放至任意大小。
/// 原图为 `FileBuffer` (mmap) 与 `PieceTable` 叠加，仅对可见的线条进行解码并现场绘制。
///
/// - 未编辑（干净）：显示、搜索（`SearchEngine`）和关注（tail -f）使用 LineIndex + mmap 执行。
/// - 编辑后 (dirty): piece 和 table 显示为 true，搜索和跟踪暂时暂停（由于与 mmap 存在差异）。
/// 保存涉及流式导出整个文本 → 替换为 atomic（异步，显示进度）。
final class PieceTableViewer: NSView, DocumentPane {
    private let documentView = DocumentView()
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))

    // MARK: - 数字尺 (A) 和数字导轨 (B)
    private let columnRuler = ColumnRulerView()
    private var columnRulerOn = false
    /// 列名称栏（带列宽控制柄），用于在构建结构时显示在主文本上方。位置与列标尺相同。
    private let structuredHeader = StructuredHeaderView()
    /// 显示标尺前需设置换行。如果线条换行，数字位数将不固定，因此在显示标尺时需要进行裁剪。
    private var wrapBeforeColumnRuler: Bool?

    /// 正在读取的字节序列的来源。这可以是本地文件，也可以是远程的稀疏缓存文件（`ByteSource`）。
    private var fileBuffer: ByteSource?
    private var lineIndex: LineIndex?
    var exactSourceLineCount: Int? {
        guard let lineIndex, lineIndex.isComplete else { return nil }
        return lineIndex.exactLineCount
    }
    /// piece table 叠加在原件上（从 B2 开始编辑的基础。通过传递已完成索引中的换行符数量生成）。
    private var pieceTable: PieceTable?
    /// 缓冲区编码（字节序列为 piece table）。用于显示、插入和搜索。
    private var encoding: DetectedEncoding = .utf8
    /// 用户在“重新打开”时明确指定的编码（此编码在重新加载时保留，因为它不会恢复为自动检测）。
    private var userChosenEncoding: DetectedEncoding?
    /// 保存时写入的编码。默认值与缓冲区相同。如果用户更改此值，则编码将偏离 `encoding`。
    /// 下次保存时，请将 S (=encoding) 转换为 T (=saveEncoding) 并导出，然后使用该编码重新打开以进行匹配。
    private var saveEncoding: DetectedEncoding = .utf8
    /// 文件换行符。插入或粘贴的换行符将与此对齐（加载期间检测；默认值为 LF）。
    private var lineEnding: LineEnding = .lf
    private(set) var fileURL: URL?

    /// 当前显示的第一行。
    private var topLine = 0
    /// 累积触控板上的分数滚动。
    private var scrollAccumulator: CGFloat = 0
    /// 每行读取的最大字节数（为极长的行提供安全保障）。
    private let maxLineBytes = 64 * 1024
    private let scrollerWidth: CGFloat = 16

    /// 当前显示的每一行的字节范围（已移除 CRLF - 用于插入符号 ↔ 字节转换）。
    private var visibleRanges: [Range<Int>] = []

    // MARK: - 插入符号/选择（字节域）

    /// 插入符位置（从文档开头算起的字节偏移量）。
    private var caretByte = 0
    /// 拖拽选择锚点（字节）。点击此锚点将得到与 caret 相同的值，即未选中任何对象。
    private var selectionAnchor = 0
    /// 当前选择范围（如果为空则为 nil）。
    private var selectionRange: Range<Int>? {
        let lo = min(caretByte, selectionAnchor)
        let hi = max(caretByte, selectionAnchor)
        return lo < hi ? lo..<hi : nil
    }
    private var blinkTimer: Timer?
    /// 上下移动时要保留的目标列（行内 UTF-16 偏移）。水平移动或编辑时禁用。
    private var caretGoalColumn: Int?

    /// IME 字符串正在转换 (B2c)。空字符串表示不进行转换。未包含在文档中 (PieceTable)。
    /// 仅在插入符位置绘制带下划线的图形。确认后插入实际文本。
    private var markedText = ""
    /// 正在转换的字符串中的选择 / 插入符 (marked 在 UTF-16 中)。
    private var markedSelection = NSRange(location: 0, length: 0)
    private var hasMarked: Bool { !markedText.isEmpty }

    /// 编辑撤销/重做 (B2b)。1 次编辑 = 1 次操作堆叠为反向操作。
    private let undoMgr = UndoManager()
    /// 为撤销操作保留的旧字节上限。超过此限制的编辑将无法撤销，并且历史记录将被丢弃（内存保护）。
    private let maxUndoBytes = 64 * 1024 * 1024

    var onStateChange: ((ViewerState) -> Void)?
    var onSearchState: ((Int, Int, Bool, Int, Bool, Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    // MARK: - 編集・保存状態（B3）

    /// 是否有未保存的更改？
    private(set) var isDirty = false
    /// 是否正在进行异步保存？（在此期间编辑功能将暂停。但仍可滚动和查看。）
    private var isSaving = false
    /// 取消正在进行的保存的令牌（由每个数据块中的后台线程引用）。
    private var saveToken: CancelToken?
    /// 未保存状态更改通知（标题栏中已编辑的点）。
    var onDirtyChange: ((Bool) -> Void)?
    /// piece table 背景窗格是编辑窗格（在构建索引时，输入功能会被禁用）。
    var canEdit: Bool { true }
    /// 插入时，由于检测编码无法表示该字符，是否回退到 UTF-8（保存时曾发出过一次警告）？
    private var didEncodingFallback = false
    /// 应用批量替换操作（抑制每个 perform 的 refresh/ 滚动，并在最后只重绘一次）。
    private var batchEditing = false
    /// 替换操作期间不要删除搜索模式（因为它会通过重复替换继续搜索下一个匹配项）。
    private var preserveSearchOnEdit = false

    // 搜索/跟踪 (B4)：当存在未保存的编辑时禁用（因为文档将与 mmap 不同）。
    // 即使使用结构化视图（只读格式化视图）也无效。
    // 搜索和跟踪关注的是**字节位置**，而数字对齐关注的是**显示**。它们彼此独立，因此即使在结构化数据中也可以应用。
    // 当“仅显示匹配的行（筛选）”与结构化格式结合使用时，结果为“grep，同时保持数字对齐”。
    // 但是，无法显示特定行的匹配高亮显示（因为格式化后的字符位置与原始字节位置不对应）。
    // （参见  `decodeLine`）。出于同样的原因，在结构化过程中不接受替换（`supportsReplace`）。
    var supportsSearch: Bool { searchEngine != nil && !isDirty }
    var supportsReplace: Bool { structuredFormatter == nil }
    var supportsFollow: Bool { fileBuffer != nil && !isDirty }

    // MARK: - 结构化显示（CSV/TSV/NDJSON 的只读格式）
    /// nil = 关闭。启用此设置后，编辑、搜索和自动换行功能将被禁用，可见线条将被格式化并绘制。
    private var structuredFormatter: TabularFormatter?
    var supportsStructured: Bool { fileBuffer != nil }
    var structuredMode: StructuredMode? { structuredFormatter?.mode }
    var structuredColumnNames: [String] { structuredFormatter?.columns.map(\.key) ?? [] }
    var structuredColumnWidths: [String: Int] {
        guard let fmt = structuredFormatter else { return [:] }
        return Dictionary(fmt.columns.map { ($0.key, $0.width) }, uniquingKeysWith: { first, _ in first })
    }
    var structuredColumnOriginalIndices: [Int] { structuredFormatter?.columns.map(\.originalIndex) ?? [] }
    /// 匹配筛选条件中的行（从 0 开始计数）。即使行被截断到上限，也返回该行。
    /// （分析师自行表示“N 或更多”）。
    var filterMatchLines: [Int]? { filterMode ? searchResults.lines : nil }

    /// 虽然干净（未经编辑），但显示、搜索和关注均使用 LineIndex+mmap（原始内容 = piece table）。
    /// 当编辑为 dirty、piece 和 table 时，显示为真，搜索和跟踪停止。
    private var readsFromOriginal: Bool { !isDirty }

    // MARK: - 搜索状态（从 B4 和 LargeFileViewer 转移而来。仅在清理后有效）
    private var searchQuery = ""
    private var searchTerms: [String] = []
    private var regexMode = false
    private var searchRegex: NSRegularExpression?
    private var caseSensitive = false
    /// 是否保留替换字符串中匹配单词的大小写 (`CasePreserving`)。
    private var preserveCase = false
    private var filterMode = false
    /// 匹配行 (`grep -C`) 前后要添加的行数。`filterDisplayLines` 的材料。
    private var contextLines = AppSettings.filterContextLines
    /// 筛选过程中实际用于对结果进行排序的行（即，按升序向前和向后扩展的匹配行）。
    /// 如果  / `contextLines` 为 0，则其内容与 `searchResults.lines` 相同。
    private var filterDisplayLines: [Int] = []
    /// 显示的行不是从搜索（拖动选择时间分布）中获得的 = 未添加上一行和下一行。
    /// 如果包含选定时间段之外的行，“选定范围”将变得不准确。
    private var filterIsExplicit = false
    private var matchHighlight = EditorTheme.current().searchMatch
    /// ANSI 调色板（已随主题更改更新）。
    private var ansiPalette = ANSIPalette.from(theme: EditorTheme.current())
    private var searchEngine: SearchEngine?
    private var searchResults = SearchEngine.Result()
    private var currentMatchIdx = -1
    private var currentMatchLine = -1
    private var searchDebounce: DispatchWorkItem?
    private var searchEpoch = 0

    /// tail -f（后缀跟踪）。仅在清洁时有效。
    private var followMode = false
    /// 当前是否正在运行延长搜索期（以防止后续计时器多次触发）？
    private var searchBusy = false
    private var followTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        blinkTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func setup() {
        documentView.configure(font: EditorFont.current())
        documentView.wrapEnabled = AppSettings.lineWrap
        documentView.onScrollWheel = { [weak self] in self?.handleScrollWheel($0) }
        documentView.onKeyDown = { [weak self] in self?.handleKeyDown($0) }
        documentView.onCopy = { [weak self] in self?.copySelectionOrVisible() }
        documentView.onCut = { [weak self] in self?.cutSelection() }
        documentView.onPaste = { [weak self] in self?.pasteClipboard() }
        documentView.onSelectAll = { [weak self] in self?.selectAllText() }
        documentView.onMouseDown = { [weak self] in self?.handleMouseDown($0) }
        documentView.onGutterClick = { [weak self] in self?.gutterClicked(line: $0, clickCount: $1) }
        documentView.onMouseDragged = { [weak self] in self?.handleMouseDragged($0) }
        addSubview(documentView)

        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .default
        scroller.target = self
        scroller.action = #selector(scrollerAction(_:))
        scroller.isEnabled = false
        addSubview(scroller)

        columnRuler.isHidden = true
        columnRuler.onToggleGuide = { [weak self] col in self?.toggleColumnGuide(col) }
        columnRuler.onMoveGuide = { [weak self] from, to in self?.moveColumnGuide(from, to: to) ?? false }
        structuredHeader.isHidden = true
        structuredHeader.onResize = { [weak self] i, w in self?.resizeStructuredColumn(i, to: w) }
        structuredHeader.onReorder = { [weak self] from, to in self?.reorderStructuredColumn(from, to) }
        addSubview(structuredHeader)
        addSubview(columnRuler)

        // 插入符号闪烁。
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.documentView.caretOn.toggle()
            self.documentView.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t

        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(self, selector: #selector(filterContextChanged),
                                               name: .siftEditorFilterContextChanged, object: nil)
        layoutSubviewsManually()
    }

    // MARK: - 布局

    override var isFlipped: Bool { true }

    func applyCurrentFontSize() {
        documentView.configure(font: EditorFont.current())
        layoutSubviewsManually()
        refresh()
    }

    /// 应用换行设置（更改或切换文档时应用 config）。
    func applyLineWrap() {
        guard structuredFormatter == nil else { return }   // 水平滚动问题已修复，结构化正在进行中。
        // 水平滚动功能已修复，即使标尺处于活动状态也依然存在。请记住此设置，并在隐藏标尺时应用它。
        // （如果未选中此项，则在环境设置中启用换行符后，缩放和文本将错位）。
        guard !columnRulerOn else { wrapBeforeColumnRuler = AppSettings.lineWrap; return }
        documentView.wrapEnabled = AppSettings.lineWrap
        if documentView.wrapEnabled { documentView.setHorizontalOffset(0) }
        refresh()
    }

    // MARK: - 切换结构化视图

    func setStructuredMode(_ mode: StructuredMode?) {
        applyStructuredMode(mode)
        updateColumnGuideVisibility()   // 成型后不要在显示屏上留下辅助线。
        layoutSubviewsManually()        // 在构建结构时将列名替换为带状结构。
    }

    private func applyStructuredMode(_ mode: StructuredMode?) {
        guard let mode else {
            structuredFormatter = nil
            // 在筛选过程中，仅显示匹配的行，且不连续，因此编辑输入不会被重置。
            documentView.inputHandler = filterMode ? nil : self
            documentView.wrapEnabled = AppSettings.lineWrap
            refresh()
            return
        }
        // JSON 格式化是一种重新格式化整个单个文档的操作，会延迟行窗口的渲染。
        // 无法放入过大的文件路径中（格式化单个巨大的 JSON 文件是不切实际的）。面向行
        // NDJSON 负责此项工作。small 文件由 EditableViewer 处理。
        if mode == .json { NSSound.beep(); return }
        // 不需要与过滤器互斥。仅显示匹配的行，数字对齐方式为“grep，同时保持数字对齐”。
        let sample = structuredSampleLines(1000)
        // 固定长度数据无法从其内容推断出来。列指南（即人工划分的列）本身就是定义。
        var fields: [ClosedRange<Int>] = []
        if mode == .fixedWidth {
            guard documentView.columnGuides.hasFieldBoundaries else { NSSound.beep(); return }
            fields = documentView.columnGuides.fieldRanges(fitting: sample)
            guard !fields.isEmpty else { NSSound.beep(); return }
        }
        structuredFormatter = TabularFormatter.build(mode: mode, sampleLines: sample, fields: fields)
        documentView.inputHandler = nil                  // 只读
        documentView.wrapEnabled = false                 // 水平滚动（不换行）
        documentView.setHorizontalOffset(0)
        setTopLine(0)
        refresh()
    }

    /// 计算结构化数据中列宽的示例（来自第一行 n 和最后一行 n 的原始字符串）。
    ///
    /// 当只看开头时，后半部分数字较长的列（顺序编号、ID 等）以缩写形式显示。
    /// 例如，当/581万行CSV的第一列被截断为`581…`时，由于无法扫描所有行，
    /// 通过观察两端来确定列宽。中间延伸过长的列仍然会被截断。
    /// 这可以用来查找单调递增的列。
    ///
    /// **筛选时，仅显示当前行**（匹配行及其周围行 N）。保持列对齐方式不变。
    /// 目标是获取  / grep，因此如果无法读取缩小范围的结果，那就毫无意义。
    /// 在仅存在于中间的文件中，无论如何查看整个文件的两端，都找不到匹配的行 `con…` 和
    /// 已关闭（2026-08-21）。上下文行列在同一张表中，因此使用相同的方法进行衡量。
    private func structuredSampleLines(_ n: Int) -> [String] {
        if filterMode {
            let matches = filterDisplayLines
            guard !matches.isEmpty else { return [] }   // 如果结果为 0， 不会重新测量（呼叫方保持当前位数）。
            // ：匹配的行分散在整个文件中，因此您必须一次一行地检索它们（无法连续读取）。
            // 10GB 实际测量值：2000 行 = 0.419 秒 / 400 行 = 0.084 秒 (2026-08-21)。过滤器是
            // 付款会在确认后立即进行，因此如果数量很多，则两端各到 200 行就会停止。
            // 匹配项少于 400 行 = 普通筛选会查看所有内容，所以这甚至都不是一个近似值。
            let cap = 200
            var picked = matches.count > 2 * cap
                ? Array(matches.prefix(cap)) + Array(matches.suffix(cap))
                : matches
            // CSV/TSV 的列名取自**样本的第一行**。如果您只传递匹配的行……
            // 第一个匹配项将成为列名，因此请务必添加第一行（= 标题行）。
            if picked.first != 0 { picked.insert(0, at: 0) }
            return picked.map { decodeLineString(lineRanges(from: $0, count: 1).first ?? (0..<0)) }
        }
        let head = lineRanges(from: 0, count: n).map { decodeLineString($0) }
        let total = displayCount
        guard total > n else { return head }
        let tailStart = max(n, total - n)
        let tail = lineRanges(from: tailStart, count: total - tailStart).map { decodeLineString($0) }
        return head + tail
    }

    /// 根据当前显示的行重新定义列宽（仅限结构化）。
    ///
    /// 当要显示的行集发生变化时调用此函数 = 筛选 ON/OFF，确认匹配，并选择时间范围。
    /// **商品分隔符（固定长度 `fields`）由人工放置，因此将保留。** 仅重新测量列宽。
    /// 通过拖动更改的列宽在此处被丢弃（此功能的作用是重新调整列宽以适应可见行）。
    private func rebuildStructuredColumns() {
        guard let fmt = structuredFormatter else { return }
        let sample = structuredSampleLines(1000)
        // ：当匹配项为0时，重新测量后该列会消失。输入时会短暂显示0个匹配项。
        // 是正常的，所以不要将列名带留空 = 保留当前的位数。
        guard !sample.isEmpty else { return }
        structuredFormatter = TabularFormatter.build(mode: fmt.mode, sampleLines: sample, fields: fmt.fields)
        syncStructuredHeader()   // 列名带也应调整为新的数字。
    }

    /// 反映显示设置（制表符宽度、行间距、当前行高亮显示、光标形状）。
    func applyDisplaySettings() {
        documentView.highlightCurrentLine = AppSettings.highlightCurrentLine
        documentView.cursorShape = AppSettings.cursorShape
        documentView.showLineNumbers = AppSettings.showLineNumbers
        documentView.showInvisibles = AppSettings.showInvisibles
        matchHighlight = EditorTheme.current().searchMatch
        ansiPalette = ANSIPalette.from(theme: EditorTheme.current())
        // 制表符宽度、行间距和配色方案由 configure (font:) 合并到段落样式、行高和颜色中。
        documentView.configure(font: EditorFont.current())
        layoutSubviewsManually()
        refresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSubviewsManually()
        refresh()
    }

    private func layoutSubviewsManually() {
        let h = bounds.height, w = bounds.width
        // 在结构化过程中，显示列名横幅。数字标尺是用于**原始数字**的工具，因此格式化后将不会显示。
        // （使用相同的位置，但只能使用其中一个）。
        let headerOn = structuredFormatter != nil
        structuredHeader.isHidden = !headerOn
        columnRuler.isHidden = !columnRulerOn || headerOn
        let topH: CGFloat = headerOn ? StructuredHeaderView.height : (columnRulerOn ? ColumnRulerView.height : 0)
        let contentW = max(0, w - scrollerWidth)
        columnRuler.frame = NSRect(x: 0, y: 0, width: contentW, height: headerOn ? 0 : topH)
        structuredHeader.frame = NSRect(x: 0, y: 0, width: contentW, height: headerOn ? topH : 0)
        documentView.frame = NSRect(x: 0, y: topH, width: contentW, height: max(0, h - topH))
        scroller.frame = NSRect(x: max(0, w - scrollerWidth), y: topH, width: scrollerWidth, height: max(0, h - topH))
        syncColumnRuler()
        syncStructuredHeader()
    }

    /// 将当前列、原点和滚动量发送到标题栏（使用与标尺相同的值）。
    private func syncStructuredHeader() {
        guard let fmt = structuredFormatter else { return }
        structuredHeader.columnWidth = documentView.columnWidth
        structuredHeader.contentInset = documentView.contentOriginX
        structuredHeader.horizontalOffset = documentView.wrapEnabled ? 0 : documentView.horizontalOffset
        let starts = fmt.columnStartColumns()
        structuredHeader.columns = zip(fmt.columns, starts).map {
            StructuredHeaderView.Column(name: $0.key, start: $1, width: $0.width)
        }
        structuredHeader.allowsReorder = (fmt.mode != .fixedWidth)
    }

    /// 通过拖动更改列宽（从标题栏调用）。**每次绘制时行都会重新排列。
    /// 在这里，只需替换形状并重新绘制它**（同样适用于 10 GB）。
    private func resizeStructuredColumn(_ index: Int, to width: Int) {
        guard let fmt = structuredFormatter else { return }
        structuredFormatter = fmt.withColumnWidth(index, width)
        syncStructuredHeader()
        refresh()
    }

    /// 通过拖动重新排列列（从标题栏调用。B19）。
    private func reorderStructuredColumn(_ from: Int, _ to: Int) {
        guard let fmt = structuredFormatter else { return }
        structuredFormatter = fmt.movingColumn(from, to: to)
        syncStructuredHeader()
        refresh()
    }

    /// 应用结构化视图的列布局。除非启用结构化视图，否则将忽略。
    func applyStructuredLayout(order: [String], widths: [String: Int]) {
        guard let fmt = structuredFormatter else { return }
        structuredFormatter = fmt.applyingLayout(order: order, widths: widths)
        syncStructuredHeader()
        refresh()
    }

    // MARK: - 数字尺 (A) 和数字导轨 (B)

    var supportsColumnRuler: Bool { true }
    var columnRulerVisible: Bool { columnRulerOn }
    var hasColumnGuides: Bool { !documentView.columnGuides.isEmpty }

    func setColumnRulerVisible(_ on: Bool) {
        guard on != columnRulerOn else { return }
        columnRulerOn = on
        columnRuler.isHidden = !on
        if on {
            if documentView.wrapEnabled {
                wrapBeforeColumnRuler = true
                documentView.wrapEnabled = false
                documentView.setHorizontalOffset(0)
            }
        } else if wrapBeforeColumnRuler != nil {
            wrapBeforeColumnRuler = nil
            // 启用结构化视图后，水平滚动是固定的，因此不要恢复原状（以免扰乱他们的工作流程）。
            if structuredFormatter == nil {
                documentView.wrapEnabled = AppSettings.lineWrap
                if documentView.wrapEnabled { documentView.setHorizontalOffset(0) }
            }
        }
        layoutSubviewsManually()
        refresh()
    }

    func clearColumnGuides() {
        guard !documentView.columnGuides.isEmpty else { return }
        documentView.columnGuides.removeAll()
        columnGuidesChanged()
    }

    var columnGuideColumns: [Int] { documentView.columnGuides.columns }

    func setColumnGuides(_ columns: [Int]) {
        let next = ColumnGuides(columns)
        guard next != documentView.columnGuides else { return }
        documentView.columnGuides = next
        columnGuidesChanged()
    }

    private func toggleColumnGuide(_ column: Int) {
        documentView.columnGuides.toggle(column)
        columnGuidesChanged()
    }

    private func moveColumnGuide(_ from: Int, to: Int) -> Bool {
        guard documentView.columnGuides.move(from, to: to) else { return false }
        columnGuidesChanged()
        return true
    }

    /// 当参考线改变时，对齐标尺、正文和**文件内存**。
    /// 如果启用了固定长度显示，则列分隔符本身已更改，因此请重新格式化文本。
    private func columnGuidesChanged() {
        columnRuler.guides = documentView.columnGuides
        updateColumnGuideVisibility()
        AppSettings.setColumnGuides(documentView.columnGuides.columns, for: fileURL)
        if structuredFormatter?.mode == .fixedWidth { setStructuredMode(.fixedWidth) } else { refresh() }
    }

    /// 将之前保存的项目定义恢复到已打开的文件中。**如果已保存，标尺也会显示。**
    /// （如果只画一条垂直线而没有任何解释，则无法知道这条线是做什么用的）。
    private func restoreColumnGuides() {
        let remembered = AppSettings.columnGuides(for: fileURL)
        documentView.columnGuides = ColumnGuides(remembered)
        columnRuler.guides = documentView.columnGuides
        updateColumnGuideVisibility()
        if !remembered.isEmpty, !columnRulerOn { setColumnRulerVisible(true) }
    }

    /// 将当前数字宽度、原点、滚动量和光标数字发送到标尺。
    /// **绘制主文本时，请使用与 `DocumentView` 相同的原点和水平滚动量值。**
    /// （如果单独计算，比例和文本将相差一位小数）。
    /// 格式化后不要在显示屏上叠加参考线。
    ///
    /// **项目定义为“原始文本中的列数”**。进入结构化显示时，文本（包括分隔符）将被重新排列。
    /// 用线穿过同一个数字指向的点并非项目的终点（我在实际设备上发现了这一点）。定义保持不变。
    /// 仅停止绘图和操作；退出后恢复正常。
    private func updateColumnGuideVisibility() {
        documentView.columnGuidesHidden = structuredFormatter != nil
        columnRuler.guidesEditable = structuredFormatter == nil
    }

    private func syncColumnRuler() {
        guard columnRulerOn else { return }
        columnRuler.columnWidth = documentView.columnWidth
        columnRuler.contentInset = documentView.contentOriginX
        columnRuler.horizontalOffset = documentView.wrapEnabled ? 0 : documentView.horizontalOffset
        columnRuler.guides = documentView.columnGuides
        let caretColumn = caretColumnForRuler()
        columnRuler.currentColumn = caretColumn
        // 您当前正在绘制哪个项目？最后一个项目结束于您当前绘制的线条的最长点。
        let widest = documentView.lines.reduce(0) { max($0, TabularFormatter.displayWidth($1.string)) }
        columnRuler.currentField = caretColumn.flatMap {
            documentView.columnGuides.fieldRange(containing: $0, lastColumn: max(widest, $0))
        }
        columnRuler.selectedColumns = nil   // 大文件的选区通常跨越多行，因此不要将其分组到一个文件中。
    }

    /// 插入符号所在位置的数字（从 1 开始计数）。如果未在可见行中找到该数字，则为 nil。
    private func caretColumnForRuler() -> Int? {
        guard let c = documentView.caret else { return nil }
        return c.utf16Index + 1
    }

    private var visibleLineCount: Int {
        max(1, Int(ceil(documentView.bounds.height / documentView.lineHeight)))
    }

    /// 显示空间中的总行数。筛选显示 = 排序后的行数（匹配行 + 前一行和后一行），清理 = LineIndex，编辑 = piece table。
    private var displayCount: Int {
        if filterMode { return filterDisplayLines.count }
        if readsFromOriginal { return lineIndex?.displayLineCount ?? pieceTable?.lineCount ?? 0 }
        return pieceTable?.lineCount ?? 0
    }
    private var maxTopLine: Int { max(0, displayCount - visibleLineCount) }

    // MARK: - 打开文件

    @discardableResult
    func open(url: URL) -> Bool { open(url: url, forcedEncoding: nil) }

    /// 缓冲区（显示/重新解码）编码。用于在“重新打开”菜单中显示勾选标记。
    var currentEncoding: DetectedEncoding { encoding }
    /// 保存时使用的编码。用于指示“文本编码”菜单中的复选框。
    var currentSaveEncoding: DetectedEncoding { saveEncoding }

    /// 设置保存编码（暂不导出。设置为 dirty，并在下次保存时转换）。
    func setSaveEncoding(_ enc: DetectedEncoding) {
        guard enc != saveEncoding else { return }
        saveEncoding = enc
        setDirty(true)          // 发生了需要保存的更改（即输出编码的更改）。
        emitState()             // 更新状态栏的显示编码。
    }

    /// 使用指定的编码重新打开当前文件（修正自动编码错误导致的乱码）。已编辑的内容将被丢弃。
    @discardableResult
    func reopen(withEncoding enc: DetectedEncoding) -> Bool {
        guard let url = fileURL else { return false }
        return open(url: url, forcedEncoding: enc)
    }

    /// 重新导入已被其他应用程序覆盖的文件。
    ///
    /// **如果只是添加内容，我们可以直接扩展索引。** 如果重新粘贴 10GB，大约需要 8 秒钟。
    /// 每次添加日志行时都这样做是不可行的（它会将其放在与 tail -f 相同的路径中）。
    /// 仅当整个文件被覆盖时才重新打开，并返回到正在查看的行。
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let url = fileURL else { return false }
        if followMode { return true }        // 在跟踪过程中，跟踪计时器正在执行相同的任务。
        if !isDirty, extendForGrowth() { refresh(); return true }
        let keepTop = topLine
        guard open(url: url, forcedEncoding: userChosenEncoding) else { return false }
        setTopLine(keepTop)                  // 如果缩短，则会在 setTopLine 侧夹紧。
        return true
    }

    /// 传递  / `forcedEncoding` 将覆盖自动检测并使用该编码打开文件（使用指定的编码重新打开）。
    @discardableResult
    func open(url: URL, forcedEncoding: DetectedEncoding?) -> Bool {
        guard let buffer = FileBuffer(url: url) else { NSSound.beep(); return false }
        self.fileBuffer = buffer
        self.fileURL = url
        self.pieceTable = nil

        let prefix = buffer.data(in: 0..<min(buffer.count, 64 * 1024))
        self.userChosenEncoding = forcedEncoding
        self.encoding = forcedEncoding ?? EncodingDetector.detect(prefix)
        self.saveEncoding = encoding        // 打开后立即保存位置 = 缓冲区编码
        self.lineEnding = LineEnding.detect(prefix, encoding: encoding)
        self.searchEngine = SearchEngine(buffer: buffer, encoding: encoding)
        clearSearchState()

        let idx = LineIndex(buffer: buffer)
        idx.estimatePrefix()
        self.lineIndex = idx

        caretByte = 0
        selectionAnchor = 0
        topLine = 0
        scrollAccumulator = 0
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        didEncodingFallback = false
        setDirty(false)
        undoMgr.removeAllActions()   // 不要继承其他文件的编辑历史记录。
        restoreColumnGuides()        // 此文件中存储的固定长度项目定义
        refresh()

        idx.buildInBackground(progress: { [weak self] p in
            self?.partialProgress = p
            self?.emitState()
        }, completion: { [weak self] in
            guard let self, let buffer = self.fileBuffer, self.lineIndex === idx else { return }
            OpenTiming.indexComplete(lines: idx.displayLineCount)   // 仅当  SIFTEDITOR_TIMING=1 时
            // ：从已完成的索引中获取换行符的数量，并通过省略对原始 init 的完整扫描来创建 piece 和 table。
            self.pieceTable = PieceTable(original: FileBufferSource(buffer),
                                         originalNewlines: idx.originalNewlines,
                                         locator: idx)
            // 一旦 、piece 和 table 都存在，编辑功能就会启用（在此之前，它将是只读的，并且可以滚动）。
            self.documentView.inputHandler = self
            self.documentView.editUndoManager = self.undoMgr
            self.refresh()
        })
        return true
    }

    // MARK: - 再描画

    private func refresh() {
        guard lineIndex != nil, fileBuffer != nil else {
            documentView.lines = []
            documentView.needsDisplay = true
            return
        }
        topLine = min(max(0, topLine), maxTopLine)
        let needed = visibleLineCount + 1
        var attributed: [NSAttributedString] = []

        if filterMode {
            // 仅显示匹配的行（仅限非连续且无差异的行）。请勿使用插入符编辑。
            // 当行 N 出现在其前后时，上下文行也会与该序列混合在一起。
            let matches = filterDisplayLines
            var numbers: [Int] = []
            var k = 0
            while k < needed, topLine + k < matches.count {
                let fl = matches[topLine + k]
                let range = lineIndex?.lineRanges(from: fl, count: 1).first ?? (0..<0)
                attributed.append(decodeLine(range))
                numbers.append(fl)
                k += 1
            }
            visibleRanges = []
            documentView.lineNumbers = numbers
            // 仅当显示前一行和后一行 N 时，才会在当前匹配行上放置一个带状区域。上下文行和匹配行
            // 当它们排列成相同的形状时，很难分辨哪一行引发了问题。
            // （由于在构建过程中无法进行行高亮显示，因此横幅是唯一的线索）。
            documentView.activeRow = (contextLines > 0 && !filterIsExplicit)
                ? numbers.firstIndex(of: currentMatchLine) : nil
            documentView.lines = attributed
            documentView.caret = nil
            documentView.selectionByRow = [:]
        } else {
            let ranges = lineRanges(from: topLine, count: needed)
            visibleRanges = ranges
            // 最后一行后没有换行符 = 不显示不可见换行符的行。
            documentView.rowWithoutEOL = ranges.indices.last.flatMap {
                ranges[$0].upperBound >= docByteCount ? $0 : nil
            }
            attributed.reserveCapacity(ranges.count)
            for r in ranges { attributed.append(decodeLine(r)) }
            documentView.lineNumbers = nil
            documentView.firstLineNumber = topLine

            if let fmt = structuredFormatter {
                // 结构化 = 只读。CSV/TSV 将第一行（标题）加粗。
                if fmt.mode != .ndjson, topLine == 0, let first = attributed.first {
                    let h = NSMutableAttributedString(attributedString: first)
                    h.addAttribute(.font, value: boldTextFont, range: NSRange(location: 0, length: h.length))
                    attributed[0] = h
                }
                // 无法进行行高亮显示（格式化字符的位置与原始字节位置不对应），
                // **可以显示一组匹配的行。** 如果没有此功能，在结构化数据库中输入搜索内容时，似乎不会发生任何事情。
                let visMatch = currentMatchIdx >= 0 && currentMatchLine >= topLine
                    && currentMatchLine < topLine + attributed.count
                documentView.activeRow = visMatch ? currentMatchLine - topLine : nil
                documentView.lines = attributed
                documentView.caret = nil
                documentView.selectionByRow = [:]
            } else {
                // 搜索中跳转到的匹配行以条带突出显示。
                let visMatch = currentMatchIdx >= 0 && currentMatchLine >= topLine
                    && currentMatchLine < topLine + attributed.count
                documentView.activeRow = visMatch ? currentMatchLine - topLine : nil

                // IME：转换时，将带下划线的字符串 marked 插入到光标行中并隐藏选区。
                if hasMarked, let (row, col) = spliceMarkedText(into: &attributed) {
                    documentView.lines = attributed
                    documentView.caret = (row, col)
                    documentView.selectionByRow = [:]
                } else {
                    documentView.lines = attributed
                    updateCaretAndSelectionViews()
                }
            }
        }
        documentView.needsDisplay = true

        syncColumnRuler()
        updateScroller()
        emitState()
        if filterMode {
            emitSearchState(searching: !searchResults.isComplete,
                            progress: searchResults.isComplete ? 100 : 0, invalid: false)
        }
    }

    /// 计算可见行的字节范围。清理后为 LineIndex（后续扩展），编辑后为 piece table（包括 CR）。
    private func lineRanges(from start: Int, count: Int) -> [Range<Int>] {
        if readsFromOriginal, let idx = lineIndex {
            return idx.lineRanges(from: start, count: count)
        }
        if let pt = pieceTable {
            let total = pt.lineCount
            guard start < total, count > 0 else { return [] }
            let end = min(start + count, total)
            var out: [Range<Int>] = []
            out.reserveCapacity(end - start)
            for line in start..<end { out.append(pt.byteRange(ofLine: line)) }
            return out
        }
        return lineIndex?.lineRanges(from: start, count: count) ?? []
    }

    /// 行的字节范围 → 原始显示字符串（已移除 CR，显示限制已限制）。格式化前的原始单行。
    private func decodeLineString(_ range: Range<Int>) -> String {
        let capped = range.lowerBound..<min(range.upperBound, range.lowerBound + maxLineBytes)
        var bytes = rawBytes(in: capped)
        // PieceTable.byteRange 在渲染端被删除，以保留 CRLF 的 CR（它不再位于 LineIndex 路径中）。
        if bytes.last == 0x0D { bytes.removeLast() }
        return decodeString(bytes)
    }

    private func decodeLine(_ range: Range<Int>) -> NSAttributedString {
        let str = decodeLineString(range)
        if let fmt = structuredFormatter {
            // 结构化 = 以列对齐方式显示（搜索高亮显示已禁用）。
            return NSAttributedString(string: fmt.format(str), attributes: documentView.textAttributes)
        }
        // ANSI 颜色：仅在查看模式 (clean) 中，SGR 将转义字符转换为颜色并显示它们。
        // 只有包含转义字符的行才能进入此路径，并且搜索高亮显示是根据删除的文本（plain）应用的。
        if EditorTheme.ansiColorsEnabled, readsFromOriginal,
           let (colored, plain) = ANSIColor.attributed(str, base: documentView.textAttributes, palette: ansiPalette) {
            let attr = NSMutableAttributedString(attributedString: colored)
            if !searchTerms.isEmpty || searchRegex != nil { highlightMatches(in: attr, text: plain) }
            return attr
        }
        let attr = NSMutableAttributedString(string: str, attributes: documentView.textAttributes)
        if !searchTerms.isEmpty || searchRegex != nil { highlightMatches(in: attr, text: str) }
        return attr
    }

    /// 标题行粗体（将 bold 特性应用于正文字体；如果不存在，则使用相同的字体）。
    private var boldTextFont: NSFont {
        NSFontManager.shared.convert(EditorFont.current(), toHaveTrait: .boldFontMask)
    }

    /// 为行内匹配的部分添加背景颜色（仅限可见行，无需全局索引）。
    private func highlightMatches(in attr: NSMutableAttributedString, text: String) {
        for r in matchRanges(in: text) { attr.addAttribute(.backgroundColor, value: matchHighlight, range: r) }
    }

    /// 返回行字符串中匹配项（UTF-16 范围）。用于高亮显示和替换。
    private func matchRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        if let rx = searchRegex {
            rx.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let r = m?.range, r.length > 0 { out.append(r) }
            }
        } else {
            let opts: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive
            for term in searchTerms where !term.isEmpty {
                var from = 0
                while from <= ns.length {
                    let r = ns.range(of: term, options: opts, range: NSRange(location: from, length: ns.length - from))
                    if r.location == NSNotFound { break }
                    out.append(r)
                    from = r.location + max(1, r.length)
                }
            }
            out.sort { $0.location < $1.location }
        }
        return out
    }

    /// 返回行内的（匹配范围，替换字符串）。literal 直接替换为 replacement，regex 扩展为 $1。
    private func matchReplacements(in text: String, with replacement: String) -> [(NSRange, String)] {
        let ns = text as NSString
        /// 如果启用了大小写保留，则实际匹配拼写的格式将转移到替换字符串。
        func shaped(_ rep: String, _ range: NSRange) -> String {
            guard preserveCase else { return rep }
            return CasePreserving.apply(rep, matching: ns.substring(with: range))
        }
        if let rx = searchRegex {
            var out: [(NSRange, String)] = []
            for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                let expanded = rx.replacementString(for: m, in: text, offset: 0, template: replacement)
                out.append((m.range, shaped(expanded, m.range)))
            }
            return out
        }
        return matchRanges(in: text).map { ($0, shaped(replacement, $0)) }
    }

    /// 从文档中提取字节范围。清理期间通过 mmap 直接读取，编辑后通过 piece 和 table 读取。
    private func rawBytes(in range: Range<Int>) -> [UInt8] {
        guard range.lowerBound < range.upperBound else { return [] }
        if !readsFromOriginal, let pt = pieceTable { return pt.bytes(in: range) }
        if let buffer = fileBuffer { return [UInt8](buffer.data(in: range)) }
        return pieceTable?.bytes(in: range) ?? []
    }

    /// 使用检测编码解码（如果出现乱码，则回退到 UTF-8 替换以防止崩溃）。
    private func decodeString(_ bytes: [UInt8]) -> String {
        let data = Data(bytes)
        if let s = String(data: data, encoding: encoding.stringEncoding) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 插入/选择 ↔ 查看

    /// 将字节域光标和选择映射到可见线内的 (row, UTF-16 偏移量)，并将其传递给绘图系统。
    private func updateCaretAndSelectionViews() {
        var caretView: (row: Int, utf16Index: Int)?
        for (i, r) in visibleRanges.enumerated() where caretByte >= r.lowerBound && caretByte <= r.upperBound {
            caretView = (i, utf16Index(lineStart: r.lowerBound, byteOffset: caretByte))
            break
        }
        documentView.caret = caretView

        var rows: [Int: DocumentView.RowSelection] = [:]
        if let sel = selectionRange {
            for (i, r) in visibleRanges.enumerated() {
                let touches = sel.lowerBound <= r.upperBound && sel.upperBound > r.lowerBound
                guard touches else { continue }
                let lo = max(sel.lowerBound, r.lowerBound)
                let hi = min(max(sel.upperBound, r.lowerBound), r.upperBound)
                let a = utf16Index(lineStart: r.lowerBound, byteOffset: lo)
                let b = utf16Index(lineStart: r.lowerBound, byteOffset: hi)
                rows[i] = .init(range: NSRange(location: a, length: max(0, b - a)),
                                extendsToLineEnd: sel.upperBound > r.upperBound)
            }
        }
        documentView.selectionByRow = rows
        documentView.ensureCaretVisibleHorizontally()
        syncColumnRuler()   // 当跟随光标水平移动时，刻度上的数值会相应变化。
    }

    /// 将行 `lineStart` 到 `byteOffset` 的内容转换为该行字符串中 UTF-16 的偏移量。
    private func utf16Index(lineStart: Int, byteOffset: Int) -> Int {
        guard byteOffset > lineStart else { return 0 }
        let s = decodeString(rawBytes(in: lineStart..<byteOffset))
        return (s as NSString).length
    }

    /// 计算文档字节从行的开头 (`lineStart`)、行字符串 (`lineString`, UTF-16) 和偏移量 (`utf16Index`) 的偏移量。
    private func byteOffset(lineStart: Int, lineString: String, utf16Index: Int) -> Int {
        let ns = lineString as NSString
        let clamped = min(max(0, utf16Index), ns.length)
        guard clamped > 0 else { return lineStart }
        let prefix = ns.substring(to: clamped)
        let n = prefix.data(using: encoding.stringEncoding)?.count ?? Array(prefix.utf8).count
        return lineStart + n
    }

    // MARK: - 鼠标

    private func handleMouseDown(_ e: NSEvent) {
        guard let b = byteAt(event: e) else { return }
        switch e.clickCount {
        case 2: selectWord(at: b)      // 双击 = 选择单词
        case 3: selectLine(at: b)      // 三击 = 行选择
        default:
            // Shift + 单击 = 将选择范围从现有锚点扩展到单击的位置。
            placeCaret(at: b, extend: e.modifierFlags.contains(.shift))
        }
    }

    /// 相当于单击。将光标移动到 `byte`。如果光标位于 `extend`，则从现有锚点扩展选择范围。
    private func placeCaret(at byte: Int, extend: Bool) {
        caretByte = byte
        if !extend { selectionAnchor = byte }
        caretGoalColumn = nil
        showCaretNow()
        refresh()
    }

    /// 选择包含  / 字节 `byte` 的单词（字母序列；如果不在单词中，则仅使用插入符号）。
    private func selectWord(at byte: Int) {
        guard let pt = pieceTable else { return }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: byte))
        let str = lineString(cr)
        let ns = str as NSString
        let u = min(utf16Index(lineStart: cr.lowerBound, byteOffset: byte), ns.length)
        var lo = u, hi = u
        if u < ns.length && isWordChar(ns.character(at: u)) {
            while lo > 0 && isWordChar(ns.character(at: lo - 1)) { lo -= 1 }
            while hi < ns.length && isWordChar(ns.character(at: hi)) { hi += 1 }
        } else if u > 0 && isWordChar(ns.character(at: u - 1)) {   // 点击单词“”之后的下一个按钮。
            while lo > 0 && isWordChar(ns.character(at: lo - 1)) { lo -= 1 }
        } else {                                                   // 不在词组上
            caretByte = byte; selectionAnchor = byte; caretGoalColumn = nil
            showCaretNow(); refresh(); return
        }
        selectionAnchor = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: lo)
        caretByte = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: hi)
        caretGoalColumn = nil
        showCaretNow(); refresh()
    }

    /// 选择  / 字节 `byte` 的整个逻辑行（从行首到下一行的开头，包括换行符）。
    private func selectLine(at byte: Int) {
        guard let pt = pieceTable else { return }
        let line = pt.line(ofByteOffset: byte)
        selectionAnchor = pt.byteOffset(ofLineStart: line)
        caretByte = line < lineCountDoc - 1 ? pt.byteOffset(ofLineStart: line + 1) : docByteCount
        caretGoalColumn = nil
        showCaretNow(); refresh()
    }

    private func handleMouseDragged(_ e: NSEvent) {
        guard let b = byteAt(event: e) else { return }
        caretByte = b
        caretGoalColumn = nil
        showCaretNow()
        refresh()
    }

    private func byteAt(event e: NSEvent) -> Int? {
        let p = documentView.convert(e.locationInWindow, from: nil)
        guard let (row, u) = documentView.index(at: p), row < visibleRanges.count else { return nil }
        let s = (row < documentView.lines.count) ? documentView.lines[row].string : ""
        return byteOffset(lineStart: visibleRanges[row].lowerBound, lineString: s, utf16Index: u)
    }

    private func showCaretNow() {
        documentView.caretOn = true
    }

    // MARK: - 光标移动（键盘）

    private var lineCountDoc: Int { pieceTable?.lineCount ?? 0 }
    private var docByteCount: Int { pieceTable?.byteCount ?? 0 }

    /// 行 `line` 的字节范围（从 CRLF 中删除 CR。光标不在 CR/LF 上）。
    private func contentRange(ofLine line: Int) -> Range<Int> {
        guard let pt = pieceTable else { return 0..<0 }
        var r = pt.byteRange(ofLine: line)
        if r.upperBound > r.lowerBound, pt.bytes(in: (r.upperBound - 1)..<r.upperBound).first == 0x0D {
            r = r.lowerBound..<(r.upperBound - 1)
        }
        return r
    }

    /// 行字符串长度限制为显示上限 (`maxLineBytes`)。即使是极长的行，也可以用更少的按键次数进行处理。
    private func lineString(_ cr: Range<Int>) -> String {
        let capped = cr.lowerBound..<min(cr.upperBound, cr.lowerBound + maxLineBytes)
        return decodeString(rawBytes(in: capped))
    }

    /// 文档字节偏移量，对应于 `cr`、UTF-16 行的 `column` 列（已钳制）。
    private func byteForColumn(_ cr: Range<Int>, column: Int) -> Int {
        let s = lineString(cr)
        return byteOffset(lineStart: cr.lowerBound, lineString: s, utf16Index: column)
    }

    /// 行的“结束符” = 包括显示上限在内的最后一个字节的内容。
    private func cappedEnd(_ cr: Range<Int>) -> Int { byteForColumn(cr, column: Int.max) }

    /// 将光标移动到目标字节。使用 `extend` 扩展选择范围，并使用 `keepGoal` 保持目标列以进行上下移动。
    private func applyMove(to target: Int, extend: Bool, keepGoal: Bool = false) {
        caretByte = min(max(0, target), docByteCount)
        if !extend { selectionAnchor = caretByte }
        if !keepGoal { caretGoalColumn = nil }
        showCaretNow()
        scrollCaretIntoView()
        refresh()
    }

    /// 移动 `topLine`，使光标所在行位于可见范围内。
    private func scrollCaretIntoView() {
        guard let pt = pieceTable else { return }
        let line = pt.line(ofByteOffset: caretByte)
        if line < topLine {
            topLine = line
        } else if line >= topLine + visibleLineCount {
            topLine = line - visibleLineCount + 1
        }
        topLine = min(max(0, topLine), maxTopLine)
    }

    private func moveHorizontal(forward: Bool, word: Bool, extend: Bool) {
        guard let pt = pieceTable else { return }
        let line = pt.line(ofByteOffset: caretByte)
        let cr = contentRange(ofLine: line)
        let target: Int
        if forward {
            if caretByte < cappedEnd(cr) {
                target = word ? wordBoundaryByte(cr, forward: true) : charByte(cr, forward: true)
            } else if line < lineCountDoc - 1 {
                target = pt.byteOffset(ofLineStart: line + 1)
            } else { target = caretByte }
        } else {
            if caretByte > cr.lowerBound {
                target = word ? wordBoundaryByte(cr, forward: false) : charByte(cr, forward: false)
            } else if line > 0 {
                target = cappedEnd(contentRange(ofLine: line - 1))
            } else { target = 0 }
        }
        applyMove(to: target, extend: extend)
    }

    /// 在该行内向前或向后移动 1 个字素的字节偏移量。
    private func charByte(_ cr: Range<Int>, forward: Bool) -> Int {
        let s = lineString(cr)
        let ns = s as NSString
        let u = utf16Index(lineStart: cr.lowerBound, byteOffset: caretByte)
        if forward {
            guard u < ns.length else { return cappedEnd(cr) }
            let comp = ns.rangeOfComposedCharacterSequence(at: u)
            return byteOffset(lineStart: cr.lowerBound, lineString: s, utf16Index: comp.location + comp.length)
        } else {
            guard u > 0 else { return cr.lowerBound }
            let comp = ns.rangeOfComposedCharacterSequence(at: u - 1)
            return byteOffset(lineStart: cr.lowerBound, lineString: s, utf16Index: comp.location)
        }
    }

    /// 字节偏移量移动到行内的下一个/上一个字边界。
    private func wordBoundaryByte(_ cr: Range<Int>, forward: Bool) -> Int {
        let s = lineString(cr)
        let ns = s as NSString
        var i = utf16Index(lineStart: cr.lowerBound, byteOffset: caretByte)
        if forward {
            while i < ns.length && !isWordChar(ns.character(at: i)) { i += 1 }
            while i < ns.length && isWordChar(ns.character(at: i)) { i += 1 }
        } else {
            while i > 0 && !isWordChar(ns.character(at: i - 1)) { i -= 1 }
            while i > 0 && isWordChar(ns.character(at: i - 1)) { i -= 1 }
        }
        return byteOffset(lineStart: cr.lowerBound, lineString: s, utf16Index: i)
    }

    private func isWordChar(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true } // 代理片段被视为词的一部分
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F // '_'
    }

    private func moveVertical(down: Bool, extend: Bool) {
        moveByLines(down ? 1 : -1, extend: extend)
    }

    private func moveByLines(_ delta: Int, extend: Bool) {
        guard let pt = pieceTable else { return }
        let line = pt.line(ofByteOffset: caretByte)
        let cr = contentRange(ofLine: line)
        let goal = caretGoalColumn ?? utf16Index(lineStart: cr.lowerBound, byteOffset: caretByte)
        caretGoalColumn = goal
        let target = min(max(0, line + delta), max(0, lineCountDoc - 1))
        if target == line {
            // ：将最外侧的行与文档的开头/结尾对齐。
            applyMove(to: delta > 0 ? cappedEnd(cr) : cr.lowerBound, extend: extend, keepGoal: true)
        } else {
            applyMove(to: byteForColumn(contentRange(ofLine: target), column: goal), extend: extend, keepGoal: true)
        }
    }

    private func moveToLineEdge(end: Bool, extend: Bool) {
        guard let pt = pieceTable else { return }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        applyMove(to: end ? cappedEnd(cr) : cr.lowerBound, extend: extend)
    }

    private func selectAllText() {
        selectionAnchor = 0
        caretByte = docByteCount
        caretGoalColumn = nil
        showCaretNow()
        scrollCaretIntoView()
        refresh()
    }

    // MARK: - 編集（変異・B2b）

    /// 检测字符串并将其转换为字节序列进行编码。如果无法表示，则回退到 UTF-8 并在保存时发出警告。
    /// 粘贴等过程中混入的换行符（\r\n / \r / \n）在编码前被标准化为文件中的 EOL。
    private func encodeForInsertion(_ text: String) -> [UInt8] {
        let normalized = lineEnding.normalize(text)
        if let d = normalized.data(using: encoding.stringEncoding) { return [UInt8](d) }
        didEncodingFallback = true
        return Array(normalized.utf8)
    }

    /// 所有突变的起点。将 `range` 替换为 `bytes`，更新光标/选择区域，并将反向操作推入撤销。
    /// 反向操作也通过此函数进行，因此当您执行撤销操作时，会自动向堆栈中添加重做操作（反之亦然）。
    private func perform(replace range: Range<Int>, with bytes: [UInt8], newCaret: Int, newAnchor: Int) {
        guard let pt = pieceTable, !isSaving else { return }   // 保存时请勿修改（在后台读取全文）
        let lo = max(0, range.lowerBound), hi = min(pt.byteCount, range.upperBound)
        guard lo <= hi, !(lo == hi && bytes.isEmpty) else { return }

        let prevCaret = caretByte, prevAnchor = selectionAnchor
        // 由于撤销备份，大幅度编辑会消耗内存，因此超过阈值将丢弃历史记录并使其不可逆转。
        let undoable = (hi - lo) <= maxUndoBytes && bytes.count <= maxUndoBytes
        let old = undoable ? pt.bytes(in: lo..<hi) : []

        if hi > lo { pt.delete(lo..<hi) }
        if !bytes.isEmpty { pt.insert(bytes, at: lo) }

        if undoable {
            let inverse = lo..<(lo + bytes.count)
            undoMgr.registerUndo(withTarget: self) { target in
                target.perform(replace: inverse, with: old, newCaret: prevCaret, newAnchor: prevAnchor)
            }
        } else {
            undoMgr.removeAllActions()
        }

        caretByte = min(max(0, newCaret), pt.byteCount)
        selectionAnchor = min(max(0, newAnchor), pt.byteCount)
        caretGoalColumn = nil
        let wasClean = !isDirty
        setDirty(true)
        if wasClean && !preserveSearchOnEdit { stopSearchAndFollowForEdit() }   // 可通过编辑禁用搜索和关注功能。
        showCaretNow()
        if batchEditing { return }   // 在批量替换过程中，最后一部分一次性全部重新绘制。
        scrollCaretIntoView()
        refresh()
    }

    /// 在光标位置（或选定范围内，如果有）插入 `bytes`。
    private func insertBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let range = selectionRange ?? caretByte..<caretByte
        let caret = range.lowerBound + bytes.count
        perform(replace: range, with: bytes, newCaret: caret, newAnchor: caret)
    }

    /// 删除字节范围（光标移动到范围的开头）。
    private func deleteRange(_ range: Range<Int>) {
        let lo = max(0, range.lowerBound), hi = min(docByteCount, range.upperBound)
        guard lo < hi else { return }
        perform(replace: lo..<hi, with: [], newCaret: lo, newAnchor: lo)
    }

    /// deleteBackward 的删除范围（一行中的 1 个字形，以及行首的前一个换行符 CR?LF）。
    private func backwardDeleteRange() -> Range<Int>? {
        guard let pt = pieceTable, caretByte > 0 else { return nil }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        if caretByte > cr.lowerBound {
            return charByte(cr, forward: false)..<caretByte
        }
        // ：行合并，删除行首的换行符和上一行末尾的换行符（CRLF 被视为 2 个字节）。
        var start = caretByte - 1
        if start > 0, pt.bytes(in: (start - 1)..<start).first == 0x0D { start -= 1 }
        return start..<caretByte
    }

    /// deleteForward 的删除范围（一行内 1 个字素，以及行尾的下一个换行符 CR?LF）。
    private func forwardDeleteRange() -> Range<Int>? {
        guard let pt = pieceTable, caretByte < docByteCount else { return nil }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        if caretByte < cr.upperBound {
            return caretByte..<charByte(cr, forward: true)
        }
        // 删除行尾（内容结束）的换行符，并将两行合并到下一行的开头。
        let line = pt.line(ofByteOffset: caretByte)
        guard line < lineCountDoc - 1 else { return nil }
        return caretByte..<pt.byteOffset(ofLineStart: line + 1)
    }

    /// 逐字删除（优先选择任何已选内容）。
    private func deleteWord(forward: Bool) {
        if let sel = selectionRange { deleteRange(sel); return }
        guard let pt = pieceTable else { return }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        if forward {
            if caretByte < cr.upperBound { deleteRange(caretByte..<wordBoundaryByte(cr, forward: true)) }
            else if let r = forwardDeleteRange() { deleteRange(r) }
        } else {
            if caretByte > cr.lowerBound { deleteRange(wordBoundaryByte(cr, forward: false)..<caretByte) }
            else if let r = backwardDeleteRange() { deleteRange(r) }
        }
    }

    /// 从行首到行尾删除（相当于 Ctrl-U / Ctrl-K）。
    private func deleteToLineEdge(end: Bool) {
        if let sel = selectionRange { deleteRange(sel); return }
        guard let pt = pieceTable else { return }
        let cr = contentRange(ofLine: pt.line(ofByteOffset: caretByte))
        if end { deleteRange(caretByte..<cappedEnd(cr)) }
        else { deleteRange(cr.lowerBound..<caretByte) }
    }

    // MARK: - 剪切/粘贴

    /// 剪切选定项目（复制→删除）。如果没有选中任何项目，则会发出哔声。
    private func cutSelection() {
        guard pieceTable != nil, let sel = selectionRange else { NSSound.beep(); return }
        let capped = sel.lowerBound..<min(sel.upperBound, sel.lowerBound + 32 * 1024 * 1024)
        let text = decodeString(rawBytes(in: capped))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        deleteRange(sel)
    }

    /// 将剪贴板中的字符串粘贴到光标位置（如果选中则替换它）。
    private func pasteClipboard() {
        guard pieceTable != nil,
              let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { NSSound.beep(); return }
        insertBytes(encodeForInsertion(text))
    }

    // MARK: - 保存（B3 流导出 → atomic 替换）

    private func setDirty(_ value: Bool) {
        guard value != isDirty else { return }
        isDirty = value
        onDirtyChange?(value)
    }

    /// 保存到现有路径（如果路径尚未确定，则保存为 Save 或 As）。成功时保存为 true。
    @discardableResult
    func save() -> Bool {
        guard pieceTable != nil else { NSSound.beep(); return false }
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    /// 选择保存位置并保存 (NSSavePanel)。保存成功：true。
    @discardableResult
    func saveAs() -> Bool {
        guard pieceTable != nil else { NSSound.beep(); return false }
        let panel = NSSavePanel()
        if let url = fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    /// piece table 的全部内容被流式传输到临时文件，并被原子地替换为 `url`。
    /// 未将全部文本加载到内存中。即使替换后，原始 mmap 仍然处于活动状态（读取仍然正确）。
    private func write(to url: URL) -> Bool {
        guard let pt = pieceTable else { NSSound.beep(); return false }
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".sifteditor-save-\(UUID().uuidString)")

        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            NSSound.beep(); return false
        }
        do {
            try pt.writeAll { slice in try handle.write(contentsOf: Data(slice)) }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
            NSAlert(error: error).runModal()
            return false
        }
        // 原子替换（等效于同一卷上的 rename）。如果文件已存在，则替换该文件；如果文件不存在，则移动该文件。
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            NSAlert(error: error).runModal()
            return false
        }

        fileURL = url
        setDirty(false)
        if didEncodingFallback {
            let a = NSAlert()
            a.messageText = L("save.encodingFallback", encoding.displayName)
            a.runModal()
            didEncodingFallback = false
        }
        emitState()
        return true
    }

    /// 异步保存（避免卡顿）。写入操作在后台队列中执行，进度报告给 main。
    /// 已完成。将 atomic 替换为 main，并更新 UI。保存时编辑暂停（仍可滚动和查看）。
    /// `saveAs=true`（或未保存）首先会弹出保存目标面板。`onBegin` 在写入开始时调用。
    /// 如果目标编码 (`saveEncoding`) 与缓冲区编码 (`encoding`) 不同，则会在写入过程中进行转换。
    /// 成功后，使用该编码重新打开文件并确保一致性（编码转换和保存）。
    func saveAsync(saveAs: Bool,
                   onBegin: @escaping () -> Void,
                   progress: @escaping (Double) -> Void,
                   completion: @escaping (Bool) -> Void) {
        guard let pt = pieceTable, !isSaving else { completion(false); return }
        let url: URL
        if saveAs || fileURL == nil {
            let panel = NSSavePanel()
            if let u = fileURL {
                panel.directoryURL = u.deletingLastPathComponent()
                panel.nameFieldStringValue = u.lastPathComponent
            }
            guard panel.runModal() == .OK, let u = panel.url else { completion(false); return }
            url = u
        } else {
            url = fileURL!
        }

        isSaving = true
        let token = CancelToken()
        saveToken = token
        onBegin()
        let total = max(1, pt.byteCount)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".sifteditor-save-\(UUID().uuidString)")
        // 转换和保存的源/目标编码（如果相同，则写入普通原始字节）。
        let source = self.encoding
        let target: DetectedEncoding? = (saveEncoding != source) ? saveEncoding : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var writeErrno: Int32 = 0
            var cancelled = false
            var encFallback = false
            var wrote = 0, lastReport = 0
            if FileManager.default.createFile(atPath: tmp.path, contents: nil),
               let handle = try? FileHandle(forWritingTo: tmp) {
                do {
                    let reportProgress = {
                        if wrote - lastReport >= (128 << 20) {          // 128MB 各项目进度报告
                            lastReport = wrote
                            let f = Double(wrote) / Double(total)
                            DispatchQueue.main.async { progress(f) }
                        }
                    }
                    if let target {
                        encFallback = try EncodingTranscoder.stream(
                            from: source, to: target,
                            feed: { sink in
                                try pt.writeAll { slice in
                                    if token.isCancelled { throw CancelToken.Cancelled() }
                                    try sink(slice)
                                    wrote += slice.count
                                    reportProgress()
                                }
                            },
                            emit: { try handle.write(contentsOf: $0) })
                    } else {
                        try pt.writeAll { slice in
                            if token.isCancelled { throw CancelToken.Cancelled() }
                            try handle.write(contentsOf: Data(slice))
                            wrote += slice.count
                            reportProgress()
                        }
                    }
                    try handle.close()
                } catch is CancelToken.Cancelled {
                    cancelled = true
                    try? handle.close()
                } catch {
                    writeErrno = Int32((error as NSError).code); if writeErrno == 0 { writeErrno = EIO }
                    try? handle.close()
                }
            } else {
                writeErrno = EIO
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isSaving = false
                self.saveToken = nil
                if cancelled {                                  // 用户中断：临时文件已丢弃，剩余文件为 dirty
                    try? FileManager.default.removeItem(at: tmp)
                    completion(false); return
                }
                guard writeErrno == 0 else {
                    try? FileManager.default.removeItem(at: tmp)
                    NSAlert(error: NSError(domain: NSPOSIXErrorDomain, code: Int(writeErrno))).runModal()
                    completion(false); return
                }
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                    } else {
                        try FileManager.default.moveItem(at: tmp, to: url)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    NSAlert(error: error).runModal()
                    completion(false); return
                }
                self.fileURL = url
                if let target {
                    // 转换并保存：使用新导出的编码重新打开，并匹配内存和磁盘。
                    if encFallback {
                        let a = NSAlert()
                        a.messageText = L("convert.lossy", target.displayName)
                        a.runModal()
                    }
                    self.open(url: url, forcedEncoding: target)
                    completion(true); return
                }
                self.setDirty(false)
                if self.didEncodingFallback {
                    let a = NSAlert()
                    a.messageText = L("save.encodingFallback", self.encoding.displayName)
                    a.runModal()
                    self.didEncodingFallback = false
                }
                self.emitState()
                completion(true)
            }
        }
    }

    /// 中断正在进行的异步保存（停止后台写入并丢弃临时文件。保留 dirty）。
    func cancelSave() { saveToken?.cancel() }

    /// 一个用于取消保存操作的小型线程安全标志。
    private final class CancelToken {
        struct Cancelled: Error {}
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

    // MARK: - 副本

    /// 将选定范围复制为纯文本，如果不存在可见范围，则复制可见范围。
    private func copySelectionOrVisible() {
        let text: String
        if let sel = selectionRange {
            let capped = sel.lowerBound..<min(sel.upperBound, sel.lowerBound + 32 * 1024 * 1024)
            text = decodeString(rawBytes(in: capped))
        } else {
            text = documentView.lines.map { $0.string }.joined(separator: "\n")
        }
        guard !text.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - 滚动/按键输入（B1 仅支持滚动）

    private func handleScrollWheel(_ event: NSEvent) {
        guard lineIndex != nil else { return }
        // 当没有换行符时，也会处理水平滚动（触控板水平滑动）。
        if !documentView.wrapEnabled, event.scrollingDeltaX != 0 {
            documentView.setHorizontalOffset(documentView.horizontalOffset - event.scrollingDeltaX)
            syncColumnRuler()        // 使刻度跟随水平滚动条移动。
        syncStructuredHeader()   // 列名称横幅也会显示。
        }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= documentView.lineHeight }
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator / documentView.lineHeight)
        if lines != 0 {
            scrollAccumulator -= CGFloat(lines) * documentView.lineHeight
            setTopLine(topLine - lines)
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let page = max(1, visibleLineCount - 1)
        switch event.keyCode {
        case 125: setTopLine(topLine + 1)      // ↓
        case 126: setTopLine(topLine - 1)      // ↑
        case 121: setTopLine(topLine + page)   // Page Down
        case 116: setTopLine(topLine - page)   // Page Up
        case 115: setTopLine(0)                 // Home
        case 119: setTopLine(maxTopLine)       // End
        case 49:  setTopLine(topLine + page)   // Space
        default: break
        }
    }

    private func setTopLine(_ value: Int) {
        let clamped = min(max(0, value), maxTopLine)
        guard clamped != topLine else { return }
        topLine = clamped
        refresh()
    }

    private func updateScroller() {
        guard lineIndex != nil else { scroller.isEnabled = false; return }
        let total = displayCount, visible = visibleLineCount
        if total > visible {
            scroller.isEnabled = true
            scroller.knobProportion = CGFloat(visible) / CGFloat(total)
            let denom = maxTopLine
            scroller.doubleValue = denom > 0 ? Double(topLine) / Double(denom) : 0
        } else {
            scroller.isEnabled = false
            scroller.knobProportion = 1
            scroller.doubleValue = 0
        }
    }

    @objc private func scrollerAction(_ sender: NSScroller) {
        let page = max(1, visibleLineCount - 1)
        switch sender.hitPart {
        case .knob, .knobSlot: topLine = Int(Double(maxTopLine) * sender.doubleValue)
        case .decrementPage: topLine -= page
        case .incrementPage: topLine += page
        case .decrementLine: topLine -= 1
        case .incrementLine: topLine += 1
        default: break
        }
        topLine = min(max(0, topLine), maxTopLine)
        refresh()
    }

    // MARK: - 搜索（仅当 B4 干净时有效。使用 SearchEngine 扫描 mmap）

    func setSearchQuery(_ q: String) { guard readsFromOriginal, q != searchQuery else { return }; searchQuery = q; rebuildSearch() }
    func setRegexMode(_ on: Bool) { guard readsFromOriginal, on != regexMode else { return }; regexMode = on; rebuildSearch() }
    func setCaseSensitive(_ on: Bool) { guard readsFromOriginal, on != caseSensitive else { return }; caseSensitive = on; rebuildSearch() }
    /// Extraction scans the same file; stop an unfinished Find scan so both do not compete for it.
    func suspendSearchForExtraction() -> Bool {
        guard !searchQuery.isEmpty, !searchResults.isComplete else { return false }
        searchDebounce?.cancel()
        searchEngine?.cancel()
        return true
    }

    func resumeSearchAfterExtraction() { rebuildSearch() }
    /// 案例保留仅在更换期间有效（搜索结果不会改变），因此请勿执行其他搜索。
    func setPreserveCase(_ on: Bool) { preserveCase = on }

    private func rebuildSearch() {
        searchBusy = false
        searchResults.isComplete = false     // 不要使用前一个单词的结果来延长长度。
        searchEpoch += 1
        let epoch = searchEpoch
        searchDebounce?.cancel()
        searchEngine?.cancel()
        currentMatchIdx = -1
        currentMatchLine = -1
        searchTerms = []
        searchRegex = nil
        filterIsExplicit = false     // 搜索词再次缩小范围 = 不再是时间段选择。
        var invalid = false
        if regexMode {
            if !searchQuery.isEmpty {
                let opts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                do { searchRegex = try NSRegularExpression(pattern: searchQuery, options: opts) } catch { invalid = true }
            }
        } else {
            searchTerms = SearchMode.splitTerms(searchQuery)
        }
        refresh()
        if searchQuery.isEmpty {
            searchResults = .init(); filterDisplayLines = []
            if filterMode { refresh() }
            emitSearchState(searching: false, progress: 0, invalid: false); return
        }
        if invalid {
            searchResults = .init(); filterDisplayLines = []
            if filterMode { refresh() }
            emitSearchState(searching: false, progress: 0, invalid: true); return
        }
        let mode: SearchMode = regexMode ? .regex(searchRegex!) : .terms(searchTerms)
        emitSearchState(searching: true, progress: 0, invalid: false)
        let work = DispatchWorkItem { [weak self] in self?.runSearch(mode, epoch: epoch) }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func runSearch(_ mode: SearchMode, epoch: Int) {
        // **即使在筛选时也显示搜索栏状态。** 以前，这是通过 filterMode 实现的。
        // 由于跳过了  emitSearchState，进度条停止在 0%。
        // 表示“我不知道它何时结束”（这是该人于 2026 年 9 月 5 日指出的）。
        // 筛选由显示匹配行的一方处理，并且该一方负责通知筛选是否完成。
        searchEngine?.search(mode, caseSensitive: caseSensitive, progress: { [weak self] res, p in
            guard let self, self.searchEpoch == epoch else { return }
            self.searchResults = res
            if self.filterMode { self.rebuildFilterDisplayLines(); self.refresh() }
            self.emitSearchState(searching: true, progress: Int(p * 100), invalid: false)
        }, completion: { [weak self] res in
            guard let self, self.searchEpoch == epoch else { return }
            self.searchResults = res
            if self.filterMode { self.rebuildFilterDisplayLines(); self.rebuildStructuredColumns(); self.refresh() }
            self.emitSearchState(searching: false, progress: 100, invalid: false)
        })
    }

    private func clearSearchState() {
        searchQuery = ""; searchTerms = []; searchRegex = nil
        filterMode = false; searchResults = .init()
        filterDisplayLines = []; filterIsExplicit = false
        currentMatchIdx = -1; currentMatchLine = -1
        searchEpoch += 1
        searchDebounce?.cancel()
        searchEngine?.cancel()
    }

    /// 仅显示指定的行。它不进行匹配行的搜索，而是直接使用提供的行号。
    ///
    /// 将搜索词留空 -- **此筛选并非搜索**，因此请勿在搜索栏中输入无效词语
    /// 无法输入。要删除它，请使用空数组（或正常使用搜索栏）。
    func showOnlyLines(_ lines: [Int]) {
        guard !isDirty else { NSSound.beep(); return }      // 编辑时行号会移动。
        searchQuery = ""; searchTerms = []; searchRegex = nil
        searchEpoch += 1
        searchDebounce?.cancel()
        searchEngine?.cancel()

        guard !lines.isEmpty else {
            if filterMode { setFilterMode(false) }
            searchResults = .init()
            filterIsExplicit = false
            filterDisplayLines = []
            refresh()
            return
        }
        var result = SearchEngine.Result()
        result.lines = lines
        result.lineCount = lines.count
        result.isComplete = true
        searchResults = result
        filterIsExplicit = true      // 请勿包含所选时间段之外的任何内容（请勿在 N 之前或之后添加行）
        currentMatchIdx = 0
        currentMatchLine = lines[0]
        rebuildFilterDisplayLines()
        if filterMode {
            topLine = 0
            rebuildStructuredColumns()
            refresh()
        } else {
            setFilterMode(true)
        }
    }

    /// 重新排列要排序的行（匹配行 + 前一行/后一行 N）。
    /// 当匹配项发生变化、前导行和后导行数发生变化或应用过滤器时调用。
    private func rebuildFilterDisplayLines() {
        let matches = searchResults.lines
        // 如果匹配结果发生变化，也请重新选择“当前匹配结果”（这样就不会在上一次查询的行上留下横幅）。
        if !filterIsExplicit {
            let stillValid = currentMatchIdx >= 0 && currentMatchIdx < matches.count
                && matches[currentMatchIdx] == currentMatchLine
            if !stillValid {
                currentMatchIdx = matches.isEmpty ? -1 : 0
                currentMatchLine = matches.first ?? -1
            }
        }
        guard !filterIsExplicit, contextLines > 0 else { filterDisplayLines = matches; return }
        filterDisplayLines = FilterContext.expand(matches: matches,
                                                  context: contextLines,
                                                  lineCount: displayLineCountForContext)
    }

    /// 前后行可扩展的范围 = 文件中的总行数。过滤期间，`displayCount`
    /// 此函数返回筛选后的数字，因此使用此函数会截断结果的末尾。
    private var displayLineCountForContext: Int {
        if readsFromOriginal { return lineIndex?.displayLineCount ?? pieceTable?.lineCount ?? 0 }
        return pieceTable?.lineCount ?? 0
    }

    /// 显示匹配行时的第一行。**当同时显示前一行和后一行时，将其向上移动前一行的行数。**
    /// 如果将匹配的行放在顶部，则刚刚显示的“上一行”将在屏幕顶部隐藏。
    /// （我展示正面和背面是因为我想看正面，所以这违背了初衷）。
    private func filterTopRow(forFileLine line: Int) -> Int {
        let idx = displayIndex(ofFileLine: line)
        guard contextLines > 0, !filterIsExplicit else { return idx }
        return max(0, idx - contextLines)
    }

    /// 指定文件行在显示序列中的位置（如果不存在，则紧随其后）。
    private func displayIndex(ofFileLine line: Int) -> Int {
        var lo = 0, hi = filterDisplayLines.count
        while lo < hi { let mid = (lo + hi) / 2; if filterDisplayLines[mid] < line { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    var filterContextLines: Int {
        AppSettings.filterContextLines
    }

    /// 更改匹配行前后添加的行数。如果启用了筛选功能，则不会丢失您当前正在查看的行。
    /// 重新排列，使**同一文件行保持在开头**。
    func setFilterContextLines(_ n: Int) {
        let clamped = min(max(0, n), FilterContext.maxContext)
        let changed = clamped != contextLines
        contextLines = clamped
        AppSettings.filterContextLines = clamped
        guard changed, filterMode else { return }
        updateFilterContextDisplay()
    }

    @objc private func filterContextChanged(_ notification: Notification) {
        let current = AppSettings.filterContextLines
        guard current != contextLines else { return }
        contextLines = current
        guard filterMode else { return }
        updateFilterContextDisplay()
    }

    private func updateFilterContextDisplay() {
        let keep = (topLine >= 0 && topLine < filterDisplayLines.count) ? filterDisplayLines[topLine] : -1
        rebuildFilterDisplayLines()
        topLine = keep >= 0 ? displayIndex(ofFileLine: keep) : 0
        scrollAccumulator = 0
        rebuildStructuredColumns()   // 要排列的行数增加或减少 = 重新测量数字。
        refresh()
    }

    func setFilterMode(_ on: Bool) {
        guard on != filterMode else { return }
        if on {
            filterMode = true
            rebuildFilterDisplayLines()
            // 跳转到您刚才查看的匹配行的位置。如果包含上下文行，匹配编号和行号将错位。
            topLine = currentMatchLine >= 0 ? filterTopRow(forFileLine: currentMatchLine) : 0
        } else {
            let fileLine = (topLine >= 0 && topLine < filterDisplayLines.count)
                ? filterDisplayLines[topLine] : topLine
            filterMode = false
            topLine = fileLine
            // 取消选择后的“项目编号”将重置为与当前查看的行匹配（保留筛选期间所做的更改）。
            let i = firstMatchIndex(after: fileLine) - 1
            currentMatchIdx = i
            currentMatchLine = i >= 0 ? searchResults.lines[i] : -1
        }
        scrollAccumulator = 0
        rebuildStructuredColumns()   // 可见行已交换 = 需要重新测量数字。
        refresh()
    }

    private func emitSearchState(searching: Bool, progress: Int, invalid: Bool) {
        let total = searchResults.lineCount
        let current: Int
        if filterMode {
            let matches = searchResults.lines
            if matches.isEmpty {
                current = 0
            } else if contextLines == 0 || filterIsExplicit {
                current = min(topLine + 1, total)      // 显示行 = 匹配行，因此位置与项目编号相同。
            } else {
                // 上下文行混杂在一起 = 显示位置和项目编号未对齐。统计有多少项已传递到第一行。
                let fl = (topLine >= 0 && topLine < filterDisplayLines.count) ? filterDisplayLines[topLine] : 0
                current = min(max(1, firstMatchIndex(after: fl)), total)
            }
        } else {
            current = currentMatchIdx >= 0 ? currentMatchIdx + 1 : 0
        }
        // 总计数是准确的，因为它还包括超过上限的行（上限仅适用于“可移动匹配行”）。
        onSearchState?(current, total, searching, progress, invalid, false)
    }

    /// 筛选时“下一个／上一个匹配”的显示行。未显示前后 N 行时，每个匹配占一行，
    /// 由于移动是直接匹配的，返回 nil 并将其保留为调用者的默认值。
    private func filterMatchRow(forward: Bool) -> Int? {
        guard contextLines > 0, !filterIsExplicit else { return nil }
        let matches = searchResults.lines
        let idx: Int
        if currentMatchIdx >= 0, currentMatchIdx < matches.count {
            // **计数从“当前匹配项”开始，而非显示的第一行。** 接近末尾的匹配项是
            // 它始终停留在屏幕最底部，永远不会到达顶部（滚动停止），
            // 从第一行开始，就无法继续到最后几行。
            idx = forward ? (currentMatchIdx + 1) % matches.count
                          : (currentMatchIdx - 1 + matches.count) % matches.count
        } else {
            // 尚未找到匹配项 = 从当前可见位置搜索。
            let fl = (topLine >= 0 && topLine < filterDisplayLines.count) ? filterDisplayLines[topLine] : -1
            idx = forward ? min(firstMatchIndex(after: fl), matches.count - 1)
                          : max(firstMatchIndex(after: fl - 1) - 1, 0)
        }
        currentMatchIdx = idx
        currentMatchLine = matches[idx]
        return filterTopRow(forFileLine: matches[idx])
    }

    private func firstMatchIndex(after line: Int) -> Int {
        let lines = searchResults.lines
        var lo = 0, hi = lines.count
        while lo < hi { let mid = (lo + hi) / 2; if lines[mid] > line { hi = mid } else { lo = mid + 1 } }
        return lo
    }

    func findNext() {
        if filterMode {
            guard !searchResults.lines.isEmpty else { NSSound.beep(); return }
            if let row = filterMatchRow(forward: true) { setTopLine(row) } else { setTopLine(topLine + 1) }
            return
        }
        let lines = searchResults.lines
        guard !lines.isEmpty else { NSSound.beep(); return }
        let idx = currentMatchIdx >= 0 ? (currentMatchIdx + 1) % lines.count
                                       : min(firstMatchIndex(after: topLine - 1), lines.count - 1)
        jumpToMatch(idx)
    }

    func findPrev() {
        if filterMode {
            guard !searchResults.lines.isEmpty else { NSSound.beep(); return }
            if let row = filterMatchRow(forward: false) { setTopLine(row) } else { setTopLine(topLine - 1) }
            return
        }
        let lines = searchResults.lines
        guard !lines.isEmpty else { NSSound.beep(); return }
        let idx = currentMatchIdx >= 0 ? (currentMatchIdx - 1 + lines.count) % lines.count
                                       : (firstMatchIndex(after: topLine - 1) - 1 + lines.count) % lines.count
        jumpToMatch(idx)
    }

    private func jumpToMatch(_ idx: Int) {
        currentMatchIdx = idx
        currentMatchLine = searchResults.lines[idx]
        setTopLine(searchResults.lines[idx])
        emitSearchState(searching: !searchResults.isComplete,
                        progress: searchResults.isComplete ? 100 : 0, invalid: false)
    }

    /// 如果编辑结果为 dirty，则停止搜索、跟踪和筛选（因为文档将与 mmap 不同）。
    private func stopSearchAndFollowForEdit() {
        if followMode { setFollowMode(false) }
        if !searchQuery.isEmpty || filterMode {
            clearSearchState()
            emitSearchState(searching: false, progress: 0, invalid: false)
        }
    }

    // MARK: - 置換（Find & Replace・B5）

    /// 将所有与当前搜索模式 (`searchTerms`/`searchRegex`) 匹配的项替换为 `replacement`。
    /// 使用清理操作的搜索结果（匹配行），找到每一行的匹配项，并将其批量应用于 END→START（1 次撤销）。
    func replaceAll(with replacement: String) {
        guard let pt = pieceTable, !isSaving, !searchQuery.isEmpty, supportsReplace else { NSSound.beep(); return }
        let lines = searchResults.lines
        guard !lines.isEmpty else { NSSound.beep(); return }   // 未找到匹配项

        // 收集每个匹配行的（文档字节范围，替换字节序列）。
        var edits: [(Range<Int>, [UInt8])] = []
        for fl in lines where fl < pt.lineCount {
            let cr = contentRange(ofLine: fl)
            let str = lineString(cr)
            for (r, rep) in matchReplacements(in: str, with: replacement) {
                let bs = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: r.location)
                let be = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: r.location + r.length)
                if bs < be { edits.append((bs..<be, encodeForInsertion(rep))) }
            }
        }
        guard !edits.isEmpty else { NSSound.beep(); return }

        // 如果从后方应用，则前部偏移量保持不变。将所有操作合并为一个撤销操作。
        edits.sort { $0.0.lowerBound > $1.0.lowerBound }
        let count = edits.count
        undoMgr.beginUndoGrouping()
        batchEditing = true
        preserveSearchOnEdit = true
        for (range, bytes) in edits {
            perform(replace: range, with: bytes, newCaret: range.lowerBound + bytes.count, newAnchor: range.lowerBound + bytes.count)
        }
        preserveSearchOnEdit = false
        batchEditing = false
        undoMgr.endUndoGrouping()

        selectionAnchor = caretByte
        scrollCaretIntoView()
        refresh()
        onSearchState?(count, count, false, 100, false, false)   // 反馈相当于“N 替换”
    }

    /// 如果当前选择匹配，则替换它并继续；否则，选择下一个匹配项（重复替换）。
    func replaceCurrent(with replacement: String) {
        guard pieceTable != nil, !isSaving, !searchQuery.isEmpty, supportsReplace else { NSSound.beep(); return }
        if let sel = selectionRange, let rep = replacementForSelection(sel, replacement) {
            let bytes = encodeForInsertion(rep)
            preserveSearchOnEdit = true
            perform(replace: sel, with: bytes,
                    newCaret: sel.lowerBound + bytes.count, newAnchor: sel.lowerBound + bytes.count)
            preserveSearchOnEdit = false
            _ = selectNextMatch(from: caretByte)
        } else {
            if !selectNextMatch(from: caretByte) { NSSound.beep() }
        }
    }

    // MARK: - 编辑工具箱（获取选区/替换选区）

    var selectedText: String? {
        guard pieceTable != nil, !isSaving, let sel = selectionRange else { return nil }
        return decodeString(rawBytes(in: sel))
    }

    var selectedTextForFind: String? {
        guard pieceTable != nil, !isSaving, let sel = selectionRange,
              sel.count <= 4096 else { return nil }
        return decodeString(rawBytes(in: sel))
    }

    /// 替换选择（1 撤销 / 替换后保留选定的字节序列。anchor=开始，caret=结束）。
    func replaceSelection(with text: String) {
        guard pieceTable != nil, !isSaving, let sel = selectionRange else { NSSound.beep(); return }
        let bytes = encodeForInsertion(text)
        perform(replace: sel, with: bytes, newCaret: sel.lowerBound + bytes.count, newAnchor: sel.lowerBound)
    }

    /// 如果选定的文本与搜索模式匹配，则返回替换字符串（literal 保持不变 / regex 展开为 $1）。如果没有匹配项，则返回 nil。
    private func replacementForSelection(_ sel: Range<Int>, _ replacement: String) -> String? {
        let str = decodeString(rawBytes(in: sel))
        let ns = str as NSString
        /// 如果启用了大小写保留，则所选内容的格式（即实际匹配的拼写）将转移到替换字符串。
        func shaped(_ rep: String) -> String {
            preserveCase ? CasePreserving.apply(rep, matching: str) : rep
        }
        if let rx = searchRegex {
            guard let m = rx.firstMatch(in: str, range: NSRange(location: 0, length: ns.length)),
                  m.range.location == 0, m.range.length == ns.length else { return nil }
            return shaped(rx.replacementString(for: m, in: str, offset: 0, template: replacement))
        }
        for term in searchTerms where !term.isEmpty {
            if ns.compare(term, options: caseSensitive ? [] : .caseInsensitive) == .orderedSame { return shaped(replacement) }
        }
        return nil
    }

    /// 从  / 字节 `from` 开始搜索并选择下一个匹配项（即使在正向扫描和编辑期间也有效）。如果找到，则选择 true。
    @discardableResult
    private func selectNextMatch(from: Int) -> Bool {
        guard let pt = pieceTable else { return false }
        let startLine = pt.line(ofByteOffset: from)
        let total = pt.lineCount
        // 当前行仅包含 from 及之后的行；后续行从开头开始。如果行尾尚未扫描，则从开头开始，并循环至 from 行。
        func scan(_ range: Range<Int>, minByte: Int) -> Range<Int>? {
            for line in range where line < total {
                let cr = contentRange(ofLine: line)
                let str = lineString(cr)
                for r in matchRanges(in: str) {
                    let bs = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: r.location)
                    let be = byteOffset(lineStart: cr.lowerBound, lineString: str, utf16Index: r.location + r.length)
                    if bs >= minByte && bs < be { return bs..<be }
                }
            }
            return nil
        }
        let hit = scan(startLine..<total, minByte: from) ?? scan(0..<(startLine + 1), minByte: 0)
        guard let range = hit else { return false }
        selectionAnchor = range.lowerBound
        caretByte = range.upperBound
        caretGoalColumn = nil
        showCaretNow()
        scrollCaretIntoView()
        refresh()
        return true
    }

    // MARK: - tail - f（后缀追踪，B4，仅限清洁版）

    var isFollowing: Bool { followMode }

    func setFollowMode(_ on: Bool) {
        guard on != followMode else { return }
        followMode = on
        if on {
            topLine = maxTopLine
            refresh()
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.followTick() }
            RunLoop.main.add(t, forMode: .common)
            followTimer = t
        } else {
            followTimer?.invalidate()
            followTimer = nil
        }
    }

    func endFollow() {
        guard followMode else { return }
        followTick()
        setFollowMode(false)
    }

    private func followTick() {
        guard followMode else { return }
        let wasAtBottom = (topLine >= maxTopLine)
        guard extendForGrowth() else { return }
        extendSearchForGrowth()
        if wasAtBottom { topLine = maxTopLine }
        refresh()
    }

    /// 搜索（筛选）仅包含扩展部分。**为确保筛选过程中不会遗漏新行**
    /// 项目。由于它是从上次结果中断的地方开始扫描的，因此即使有 10 个 GB，它也不会每次都重新扫描。
    /// 搜索进行中时（结果尚未完成或刚重新输入一个词后），不执行任何操作。在下一个循环中继续执行。
    private func extendSearchForGrowth() {
        guard !searchQuery.isEmpty, searchResults.isComplete, !searchBusy else { return }
        let mode: SearchMode
        if regexMode { guard let re = searchRegex else { return }; mode = .regex(re) } else { mode = .terms(searchTerms) }
        let epoch = searchEpoch
        searchBusy = true
        searchEngine?.search(mode, caseSensitive: caseSensitive, resume: searchResults, progress: { _, _ in }, completion: { [weak self] res in
            guard let self else { return }
            self.searchBusy = false
            guard self.searchEpoch == epoch else { return }
            let bottom = self.topLine >= self.maxTopLine
            self.searchResults = res
            if self.filterMode { self.rebuildFilterDisplayLines() }
            if self.followMode && bottom { self.topLine = self.maxTopLine }
            self.refresh()
            self.emitSearchState(searching: false, progress: 100, invalid: false)
        })
    }

    /// 仅导入添加的内容（跟踪和重新加载外部更改的通用路径）。
    /// 如果它没有被扩展，则为 false（= 重写。调用方重新打开页面）。
    ///
    /// piece table 的**原始长度（生成时）**已刻录到作品中，因此如果您只扩展索引……
    /// 编辑开始后，添加的内容立即消失。如果索引已完成，则无需扫描即可重新创建索引。
    /// 我们一起把它重新粘贴到这里。
    @discardableResult
    private func extendForGrowth() -> Bool {
        guard let buffer = fileBuffer, let idx = lineIndex,
              let newSize = buffer.remapIfGrownTry() else { return false }
        idx.extend(toByte: newSize)
        if pieceTable != nil, idx.isComplete {
            pieceTable = PieceTable(original: FileBufferSource(buffer),
                                    originalNewlines: idx.originalNewlines,
                                    locator: idx)
        }
        return true
    }

    // MARK: - 状态

    /// 完整索引进度（从 buildInBackground 更新）。用于状态栏中的“正在索引 N%”。
    private var partialProgress: Double = 0

    private func emitState() {
        guard let idx = lineIndex, let buffer = fileBuffer else { return }
        // 清理后，设置 LineIndex（后续扩展），编辑后，将 piece 和 table 设置为 true。
        let state = ViewerState(
            encodingName: saveEncoding.displayName,      // 显示要保存的编码（更改将在下次保存时生效）
            lineCount: readsFromOriginal ? idx.displayLineCount : (pieceTable?.lineCount ?? idx.displayLineCount),
            lineCountIsExact: readsFromOriginal ? idx.isComplete : (pieceTable != nil),
            fileSize: readsFromOriginal ? buffer.count : (pieceTable?.byteCount ?? buffer.count),
            indexProgress: idx.isComplete ? 1.0 : partialProgress,
            caret: caretPosition
        )
        onStateChange?(state)
    }

    /// 插入符（行、列）（均从 1 开始计数）。在没有插入符的显示器中，其值为 nil。
    /// 数字位数是从行首开始的字符数加 1（为了与人数的数字位数相匹配，而不是字节数）。
    private var caretPosition: (line: Int, column: Int)? {
        guard let pt = pieceTable, structuredFormatter == nil, !filterMode else { return nil }
        let line = pt.line(ofByteOffset: caretByte)
        let start = pt.byteOffset(ofLineStart: line)
        let column = start < caretByte ? decodeString(rawBytes(in: start..<caretByte)).count : 0
        return (line + 1, column + 1)
    }

    // MARK: - DocumentPane

    func reEmitState() { emitState() }
    func focusContent() { window?.makeFirstResponder(documentView) }

    /// 滚动到指定的行（从 1 开始）。
    func goToLine(_ line1Based: Int) {
        if filterMode { setFilterMode(false) }
        setTopLine(max(0, line1Based - 1))
        focusContent()
    }

    // MARK: - 书签

    private(set) var bookmarks: Set<Int> = []
    var bookmarkedLines: Set<Int> { bookmarks }

    /// 书签放置的行。如果存在光标，则书签位于该行；否则，书签位于显示的第一行。
    /// **筛选时，插入匹配行的绝对编号**（将其附加到可见行是最自然的方式）。
    private var bookmarkTargetLine: Int {
        // 筛选时，它应用于“可见匹配行”。在默认显示中，它是光标所在行。
        // （如果没有插入符号，则会显示显示屏的第一行）。
        if filterMode {
            let shown = filterDisplayLines
            return shown.indices.contains(topLine) ? shown[topLine] : topLine
        }
        if let pt = pieceTable { return pt.line(ofByteOffset: caretByte) }
        return topLine
    }

    func toggleBookmark() { toggleBookmark(line: bookmarkTargetLine) }

    /// 为指定的绝对行（从 0 开始）添加和删除书签。此处也支持点击页边距。
    func toggleBookmark(line: Int) {
        if bookmarks.contains(line) { bookmarks.remove(line) } else { bookmarks.insert(line) }
        documentView.bookmarkedLines = bookmarks
        refresh()
    }

    /// 仅显示书签的行（升序排列，绝对行从 0 开始）。并非仅在显示时显示 nil。
    /// 双击拖放行时，显示顺序存储在此处。
    private var bookmarkViewLines: [Int]?
    var isBookmarkView: Bool { bookmarkViewLines != nil }

    @discardableResult
    func setBookmarkView(_ on: Bool) -> Bool {
        if on {
            guard !bookmarks.isEmpty, !isDirty else { NSSound.beep(); return false }
            let lines = bookmarks.sorted()
            bookmarkViewLines = lines
            showOnlyLines(lines)
            return true
        }
        guard bookmarkViewLines != nil else { return true }
        bookmarkViewLines = nil
        showOnlyLines([])
        return true
    }

    /// 单击装订线。单击一次 = 附加/分离（即使只显示书签，该行仍然保留）。
    /// 仅显示书签时双击会删除书签并隐藏该行。
    private func gutterClicked(line: Int, clickCount: Int) {
        guard clickCount >= 2, var lines = bookmarkViewLines else {
            toggleBookmark(line: line)
            return
        }
        bookmarks.remove(line)
        documentView.bookmarkedLines = bookmarks
        lines.removeAll { $0 == line }
        guard !lines.isEmpty else {
            setBookmarkView(false)
            NotificationCenter.default.post(name: .bookmarkViewEnded, object: self)
            return
        }
        let keepTop = topLine
        bookmarkViewLines = lines
        showOnlyLines(lines)
        topLine = min(keepTop, lines.count - 1)
        refresh()
    }

    func goToBookmark(forward: Bool) {
        let from = bookmarkTargetLine
        // 这不会跳转到当前行（它会变成一个按下后不会移动的按钮）。
        let target = forward ? bookmarks.filter { $0 > from }.min()
                             : bookmarks.filter { $0 < from }.max()
        guard let target else { NSSound.beep(); return }
        goToLine(target + 1)
    }

    // MARK: - 拖放

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}

#if DEBUG
// MARK: - 测试接口（以无头模式驱动 B2b 编辑流程）

/// 这是验证以 document 为单位的 `insertText` / `doCommand` / 撤销 / 剪切和粘贴操作的入口点，无需创建  / GUI。
extension PieceTableViewer {
    /// 在内存原文件中准备 piece 和 table，并启用编辑（绕过文件 open 的异步路径）。
    func _testLoad(_ bytes: [UInt8], encoding: DetectedEncoding = .utf8) {
        self.encoding = encoding
        self.saveEncoding = encoding
        self.lineEnding = LineEnding.detect(Data(bytes), encoding: encoding)
        self.pieceTable = PieceTable(bytes: bytes)
        self.caretByte = 0
        self.selectionAnchor = 0
        self.caretGoalColumn = nil
        self.undoMgr.removeAllActions()
    }

    var _testDocBytes: [UInt8] {
        guard let pt = pieceTable else { return [] }
        return pt.bytes(in: 0..<pt.byteCount)
    }
    var _testDocString: String { decodeString(_testDocBytes) }
    /// 是否有换行？（数字尺会裁掉换行部分，所以用这个方法来检查。）
    var _testWrapEnabled: Bool { documentView.wrapEnabled }
    var _testColumnGuides: [Int] { documentView.columnGuides.columns }
    /// 标尺认为“第一个数字在这里”是 x（窗格坐标）。
    var _testRulerColumnOneX: CGFloat { syncColumnRuler(); return columnRuler.contentInset }
    /// 文本的第一个字符实际上是绘制的 x。`DocumentView` 是手动绘制的，所以这就是定义本身。
    var _testFirstGlyphX: CGFloat { documentView.contentOriginX }
    /// 这与点击标尺的效果相同。
    func _testToggleColumnGuide(_ column: Int) { toggleColumnGuide(column) }
    @discardableResult func _testMoveColumnGuide(_ from: Int, to: Int) -> Bool { moveColumnGuide(from, to: to) }
    var _testColumnGuidesHidden: Bool { documentView.columnGuidesHidden }
    var _testCaret: Int { caretByte }
    var _testLineCount: Int { pieceTable?.lineCount ?? 0 }

    func _testSetCaret(_ b: Int) { caretByte = b; selectionAnchor = b; caretGoalColumn = nil }
    func _testSelect(_ r: Range<Int>) { selectionAnchor = r.lowerBound; caretByte = r.upperBound }
    func _testInsert(_ s: String) { insertText(s) }
    func _testCommand(_ selector: String) { doCommand(Selector(selector)) }
    func _testCut() { cutSelection() }
    func _testPaste() { pasteClipboard() }
    func _testUndo() { undoMgr.undo() }
    func _testRedo() { undoMgr.redo() }

    // 替换 (B5)：直接注入搜索状态来驱动替换（绕过 open 的异步特性）。
    func _testSetSearch(terms: [String], regex: NSRegularExpression? = nil, caseSensitive: Bool = false, matchLines: [Int]) {
        self.searchTerms = terms
        self.searchRegex = regex
        self.caseSensitive = caseSensitive
        self.searchQuery = regex?.pattern ?? terms.joined(separator: " ")
        var r = SearchEngine.Result()
        r.lines = matchLines
        r.lineCount = matchLines.count
        r.isComplete = true
        self.searchResults = r
    }
    func _testReplaceAll(_ s: String) { replaceAll(with: s) }
    func _testReplaceCurrent(_ s: String) { replaceCurrent(with: s) }
    /// “仅显示匹配行”功能是否仍然启用？（用于验证与结构化数据的兼容性）
    var _testFilterMode: Bool { filterMode }
    /// 筛选器中列出的行（匹配行 + 前一行和后一行 N）。
    var _testFilterDisplayLines: [Int] { filterDisplayLines }
    var _testTopLine: Int { topLine }
    /// 当前被称为“第 n 个项目”的匹配行（要标记的行）。
    var _testCurrentMatchLine: Int { currentMatchLine }
    /// 当前使用的列宽。这用于验证列宽是否与筛选器中显示的行一致。
    var _testStructuredColumnWidths: [Int] { structuredFormatter?.columns.map(\.width) ?? [] }
    var _testSelection: Range<Int>? { selectionRange }

    // 選択（B7）
    func _testSelectWord(at byte: Int) { selectWord(at: byte) }
    func _testSelectLine(at byte: Int) { selectLine(at: byte) }
    func _testClick(at byte: Int, extend: Bool = false) { placeCaret(at: byte, extend: extend) }

    // 保存（B3）
    var _testIsDirty: Bool { isDirty }
    @discardableResult func _testWrite(to url: URL) -> Bool { write(to: url) }
    func _testSaveAsync(to url: URL, onBegin: @escaping () -> Void,
                        progress: @escaping (Double) -> Void, completion: @escaping (Bool) -> Void) {
        fileURL = url
        saveAsync(saveAs: false, onBegin: onBegin, progress: progress, completion: completion)
    }
    func _testSetSaveEncoding(_ enc: DetectedEncoding) { setSaveEncoding(enc) }
    var _testSaveEncoding: DetectedEncoding { saveEncoding }
    var _testIsSaving: Bool { isSaving }

    // IME（B2c）
    var _testHasMarked: Bool { hasMarked }
    var _testMarkedText: String { markedText }
    func _testSetMarked(_ s: String, sel: NSRange) {
        setMarkedText(s, selectedRange: sel, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func _testUnmark() { unmarkText() }
}
#endif

// MARK: - DocumentTextInputHandler（按键输入端口）

extension PieceTableViewer: DocumentTextInputHandler {
    /// `interpretKeyEvents` 处理已解析的编辑命令（B2a 仅处理移动和选择）。
    func doCommand(_ selector: Selector) {
        guard pieceTable != nil else { return }

        // 移除  `...AndModifySelection:` 并剪掉“我应该扩大选择范围吗？”。
        var name = NSStringFromSelector(selector)
        var extend = false
        if name.hasSuffix("AndModifySelection:") {
            extend = true
            name = String(name.dropLast("AndModifySelection:".count)) + ":"
        }
        let page = max(1, visibleLineCount - 1)

        switch name {
        case "moveLeft:":  moveHorizontal(forward: false, word: false, extend: extend)
        case "moveRight:": moveHorizontal(forward: true,  word: false, extend: extend)
        case "moveWordLeft:", "moveWordBackward:":  moveHorizontal(forward: false, word: true, extend: extend)
        case "moveWordRight:", "moveWordForward:":  moveHorizontal(forward: true,  word: true, extend: extend)
        case "moveUp:":   moveVertical(down: false, extend: extend)
        case "moveDown:": moveVertical(down: true,  extend: extend)
        case "pageUp:":   moveByLines(-page, extend: extend)
        case "pageDown:": moveByLines(page,  extend: extend)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:", "moveToBeginningOfParagraph:":
            moveToLineEdge(end: false, extend: extend)
        case "moveToEndOfLine:", "moveToRightEndOfLine:", "moveToEndOfParagraph:":
            moveToLineEdge(end: true, extend: extend)
        case "moveToBeginningOfDocument:": applyMove(to: 0, extend: extend)
        case "moveToEndOfDocument:":       applyMove(to: docByteCount, extend: extend)
        case "selectAll:": selectAllText()
        // 纯滚动（光标不移动）。
        case "scrollPageUp:":   setTopLine(topLine - page)
        case "scrollPageDown:": setTopLine(topLine + page)
        case "scrollToBeginningOfDocument:": setTopLine(0)
        case "scrollToEndOfDocument:":       setTopLine(maxTopLine)
        // --- 変異系（B2b）---
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:":
            insertBytes(lineEnding.bytes)
        case "insertTab:": insertBytes([0x09])
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:":
            if let sel = selectionRange { deleteRange(sel) }
            else if let r = backwardDeleteRange() { deleteRange(r) }
        case "deleteForward:":
            if let sel = selectionRange { deleteRange(sel) }
            else if let r = forwardDeleteRange() { deleteRange(r) }
        case "deleteWordBackward:": deleteWord(forward: false)
        case "deleteWordForward:":  deleteWord(forward: true)
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:": deleteToLineEdge(end: false)
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:":             deleteToLineEdge(end: true)
        case "insertBacktab:", "insertTabIgnoringFieldEditor:": break
        default: break
        }
    }

    /// 在光标位置 (B2b) 插入已确认的文本（部分来自正常输入、IME 确认和粘贴的文本）。
    /// 如果转换正在进行中，则丢弃 marked 并插入确认的字符串 (B2c)。
    func insertText(_ text: String) {
        guard pieceTable != nil else { return }
        let wasMarked = hasMarked
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        if !text.isEmpty {
            insertBytes(encodeForInsertion(text))   // perform() 包含 refresh
        } else if wasMarked {
            refresh()                               // 确认为空（取消转换）→ 删除下划线
        }
    }

    // MARK: - IME（marked text / 変換中・B2c）

    func setMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange) {
        guard pieceTable != nil else { return }
        // 如果在转换开始时（在 marked 可用之前）有选择，则删除该选择并将其合并到那里。
        if !hasMarked, let sel = selectionRange { deleteRange(sel) }
        markedText = text
        let n = (text as NSString).length
        let loc = min(max(0, selectedRange.location), n)
        markedSelection = NSRange(location: loc, length: min(selectedRange.length, n - loc))
        caretGoalColumn = nil
        showCaretNow()
        refresh()
    }

    func unmarkText() {
        guard pieceTable != nil else { return }
        let t = markedText
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        if !t.isEmpty { insertBytes(encodeForInsertion(t)) } else { refresh() }
    }

    func hasMarkedText() -> Bool { hasMarked }

    func markedRange() -> NSRange {
        hasMarked ? NSRange(location: 0, length: (markedText as NSString).length)
                  : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        hasMarked ? markedSelection : NSRange(location: 0, length: 0)
    }

    /// 将带下划线的字符串 marked 插入到光标线的可见显示区域，并返回光标在 marked 中的位置 (row, col)。
    /// 文件将不作修改（仅限图纸）。假定 marked 格式中没有换行符（日文格式为单行）。
    private func spliceMarkedText(into lines: inout [NSAttributedString]) -> (row: Int, col: Int)? {
        guard hasMarked,
              let row = visibleRanges.firstIndex(where: { caretByte >= $0.lowerBound && caretByte <= $0.upperBound }),
              row < lines.count else { return nil }
        let col = utf16Index(lineStart: visibleRanges[row].lowerBound, byteOffset: caretByte)
        let m = NSMutableAttributedString(attributedString: lines[row])
        let clampedCol = min(col, m.length)
        var attrs = documentView.textAttributes
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        m.insert(NSAttributedString(string: markedText, attributes: attrs), at: clampedCol)
        lines[row] = m
        let caretCol = clampedCol + min(markedSelection.location, (markedText as NSString).length)
        return (row, caretCol)
    }
}
