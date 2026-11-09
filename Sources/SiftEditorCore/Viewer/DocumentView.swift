import AppKit
import CoreText

/// 文本输入（光标移动和修改）的委托目标。由 `PieceTableViewer` 实现。
///
/// `DocumentView` 作为第一响应者接收到关键输入，而 `interpretKeyEvents`
/// `NSTextInputClient` 的数据被分解成各个方法，然后转发到这里。
/// 移动系统 (`doCommand`) = B2a，已确认的文本插入 (`insertText`) = B2b，
/// marked text（IME 変換中）＝B2c。
protocol DocumentTextInputHandler: AnyObject {
    /// 由  / `interpretKeyEvents` 解析的编辑命令（例如，`moveRight:`）。
    func doCommand(_ selector: Selector)
    /// 插入已确认的文本。已确认的文本 IME 也在此处（删除 marked 并插入最终文本）。
    func insertText(_ text: String)

    // --- IME（marked text / 変換中）B2c ---
    /// 正在更新正在转换的字符串。`selectedRange` 是 marked (UTF-16) 中的一个选择。
    func setMarkedText(_ text: String, selectedRange: NSRange, replacementRange: NSRange)
    /// 确认转换（按原样插入当前的 marked）。
    func unmarkText()
    /// 正在转换？
    func hasMarkedText() -> Bool
    /// 要转换的字符串的范围（本地范围 UTF-16，从 0 开始，以 marked 为起始点。如果不进行转换，则为 NSNotFound）。
    func markedRange() -> NSRange
    /// 选择 / 光标范围（转换期间在 marked 范围内，否则为空）。
    func selectedRange() -> NSRange
}

/// 仅显示可见行的固定大小视图。
///
/// 没有状态（topLine 或滚动量）。要显示的行数组为：
/// 从  / `LargeFileViewer` 接收，从上到下绘制，宽度相等，线高固定。
/// 因为它不依赖于巨大的 documentView 高度，所以不受 float 精度限制的影响。
final class DocumentView: NSView {
    var lineHeight: CGFloat = 16
    var gutterWidth: CGFloat = 64
    private let textLeftPadding: CGFloat = 8
    private let gutterRightPadding: CGFloat = 8

    /// 当前显示的第一行的行号（从 0 开始计数）。用于显示行间距编号（连续显示时）。
    var firstLineNumber: Int = 0
    /// 每行的行号（从 0 开始）。在显示非连续行（筛选显示）时设置。如果为 nil，则为 firstLineNumber + i。
    var lineNumbers: [Int]? = nil
    /// 当前搜索匹配项所在的行（在可见列表中的索引）。以横幅突出显示。nil 未突出显示。
    var activeRow: Int? = nil
    /// 带有书签的行（**绝对行号**，从 0 开始）。标记装订线。
    /// 使用绝对数字而不是可见索引的原因是避免每次滚动时都重新排列数据。
    var bookmarkedLines: Set<Int> = []
    private let bookmarkColor = NSColor.systemOrange
    private let activeLineColor = NSColor.systemTeal.withAlphaComponent(0.14)
    /// 每行背景色（diff 的添加/删除/修改区域）。元素排列顺序与 `lines` 相同。如果为空，则不应用颜色。
    /// 由于颜色包含行号（行间距），因此您也可以通过颜色来判断一行在哪一侧。
    var rowBackgrounds: [NSColor?] = []
    /// 未显示行号的行（仅存在于另一侧，且 diff 表示填充为空白的行）。此值为 `lineNumbers`。
    static let noLineNumber = -1
    /// 从上到下绘制行。
    var lines: [NSAttributedString] = [] { didSet { layoutsDirty = true } }

    var textAttributes: [NSAttributedString.Key: Any] = [:]
    private var gutterAttributes: [NSAttributedString.Key: Any] = [:]
    private var invisibleAttributes: [NSAttributedString.Key: Any] = [:]

    // MARK: - 插入符/选择框（仅与 PieceTableViewer 一起使用。如果未设置，则不绘制）

