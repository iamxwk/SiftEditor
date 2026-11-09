import AppKit

/// 列名称（网格标题）栏，在使用结构化显示时固定在主要文本上方，以及用于调整列宽的句柄。
///
/// 使用与数字标尺 (`ColumnRuler`) 相同的位置和坐标计算方式。两个窗格中均显示相同的视图。
/// 使用它，它们每个人都会告诉你 `contentInset`（第一个数字 x）和 `horizontalOffset`（水平滚动量）。
///
/// 列名不一定与文本的第一行相同（NDJSON 是键，固定长度是列本身）。
/// 由于它不会消失，即使在 5,810,000 行中的第 3,000,000 行，您仍然可以找到“这一列是什么”。
final class StructuredHeaderView: NSView {
    static let height: CGFloat = 20

    /// 等宽字体，1 位宽度。
    var columnWidth: CGFloat = 8 { didSet { if columnWidth != oldValue { needsDisplay = true } } }
    /// 在此视图的坐标中，第一个位置的最左边数字是 x。
    var contentInset: CGFloat = 0 { didSet { if contentInset != oldValue { needsDisplay = true } } }
    /// 主文本中的水平滚动量。
    var horizontalOffset: CGFloat = 0 { didSet { if horizontalOffset != oldValue { needsDisplay = true } } }

    /// 列名以及每列的起始列和宽度（从 `TabularFormatter` 获取）。
    struct Column: Equatable { let name: String; let start: Int; let width: Int }
    var columns: [Column] = [] { didSet { if columns != oldValue { needsDisplay = true } } }

    /// 当列宽完成更改时（列号，新宽度）。**仅在释放时调用**（每次拖动时）
    ///（不要重新排列数百万行）。
    var onResize: ((Int, Int) -> Void)?

    /// 当列排序完成时（原始列号，目标列号）。**仅在释放时调用**
    /// (格式与 resize 相同。每次拖出文本时，请勿重新排列文本)。
    var onReorder: ((Int, Int) -> Void)?

    /// 此格式是否支持排序？（B19: 和 fixedWidth 除外——项目即列位置本身）
    /// 因此，呼叫方检查 `mode` 以进行配置。支持默认值。
    var allowsReorder: Bool = true

    /// 抓取命中检测（数字）。防止像素级细线瞄准。
    private let hitTolerance = 1

    /// 被持有的列和当前目标列（仅用于显示预览行）。
    private var draggingIndex: Int?
    private var draggingColumn: Int?

    /// 排序时获取的源列和当前要插入的目标列（`columns` 和 index）。
    private var reorderSourceIndex: Int?
    private var reorderTargetIndex: Int?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { EditorTheme.isOpaqueBackground }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: - 数字 ↔ x（与尺子的公式相同）

    private func viewX(ofColumn col: Int) -> CGFloat {
        contentInset - horizontalOffset + ColumnRuler.x(ofColumn: col, columnWidth: columnWidth)
    }

    private func column(atViewX x: CGFloat) -> Int {
        ColumnRuler.column(atX: x - contentInset + horizontalOffset, columnWidth: columnWidth)
    }

    /// 带有抓取柄的数字（每列中最右边字符之后的那个数字）。
    private var handleColumns: [Int] { columns.map { $0.start + $0.width } }

    /// x 列的 index 值（用于确定排序的源和目标）。如果该列超出屏幕范围，则使用 nil 值。
    private func columnIndex(atViewX x: CGFloat) -> Int? {
        let col = column(atViewX: x)
        return columns.firstIndex { col >= $0.start && col < $0.start + max($0.width, 1) }
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        let theme = EditorTheme.current()
        if !EditorTheme.isOpaqueBackground {
            NSColor.clear.set()
            dirtyRect.intersection(bounds).fill(using: .copy)
        }
        EditorTheme.withBackgroundOpacity(theme.chromeBackground).setFill()
        dirtyRect.intersection(bounds).fill()

        theme.separator.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        divider.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        divider.stroke()

        // 请勿在屋檐上绘制任何图案。
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: NSRect(x: contentInset, y: 0,
                                  width: max(0, bounds.width - contentInset),
                                  height: bounds.height)).setClip()

