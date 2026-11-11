import AppKit
import SwiftHighlight

/// 小文件编辑窗格。将整个文件加载到内存中并使用 `NSTextView`
/// 编辑（撤销、IME、选择和标准复制由标准 AppKit 功能处理）。
///
/// 大文件由 `LargeFileViewer` 处理（mmap + 稀疏索引，只读）。
/// 分发阈值为 `EditableViewer.sizeThreshold`。
final class EditableViewer: NSView, DocumentPane, NSTextViewDelegate {
    /// 行内结构化编辑尚未开放；保留现有控件和状态反馈供后续实现。
    private static let structuredInlineEditingAvailable = false
    /// 在编辑窗格中打开低于此阈值的文件（高于此阈值的文件以只读模式查看）。
    static let sizeThreshold = 8 * 1024 * 1024

    private let scrollView = NSScrollView()
    private let textView = EditorTextView()
    private var highlightGeneration = 0
    private var highlightTask: DispatchWorkItem?
    private var highlightedSyntax: EditorSyntax?
    private var highlightSpans: [SwiftSyntaxEngine.Span]?
    private var paintedSyntaxRange: NSRange?
    private var chosenSyntax: EditorSyntax?
    private var csvGridView: CSVGridView?
    /// 此窗格的编辑历史记录（按窗格存储，而不是按窗口存储。请参阅 undoManager (for:)）。
    private let paneUndoManager = UndoManager()
    private let jsonQueryBar = JsonQueryBar()
    /// 行号槽（与 config 一起进出）。
    private var lineNumberRuler: LineNumberRulerView!
    /// 起始索引缓存（行号栏和状态栏中的“行:列”共享）。
    /// 当文本更改时丢弃它，并在再次需要时重新计数。
    private var lineIndexCache: LineStartIndex?
    /// 通过显示/隐藏查询栏来切换文本顶部（只能启用一个）。
    private var scrollTopToContainer: NSLayoutConstraint!
    private var scrollTopToBar: NSLayoutConstraint!

    // MARK: - 数字尺 (A) 和数字导轨 (B)
    private let columnRuler = ColumnRulerView()
    private var columnRulerOn = false
    /// 列名称栏（带列宽控制柄），用于在构建结构时显示在主文本上方。其位置与列标尺相同。
    private let structuredHeader = StructuredHeaderView()
    /// 显示标尺前的换行设置。**如果启用换行，数字位数将不固定**，因此在显示标尺时需要进行调整。
    /// 切换到水平滚动，收起时返回此处。
    private var wrapBeforeColumnRuler: Bool?
    private var rulerTopToContainer: NSLayoutConstraint!
    private var rulerTopToBar: NSLayoutConstraint!
    private var scrollTopToRuler: NSLayoutConstraint!
    private var headerTopToContainer: NSLayoutConstraint!
    private var headerTopToBar: NSLayoutConstraint!
    private var scrollTopToHeader: NSLayoutConstraint!

    private(set) var fileURL: URL?
    private(set) var generatedTitle: String?
    private var encoding: DetectedEncoding = .utf8
    /// 用户在“重新打开”时明确指定的编码（它不会恢复为自动检测，因此在重新加载时会保留）。
    private var userChosenEncoding: DetectedEncoding?
    /// 文件换行符。保存时，整个文本将标准化为该字符（NSTextView 会将换行符插入为 LF）。
    private var lineEnding: LineEnding = .lf
    private var byteSize = 0

    /// 是否有未保存的更改？
    private(set) var isDirty = false
    /// 状态更改时的通知（用于在标题栏中显示 edited）。
    var onDirtyChange: ((Bool) -> Void)?
    /// 保存完成时的通知（用于与外部更改监视器同步和侧边栏更新）。
    var onSaveCompleted: (() -> Void)?

    // MARK: - 未保存文本的保护 (DraftStore)
    //
    // 未保存的新文档的正文是用户在其他任何地方保存的唯一副本。
    // 如果您在完成后一次性写入所有内容，则在发生崩溃、强制关机或断电的情况下，所有内容都将丢失。
    // （防抖动）并写入 draft 文件，以便即使程序崩溃也能保留该文件。

    /// 存储此 draft（用于测试，插入临时目录中的那个）。
    var draftStore: DraftStore = .shared
    /// id 是未保存的新文档正文的存放位置 (draft)。对于已保存的文件，则为 nil。
    private(set) var draftID: String?
    /// 不要每次击键后都写字；等待这么长时间，给自己一些时间冷静下来再写字。
    private var draftSaveTimer: Timer?
    private static let draftDebounce: TimeInterval = 1.0

    var onStateChange: ((ViewerState) -> Void)?
    var onSearchState: ((Int, Int, Bool, Int, Bool, Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    // 仅在纯编辑状态下可进行搜索（结构化/格式化/查询的内容显示为只读）。
    // （因为替换目标将不再是正文）。末尾的“跟随”是查看大文件的功能，因此不会显示。
    var supportsSearch: Bool { structuredFormatter == nil && !jsonPrettyActive && !jsonQueryActive }
    var supportsFollow: Bool { false }
    /// “仅显示匹配的行”是一种只读显示方法，它将主要文本替换为仅匹配的行。
    /// 仅在原始编辑状态下接受（在结构化/格式化/查询编辑期间，正文已被替换）。
    var supportsSearchFilter: Bool { structuredFormatter == nil && !jsonPrettyActive && !jsonQueryActive }
    /// 虽然只显示匹配的行，但它是只读的 = 替换的目标不再是主要文本，因此不会被接受。
    var supportsReplace: Bool { canEditRawText }
    /// 格式化 / 查询期间只读以及仅显示匹配行时只读。
    var canEdit: Bool { csvGridView != nil || (structuredFormatter == nil && !jsonPrettyActive && !jsonQueryActive && preFilterText == nil) }
    private var canEditRawText: Bool { canEdit && csvGridView == nil }

    // MARK: - 结构化视图（只读格式化视图）
    private var structuredFormatter: TabularFormatter?
    /// JSON：是否启用格式设置（单个文档的缩进）？与 CSV/TSV/NDJSON 不同，它不是按列排列的，因此这是一个单独的标志。
    private var jsonPrettyActive = false
    /// JSON 查询窗口是否已启用？（结果目前以只读模式显示。）
    private var jsonQueryActive = false
    /// 结构化 ON 先前文本（使用 OFF 恢复）。
    private var preStructuredText: String?
    /// Extract Frequent Strings reports have numbered CSV columns and no header data row.
    private var generatedCSVWithoutHeader = false

    // MARK: - 仅显示匹配的行（筛选/live grep）
    //
    // 大文件本身会绘制可见的线条，因此只需要“绘制匹配的线条”即可。
    // 正文位于 `NSTextView`，因此**请将其替换为仅包含匹配行的正文**。
    // 使用与结构化显示相同的方法（备份原始文本并将其设为只读）。
    // 保存，行号，draft 必须始终指向 `logicalText`，即原文。如果写错了……
    // “如果在应用筛选条件的情况下保存，会导致程序出现最糟糕的问题，即其他行会消失。”

    /// 过滤器 ON：先前文本（已使用 OFF 恢复）。nil 表示未应用任何过滤器。
    private var preFilterText: String?
    /// 每行文本在原文中的行号（从0开始计数）。这用于在页边空白处显示原文行号。
    /// 显示 N 之前和之后的行时，上下文行也包含在内 = **不一定是匹配的行**。
    private var filterLineNumbers: [Int] = []
    /// 实际匹配的行（从 0 开始计数）。请点击此处查看分析（按值筛选）。
    private var filterMatchedLineNumbers: [Int] = []
    /// 在匹配行 (`grep -C`) 之前和之后要添加的行数。
    private var contextLines = AppSettings.filterContextLines
    /// 当前筛选是否基于时区规范 (`showOnlyLines`)？如果是，则不要添加前面或后面的 N 行。
    private var filterIsExplicit = false
    var supportsStructured: Bool { true }
    var supportsJsonReformat: Bool { true }   // 是一个可容纳全部文本的小文件窗格，因此可以进行单个 JSON 格式设置。
    var structuredMode: StructuredMode? { jsonPrettyActive ? .json : structuredFormatter?.mode }
    var structuredColumnNames: [String] { structuredFormatter?.columns.map(\.key) ?? [] }
    var structuredColumnWidths: [String: Int] {
        guard let fmt = structuredFormatter else { return [:] }
        return Dictionary(fmt.columns.map { ($0.key, $0.width) }, uniquingKeysWith: { first, _ in first })
    }
    var structuredColumnOriginalIndices: [Int] { structuredFormatter?.columns.map(\.originalIndex) ?? [] }
    /// 筛选器中匹配的行（从 0 开始计数）。返回**匹配的行，而不是显示行**。
    /// （如果我们把前面和后面的 N 行的上下文也算作“匹配”，分析结果的数量将会膨胀）。
    var filterMatchLines: [Int]? { preFilterText != nil ? filterMatchedLineNumbers : nil }

    // MARK: - 检测并跳转到列数不匹配处
    var columnMismatchCount: Int {
        guard Self.structuredInlineEditingAvailable else { return 0 }
        return mismatchedLineNumbers.count
    }
    var onColumnMismatchChange: ((Int) -> Void)?
    private var mismatchedLineNumbers: [Int] = []
    private var lastMismatchJumpIndex: Int = -1

    func jumpToNextMismatchLine() {
        guard Self.structuredInlineEditingAvailable, !mismatchedLineNumbers.isEmpty else { return }
        lastMismatchJumpIndex = (lastMismatchJumpIndex + 1) % mismatchedLineNumbers.count
        let targetLine = mismatchedLineNumbers[lastMismatchJumpIndex]
        goToLine(targetLine)
    }

    func jumpToPrevMismatchLine() {
        guard Self.structuredInlineEditingAvailable, !mismatchedLineNumbers.isEmpty else { return }
        if lastMismatchJumpIndex <= 0 {
            lastMismatchJumpIndex = mismatchedLineNumbers.count - 1
        } else {
            lastMismatchJumpIndex -= 1
        }
        let targetLine = mismatchedLineNumbers[lastMismatchJumpIndex]
        goToLine(targetLine)
    }

    // MARK: - 在结构化视图中编辑行

    private let lineEditorBar = LineEditorBar()
    private var editingLineNumber: Int?

    private func startLineEditingForCurrentSelection() {
        guard Self.structuredInlineEditingAvailable else { return }
        guard structuredMode != nil else { return }
        let charIndex = textView.selectedRange().location
        let line0 = currentLineIndex().lineIndex(at: charIndex)
        let targetLine = line0 + 1
        guard let raw = lineText(targetLine) else { return }

        editingLineNumber = targetLine

        // 计算对应行的屏幕位置。
        if let lm = textView.layoutManager,
           let tc = textView.textContainer,
           let range = lineRange(targetLine) {
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let lineRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let viewRect = textView.convert(lineRect, to: self)

            let barHeight: CGFloat = 34
            let barY = min(max(40, viewRect.minY - 2), bounds.height - barHeight - 10)
            lineEditorBar.frame = NSRect(x: 20, y: barY, width: max(300, bounds.width - 40), height: barHeight)
        } else {
            lineEditorBar.frame = NSRect(x: 20, y: 50, width: max(300, bounds.width - 40), height: 34)
        }

        addSubview(lineEditorBar) // 始终在前
        lineEditorBar.isHidden = false
        lineEditorBar.beginEdit(line: targetLine, text: raw)
    }

    private func commitLineEditing(_ newText: String) {
        guard let line = editingLineNumber else { return }
        if replaceLine(line, with: newText) {
            AppSettings.playLineEditSound()
        }
        cancelLineEditing()
    }

    private func cancelLineEditing() {
        editingLineNumber = nil
        lineEditorBar.isHidden = true
        focusContent()
    }

    // MARK: - 搜索和替换状态
    //
    // 整个文本都在内存中，因此与大文件端不同（SearchEngine 的异步扫描）
    // 所有匹配项均可立即计数。匹配项以数组形式存储在 UTF-16 范围内。
    // 高亮仅应用于可见区域，使用 temporary attribute（主文本的属性不受影响）。

    private var searchQuery = ""
    private var searchTerms: [String] = []
    private var searchRegex: NSRegularExpression?
    private var searchCaseSensitive = false
    private var searchRegexMode = false
    private var searchPreserveCase = false
    /// 正则表达式损坏（在搜索栏中显示“无效”）。
    private var searchInvalid = false
    /// 匹配范围（按文本顺序）。
    private var matches: [NSRange] = []
    /// 当前匹配（基于 1；0 = 尚未移动）。
    private var currentMatch = 0
    /// 计数上限。确保即使单字符查询产生数百万个匹配项，输入也不会停止。
    /// 由于它与每次按键同步计数，因此移除它会导致 8MB × 1 个字符出现明显的瓶颈。
    private static let matchCap = 200_000
    /// 是否已达到上限（= `matches.count` 为下限，而非总数）？将计数显示更改为“N 或更多”。
    private var matchesCapped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = EditorFont.current()
        textView.textContainerInset = NSSize(width: 4, height: 6)
        applyParagraphStyle()

        // 防止水平滚动，并使文本容器宽度跟随视图（自动换行）。
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        applyColors()

        scrollView.documentView = textView
        addSubview(scrollView)

        // 行号间距。滚动、更改文本或更改设置时重新绘制。
        let ruler = LineNumberRulerView(textView: textView)
        ruler.lineIndexProvider = { [weak self] in self?.currentLineIndex() ?? LineStartIndex("") }
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = AppSettings.showLineNumbers
        ruler.onLineClick = { [weak self] in self?.gutterClicked(row: $0, clickCount: $1) }
        lineNumberRuler = ruler
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(filterContextChanged),
                                               name: .siftEditorFilterContextChanged, object: nil)

        jsonQueryBar.translatesAutoresizingMaskIntoConstraints = false
        jsonQueryBar.isHidden = true
        jsonQueryBar.onQueryChange = { [weak self] q in self?.runJsonQuery(q) }
        jsonQueryBar.onClose = { [weak self] in self?.closeJsonQuery() }
        addSubview(jsonQueryBar)

        columnRuler.translatesAutoresizingMaskIntoConstraints = false
        columnRuler.isHidden = true
        columnRuler.onToggleGuide = { [weak self] col in self?.toggleColumnGuide(col) }
        columnRuler.onMoveGuide = { [weak self] from, to in self?.moveColumnGuide(from, to: to) ?? false }
        textView.onFieldTab = { [weak self] backwards in self?.moveCaretToField(backwards: backwards) ?? false }
        textView.onAlignAll = { [weak self] in self?.alignToColumnGuides() ?? false }
        textView.onActivateLineEditing = { [weak self] in self?.startLineEditingForCurrentSelection() }
        lineEditorBar.isHidden = true
        lineEditorBar.onCommit = { [weak self] newText in self?.commitLineEditing(newText) }
        lineEditorBar.onCancel = { [weak self] in self?.cancelLineEditing() }
        if Self.structuredInlineEditingAvailable { addSubview(lineEditorBar) }

        // 移动行后，将字符移动到相应的数字（如果不需要，则为⌘Z）。
        columnRuler.onGuideDragEnded = { [weak self] in self?.alignToColumnGuides() }
        structuredHeader.translatesAutoresizingMaskIntoConstraints = false
        structuredHeader.isHidden = true
        structuredHeader.onResize = { [weak self] i, w in self?.resizeStructuredColumn(i, to: w) }
        structuredHeader.onReorder = { [weak self] from, to in self?.reorderStructuredColumn(from, to) }
        addSubview(structuredHeader)
        addSubview(columnRuler)

        // 从上到下依次为：[查询栏] [列标尺] [主体]。只有显示的条目才会占用空间。
        scrollTopToContainer = scrollView.topAnchor.constraint(equalTo: topAnchor)
        scrollTopToBar = scrollView.topAnchor.constraint(equalTo: jsonQueryBar.bottomAnchor)
        scrollTopToRuler = scrollView.topAnchor.constraint(equalTo: columnRuler.bottomAnchor)
        scrollTopToHeader = scrollView.topAnchor.constraint(equalTo: structuredHeader.bottomAnchor)
        headerTopToContainer = structuredHeader.topAnchor.constraint(equalTo: topAnchor)
        headerTopToBar = structuredHeader.topAnchor.constraint(equalTo: jsonQueryBar.bottomAnchor)
        rulerTopToContainer = columnRuler.topAnchor.constraint(equalTo: topAnchor)
        rulerTopToBar = columnRuler.topAnchor.constraint(equalTo: jsonQueryBar.bottomAnchor)
        NSLayoutConstraint.activate([
            jsonQueryBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            jsonQueryBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            jsonQueryBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            jsonQueryBar.heightAnchor.constraint(equalToConstant: JsonQueryBar.height),
            columnRuler.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnRuler.trailingAnchor.constraint(equalTo: trailingAnchor),
            columnRuler.heightAnchor.constraint(equalToConstant: ColumnRulerView.height),
            structuredHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            structuredHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            structuredHeader.heightAnchor.constraint(equalToConstant: StructuredHeaderView.height),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollTopToContainer,
        ])
    }