    /// 插入符位置（可见行索引和行字符串中的 UTF-16 偏移量）。
    /// nil = 插入符号超出可见范围/不存在。
    var caret: (row: Int, utf16Index: Int)?
    /// 闪烁显示阶段（false 之间未绘制光标）。
    var caretOn: Bool = true
    /// 选择并高亮显示每个可见的行。`range` 是行字符串中 UTF-16 的范围。
    /// `extendsToLineEnd` 指示选区是否跨越换行符延伸到行尾（将选区延伸到右边缘）。
    struct RowSelection { var range: NSRange; var extendsToLineEnd: Bool }
    var selectionByRow: [Int: RowSelection] = [:]
    private var selectionColor = EditorTheme.current().selection

    /// 用于绘制辅助线的数字（从 1 开始）。如果为空，则不绘制。
    var columnGuides = ColumnGuides() { didSet { if columnGuides != oldValue { needsDisplay = true } } }
    /// 隐藏参考线（结构化显示正在进行中）。**定义是原始文本中的列数**，因此格式化后的显示将是……
    /// 当重叠时，它指向不同的位置。定义本身不会被擦除，只是绘制过程会停止。
    var columnGuidesHidden = false { didSet { if columnGuidesHidden != oldValue { needsDisplay = true } } }
    /// 等宽字体，个位数宽度（`configure(font:)` 已更新）。该值与标尺共享。
    private(set) var columnWidth: CGFloat = 8

    /// 长行的处理。false = 水平滚动而不换行，true = 按内容宽度换行（B6 和 config 是关联的）。
    var wrapEnabled = false { didSet { if wrapEnabled != oldValue { layoutsDirty = true; needsDisplay = true } } }
    /// 不换行时的水平滚动量 (px)。
    var horizontalOffset: CGFloat = 0

    // MARK: - 表示設定（config 連動）

    /// 用浅色带突出显示插入符行（仅当未进行选择时）。
    var highlightCurrentLine = AppSettings.highlightCurrentLine
    /// 插入符号形状。
    var cursorShape: CursorShape = AppSettings.cursorShape
    /// 是否显示行号（间距）？如果为 false，则间距宽度为 0，正文将从左边缘绘制。
    var showLineNumbers = AppSettings.showLineNumbers
    /// 是否应将不可见字符（制表符、换行符、全角空格、尾随空格）显示为符号？
    var showInvisibles = AppSettings.showInvisibles
    /// 可见的线条，但其后没有换行符（即，文档末尾没有换行符的线条）。未绘制换行符。
    var rowWithoutEOL: Int?
    /// 块光标宽度（使用 configure 从 font 计算得出）。
    private var caretWidth: CGFloat = 8
    private var currentLineColor = EditorTheme.current().currentLine
    /// 文本背景颜色（从 configure 中的 theme 更新。用于 draw 和 fill 的背景）。
    private var backgroundColor = EditorTheme.current().background
    /// 沟槽背景和分隔线（由 configure 中的 theme 更新）。
    private var gutterBackground = EditorTheme.current().chromeBackground
    private var gutterSeparator = EditorTheme.current().separator

    /// 每条可见逻辑线的布局（换行、绘制、坐标变换）。使用 lines/wrap/ 宽度/字体更改重建。
    private var rowLayouts: [LineLayout] = []
    private var layoutsDirty = true
    private var layoutWidth: CGFloat = 0