        drawNames(theme: theme)
        drawHandles(theme: theme)
        drawReorderFeedback(theme: theme)
    }

    /// 列名。**裁剪至列宽**（如果超出列宽，则无法区分哪个名称属于哪一列）。
    /// 排序时，原始列隐约可见，表明它正在被“提升”。
    private func drawNames(theme: EditorColorTheme) {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        for (i, col) in columns.enumerated() {
            let x = viewX(ofColumn: col.start)
            let w = CGFloat(col.width) * columnWidth
            guard x + w > 0, x < bounds.width else { continue }   // 请勿在屏幕外绘制图形。
            let alpha: CGFloat = (i == reorderSourceIndex) ? 0.35 : 1.0
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: theme.chromeSecondaryText.withAlphaComponent(alpha),
            ]
            let name = TabularFormatter.pad(col.name, to: col.width)
            NSAttributedString(string: name, attributes: attrs)
                .draw(in: NSRect(x: x, y: 3, width: w, height: bounds.height - 5))
        }
    }

    /// 指示排序过程中插入点的垂直线。**样式与 resize 的预览线不同**
    /// 使用  /（粗实线 + 强调色）来区分“移动边框”和“插入整列”。
    private func drawReorderFeedback(theme: EditorColorTheme) {
        guard reorderSourceIndex != nil, let target = reorderTargetIndex,
              columns.indices.contains(target) else { return }
        let col = columns[target]
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        let x = floor(viewX(ofColumn: col.start)) + 0.5
        path.move(to: NSPoint(x: x, y: 0))
        path.line(to: NSPoint(x: x, y: bounds.height))
        path.stroke()
    }

    /// 列边界（抓取手）。拖动时，该位置会出现一条粗线。
    private func drawHandles(theme: EditorColorTheme) {
        theme.separator.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for col in handleColumns {
            let x = floor(viewX(ofColumn: col)) + 0.5
            path.move(to: NSPoint(x: x, y: 2))
            path.line(to: NSPoint(x: x, y: bounds.height - 2))
        }
        path.stroke()

        guard let preview = draggingColumn else { return }
        theme.columnGuide(alpha: 0.9).setStroke()
        let live = NSBezierPath()
        live.lineWidth = 2
        let x = floor(viewX(ofColumn: preview)) + 0.5
        live.move(to: NSPoint(x: x, y: 0))
        live.line(to: NSPoint(x: x, y: bounds.height))
        live.stroke()
    }

    // MARK: - 操作

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.x >= contentInset else { return }
        let col = column(atViewX: p.x)
        // 最接近的抓取结果（允许一位数字）。如果抓取到边界，请使用 resize；否则，请尝试重新排列。
        // （这两个手势是互斥的——边界优先）。
        let hit = handleColumns.enumerated()
            .filter { abs($0.element - col) <= hitTolerance }
            .min { abs($0.element - col) < abs($1.element - col) }
        if let hit {
            draggingIndex = hit.offset
            draggingColumn = hit.element
            needsDisplay = true
            return
        }
        guard allowsReorder, let index = columnIndex(atViewX: p.x) else { return }
        reorderSourceIndex = index
        reorderTargetIndex = index
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if draggingIndex != nil {
            let col = column(atViewX: max(contentInset, p.x))
            guard col != draggingColumn else { return }
            draggingColumn = col          // 只需移动线条，暂时不要重新排列文本。
            needsDisplay = true
            return
        }
        guard reorderSourceIndex != nil else { return }
        guard let target = columnIndex(atViewX: max(contentInset, p.x)), target != reorderTargetIndex else { return }
        reorderTargetIndex = target        // 只需将该行移动到您想要插入的位置即可。暂时不要重新排列正文。
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if draggingIndex != nil {
            defer { draggingIndex = nil; draggingColumn = nil; needsDisplay = true }
            guard let index = draggingIndex, let to = draggingColumn,
                  columns.indices.contains(index) else { return }
            let width = max(TabularFormatter.minColumnWidth,
                            min(to - columns[index].start, TabularFormatter.maxColumnWidth))
            guard width != columns[index].width else { return }
            onResize?(index, width)
            return
        }
        defer { reorderSourceIndex = nil; reorderTargetIndex = nil; needsDisplay = true }
        guard let from = reorderSourceIndex, let to = reorderTargetIndex, from != to else { return }
        onReorder?(from, to)
    }

    override func resetCursorRects() {
        for col in handleColumns {
            let x = viewX(ofColumn: col)
            guard x >= contentInset else { continue }
            addCursorRect(NSRect(x: x - 3, y: 0, width: 6, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }
}