    // MARK: - 数字尺 (A) 和数字导轨 (B)

    var supportsColumnRuler: Bool { true }
    var columnRulerVisible: Bool { columnRulerOn }
    var hasColumnGuides: Bool { !textView.columnGuides.isEmpty }

    func setColumnRulerVisible(_ on: Bool) {
        guard on != columnRulerOn else { return }
        columnRulerOn = on
        if on {
            // 文本换行时，一行文本被分成多行，导致列数不一致。请水平滚动查看。
            // 如果水平滚动已经启用（例如，在结构化视图中），请不要触碰它（也不要记录它，以免在返回原始视图时破坏它）。
            if textView.textContainer?.widthTracksTextView == true {
                wrapBeforeColumnRuler = true
                setWrapMode(wrapped: false)
            }
        } else if wrapBeforeColumnRuler == true {
            wrapBeforeColumnRuler = nil
            // 如果在标尺显示期间切换到结构化视图或类似视图，请勿中断该过程。
            if canEdit { setWrapMode(wrapped: true) }
        }
        updateTopLayout()
        syncColumnRuler()
        textView.needsDisplay = true
    }

    func clearColumnGuides() {
        guard !textView.columnGuides.isEmpty else { return }
        textView.columnGuides.removeAll()
        columnGuidesChanged()
    }

    var columnGuideColumns: [Int] { textView.columnGuides.columns }

    func setColumnGuides(_ columns: [Int]) {
        let next = ColumnGuides(columns)
        guard next != textView.columnGuides else { return }
        textView.columnGuides = next
        columnGuidesChanged()
    }

    private func toggleColumnGuide(_ column: Int) {
        textView.columnGuides.toggle(column)
        columnGuidesChanged()
    }

    private func moveColumnGuide(_ from: Int, to: Int) -> Bool {
        guard textView.columnGuides.move(from, to: to) else { return false }
        columnGuidesChanged()
        return true
    }

    /// 当参考线改变时，对齐标尺、正文和**该文件的内存**。
    /// 如果启用了固定长度显示，则列分隔符本身已更改，因此请重新格式化文本。
    private func columnGuidesChanged() {
        columnRuler.guides = textView.columnGuides
        updateColumnGuideVisibility()
        textView.needsDisplay = true
        AppSettings.setColumnGuides(textView.columnGuides.columns, for: fileURL)
        if structuredFormatter?.mode == .fixedWidth { setStructuredMode(.fixedWidth) }
    }

    /// 将之前保存的项目定义恢复到已打开的文件中。**如果已保存，标尺也会显示。**
    /// (如果只画一条垂直线而没有任何解释，就无法知道这条线是做什么用的)。
    private func restoreColumnGuides() {
        let remembered = AppSettings.columnGuides(for: fileURL)
        textView.columnGuides = ColumnGuides(remembered)
        columnRuler.guides = textView.columnGuides
        updateColumnGuideVisibility()
        if !remembered.isEmpty, !columnRulerOn { setColumnRulerVisible(true) }
    }

    /// 根据是否存在查询栏或列标尺调整文本的上边缘。
    private func updateTopLayout() {
        let bar = !jsonQueryBar.isHidden
        // 在构建结构时，会显示列名带。数字标尺是用于**原始数字**的工具，因此格式化后的显示效果将与原始数字不同。
        // 含义发生变化（使用相同的位置，但只显示其中一个）。
        let header = structuredFormatter != nil && csvGridView == nil
        structuredHeader.isHidden = !header
        columnRuler.isHidden = !columnRulerOn || header
        for c in [scrollTopToContainer, scrollTopToBar, scrollTopToRuler, scrollTopToHeader,
                  rulerTopToContainer, rulerTopToBar, headerTopToContainer, headerTopToBar] {
            c?.isActive = false
        }
        if header {
            (bar ? headerTopToBar : headerTopToContainer)?.isActive = true
            scrollTopToHeader.isActive = true
        } else if columnRulerOn {
            (bar ? rulerTopToBar : rulerTopToContainer)?.isActive = true
            scrollTopToRuler.isActive = true
        } else {
            (bar ? scrollTopToBar : scrollTopToContainer)?.isActive = true
        }
    }

    /// 将当前列、原点和滚动量发送到标题栏（使用与标尺相同的值）。
    private func syncStructuredHeader() {
        guard let fmt = structuredFormatter else { return }
        let font = textView.font ?? EditorFont.current()
        structuredHeader.columnWidth = EditorStyle.columnWidth(for: font)
        let offset = scrollView.contentView.bounds.origin.x
        structuredHeader.horizontalOffset = offset
        let textOriginInTextView = textView.textContainerOrigin.x
            + (textView.textContainer?.lineFragmentPadding ?? 0)
        structuredHeader.contentInset = textView.convert(NSPoint(x: textOriginInTextView, y: 0),
                                                         to: structuredHeader).x + offset
        let starts = fmt.columnStartColumns()
        structuredHeader.columns = zip(fmt.columns, starts).map {
            StructuredHeaderView.Column(name: $0.key, start: $1, width: $0.width)
        }
        structuredHeader.allowsReorder = (fmt.mode != .fixedWidth)
    }