    /// 用于将输入事件转发到 LargeFileViewer 的钩子。
    var onScrollWheel: ((NSEvent) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?
    var onCopy: (() -> Void)?
    /// 将编辑菜单（剪切、粘贴、全选）转发到 PieceTableViewer 的钩子（B2b）。
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSelectAll: (() -> Void)?
    /// 用于将鼠标操作转移到 PieceTableViewer 的钩子（按压/拖动）。
    var onMouseDown: ((NSEvent) -> Void)?
    /// 点击行号栏（行号条）。参数为绝对行号（从 0 开始）。仅当设置时，
    /// 点击装订线会将光标移动到此区域而不是正文（添加/删除书签）。
    var onGutterClick: ((Int, Int) -> Void)?   // (絶対行番号, clickCount)
    var onMouseDragged: ((NSEvent) -> Void)?

    /// 编辑撤销管理器 (B2b)。当 PieceTableViewer 启用编辑功能时注入。
    /// 菜单 ⌘Z / ⌘⇧Z (`undo:` / `redo:`) 通过响应链到达此处。
    weak var editUndoManager: UndoManager?

    /// 文本输入的委托目标。仅当配置后，按键输入才会通过 `interpretKeyEvents` 路由到编辑系统。
    /// nil（只读 LargeFileViewer / 索引正在建设中）是传统的 `onKeyDown`（可滚动）。
    weak var inputHandler: DocumentTextInputHandler?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(font: NSFont) {
        lineHeight = EditorStyle.lineHeight(for: font)
        caretWidth = EditorStyle.caretWidth(for: font)
        columnWidth = EditorStyle.columnWidth(for: font)
        // 调整装订线宽度以匹配字体大小，使行号能够显示（如果隐藏则为 0）。
        gutterWidth = showLineNumbers ? max(64, ceil(font.pointSize * 4.5)) : 0
        // 重新阅读  颜色方案（config 链接）。
        let theme = EditorTheme.current()
        selectionColor = theme.selection
        currentLineColor = theme.currentLine
        backgroundColor = theme.background
        gutterBackground = theme.chromeBackground
        gutterSeparator = theme.separator
        textAttributes = [
            .font: font,
            .foregroundColor: theme.foreground,
            .paragraphStyle: EditorStyle.paragraphStyle(for: font),
        ]
        gutterAttributes = [
            .font: font,
            .foregroundColor: theme.chromeSecondaryText,
        ]
        invisibleAttributes = [
            .font: font,
            .foregroundColor: theme.chromeSecondaryText.withAlphaComponent(0.7),
        ]
        layoutsDirty = true
    }

    /// 在主文本上方叠加一行不可见的字符符号。`drawEOL` 是 false 行（不含尾随换行符）。
    /// diff 的填充行中不显示换行符。
    private func drawInvisibles(layout: LineLayout, origin: NSPoint, drawEOL: Bool) {
        let line = layout.string
        for marker in InvisibleGlyphs.markers(in: line) {
            let p = layout.caretPoint(forCharIndex: marker.utf16Index)
            NSAttributedString(string: marker.glyph, attributes: invisibleAttributes)
                .draw(at: NSPoint(x: origin.x + p.x, y: origin.y + p.y))
        }
        guard drawEOL else { return }
        let p = layout.caretPoint(forCharIndex: (line as NSString).length)
        NSAttributedString(string: InvisibleGlyphs.eol, attributes: invisibleAttributes)
            .draw(at: NSPoint(x: origin.x + p.x, y: origin.y + p.y))
    }

    private var contentX: CGFloat { gutterWidth + textLeftPadding }

    /// 正文的第一个字符将显示在 x（页边距 + 左边距）处。此设置公开，以便数字标尺使用相同的原点。
    var contentOriginX: CGFloat { contentX }

    /// 重建逻辑行布局（如有必要）。文本换行时，在内容宽度处折叠行。
    private func rebuildLayoutsIfNeeded() {
        let width = max(1, bounds.width - contentX - 4)
        if !layoutsDirty && width == layoutWidth && rowLayouts.count == lines.count { return }
        layoutWidth = width
        layoutsDirty = false
        rowLayouts = lines.map { LineLayout($0, maxWidth: width, wrap: wrapEnabled, lineHeight: lineHeight) }
    }

    /// 当背景不透明度 < 1.0 时，它将被绘制为不透明视图（允许其后面的桌面显示出来）。
    override var isOpaque: Bool { EditorTheme.isOpaqueBackground }

    override func draw(_ dirtyRect: NSRect) {
        let clip = dirtyRect.intersection(bounds)
        if !EditorTheme.isOpaqueBackground {
            // 不透明时：去除前一帧的残影，然后覆盖半透明颜色。
            NSColor.clear.set()
            clip.fill(using: .copy)
        }
        EditorTheme.withBackgroundOpacity(backgroundColor).setFill()
        // **请勿直接绘制 dirtyRect。** NSView 默认情况下未被裁剪，因此 dirtyRect
        // 当它超出自身的 bounds（包含整个窗口）时，它会填充相邻的视图。
        // 单独显示时， 没有显示出来，因为整个表面都被填满了，但当它与 diff 并排放置时，左边的那个就消失了。
        clip.fill()

        // 装订线背景（如果您已设置为不显示行号，请省略整个背景。）
        if gutterWidth > 0 {
            let gutterRect = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
            EditorTheme.withBackgroundOpacity(gutterBackground).setFill()
            gutterRect.fill()
            gutterSeparator.setStroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: gutterWidth - 0.5, y: 0))
            divider.line(to: NSPoint(x: gutterWidth - 0.5, y: bounds.height))
            divider.stroke()
        }

        guard !lines.isEmpty else { return }
        rebuildLayoutsIfNeeded()

        let xOff = wrapEnabled ? 0 : horizontalOffset
        let numOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        var y: CGFloat = 0
        for (i, layout) in rowLayouts.enumerated() {
            if y > bounds.height { break }
            let rowH = layout.height

            // diff 行带（整个行间距着色 = 颜色表示“此行不在对方一侧”）
            if i < rowBackgrounds.count, let bg = rowBackgrounds[i] {
                bg.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowH).fill()
            }

            // 拨码行带（仅在未选择时显示，包含包边在内的全高）
            if highlightCurrentLine, caret?.row == i, selectionByRow[i] == nil {
                currentLineColor.setFill()
                NSRect(x: gutterWidth, y: y, width: max(0, bounds.width - gutterWidth), height: rowH).fill()
            }

            // 活动匹配行栏（总高度，包括换行符）
            if i == activeRow {
                activeLineColor.setFill()
                NSRect(x: gutterWidth, y: y, width: max(0, bounds.width - gutterWidth), height: rowH).fill()
            }

            // 行号（右对齐，与第一行子行高度对齐）
            let lineNo = (lineNumbers != nil && i < lineNumbers!.count) ? lineNumbers![i] : firstLineNumber + i
            // 对于  diff，仅存在于另一侧的行将不会显示编号（不存在的行将不会被分配编号）。
            if gutterWidth > 0, lineNo != DocumentView.noLineNumber {
                // 书签标记。将其放置在数字左侧较小的位置——当放置在行内容上方时，它只会覆盖该行。
                // 内容变得难以辨认。如果将编号擦除并替换为标记，则无法确定是哪一行。
                if bookmarkedLines.contains(lineNo) {
                    bookmarkColor.setFill()
                    let r = NSRect(x: 5, y: y + (lineHeight - 6) / 2, width: 6, height: 6)
                    NSBezierPath(ovalIn: r).fill()
                }
                let numStr = NSAttributedString(string: "\(lineNo + 1)", attributes: gutterAttributes)
                let numSize = numStr.size()
                let numX = gutterWidth - gutterRightPadding - numSize.width
                numStr.draw(with: NSRect(x: max(2, numX), y: y, width: numSize.width, height: lineHeight), options: numOpts)
            }