    /// Tab **用空格填充到下一位数字**（即，字符串向该数字偏移）。填充后，变为 true。
    ///
    /// 移动方式与文字处理软件中的制表符定位相同。输入固定长度文本的用户希望光标能够“跳动”。
    /// 这不是关于“事物”的问题，而是关于“**对齐数字**”的问题，所以请发送字符。
    ///
    /// - 插入空格而不是制表符。如果固定长度的文件中混杂了制表符，其他工具将无法正常工作。
    /// 当你阅读它时，数字数量会立即减少。
    /// - 数字位数是按**显示宽度**（全角 = 2）计算的。如果按字符数计算，包含全角字符的行将会偏移。
    /// - ⇧Tab 与之相反；它会删除直到前一个数字的空格（它不会删除空格以外的任何内容）。
    private func moveCaretToField(backwards: Bool) -> Bool {
        let guides = textView.columnGuides
        guard canEditRawText else { return false }
        // **如果还没有断点，Tab 将在此处绘制。**
        // 这样做是为了省去先显示标尺再点击刻度的初步步骤。
        // （您可以通过输入 Tab → 输入 Tab 来执行数字除法）。
        guard guides.hasFieldBoundaries else { return createFieldBoundaryAtCaret(backwards: backwards) }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: min(caret, text.length), length: 0))
        let lineStart = lineRange.location
        let line = text.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
        let column = Self.displayColumn(of: caret - lineStart, in: line)

        if backwards {
            guard let target = guides.previousFieldStart(before: column) else { return true }
            // 仅当前面的元素为空时，才将位数缩减至前一项的位数。**请勿删除任何字符。**
            let targetOffset = lineStart + Self.utf16Offset(ofColumn: target, in: line)
            var from = caret
            while from > targetOffset, text.substring(with: NSRange(location: from - 1, length: 1)) == " " {
                from -= 1
            }
            guard from < caret else {
                textView.setSelectedRange(NSRange(location: max(targetOffset, lineStart), length: 0))
                emitState()
                return true
            }
            replaceForFieldTab(NSRange(location: from, length: caret - from), with: "")
            return true
        }

        guard let target = guides.nextFieldStart(after: column) else {
            return createFieldBoundaryAtCaret(backwards: false)   // 最右边也是一样 = 那里有个断点
        }
        let pad = String(repeating: " ", count: max(1, target - column))
        replaceForFieldTab(NSRange(location: caret, length: 0), with: pad)
        return true
    }

    /// 在插入符的数字上绘制一个切口（使用 Tab 创建数字除法的路径）。
    ///
    /// **线条和尺子均由 Tab 提供。** 画线时，立即切线并拿出尺子。
    /// （如果线条被折叠，就无法画线，而且没有尺子，也无法稍后进行调整）。
    /// ⇧Tab 不会创建它（不要使用反向操作增加它）。
    private func createFieldBoundaryAtCaret(backwards: Bool) -> Bool {
        guard !backwards else { return false }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: min(caret, text.length), length: 0))
        let line = text.substring(with: lineRange).replacingOccurrences(of: "\n", with: "")
        let column = Self.displayColumn(of: caret - lineRange.location, in: line)
        guard column > 1 else { return false }                       // 行的开头不是换行符。
        guard !textView.columnGuides.columns.contains(column) else { return true }   // 忽略双击
        textView.columnGuides.insert(column)
        columnGuidesChanged()
        if !columnRulerOn { setColumnRulerVisible(true) }            // 使绘制的线条可见
        emitState()
        return true
    }

    /// 标尺右侧显示的简短信息。**仅当您按下⌥Tab时，标尺上的线条实际发生变化时才会显示。**
    /// 一旦你完成排列，它就会消失（如果你把它放在一边，它就会成为风景的一部分，不会被阅读）。
    private func alignHint() -> String? {
        let guides = textView.columnGuides
        guard guides.hasFieldBoundaries, canEditRawText else { return nil }
        // 前几行就足够了（每次输入时不需要重新排列 8MB）。
        let sample: [String] = Array(textView.string.components(separatedBy: "\n").prefix(200))
        guard ColumnAlign.needsAlignment(sample, to: guides.fieldStarts) else { return nil }
        return L("columnRuler.alignHint")
    }

    /// 为列参考线分配对齐选定范围（如果不存在选定范围，则对齐整个文本）。1 撤销。
    ///
    /// **如果将第一行格式化为 Tab，则其余行也使用相同的数字** -- 如果没有这样做，确定数字后……
    /// 这涉及手动对齐数百行，最终打开 `awk`。
    @discardableResult
    func alignToColumnGuides() -> Bool {
        guard canEditRawText else { return false }
        // **如果没有断点，请从内开始。** “首先，拿出尺子画线。”
        // 假设  正确，只有知道订单内容的人才能使用它。它会立即执行 ⌥Tab。
        if !textView.columnGuides.hasFieldBoundaries {
            let sample: [String] = Array(textView.string.components(separatedBy: "\n").prefix(1000))
            let starts = ColumnAlign.inferFieldStarts(from: sample)
            guard starts.count >= 2 else { return false }
            // 第一个数字不是换行符（它是第一项的开头）。如果画一条线，它将位于正文的左边缘。
            // 竖线碍事，所以我把它去掉。
            textView.columnGuides = ColumnGuides(starts.filter { $0 > 1 })
            columnGuidesChanged()
            if !columnRulerOn { setColumnRulerVisible(true) }   // 使绘制的线条可见
        }
        let guides = textView.columnGuides
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        // 当进行选择时，将选择所应用的整行作为目标（该行不会从中间分割）。
        let range = selection.length > 0 ? text.lineRange(for: selection) : NSRange(location: 0, length: text.length)
        let source = text.substring(with: range)
        let aligned = ColumnAlign.align(source, to: guides.fieldStarts)
        guard aligned != source else { return false }
        guard textView.shouldChangeText(in: range, replacementString: aligned) else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: aligned)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: (aligned as NSString).length))
        invalidateLineIndex()
        emitState()
        return true
    }

    /// 对  / Tab 执行修剪/编辑，并执行 1 次撤销（像普通编辑一样堆叠）。
    ///
    /// **触摸数字时，调出标尺。** 如果看不到标尺，就不知道当前位于哪个数字上。
    /// 字母移动时没有任何断点指示。
    private func replaceForFieldTab(_ range: NSRange, with text: String) {
        if !columnRulerOn { setColumnRulerVisible(true) }
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        invalidateLineIndex()
        emitState()
    }

    /// UTF-16 在行中的位置 → 显示列（从 1 开始）。
    private static func displayColumn(of utf16Offset: Int, in line: String) -> Int {
        var width = 0
        var consumed = 0
        for ch in line {
            let len = String(ch).utf16.count
            if consumed >= utf16Offset { break }
            consumed += len
            width += TabularFormatter.displayWidth(String(ch))
        }
        return width + 1
    }

    /// 显示列（从 1 开始）→ UTF-16 在行内的位置。如果行较短，则位于行尾。
    private static func utf16Offset(ofColumn column: Int, in line: String) -> Int {
        var width = 1
        var offset = 0
        for ch in line {
            if width >= column { return offset }
            width += TabularFormatter.displayWidth(String(ch))
            offset += String(ch).utf16.count
        }
        return offset
    }

    /// 格式化后不要在显示屏上叠加参考线。
    ///
    /// **项目定义为“原始文本中的列数”**。进入结构化显示时，文本（包括分隔符）将被重新排列。
    /// 用线穿过同一个数字指向的点并非项目的终点（我在实际设备上发现了这一点）。定义保持不变。
    /// 仅停止绘图和操作；退出后恢复正常。
    private func updateColumnGuideVisibility() {
        let structured = structuredFormatter != nil || jsonPrettyActive || jsonQueryActive
        textView.columnGuidesHidden = structured
        columnRuler.guidesEditable = !structured
    }

    /// 将当前数字宽度、原点、滚动量和光标数字发送到标尺。
    private func syncColumnRuler() {
        guard columnRulerOn else { return }
        let font = textView.font ?? EditorFont.current()
        columnRuler.columnWidth = EditorStyle.columnWidth(for: font)
        // 第一个数字 x **不能猜测**。将间距宽度、容器边距和滚动位置相加。
        // 当我自己编写公式时，我总是会重复计算其中一项（它实际上会向右移动行号的间距）。
        // 将文本中第一个字符的位置转换为 AppKit，并将其用作原点。
        let offset = scrollView.contentView.bounds.origin.x
        columnRuler.horizontalOffset = offset
        let textOriginInTextView = textView.textContainerOrigin.x
            + (textView.textContainer?.lineFragmentPadding ?? 0)
        let inPane = textView.convert(NSPoint(x: textOriginInTextView, y: 0), to: columnRuler)
        // 转换结果包含滚动浏览的部分。由于标尺侧再次减去了这部分内容，因此它将被重新添加进去。
        columnRuler.contentInset = inPane.x + offset
        columnRuler.guides = textView.columnGuides
        let caretColumn = caretPosition.column
        columnRuler.currentColumn = caretColumn
        columnRuler.hint = alignHint()
        // 您当前正在查看哪个项目？（标尺还可以看到您已使用 Tab 经过。）
        // 最后一个项目在文本边缘关闭——如果保持打开状态，横幅将延伸到屏幕边缘。
        let widest = ColumnRuler.column(atX: (textView.layoutManager?.usedRect(for: textView.textContainer!).width ?? 0),
                                        columnWidth: EditorStyle.columnWidth(for: font))
        columnRuler.currentField = textView.columnGuides.fieldRange(containing: caretColumn,
                                                                    lastColumn: max(widest, caretColumn))
        columnRuler.selectedColumns = selectedColumnRange()
    }

    /// 选择列范围（仅当选择内容可在一行内显示时）。跨越多行的选择内容将不包含在列范围内。
    private func selectedColumnRange() -> ClosedRange<Int>? {
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        let text = textView.string as NSString
        let index = currentLineIndex()
        let start = index.position(at: range.location, in: text)
        let end = index.position(at: NSMaxRange(range), in: text)
        guard start.line == end.line, end.column > start.column else { return nil }
        return start.column...(end.column - 1)
    }

    override var isFlipped: Bool { true }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.repaintVisibleSyntax() }
    }

    // MARK: - 起始索引（行号间距和光标位置的共享缓存）

    /// 当前显示文本中每行开头的索引。如果未找到，则重新计数并缓存。
    private func currentLineIndex() -> LineStartIndex {
        if let cached = lineIndexCache { return cached }
        let index = LineStartIndex(textView.string as NSString)
        lineIndexCache = index
        return index
    }

    /// 当主文本被替换/编辑时调用（下次需要时重新计数）。
    /// 如果文本发生更改，搜索匹配位置也将失效，因此请在此处重新计数（文本替换为
    /// 由于它不经过  / delegate，因此单独 textDidChange 会丢失一些数据。
    private func invalidateLineIndex() {
        lineIndexCache = nil
        lineNumberRuler?.updateThickness()
        lineNumberRuler?.needsDisplay = true
        if !searchQuery.isEmpty { recomputeMatches() }
    }

    @objc private func scrolled() {
        lineNumberRuler?.needsDisplay = true
        syncColumnRuler()                               // 使刻度跟随水平滚动条移动。
        syncStructuredHeader()                          // 还会显示带有列名称的横幅。
        if !matches.isEmpty { applySearchHighlight() }   // 我会重新发送，因为我只会涂可见区域。
        repaintVisibleSyntax()
    }

    /// 光标位置（起始行和列为 1）。选中后，光标指向选区的起始位置。
    private var caretPosition: (line: Int, column: Int) {
        let text = textView.string as NSString
        return currentLineIndex().position(at: textView.selectedRange().location, in: text)
    }

    // MARK: - 打开文件

    @discardableResult
    func open(url: URL) -> Bool { open(url: url, forcedEncoding: nil) }

    var currentEncoding: DetectedEncoding { encoding }
    var currentSaveEncoding: DetectedEncoding { encoding }
    var currentSyntax: EditorSyntax { chosenSyntax ?? EditorSyntax.forFile(fileURL) }
    var currentLineEnding: LineEnding { lineEnding }

    func setSyntax(_ syntax: EditorSyntax, rememberExtension: Bool = true) {
        chosenSyntax = syntax
        if rememberExtension, let ext = fileURL?.pathExtension.lowercased(), !ext.isEmpty {
            AppSettings.setSyntaxLanguage(syntax, forExtension: ext)
        }
        applySyntaxHighlight()
        emitState()
    }

    func setLineEnding(_ ending: LineEnding) {
        guard lineEnding != ending else { return }
        lineEnding = ending
        setDirty(true)
        emitState()
    }

    /// 使用指定的编码重新打开当前文件（修正自动编码错误导致的乱码）。已编辑的内容将被丢弃。
    @discardableResult
    func reopen(withEncoding enc: DetectedEncoding) -> Bool {
        guard let url = fileURL else { return false }
        return open(url: url, forcedEncoding: enc)
    }

    /// 如果传递  / `forcedEncoding`，则自动检测将被覆盖，并且代码将使用该编码进行解码。
    @discardableResult
    func open(url: URL, forcedEncoding: DetectedEncoding?) -> Bool {
        guard let data = try? Data(contentsOf: url) else {
            NSSound.beep()
            return false
        }
        let prefix = data.prefix(64 * 1024)
        let detected = forcedEncoding ?? EncodingDetector.detect(prefix)
        // 使用检测编码解码 。如果解码失败，则回退到 UTF-8 替换解码。
        let text: String
        if let s = String(data: data, encoding: detected.stringEncoding) {
            text = s
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        self.fileURL = url
        self.chosenSyntax = nil
        self.draftID = nil          // 打开实际文件的窗格中没有 draft
        self.userChosenEncoding = forcedEncoding
        self.encoding = detected
        self.lineEnding = LineEnding.detect(Data(prefix), encoding: detected)
        self.byteSize = data.count
        resetStructuredPresentation()
        textView.string = text
        invalidateLineIndex()
        applyParagraphStyle()                       // 将制表符宽度和行距应用于整个文本。
        applySyntaxHighlight()
        textView.undoManager?.removeAllActions()   // 请勿撤销加载。
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setDirty(false)
        restoreColumnGuides()
        emitState()
        return true
    }

    /// 重新导入已被其他应用程序覆盖的文件。
    /// 保持光标和滚动位置（它会自动运行，所以如果每次都跳到顶部就没用了）。
    /// 如果用户在“重新打开”时指定了编码，则编码将被保留（不会恢复为自动检测）。
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let url = fileURL else { return false }
        let selection = textView.selectedRange()
        let scrollOrigin = scrollView.contentView.bounds.origin
        guard open(url: url, forcedEncoding: userChosenEncoding) else { return false }

        // 由于长度可能会缩短，因此所选内容将四舍五入到新的文本长度。
        let length = (textView.string as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location,
                                          length: min(selection.length, length - location)))
        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    /// 会话恢复正文（结构化会话期间的原始逻辑正文）。当前内容，无论是否已保存。
    var restorableText: String? { logicalText }

    // MARK: - 打印（在打印对话框中选择“另存为 PDF ▸ PDF”也可输出 PDF）

    var canPrint: Bool { true }

    /// 打印当前显示的文本。分页符和换行符由 NSTextView 处理。
    /// 启用结构化显示时，按原样打印格式化的外观（与屏幕显示匹配）。
    func printDocument() {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        // 确保留出页眉/页脚边距，同时调整宽度以适应纸张，使线条不会被截断。
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.jobTitle = fileURL?.lastPathComponent ?? L("doc.untitled")
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        if let win = window {
            op.runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }

    // 读取和写入  MARK: - draft（未保存的文本）

    /// 输入后稍等片刻，然后输入 draft（不要每次连续输入都敲击磁盘）。
    private func scheduleDraftSave() {
        guard fileURL == nil, draftID != nil else { return }   // 保存的文件不包含 draft
        draftSaveTimer?.invalidate()
        draftSaveTimer = Timer.scheduledTimer(withTimeInterval: Self.draftDebounce, repeats: false) { [weak self] _ in
            self?.flushDraft()
        }
    }

    /// 立即将累积文本写入 draft（在终止前和停用时也会调用）。
    func flushDraft() {
        draftSaveTimer?.invalidate()
        draftSaveTimer = nil
        guard fileURL == nil, let id = draftID else { return }
        draftStore.write(id: id, text: logicalText)
    }

    /// 丢弃  / draft。**仅当用户关闭（丢弃）文档时调用。**
    /// “已保存的文件”窗格中没有任何反应（缺少 draftID）。
    func discardDraft() {
        draftSaveTimer?.invalidate()
        draftSaveTimer = nil
        guard let id = draftID else { return }
        draftStore.discard(id)
        draftID = nil
    }

    /// 从  / draft 恢复未保存的新文档（文档正文位于磁盘上的 draft 文件中）。
    func restoreDraft(id: String, text: String, dirty: Bool) {
        draftID = id
        restoreUntitled(text: text, dirty: dirty)
    }

    /// 从上次会话中恢复一个未保存的新文档及其正文（路径未确定）。
    func restoreUntitled(text: String, dirty: Bool) {
        fileURL = nil
        chosenSyntax = nil
        encoding = .utf8
        lineEnding = .lf
        byteSize = text.utf8.count
        resetStructuredPresentation()
        textView.string = text
        invalidateLineIndex()
        applyParagraphStyle()
        applySyntaxHighlight()
        textView.undoManager?.removeAllActions()   // 请勿撤销恢复操作。
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setDirty(dirty)
        emitState()
    }

    /// 初始化为一个新的空文档（路径尚未确定；将在保存时确定）。
    /// 此时，将 id 分配给 draft（当主体为空时，不要创建文件）。
    func newDocument() {
        draftID = DraftStore.newID()
        fileURL = nil
        chosenSyntax = nil
        generatedTitle = nil
        encoding = .utf8
        lineEnding = .lf
        byteSize = 0
        resetStructuredPresentation()
        textView.string = ""
        invalidateLineIndex()
        applySyntaxHighlight()
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        setDirty(false)
        emitState()
    }

    /// Put a generated, unsaved report in a normal editor document.
    func setGeneratedText(_ text: String) {
        generatedCSVWithoutHeader = false
        textView.string = text
        invalidateLineIndex()
        applySyntaxHighlight()
        textView.undoManager?.removeAllActions()
        setDirty(true)
        emitState()
    }

    func setGeneratedCSVText(_ text: String, hasHeader: Bool = false, title: String? = nil) {
        generatedTitle = title
        setGeneratedText(text)
        generatedCSVWithoutHeader = !hasHeader
    }

    // MARK: - 保存

    /// 更新变更状态，并在有任何变更时发出通知。
    private func setDirty(_ value: Bool) {
        guard value != isDirty else { return }
        isDirty = value
        onDirtyChange?(value)
    }

    /// 设置保存编码（暂不导出。设置为 dirty 并在下次保存时应用）。
    /// 由于小文件保留字符串，因此无需区分保存的编码和缓冲区的编码。
    func setSaveEncoding(_ enc: DetectedEncoding) {
        guard enc != encoding else { return }
        encoding = enc          // ⌘S write() 重新编码为该编码并将其写入。
        setDirty(true)
        emitState()
    }

    /// 保存到现有路径（如果路径不存在，则保存为 saveAs）。成功时保存为 true。
    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    /// 选择保存位置并保存 (NSSavePanel)。保存成功：true。
    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        if let url = fileURL {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    /// 用于保存和行数计算的逻辑文本。启用结构化显示时，它将返回原始文本，而不是格式化后的外观。
    /// （格式化只是显示转换，不会损坏 CSV/JSON 的内容）。
    private var logicalText: String { csvGridView?.sourceIncludingPendingEdit() ?? preFilterText ?? preStructuredText ?? textView.string }

    /// 使用检测到的编码原子地写入当前文本。
    /// 如果检测到的编码无法表示的字符数增加，则会回退到 UTF-8。
    private func write(to url: URL) -> Bool {
        guard csvGridView?.flushPendingEdit() != false else { return false }
        // NSTextView 在 LF 处插入换行符，因此保存时，文件中的整个文本将与 EOL 对齐。
        let s = lineEnding.normalize(logicalText)
        var enc = encoding
        var data = s.data(using: enc.stringEncoding)
        if data == nil {
            let original = enc.displayName
            enc = .utf8
            data = s.data(using: .utf8)
            let a = NSAlert()
            a.messageText = L("save.encodingFallback", original)
            a.runModal()
        }
        guard let data else { NSSound.beep(); return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        encoding = enc
        fileURL = url
        byteSize = data.count
        setDirty(false)
        // 正文已成为实际文件。draft 不再需要（它是可以删除的两个路径之一）。
        discardDraft()
        emitState()
        return true
    }

    // MARK: - NSTextViewDelegate

    /// 此窗格特有的撤销功能。默认情况下，它与窗口共享撤销功能，但如果一个窗口中有多个文档……
    /// 由于其结构方式，⌘Z 将返回到编辑另一个文档。
    func undoManager(for view: NSTextView) -> UndoManager? { paneUndoManager }

    func textDidChange(_ notification: Notification) {
        setDirty(true)
        scheduleDraftSave()   // 为确保即使程序崩溃，未保存的文本仍保留在磁盘上，请将未保存的主文本保存到磁盘。
        invalidateLineIndex() // 行未对齐 = 重新计算行号间距和插入符位置。
        applySyntaxHighlight()
        emitState()           // 更新行计数和状态
    }

    /// 当光标移动时，更新状态栏中的“行:列”。
    func textViewDidChangeSelection(_ notification: Notification) {
        emitState()
    }

    // MARK: - 编辑工具箱（获取选择/替换、变换/管道功能包含在这两个工具箱中。）

    var selectedText: String? {
        guard canEditRawText else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    var selectedTextForFind: String? {
        let range = textView.selectedRange()
        guard range.length > 0, range.length <= 1024 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    /// 替换所选内容并将其放入 NSTextView 的撤销机制中（保持替换内容被选中）。
    func replaceSelection(with text: String) {
        guard canEditRawText else { NSSound.beep(); return }
        let range = textView.selectedRange()
        guard range.length > 0 else { NSSound.beep(); return }
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.replaceCharacters(in: range, with: text)
        textView.didChangeText()   // dirty/draft/ 状态通过  textDidChange 更新。
        textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
    }

    // MARK: - 多光标（仅适用于 NSTextView 的非连续选择 = 仅在此窗格中）

    var supportsMultiCursor: Bool { canEditRawText }
    func addCaret(above: Bool) {
        guard canEditRawText else { NSSound.beep(); return }
        textView.addCaret(above: above)
    }
    func selectNextOccurrence() {
        guard canEditRawText else { NSSound.beep(); return }
        textView.selectNextOccurrence()
    }
    func selectAllSearchMatches() -> SearchSelectAllOutcome {
        guard canEditRawText, !searchInvalid, !searchQuery.isEmpty else { return .unavailable }
        guard !matchesCapped else { return .capped }
        guard !matches.isEmpty else { return .noMatches }
        textView.window?.makeFirstResponder(textView)
        textView.selectSearchMatches(matches)
        return .selectedMatches(matches.count)
    }

    // MARK: - 検索・置換

    func setSearchQuery(_ q: String) {
        guard q != searchQuery else { return }
        searchQuery = q
        rebuildSearch()
    }
    func setCaseSensitive(_ on: Bool) {
        guard on != searchCaseSensitive else { return }
        searchCaseSensitive = on
        rebuildSearch()
    }
    func setRegexMode(_ on: Bool) {
        guard on != searchRegexMode else { return }
        searchRegexMode = on
        rebuildSearch()
    }
    func setPreserveCase(_ on: Bool) { searchPreserveCase = on }
    /// 仅显示匹配的行（live grep）。ON 之间的部分为只读，正文内容仅替换为匹配的行。
    /// 原文已移至 `preFilterText`，保存、行数和 draft 应始终指向该位置。
    func setFilterMode(_ on: Bool) {
        guard on != (preFilterText != nil) else { return }
        if on {
            guard supportsSearchFilter else { NSSound.beep(); return }
            preFilterText = textView.string
            textView.isEditable = false
            applyFilteredText()
        } else {
            guard let original = preFilterText else { return }
            preFilterText = nil
            filterLineNumbers = []
            filterMatchedLineNumbers = []
            lineNumberRuler?.displayLineNumber = nil
            lineNumberRuler?.maxLineNumberOverride = nil
            textView.isEditable = true
            textView.delegate = nil
            textView.string = original
            textView.delegate = self
            applyParagraphStyle(); applyColors()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            invalidateLineIndex()
            recomputeMatches()
            emitState()
        }
    }

    var filterContextLines: Int {
        AppSettings.filterContextLines
    }

    /// 更改匹配行前后添加的行数。如果筛选正在进行中，请重新发布主文本。
    func setFilterContextLines(_ n: Int) {
        let clamped = min(max(0, n), FilterContext.maxContext)
        let changed = clamped != contextLines
        contextLines = clamped
        AppSettings.filterContextLines = clamped
        guard changed else { return }
        // 请勿在按一天中的时间进行筛选时重新发布（重新发布会将其变成基于搜索的筛选）。
        if preFilterText != nil, !filterIsExplicit { applyFilteredText() }
    }

    @objc private func filterContextChanged(_ notification: Notification) {
        let current = AppSettings.filterContextLines
        guard current != contextLines else { return }
        contextLines = current
        if preFilterText != nil, !filterIsExplicit { applyFilteredText() }
    }

    /// 仅显示指定的行（通过拖动时间分布图选择）。如果数组为空，则取消选择。
    func showOnlyLines(_ lines: [Int]) {
        guard !lines.isEmpty else {
            if preFilterText != nil { setFilterMode(false) }
            return
        }
        guard supportsSearchFilter else { NSSound.beep(); return }
        if preFilterText == nil {
            preFilterText = textView.string
            textView.isEditable = false
        }
        applyFilteredText(only: Set(lines))
    }

    /// 从原始文本中提取匹配的行并重新显示。每次查询更改时都应调用此函数。
    /// 如果查询为空，则匹配项为 0 = 不显示任何内容（与大文件端的过滤器行为相同）。
    ///
    /// 如果匹配行之前和之后的行有设置（相当于 N），则匹配行周围的行也将包含在内（相当于 `grep -C`）。
    /// **请勿添加到指定时间范围筛选器 (`explicit`)** -- 超出所选范围的行
    /// 当两者混合在一起时，“选定的时间段”就变成了谎言。
    private func applyFilteredText(only explicit: Set<Int>? = nil) {
        guard let source = preFilterText else { return }
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // 末尾多余换行符（未创建空行）
        var matched: [Int] = []
        for (i, line) in lines.enumerated() {
            // 如果指定了行 ，则按照该行进行筛选（基于时间分布）。否则，使用搜索结果中匹配的行。
            let keep = explicit.map { $0.contains(i) } ?? !matchRanges(in: line).isEmpty
            if keep { matched.append(i) }
        }
        let numbers = explicit == nil
            ? FilterContext.expand(matches: matched, context: contextLines, lineCount: lines.count)
            : matched
        let kept = numbers.map { lines[$0] }
        filterIsExplicit = explicit != nil
        filterMatchedLineNumbers = matched
        filterLineNumbers = numbers
        // 装订线显示的是**原始行号**，而不是显示顺序（以便清楚地表明这些行不是连续的）。
        lineNumberRuler?.displayLineNumber = { [weak self] row in
            guard let self, row >= 0, row < self.filterLineNumbers.count else { return row + 1 }
            return self.filterLineNumbers[row] + 1
        }
        lineNumberRuler?.maxLineNumberOverride = max(lines.count, 1)

        textView.delegate = nil
        textView.string = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        textView.delegate = self
        applyParagraphStyle(); applyColors()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        lineIndexCache = nil
        lineNumberRuler?.updateThickness()
        lineNumberRuler?.needsDisplay = true
        recomputeMatches()
        emitState()
    }

    /// 从查询模式重建模式并重新统计匹配项。
    private func rebuildSearch() {
        searchTerms = []
        searchRegex = nil
        searchInvalid = false
        if !searchQuery.isEmpty {
            if searchRegexMode {
                // ^ / $ 应用于行的开头和结尾（类似于大文件检查每一行的方式）。
                var opts: NSRegularExpression.Options = [.anchorsMatchLines]
                if !searchCaseSensitive { opts.insert(.caseInsensitive) }
                do { searchRegex = try NSRegularExpression(pattern: searchQuery, options: opts) }
                catch { searchInvalid = true }
            } else {
                searchTerms = SearchMode.splitTerms(searchQuery)
            }
        }
        // 仅显示匹配的行，但显示的整个文本将被重建（包括文本内的计数）。
        if preFilterText != nil { applyFilteredText() } else { recomputeMatches() }
    }

    /// 重新统计整个文本中的匹配项，并更新突出显示和计数显示。
    private func recomputeMatches() {
        matches = matchRanges(in: textView.string)
        matchesCapped = matches.count >= Self.matchCap
        currentMatch = 0
        applySearchHighlight()
        emitSearchState()
    }

    /// 匹配字符串（UTF-16 范围，文本顺序）。对于字面值，将匹配所有出现的位置。
    private func matchRanges(in text: String) -> [NSRange] {
        guard !searchInvalid else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        if let rx = searchRegex {
            rx.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
                if let r = m?.range, r.length > 0 {
                    out.append(r)
                    if out.count >= Self.matchCap { stop.pointee = true }
                }
            }
            return out
        }
        let opts: NSString.CompareOptions = searchCaseSensitive ? [] : .caseInsensitive
        for term in searchTerms where !term.isEmpty {
            var from = 0
            while from <= ns.length, out.count < Self.matchCap {
                let r = ns.range(of: term, options: opts, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                out.append(r)
                from = r.location + max(1, r.length)
            }
        }
        if searchTerms.count > 1 { out.sort { $0.location < $1.location } }
        return out
    }

    private func emitSearchState() {
        onSearchState?(currentMatch, matches.count, false, 0, searchInvalid, matchesCapped)
    }

    /// 绘制匹配项。仅绘制可见区域，因此即使有数万次点击，滚动也不会变慢。
    /// (不是主文本的属性；temporary attribute = 不包含在撤销或保存中)。
    private func applySearchHighlight() {
        guard let lm = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        guard !matches.isEmpty else { return }
        // “当前匹配”通过选择（NSTextView 从顶部抽取）来指示。此处，所有匹配项的颜色相同。
        let color = EditorTheme.current().searchMatch
        let visible = visibleCharacterRange()
        for r in matches where NSIntersectionRange(r, visible).length > 0 {
            lm.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: r)
        }
    }

    /// 屏幕上显示的当前文本范围（前后留有少量边距）。
    private func visibleCharacterRange() -> NSRange {
        guard let lm = textView.layoutManager, let container = textView.textContainer else {
            return NSRange(location: 0, length: 0)
        }
        let glyphs = lm.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = textView.textStorage?.length ?? 0
        let start = max(0, chars.location - 1000)
        let end = min(length, chars.location + chars.length + 1000)
        return NSRange(location: start, length: max(0, end - start))
    }

    func findNext() {
        guard !matches.isEmpty else { NSSound.beep(); return }
        let sel = textView.selectedRange()
        let from = sel.location + sel.length
        // 选择后的第一个匹配项。如果没有匹配项，则移至开头。
        let idx = matches.firstIndex { $0.location >= from } ?? 0
        select(match: idx)
    }

    func findPrev() {
        guard !matches.isEmpty else { NSSound.beep(); return }
        let sel = textView.selectedRange()
        let idx = matches.lastIndex { $0.location < sel.location } ?? (matches.count - 1)
        select(match: idx)
    }

    /// 选择  / `index` 处的匹配项，并将其放置在屏幕上。
    private func select(match index: Int) {
        guard index >= 0, index < matches.count else { return }
        currentMatch = index + 1
        let r = matches[index]
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        applySearchHighlight()
        emitSearchState()
    }

    /// 替换当前匹配项并继续。如果选择不匹配，只需搜索下一个（您可以按住前进）。
    func replaceCurrent(with replacement: String) {
        guard canEditRawText else { NSSound.beep(); return }
        guard !matches.isEmpty else { NSSound.beep(); return }
        let sel = textView.selectedRange()
        guard sel.length > 0, matches.contains(where: { NSEqualRanges($0, sel) }),
              let text = replacementText(for: sel, with: replacement) else {
            findNext()
            return
        }
        guard textView.shouldChangeText(in: sel, replacementString: text) else { return }
        textView.replaceCharacters(in: sel, with: text)
        textView.didChangeText()   // textDidChange 触发对匹配 dirty/draft/ 的重新计数。
        let after = NSRange(location: sel.location + (text as NSString).length, length: 0)
        textView.setSelectedRange(after)
        findNext()
    }

    /// 替换所有匹配项（撤销 1）。
    func replaceAll(with replacement: String) {
        guard canEditRawText, !matches.isEmpty, let storage = textView.textStorage else { NSSound.beep(); return }
        var ranges: [NSRange] = []
        var strings: [String] = []
        var last = -1
        for r in matches {
            guard r.location >= last else { continue }   // 当单词重叠时，先选中的单词优先。
            guard let s = replacementText(for: r, with: replacement) else { continue }
            ranges.append(r)
            strings.append(s)
            last = r.location + r.length
        }
        guard !ranges.isEmpty else { NSSound.beep(); return }
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                        replacementStrings: strings) else { return }
        // 从背面应用（先更换正面会改变背面的范围）。
        storage.beginEditing()
        for (r, s) in zip(ranges, strings).reversed() { storage.replaceCharacters(in: r, with: s) }
        storage.endEditing()
        textView.didChangeText()
        applyParagraphStyle()   // 对插入的文本应用制表符宽度和行距。
        textView.setSelectedRange(NSRange(location: min(ranges[0].location, storage.length), length: 0))
    }

    /// 替换字符串，用于匹配范围 `range`（正则表达式反映 $1 扩展和大小写保留）。
    /// 如果它不再符合该模式，则为 nil。
    private func replacementText(for range: NSRange, with replacement: String) -> String? {
        let ns = textView.string as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        let matched = ns.substring(with: range)
        func shaped(_ s: String) -> String {
            searchPreserveCase ? CasePreserving.apply(s, matching: matched) : s
        }
        if let rx = searchRegex {
            let text = textView.string
            guard let m = rx.firstMatch(in: text, range: range), NSEqualRanges(m.range, range) else { return nil }
            return shaped(rx.replacementString(for: m, in: text, offset: 0, template: replacement))
        }
        return shaped(replacement)
    }

    /// 行跳转（从 1 开始）。将光标放在行的开头并将其放在屏幕上。
    // MARK: - 书签

    private(set) var bookmarks: Set<Int> = []
    var bookmarkedLines: Set<Int> { bookmarks }

    /// 光标所在行（从 0 开始）。
    private var caretLine0: Int {
        let index = currentLineIndex()
        return index.lineIndex(at: textView.selectedRange().location)
    }

    /// 显示行号（从 0 开始），并将其设置为原始文件中的行号。筛选过程中，显示的行号与原始行号将不一致。
    private func absoluteLine(forRow row: Int) -> Int {
        preFilterText != nil && row >= 0 && row < filterLineNumbers.count ? filterLineNumbers[row] : row
    }

    func toggleBookmark() { toggleBookmark(line: absoluteLine(forRow: caretLine0)) }

    /// 添加和删除原始文件中行（从 0 开始）的书签。
    func toggleBookmark(line: Int) {
        if bookmarks.contains(line) { bookmarks.remove(line) } else { bookmarks.insert(line) }
        // 此命令重新绘制行号标尺（小文件侧的装订线位于此处）。
        lineNumberRuler?.bookmarkedLines = bookmarks
        lineNumberRuler?.needsDisplay = true
    }

    /// 用于仅显示书签的行（按升序排列，原始文件中的行）。显示时不是 nil。
    private var bookmarkViewLines: [Int]?
    var isBookmarkView: Bool { bookmarkViewLines != nil }

    @discardableResult
    func setBookmarkView(_ on: Bool) -> Bool {
        if on {
            guard !bookmarks.isEmpty, supportsSearchFilter else { NSSound.beep(); return false }
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

    /// 书签栏点击（`row` 为显示的行）。单击一次 = 附加/分离（即使只显示书签，该行仍然保留）。
    /// 仅显示书签时双击会删除书签并隐藏该行。
    private func gutterClicked(row: Int, clickCount: Int) {
        let line = absoluteLine(forRow: row)
        guard clickCount >= 2, var lines = bookmarkViewLines else {
            toggleBookmark(line: line)
            return
        }
        bookmarks.remove(line)
        lineNumberRuler?.bookmarkedLines = bookmarks
        lines.removeAll { $0 == line }
        guard !lines.isEmpty else {
            setBookmarkView(false)
            NotificationCenter.default.post(name: .bookmarkViewEnded, object: self)
            return
        }
        let keepY = scrollView.contentView.bounds.origin.y
        bookmarkViewLines = lines
        showOnlyLines(lines)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: keepY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        lineNumberRuler?.needsDisplay = true
    }

    func goToBookmark(forward: Bool) {
        let from = absoluteLine(forRow: caretLine0)
        let target = forward ? bookmarks.filter { $0 > from }.min()
                             : bookmarks.filter { $0 < from }.max()
        guard let target else { NSSound.beep(); return }
        if preFilterText != nil {
            // 筛选时，只有出现在主文本中的行才会被用作目标。
            guard let row = filterLineNumbers.firstIndex(of: target) else { NSSound.beep(); return }
            goToLine(row + 1)
        } else {
            goToLine(target + 1)
        }
    }

    func goToLine(_ line1Based: Int) {
        let ns = textView.string as NSString
        guard ns.length >= 0 else { return }
        let index = currentLineIndex()
        let line0 = min(max(0, line1Based - 1), max(0, index.lineCount - 1))
        let location = min(index.start(ofLine: line0), ns.length)
        let range = NSRange(location: location, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        focusContent()
    }

    private func lineRange(_ line1Based: Int) -> NSRange? {
        let ns = textView.string as NSString
        guard ns.length > 0 else { return nil }
        let index = currentLineIndex()
        let line0 = line1Based - 1
        guard line0 >= 0, line0 < index.lineCount else { return nil }
        let start = index.start(ofLine: line0)
        let end = (line0 + 1 < index.lineCount) ? index.start(ofLine: line0 + 1) : ns.length
        var contentEnd = end
        if contentEnd > start, ns.character(at: contentEnd - 1) == 0x0A {
            contentEnd -= 1
            if contentEnd > start, ns.character(at: contentEnd - 1) == 0x0D {
                contentEnd -= 1
            }
        }
        return NSRange(location: start, length: max(0, contentEnd - start))
    }

    func lineText(_ line1Based: Int) -> String? {
        let text = logicalText
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let line0 = line1Based - 1
        guard line0 >= 0, line0 < lines.count else { return nil }
        return lines[line0]
    }

    func replaceLine(_ line1Based: Int, with newText: String) -> Bool {
        if let original = preStructuredText {
            // 结构化显示进行中：替换原始文本，重新绘制结构化显示，然后保存。
            var lines = original.components(separatedBy: "\n")
            let hasTrailingNewline = lines.last == ""
            if hasTrailingNewline { lines.removeLast() }
            let line0 = line1Based - 1
            guard line0 >= 0, line0 < lines.count else { return false }
            lines[line0] = newText
            var updated = lines.joined(separator: "\n")
            if hasTrailingNewline { updated += "\n" }
            preStructuredText = updated
            // 重建结构化格式化程序并重新绘制。
            if let mode = structuredMode {
                let sample = lines.count > 2000
                    ? Array(lines.prefix(1000)) + Array(lines.suffix(1000))
                    : lines
                structuredFormatter = TabularFormatter.build(mode: mode, sampleLines: sample, fields: [])
            }
            renderStructured()
            if let url = fileURL {
                if write(to: url) {
                    onSaveCompleted?()
                }
            } else {
                isDirty = true
                onDirtyChange?(true)
            }
            return true
        }

        guard let range = lineRange(line1Based) else { return false }
        textView.replaceCharacters(in: range, with: newText)
        if let url = fileURL {
            if write(to: url) {
                onSaveCompleted?()
            }
        }
        return true
    }

    // MARK: - DocumentPane

    func reEmitState() { emitState() }

    func focusContent() {
        if let csvGridView { csvGridView.focusContent(); return }
        window?.makeFirstResponder(textView)
    }

    /// 确保包含插入文本的窗格在隐藏时激活后立即呈现。
    /// 在隐藏状态下设置 `string` 会导致字形布局延迟，直到您与其交互才会显示字形。
    /// 有时可以看到。显式运行帧确认 → 字形布局 → 重绘。
    func ensureVisibleLayout() {
        layoutSubtreeIfNeeded()
        if let container = textView.textContainer, let lm = textView.layoutManager {
            lm.ensureLayout(for: container)
        }
        textView.needsDisplay = true
        repaintVisibleSyntax()
    }

    func applyCurrentFontSize() {
        csvGridView?.applyCurrentFontSize()
        textView.font = EditorFont.current()
        applyParagraphStyle()   // 行高取决于字体，因此将重新计算。
        applySyntaxHighlight()   // bold/italic 的字体也将以新的尺寸重新制作。
        lineNumberRuler?.updateThickness()   // 行号也使用相同的字体绘制，因此宽度会发生变化。
        lineNumberRuler?.needsDisplay = true
    }

    func applyDisplaySettings() {
        textView.cursorShape = AppSettings.cursorShape
        textView.highlightCurrentLine = AppSettings.highlightCurrentLine
        textView.showInvisibles = AppSettings.showInvisibles
        applyParagraphStyle()   // 制表符宽度和行间距
        applyColors()           // 颜色方案（主题）
        applySyntaxHighlight()   // 强调色也取决于主题，所以要重新粉刷。
        scrollView.rulersVisible = AppSettings.showLineNumbers
        lineNumberRuler?.updateThickness()
        lineNumberRuler?.needsDisplay = true
        textView.needsDisplay = true
    }

    // MARK: - 構造化表示

    func setStructuredMode(_ mode: StructuredMode?) {
        applyStructuredMode(mode)
        updateColumnGuideVisibility()   // 重塑后不要在显示屏上留下参考线（有很多入口点，所以我们将在这里全部完成）
        updateTopLayout()               // 在构建结构时将列名替换为带状结构。
        syncStructuredHeader()
    }

    private func applyStructuredMode(_ mode: StructuredMode?) {
        guard csvGridView?.flushPendingEdit() != false else { return }
        csvGridView?.removeFromSuperview()
        csvGridView = nil
        scrollView.isHidden = false
        if jsonQueryActive { closeJsonQuery() }   // 如果在查询过程中切换到结构化查询，请先将其折叠。
        guard let mode else {
            // OFF: 文本可以恢复、编辑并换行至其原始状态。
            cancelLineEditing()
            let targetLine = currentLineIndex().lineIndex(at: textView.selectedRange().location) + 1
            mismatchedLineNumbers = []
            lastMismatchJumpIndex = -1
            onColumnMismatchChange?(0)
            let original = preStructuredText ?? textView.string
            structuredFormatter = nil
            jsonPrettyActive = false
            preStructuredText = nil
            textView.isEditable = true
            setWrapMode(wrapped: true)
            textView.delegate = nil
            textView.string = original
            // `NSTextStorage.replaceCharacters(in:with:)` 是要替换的范围的第一个字符的属性。
            // 将传递给新字符串。结构化显示 CSV/TSV 的第一行以粗体显示。
            // 如果您替换之前粗体的第一个字符，则您替换的整个文本将再次变为粗体。
            // （已在实际设备上测试 - 2026-09-25）。整个过程与 `applyCurrentFontSize()` 完全相同。
            // 与字体  对齐。
            textView.font = EditorFont.current()
            textView.delegate = self
            applyParagraphStyle(); applyColors()
            invalidateLineIndex()
            goToLine(targetLine)
            applySyntaxHighlight()
            emitState()
            return
        }
        // ON: 由当前文本格式化（只读）。
        // 如果正在进行筛选，请先折叠筛选框。对于小文件，**正文**将被转换为格式化文本。
        // 由于它将被替换，因此无法在缩小后的文本上应用格式。如果您应用了格式，稍后……
        // 运行过滤器移除（`hideSearch` → `setFilterMode(false)`）原文全文为正文
        // 被覆盖，只有格式化的结果消失了，只留下列名栏和行号（2026-08-21）。
        if preFilterText != nil { setFilterMode(false) }
        let source = preStructuredText ?? textView.string
        // JSON 格式为单文档缩进（非列式）。如果格式无效（例如 JSON），则会直接切换到 beep 而不进行任何切换。
        if mode == .json {
            guard let pretty = JsonFormatter.pretty(source) else { NSSound.beep(); return }
            preStructuredText = source
            structuredFormatter = nil
            jsonPrettyActive = true
            textView.isEditable = false
            setWrapMode(wrapped: false)
            textView.delegate = nil
            textView.textStorage?.setAttributedString(readonlyAttributed(pretty))
            textView.delegate = self
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            invalidateLineIndex()
            return
        }
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // 尾随换行符的剩余部分
        // 由于只对开头进行采样会遗漏后半部分数字较长的列，因此对两端都进行了采样。
        // （与 `structuredSampleLines` 在大文件方面采用相同的策略）。
        let sample = lines.count > 2000
            ? Array(lines.prefix(1000)) + Array(lines.suffix(1000))
            : lines
        // 固定长度数据无法从其内容推断出来。列指南（即人工划分的列）本身就是定义。
        var fields: [ClosedRange<Int>] = []
        if mode == .fixedWidth {
            guard textView.columnGuides.hasFieldBoundaries else { NSSound.beep(); return }
            fields = textView.columnGuides.fieldRanges(fitting: sample)
            guard !fields.isEmpty else { NSSound.beep(); return }
        }
        preStructuredText = source
        jsonPrettyActive = false
        structuredFormatter = TabularFormatter.build(mode: mode, sampleLines: sample, fields: fields,
                                                     firstRowIsHeader: !(mode == .csv && generatedCSVWithoutHeader))
        textView.isEditable = false
        setWrapMode(wrapped: false)
        if mode == .csv || mode == .tsv {
            do {
                let document = try CSVGridDocument(source: source, mode: mode,
                                                   hasHeader: !(mode == .csv && generatedCSVWithoutHeader))
                let grid = CSVGridView(document: document)
                grid.onChange = { [weak self] updated in self?.applyCSVGridChange(updated) }
                grid.onPendingChange = { [weak self] in
                    self?.setDirty(true)
                    self?.scheduleDraftSave()
                }
                grid.onUndo = { [weak self] in self?.paneUndoManager.undo() }
                grid.onRedo = { [weak self] in self?.paneUndoManager.redo() }
                addSubview(grid)
                NSLayoutConstraint.activate([
                    grid.topAnchor.constraint(equalTo: topAnchor),
                    grid.leadingAnchor.constraint(equalTo: leadingAnchor),
                    grid.trailingAnchor.constraint(equalTo: trailingAnchor),
                    grid.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
                csvGridView = grid
                scrollView.isHidden = true
                structuredHeader.isHidden = true
            } catch {
                renderStructured()
                let alert = NSAlert()
                alert.messageText = L("csv.invalidQuote")
                if let window { alert.beginSheetModal(for: window) } else { NSSound.beep() }
            }
        } else {
            renderStructured()
        }
    }

    private func applyCSVGridChange(_ source: String) {
        let previous = preStructuredText ?? textView.string
        guard source != previous else { return }
        paneUndoManager.registerUndo(withTarget: self) { target in target.restoreCSVGridSource(previous) }
        preStructuredText = source
        setDirty(true)
        scheduleDraftSave()
        emitState()
    }

    private func restoreCSVGridSource(_ source: String) {
        let previous = preStructuredText ?? textView.string
        paneUndoManager.registerUndo(withTarget: self) { target in target.restoreCSVGridSource(previous) }
        preStructuredText = source
        csvGridView?.updateSource(source)
        setDirty(true)
        scheduleDraftSave()
        emitState()
    }

    /// 使用当前格式化工具重新格式化文本。**仅在更改列宽时调用此函数。**
    /// (当通过 `setStructuredMode` 处理时，列宽会根据样本重新计算，并且更改后的宽度会消失)。
    private func renderStructured() {
        guard let fmt = structuredFormatter, let source = preStructuredText else { return }
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let formatted = formattedText(lines: lines, formatter: fmt)
        let selection = textView.selectedRange()
        textView.delegate = nil
        textView.textStorage?.setAttributedString(formatted)
        textView.delegate = self
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        invalidateLineIndex()
        syncStructuredHeader()
    }

    /// 通过拖动更改列宽（从标题栏调用）。
    private func resizeStructuredColumn(_ index: Int, to width: Int) {
        guard let fmt = structuredFormatter else { return }
        structuredFormatter = fmt.withColumnWidth(index, width)
        renderStructured()
    }

    /// 通过拖动重新排列列（从标题栏调用。B19）。
    private func reorderStructuredColumn(_ from: Int, _ to: Int) {
        guard let fmt = structuredFormatter else { return }
        structuredFormatter = fmt.movingColumn(from, to: to)
        renderStructured()
    }

    /// 应用结构化视图的列布局。除非启用结构化视图，否则将忽略。
    func applyStructuredLayout(order: [String], widths: [String: Int]) {
        guard let fmt = structuredFormatter else { return }
        structuredFormatter = fmt.applyingLayout(order: order, widths: widths)
        renderStructured()
    }

    /// 预格式化只读文本（等宽字体；CSV/TSV 表示第一行粗体，列数不匹配的行以浅红色突出显示）。
    private func formattedText(lines: [String], formatter: TabularFormatter) -> NSAttributedString {
        let font = EditorFont.current()
        let theme = EditorTheme.current()
        let style = EditorStyle.paragraphStyle(for: font)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.foreground, .paragraphStyle: style]
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let out = NSMutableAttributedString()

        var mismatches: [Int] = []
        let sep: Character? = (formatter.mode == .csv) ? "," : (formatter.mode == .tsv ? "\t" : nil)
        let isDelimited = sep != nil
        var expectedCount = 0
        if isDelimited, let first = lines.first {
            expectedCount = TabularFormatter.splitDelimited(first, sep: sep!, csvQuotes: formatter.mode == .csv).count
        }

        for (i, line) in lines.enumerated() {
            var attrs = base
            // 只有 CSV/TSV 在第一行有列名（NDJSON 是键投影，固定长度数据没有标题）。
            if (formatter.mode == .csv && !generatedCSVWithoutHeader || formatter.mode == .tsv), i == 0 {
                attrs[.font] = bold
            } else if isDelimited, expectedCount > 0, Self.structuredInlineEditingAvailable {
                let colCount = TabularFormatter.splitDelimited(line, sep: sep!, csvQuotes: formatter.mode == .csv).count
                if colCount != expectedCount {
                    attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.12)
                    mismatches.append(i + 1) // 1 起始行号
                }
            }
            out.append(NSAttributedString(string: formatter.format(line), attributes: attrs))
            out.append(NSAttributedString(string: "\n", attributes: base))
        }

        if Self.structuredInlineEditingAvailable {
            self.mismatchedLineNumbers = mismatches
            self.lastMismatchJumpIndex = -1
            self.onColumnMismatchChange?(mismatches.count)
        } else {
            self.mismatchedLineNumbers = []
            self.lastMismatchJumpIndex = -1
            self.onColumnMismatchChange?(0)
        }

        return out
    }

    /// 只读格式化文本（等宽字体，主题配色方案）。用于渲染格式化文本（JSON）。
    private func readonlyAttributed(_ s: String) -> NSAttributedString {
        let font = EditorFont.current()
        let theme = EditorTheme.current()
        let style = EditorStyle.paragraphStyle(for: font)
        return NSAttributedString(string: s,
                                  attributes: [.font: font, .foregroundColor: theme.foreground, .paragraphStyle: style])
    }

    // MARK: - JSON 原地查询（结果为易失性数据，只读且不保存）

    var supportsJsonQuery: Bool { true }
    var jsonQueryIsActive: Bool { jsonQueryActive }

    /// 打开和关闭查询栏。要打开查询栏，请求体必须是有效的 JSON（否则必须是 beep）。
    func toggleJsonQuery() {
        applyToggleJsonQuery()
        updateColumnGuideVisibility()
    }

    private func applyToggleJsonQuery() {
        if jsonQueryActive { closeJsonQuery(); return }
        let source = preStructuredText ?? textView.string
        guard JsonFormatter.pretty(source) != nil else { NSSound.beep(); return }   // 仅有效 JSON
        // 如果出现结构化/格式化文本，请将其折叠并确认来源。
        preStructuredText = source
        structuredFormatter = nil
        jsonPrettyActive = false
        jsonQueryActive = true
        textView.isEditable = false
        setWrapMode(wrapped: false)
        showQueryBar(true)
        jsonQueryBar.clear()
        runJsonQuery("")                 // 空 = 格式化整个显示
        jsonQueryBar.focusField()
    }

    /// 计算表达式并将结果替换文本。空表达式将完全格式化。错误信息在进度条上以红色显示。
    private func runJsonQuery(_ expr: String) {
        guard jsonQueryActive, let source = preStructuredText else { return }
        do {
            let text = try JsonQuery.run(expr, onJSONText: source)
            textView.delegate = nil
            textView.textStorage?.setAttributedString(readonlyAttributed(text))
            textView.delegate = self
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            invalidateLineIndex()
            jsonQueryBar.setStatus(error: nil)
        } catch {
            jsonQueryBar.setStatus(error: L("jsonquery.error"))
        }
    }

    /// 终止查询并返回到原始可编辑文本正文（结果将不会保存）。
    private func closeJsonQuery() {
        guard jsonQueryActive else { return }
        jsonQueryActive = false
        showQueryBar(false)
        jsonQueryBar.clear()
        guard let original = preStructuredText else { textView.isEditable = true; return }
        preStructuredText = nil
        textView.isEditable = true
        setWrapMode(wrapped: true)
        textView.delegate = nil
        textView.string = original
        textView.delegate = self
        applyParagraphStyle(); applyColors()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        invalidateLineIndex()
        emitState()
    }

    private func showQueryBar(_ show: Bool) {
        jsonQueryBar.isHidden = !show
        updateTopLayout()
    }

    /// 在自动换行文本 (true) 和水平滚动 (false - 无列换行) 之间切换。
    private func setWrapMode(wrapped: Bool) {
        guard let container = textView.textContainer else { return }
        if wrapped {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            let big = CGFloat.greatestFiniteMagnitude
            container.size = NSSize(width: big, height: big)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: big, height: big)
            scrollView.hasHorizontalScroller = true
        }
    }

    /// 加载单独的文件或创建新文件时，禁用结构化视图并返回到普通编辑状态。
    private func resetStructuredPresentation() {
        generatedCSVWithoutHeader = false
        if jsonQueryActive {
            jsonQueryActive = false
            showQueryBar(false)
            jsonQueryBar.clear()
        }
        guard structuredFormatter != nil || jsonPrettyActive || preStructuredText != nil else { return }
        structuredFormatter = nil
        jsonPrettyActive = false
        preStructuredText = nil
        textView.isEditable = true
        setWrapMode(wrapped: true)
    }

    /// 应用主题中主文本区域的颜色方案（前景、背景、选区）。当前行高亮显示为
    /// `EditorTextView` 在渲染过程中直接读取 `EditorTheme`。
    private func applyColors() {
        let theme = EditorTheme.current()
        let translucent = !EditorTheme.isOpaqueBackground
        textView.textColor = theme.foreground
        textView.backgroundColor = EditorTheme.withBackgroundOpacity(theme.background)
        textView.insertionPointColor = theme.foreground
        // 当背景透明时（窗口 = 桌面），背景可见，因此周围的滚动视图不会绘制背景。
        textView.drawsBackground = true
        scrollView.drawsBackground = !translucent
        scrollView.backgroundColor = EditorTheme.withBackgroundOpacity(theme.background)
        textView.enclosingScrollView?.contentView.drawsBackground = !translucent
        textView.selectedTextAttributes[.backgroundColor] = theme.selection
    }

    /// 将段落样式（制表符宽度和行距）typingAttributes 应用于整个文本。
    private func applyParagraphStyle() {
        let style = EditorStyle.paragraphStyle(for: textView.font ?? EditorFont.current())
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: style,
                                 range: NSRange(location: 0, length: storage.length))
        }
    }

    // MARK: - 语法高亮

    /// 高亮与可编辑文档共用 8 MiB 上限；只有当前可见区域会写入 AppKit 属性。
    private static let syntaxHighlightSizeLimit = sizeThreshold
    private static let syntaxQueue = DispatchQueue(label: "SiftEditor.syntax", qos: .utility)

    private func styledAttributes(baseFont: NSFont, trait: NSFontDescriptor.SymbolicTraits,
                                  color: NSColor) -> [NSAttributedString.Key: Any] {
        var traits = baseFont.fontDescriptor.symbolicTraits
        traits.insert(trait)
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        if let styled = NSFont(descriptor: descriptor, size: baseFont.pointSize),
           styled.fontDescriptor.symbolicTraits.contains(trait) {
            return [.font: styled, .foregroundColor: color]
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: color]
        if trait == .bold {
            attrs[.strokeWidth] = -3.0
            attrs[.strokeColor] = color
        } else if trait == .italic {
            attrs[.obliqueness] = 0.2
        }
        return attrs
    }

    private func clearSyntaxHighlight() {
        guard let range = paintedSyntaxRange, let layout = textView.layoutManager else { return }
        paintedSyntaxRange = nil
        let length = textView.textStorage?.length ?? 0
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clipped.length > 0 else { return }
        for key: NSAttributedString.Key in [.foregroundColor, .font, .underlineStyle, .strikethroughStyle,
                                            .strokeWidth, .strokeColor, .obliqueness] {
            layout.removeTemporaryAttribute(key, forCharacterRange: clipped)
        }
    }

    private func applySyntaxHighlight() {
        highlightGeneration &+= 1
        highlightTask?.cancel()
        let generation = highlightGeneration
        let syntax = currentSyntax
        if syntax != highlightedSyntax {
            clearSyntaxHighlight()
            highlightedSyntax = nil
        }
        // NSTextStorage.length is cheap; avoid copying an entire multi-megabyte buffer on every keystroke.
        guard syntax != .text, canEdit,
              (textView.textStorage?.length ?? 0) <= Self.syntaxHighlightSizeLimit else {
            clearSyntaxHighlight()
            highlightSpans = nil
            highlightedSyntax = nil
            return
        }
        let content = textView.string
        guard content.utf8.count <= Self.syntaxHighlightSizeLimit else {
            clearSyntaxHighlight()
            highlightSpans = nil
            highlightedSyntax = nil
            return
        }
        highlightedSyntax = syntax
        highlightSpans = nil
        // Tiny documents can be colored immediately. Larger ones are debounced and scanned off the UI thread.
        if content.utf8.count <= 64 * 1024 {
            paintSyntax(SwiftSyntaxEngine.spans(text: content, syntax: syntax), generation: generation)
        } else {
            let task = DispatchWorkItem { [weak self] in
                let spans = SwiftSyntaxEngine.spans(text: content, syntax: syntax)
                DispatchQueue.main.async { [weak self] in
                    self?.paintSyntax(spans, generation: generation)
                }
            }
            highlightTask = task
            Self.syntaxQueue.asyncAfter(deadline: .now() + 0.12, execute: task)
        }
    }

    private func paintSyntax(_ spans: [SwiftSyntaxEngine.Span], generation: Int) {
        guard generation == highlightGeneration else { return }
        highlightSpans = spans
        repaintVisibleSyntax(force: true)
    }

    private func repaintVisibleSyntax(force: Bool = false) {
        guard let spans = highlightSpans, let layout = textView.layoutManager else { return }
        let length = textView.textStorage?.length ?? 0
        let visible: NSRange = length <= 64 * 1024
            ? NSRange(location: 0, length: length)
            : visibleCharacterRange()
        guard visible.length > 0 else { return }
        if !force, paintedSyntaxRange == visible { return }
        clearSyntaxHighlight()
        paintedSyntaxRange = visible
        let font = textView.font ?? EditorFont.current()
        let theme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? Theme.xcodeDark : Theme.xcodeLight
        for span in SwiftSyntaxEngine.spans(spans, intersecting: visible) {
            let clipped = NSIntersectionRange(span.range, visible)
            guard clipped.length > 0, NSMaxRange(clipped) <= length else { continue }
            let scope = span.scope
            guard scope.id != 0 else { continue }
            let style = theme.style(for: scope)
            let color = NSColor(calibratedRed: CGFloat(style.foreground.components.red),
                                green: CGFloat(style.foreground.components.green),
                                blue: CGFloat(style.foreground.components.blue), alpha: 1)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if scope.isWithin(.heading) || scope.isWithin(.bold) || style.bold {
                attrs.merge(styledAttributes(baseFont: font, trait: .bold, color: color)) { _, new in new }
            } else if scope.isWithin(.italic) || style.italic {
                attrs.merge(styledAttributes(baseFont: font, trait: .italic, color: color)) { _, new in new }
            }
            if scope.isWithin(.strikethrough) || style.strikethrough {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            layout.addTemporaryAttributes(attrs, forCharacterRange: clipped)
        }
    }

    private func emitState() {
        let state = ViewerState(
            encodingName: encoding.displayName,
            lineCount: lineCount(of: logicalText),
            lineCountIsExact: true,
            // 在清洁模式下，读取时会显示实际磁盘大小（准确且经济）。编辑过程中，会实时计算已保存的字节数。
            fileSize: isDirty ? liveByteSize : byteSize,
            indexProgress: 1.0,
            caret: caretPosition,
            charCount: (logicalText.count, selectedCharCount)
        )
        onStateChange?(state)
        syncColumnRuler()   // 插入数字和选择带如下。
    }

    /// 所选范围内的字符数（以字形为单位）。如果未进行任何选择，则为 0。
    private var selectedCharCount: Int {
        let r = textView.selectedRange()
        guard r.length > 0 else { return 0 }
        return (textView.string as NSString).substring(with: r).count
    }

    /// 保存当前缓冲区时的字节数（包括 EOL 规范化 + 保存编码）。
    /// 当无法编码时，使用 UTF-8 将其简化为近似值。
    private var liveByteSize: Int {
        let normalized = lineEnding.normalize(logicalText)
        let n = normalized.lengthOfBytes(using: encoding.stringEncoding)
        return (n > 0 || normalized.isEmpty) ? n : normalized.utf8.count
    }

    /// 行数（如果行尾没有换行符，则该行也算作一行）。空字符串表示 0 行。
    private func lineCount(of s: String) -> Int {
        if s.isEmpty { return 0 }
        var count = 0
        for ch in s where ch == "\n" { count += 1 }
        return s.hasSuffix("\n") ? count : count + 1
    }
}

#if DEBUG
extension EditableViewer {
    var _testText: String { textView.string }
    var _testEncoding: DetectedEncoding { encoding }
    var _testLineEnding: LineEnding { lineEnding }
    func _testSetText(_ s: String) { textView.string = s; invalidateLineIndex(); setDirty(true); applySyntaxHighlight() }
    func _testSelect(_ range: NSRange) { textView.setSelectedRange(range) }
    var _testSelection: NSRange { textView.selectedRange() }
    /// 是否自动换行？（列标尺会截断换行，因此使用此功能进行检查。）
    var _testWrapsText: Bool { textView.textContainer?.widthTracksTextView ?? false }
    var _testColumnGuides: [Int] { textView.columnGuides.columns }
    /// 标尺认为“第一个数字在这里” x（恢复窗格坐标和滚动量）。
    var _testRulerColumnOneX: CGFloat { syncColumnRuler(); return columnRuler.contentInset }
    /// 文本的第一个字符实际上是绘制在 x 坐标系中（在窗格坐标系中也是如此）。这两个坐标必须匹配。
    var _testFirstGlyphX: CGFloat? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              (textView.string as NSString).length > 0 else { return nil }
        lm.ensureLayout(for: tc)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: tc)
        let x = rect.minX + textView.textContainerOrigin.x
        return textView.convert(NSPoint(x: x, y: 0), to: columnRuler).x
            + scrollView.contentView.bounds.origin.x
    }
    /// 这相当于点击标尺（已在 `ColumnGuides.nearest` 端测试过点击检测）。
    func _testToggleColumnGuide(_ column: Int) { toggleColumnGuide(column) }
    @discardableResult func _testFieldTab(backwards: Bool = false) -> Bool { moveCaretToField(backwards: backwards) }
    var _testRulerHint: String? { alignHint() }
    @discardableResult func _testMoveColumnGuide(_ from: Int, to: Int) -> Bool { moveColumnGuide(from, to: to) }
    var _testColumnGuidesHidden: Bool { textView.columnGuidesHidden }
    var _testMatchCount: Int { matches.count }
    var _testSelectedMatchRanges: [NSRange] { textView._testCarets }
    var _testMatchesCapped: Bool { matchesCapped }
    static var _testMatchCap: Int { matchCap }
    var _testCurrentMatch: Int { currentMatch }
    var _testSearchInvalid: Bool { searchInvalid }
    /// 撤销一次。自动组 (groupsByEvent) 在事件循环完成一个周期后关闭。
    /// 在测试中，循环先运行，然后返回。
    func _testUndo() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        textView.undoManager?.undo()
    }
    @discardableResult func _testWrite(to url: URL) -> Bool { write(to: url) }
    var _testJsonQueryActive: Bool { jsonQueryActive }
    var _testIsMarkdownFile: Bool { currentSyntax == .markdown }
    var _testSyntax: EditorSyntax { currentSyntax }
    var _testSyntaxTokenCount: Int? { highlightSpans?.count }
    var _testPaintedSyntaxRange: NSRange? { paintedSyntaxRange }
    var _testCodeLanguage: CodeSyntax.Language? {
        guard let ext = fileURL?.pathExtension.lowercased() else { return nil }
        return CodeSyntax.Language.detect(extension: ext)
    }
    func _testMarkdownColor(at location: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: location,
                                                    effectiveRange: nil) as? NSColor
    }
    func _testMarkdownFontTraits(at location: Int) -> NSFontDescriptor.SymbolicTraits {
        guard let font = textView.layoutManager?.temporaryAttribute(.font, atCharacterIndex: location,
                                                                     effectiveRange: nil) as? NSFont else { return [] }
        return font.fontDescriptor.symbolicTraits
    }
    /// textStorage 上的**真实**字体（非 temporary）。结构化显示粗体（首行）
    /// 用于检查返回原始文本后是否还有任何数据残留。
    func _testStoredFontTraits(at location: Int) -> NSFontDescriptor.SymbolicTraits {
        guard let font = textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        else { return [] }
        return font.fontDescriptor.symbolicTraits
    }
    func _testHasStrikethrough(at location: Int) -> Bool {
        textView.layoutManager?.temporaryAttribute(.strikethroughStyle, atCharacterIndex: location,
                                                    effectiveRange: nil) != nil
    }
    /// 对于缺少真正的 Bold/Italic 的字体，合成（负数 strokeWidth）是否有效？
    func _testHasSyntheticBoldStroke(at location: Int) -> Bool {
        textView.layoutManager?.temporaryAttribute(.strokeWidth, atCharacterIndex: location,
                                                    effectiveRange: nil) != nil
    }
    func _testRefreshMarkdownHighlight() { applySyntaxHighlight() }
    /// 与在查询栏中输入表达式时相同的路径（仅运行评估，而不依赖于栏中的 UI）。
    func _testRunJsonQuery(_ expr: String) { runJsonQuery(expr) }
}
#endif