            // 从这里开始（选择文本，光标），向左水平滚动。
            // 将文本裁剪到主文本区域，使文本不与装订线重叠。
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: gutterWidth, y: 0,
                                      width: max(0, bounds.width - gutterWidth),
                                      height: bounds.height)).setClip()
            defer { NSGraphicsContext.restoreGraphicsState() }

            // 选择高亮显示（填充一个包含文本并跨越换行符的矩形）
            if let sel = selectionByRow[i] {
                selectionColor.setFill()
                let origin = NSPoint(x: contentX - xOff, y: y)
                layout.enumerateSelectionRects(sel.range, extendToEnd: sel.extendsToLineEnd,
                                               origin: origin, viewWidth: bounds.width) { NSBezierPath(rect: $0).fill() }
            }

            // 正文（将所有换行部分绘制在一起。对于未换行的部分，减去水平偏移量）
            layout.draw(at: NSPoint(x: contentX - xOff, y: y))

            // 不可见字符（符号叠加在正文之上。它们仅放置在空格处和行尾，因此不会与正文冲突。）
            if showInvisibles {
                drawInvisibles(layout: layout, origin: NSPoint(x: contentX - xOff, y: y),
                               drawEOL: i != rowWithoutEOL && lineNo != DocumentView.noLineNumber)
            }

            // 插入符号（形状与 config 关联）
            if caretOn, let c = caret, c.row == i {
                let p = layout.caretPoint(forCharIndex: c.utf16Index)
                let x = contentX - xOff + p.x
                NSColor.textColor.setFill()
                switch cursorShape {
                case .bar:
                    NSRect(x: x, y: y + p.y, width: 1.5, height: lineHeight).fill()
                case .block:
                    NSColor.textColor.withAlphaComponent(0.4).setFill()
                    NSRect(x: x, y: y + p.y, width: caretWidth, height: lineHeight).fill()
                case .underline:
                    NSRect(x: x, y: y + p.y + lineHeight - 2, width: caretWidth, height: 2).fill()
                }
            }
            y += rowH
        }

        drawColumnGuides(xOffset: xOff)

        if !lines.isEmpty { OpenTiming.firstPaint() }   // 仅在 SIFTEDITOR_TIMING=1 时有效
    }

    /// 线引导线（沿文本整个高度的垂直线）。
    ///
    /// 绘制行带（diff，当前行）**之后**再绘制该行带。如果先将其绘制为背景，则会被行带覆盖。
    /// 因为它是一条细的半透明线条，即使放在文字上面也不会遮挡文字。
    private func drawColumnGuides(xOffset: CGFloat) {
        guard !columnGuides.isEmpty, !columnGuidesHidden, !wrapEnabled else { return }   // 循环期间数字位数不固定。
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: NSRect(x: gutterWidth, y: 0,
                                  width: max(0, bounds.width - gutterWidth),
                                  height: bounds.height)).setClip()
        let theme = EditorTheme.current()

        // 将每隔一个项目涂上浅色（与小文件相同；无需格式化即可使其看起来像一列）。
        // **请填写数据至数字处。** 如果填写到屏幕右边缘，只需画一条线即可。
        // 看起来像是“右半部分被涂上了颜色”，而且看起来不像是一排。
        let widestRow = lines.reduce(0) { max($0, TabularFormatter.displayWidth($1.string)) }
        let lastVisible = min(ColumnRuler.column(atX: bounds.width - contentX + xOffset, columnWidth: columnWidth),
                              widestRow)
        theme.columnGuide(alpha: 0.13).setFill()
        for span in columnGuides.stripes(upTo: lastVisible) {
            let x0 = contentX - xOffset + ColumnRuler.x(ofColumn: span.lowerBound, columnWidth: columnWidth)
            let x1 = contentX - xOffset + ColumnRuler.x(ofColumn: span.upperBound + 1, columnWidth: columnWidth)
            let clipped = NSRect(x: max(gutterWidth, x0), y: 0,
                                 width: max(0, min(bounds.width, x1) - max(gutterWidth, x0)), height: bounds.height)
            clipped.fill()
        }

        theme.columnGuide(alpha: 0.45).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for col in columnGuides.columns {
            let x = floor(contentX - xOffset + ColumnRuler.x(ofColumn: col, columnWidth: columnWidth)) + 0.5
            guard x >= gutterWidth, x <= bounds.width else { continue }
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
        }
        path.stroke()
    }

    /// 返回最接近点 `p`（此视图坐标）的插入位置，表示为（可见行，行内 UTF-16 偏移）。
    func index(at p: NSPoint) -> (row: Int, utf16Index: Int)? {
        guard !lines.isEmpty else { return nil }
        rebuildLayoutsIfNeeded()
        let xOff = wrapEnabled ? 0 : horizontalOffset
        var y: CGFloat = 0
        for (i, layout) in rowLayouts.enumerated() {
            if p.y < y + layout.height || i == rowLayouts.count - 1 {
                let local = NSPoint(x: max(0, p.x - contentX + xOff), y: max(0, p.y - y))
                return (i, layout.charIndex(at: local))
            }
            y += layout.height
        }
        return (rowLayouts.count - 1, 0)
    }

    /// 可见逻辑行 `row` 的总高度（包括换行符）。供 viewer 用于光标滚动计算。
    func rowHeight(_ row: Int) -> CGFloat {
        rebuildLayoutsIfNeeded()
        guard row >= 0, row < rowLayouts.count else { return lineHeight }
        return rowLayouts[row].height
    }

    /// 可见逻辑线 `row` 的绘制宽度（不换行时的最大子线宽度）。用作水平滚动的上限。
    func rowWidth(_ row: Int) -> CGFloat {
        rebuildLayoutsIfNeeded()
        guard row >= 0, row < rowLayouts.count else { return 0 }
        return rowLayouts[row].width
    }

    /// 不换行时可实现的最大水平滚动量（可见行的最大宽度 - 显示宽度）。
    var maxHorizontalOffset: CGFloat {
        guard !wrapEnabled else { return 0 }
        rebuildLayoutsIfNeeded()
        let widest = rowLayouts.map { $0.width }.max() ?? 0
        let visible = max(0, bounds.width - contentX - 4)
        return max(0, widest - visible + 12)
    }

    /// 设置水平滚动量（限制）。更改时重新绘制。
    func setHorizontalOffset(_ x: CGFloat) {
        let clamped = min(max(0, x), maxHorizontalOffset)
        guard clamped != horizontalOffset else { return }
        horizontalOffset = clamped
        needsDisplay = true
    }

    /// 当没有折返时，移动 `horizontalOffset`，使光标呈水平方向。
    func ensureCaretVisibleHorizontally() {
        guard !wrapEnabled, let c = caret else { return }
        rebuildLayoutsIfNeeded()
        guard c.row < rowLayouts.count else { return }
        let x = rowLayouts[c.row].caretPoint(forCharIndex: c.utf16Index).x
        let visibleWidth = max(0, bounds.width - contentX - 4)
        var off = horizontalOffset
        if x - off > visibleWidth - 12 { off = x - visibleWidth + 12 }
        if x - off < 0 { off = x - 12 }
        setHorizontalOffset(off)
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event)
    }

    override func keyDown(with event: NSEvent) {
        if inputHandler != nil {
            interpretKeyEvents([event])
        } else {
            onKeyDown?(event)
        }
    }

    /// 当没有输入处理程序（只读）时，它没有输入上下文，也不会调用 IME。
    override var inputContext: NSTextInputContext? {
        inputHandler == nil ? nil : super.inputContext
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let onGutterClick, gutterWidth > 0 {
            let p = convert(event.locationInWindow, from: nil)
            if p.x < gutterWidth, let (row, _) = index(at: p) {
                let lineNo = (lineNumbers != nil && row < lineNumbers!.count) ? lineNumbers![row] : firstLineNumber + row
                if lineNo != DocumentView.noLineNumber { onGutterClick(lineNo, event.clickCount) }
                return
            }
        }
        onMouseDown?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(event)
    }

    /// 标准复制 (⌘C)。通过 LargeFileViewer 将可见内容复制到剪贴板。
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    /// 剪切 (⌘X) / 粘贴 (⌘V) / 全选 (⌘A)。PieceTableViewer 仅在启用编辑功能 (B2b) 时执行。
    @objc func cut(_ sender: Any?) { onCut?() }
    @objc func paste(_ sender: Any?) { onPaste?() }
    override func selectAll(_ sender: Any?) {
        if let onSelectAll { onSelectAll() } else { super.selectAll(sender) }
    }

    /// 撤销 (⌘Z) / 重做 (⌘⇧Z)。传输到编辑管理器 (B2b)。
    @objc func undo(_ sender: Any?) { editUndoManager?.undo() }
    @objc func redo(_ sender: Any?) { editUndoManager?.redo() }
}

// MARK: - 启用/禁用菜单项

extension DocumentView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return editUndoManager?.canUndo ?? false
        case #selector(redo(_:)): return editUndoManager?.canRedo ?? false
        case #selector(cut(_:)):
            return inputHandler != nil          // 仅在启用编辑功能时可用（在只读查看器中无效）
        case #selector(copy(_:)):
            return true                          // 只读模式也是可以接受的。该钩子会判断是否已做出选择。
        case #selector(selectAll(_:)):
            return onSelectAll != nil && !lines.isEmpty
        case #selector(paste(_:)):
            return inputHandler != nil && NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
        default:
            return true
        }
    }
}

// MARK: - NSTextInputClient

/// 将按键输入分解为编辑命令/确认文本/IME 并将其传输到 `inputHandler`。
/// B2a 仅用于移动（`doCommandBySelector`）。marked 和 text（IME）将通过 B2c 进行扩展。
extension DocumentView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        inputHandler?.insertText(text)
    }

    override func doCommand(by selector: Selector) {
        // 这也抑制了不支持的选择器，避免了 `noResponder` 哔声。
        inputHandler?.doCommand(selector)
    }

    // --- marked text（正在转换为 IME）：B2c。状态和渲染由 PieceTableViewer 持有。---
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        inputHandler?.setMarkedText(text, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    func unmarkText() { inputHandler?.unmarkText() }
    func hasMarkedText() -> Bool { inputHandler?.hasMarkedText() ?? false }
    func markedRange() -> NSRange { inputHandler?.markedRange() ?? NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { inputHandler?.selectedRange() ?? NSRange(location: NSNotFound, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// 转换候选窗口的定位。返回当前光标所在屏幕的矩形区域（转换期间位于 marked 区域内）。
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let c = caret, let win = window else { return .zero }
        rebuildLayoutsIfNeeded()
        let xOff = wrapEnabled ? 0 : horizontalOffset
        var y: CGFloat = 0
        for (i, layout) in rowLayouts.enumerated() {
            if i == c.row {
                let p = layout.caretPoint(forCharIndex: c.utf16Index)
                let inView = NSRect(x: contentX - xOff + p.x, y: y + p.y, width: 1, height: lineHeight)
                return win.convertToScreen(convert(inView, to: nil))
            }
            y += layout.height
        }
        return .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

// MARK: - 1 逻辑线布局（环绕、绘制、坐标变换）

/// `NSLayoutManager` 布局一条逻辑线，包括换行、插入符和命中测试。
/// 提供一个选择矩形。当未选择换行（`wrap=false`）时，容器宽度设置为无限大，以适应单行显示。
private final class LineLayout {
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    let rowCount: Int
    let height: CGFloat
    let width: CGFloat
    /// 行的原始字符串（用于计算不可见字符符号的位置）。
    var string: String { storage.string }

    init(_ attr: NSAttributedString, maxWidth: CGFloat, wrap: Bool, lineHeight: CGFloat) {
        storage = NSTextStorage(attributedString: attr)
        let w = wrap ? maxWidth : CGFloat.greatestFiniteMagnitude
        container = NSTextContainer(size: NSSize(width: w, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        // 计算换行后有多少行。
        var rows = 0
        let glyphs = manager.numberOfGlyphs
        if glyphs == 0 {
            rows = 1
        } else {
            var gi = 0
            while gi < glyphs {
                var lr = NSRange()
                _ = manager.lineFragmentRect(forGlyphAt: gi, effectiveRange: &lr)
                rows += 1
                gi = NSMaxRange(lr)
            }
        }
        rowCount = max(1, rows)
        height = CGFloat(rowCount) * lineHeight
        width = ceil(manager.usedRect(for: container).width)
    }

    func draw(at origin: CGPoint) {
        let gr = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: gr, at: origin)   // 搜索高亮显示等的背景颜色
        manager.drawGlyphs(forGlyphRange: gr, at: origin)
    }

    /// 插入符原点位于字符位置 `ci` (UTF-16)（此布局坐标的左上角原点）。
    func caretPoint(forCharIndex ci: Int) -> CGPoint {
        let len = storage.length
        guard len > 0 else { return .zero }
        let clamped = min(max(0, ci), len)
        if clamped >= len {
            let last = manager.numberOfGlyphs - 1
            guard last >= 0 else { return .zero }
            let lr = manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
            return CGPoint(x: rect.maxX, y: lr.minY)
        }
        let gi = manager.glyphIndexForCharacter(at: clamped)
        let lr = manager.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        let loc = manager.location(forGlyphAt: gi)
        return CGPoint(x: lr.minX + loc.x, y: lr.minY)
    }

    /// 最接近布局坐标 `point`（左上原点）的插入点 (UTF-16)。
    func charIndex(at point: CGPoint) -> Int {
        guard manager.numberOfGlyphs > 0 else { return 0 }
        var frac: CGFloat = 0
        let gi = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &frac)
        var ci = manager.characterIndexForGlyph(at: gi)
        if frac > 0.5 { ci += 1 }
        return min(max(0, ci), storage.length)
    }

    /// UTF-16 枚举选择矩形的范围（跨越换行）。`extendToEnd` 延伸到右边缘。
    func enumerateSelectionRects(_ range: NSRange, extendToEnd: Bool, origin: CGPoint,
                                 viewWidth: CGFloat, _ body: (NSRect) -> Void) {
        let len = storage.length
        let loc = min(max(0, range.location), len)
        let end = min(range.location + range.length, len)
        let charRange = NSRange(location: loc, length: max(0, end - loc))
        if charRange.length == 0 {
            if extendToEnd {   // 仅选择换行符（空行等）→ 行首的细带
                let p = caretPoint(forCharIndex: loc)
                body(NSRect(x: origin.x + p.x, y: origin.y + p.y, width: max(4, viewWidth - (origin.x + p.x)), height: height / CGFloat(rowCount)))
            }
            return
        }
        let glyphRange = manager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rects: [NSRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in
            var r = rect.offsetBy(dx: origin.x, dy: origin.y)
            if extendToEnd { r.size.width = max(r.width, viewWidth - r.minX) }
            rects.append(r)
        }
        for r in rects { body(r) }
    }
}
