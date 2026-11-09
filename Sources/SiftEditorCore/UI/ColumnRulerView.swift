import AppKit

extension EditorColorTheme {
    /// 列参考线颜色。**请勿在设置中显示此项；它源自主题。**（请勿将此项添加到配色方案选项卡）。
    /// 文本上标尺标记和线条的叠加改变了文本的粗细，因此透明度由调用者决定。
    func columnGuide(alpha: CGFloat) -> NSColor {
        chromeSecondaryText.withAlphaComponent(alpha)
    }
}

/// 主文本上方显示的梁尺 (A) 和梁导向操作面 (B)。
///
/// 两个窗格都使用**同一个视图类**。小文件将其放在 `NSScrollView` 上方，大文件则
/// 将  / `DocumentView` 放在最上面，每个都将是 `contentInset`（第一个数字为 x）和 `horizontalOffset`。
/// （请告诉我水平滚动的量）。数字 ↔ x 之间的唯一转换方法是使用 `ColumnRuler`。
/// 无论如何放置，刻度的位置始终匹配。
final class ColumnRulerView: NSView {
    static let height: CGFloat = 16

    /// 等宽字体，1 位宽度。
    var columnWidth: CGFloat = 8 { didSet { if columnWidth != oldValue { needsDisplay = true } } }
    /// 在此视图的坐标系中，第一列最左边的数字是 x（页边距宽度 + 文本左边距）。
    var contentInset: CGFloat = 0 { didSet { if contentInset != oldValue { needsDisplay = true } } }
    /// 主文本中的水平滚动量。
    var horizontalOffset: CGFloat = 0 { didSet { if horizontalOffset != oldValue { needsDisplay = true } } }
    /// 已绘制的指南。
    var guides = ColumnGuides() { didSet { if guides != oldValue { needsDisplay = true } } }
    /// 是否可以修改项目定义？**结构化显示期间的 false** -- 在格式化显示中，屏幕上的列数和
    /// 数字的定义不同，因此显示或允许他人获取它是谎言（该刻度可作为显示数字）。
    var guidesEditable = true { didSet { if guidesEditable != oldValue { needsDisplay = true } } }
    /// 插入符号所在的数字（从 1 开始计数）。如果是 nil，则不要高亮显示。
    var currentColumn: Int? { didSet { if currentColumn != oldValue { needsDisplay = true } } }
    /// 光标所在位置的数字范围。**这表明该项已使用 Tab 进行遍历。**
    var currentField: ClosedRange<Int>? { didSet { if currentField != oldValue { needsDisplay = true } } }
    /// 最右侧显示提示文字（“按 ⌥Tab 也能对齐第二行及后续行”）。**这只是文本，不是按钮。**
    /// 按钮和图标不易被注意到，但如果文本出现在这里则可以阅读。
    /// nil 将消失 --**排列完成后请删除**（如果您不删除它们，它们将成为背景的一部分，不会被读取）。
    var hint: String? { didSet { if hint != oldValue { needsDisplay = true } } }
    /// 选定的数字范围（从 1 开始，闭合区间）。如果是 nil，则不显示任何频段。
    var selectedColumns: ClosedRange<Int>? { didSet { if selectedColumns != oldValue { needsDisplay = true } } }

    /// 点击标尺添加/移除参考线。
    var onToggleGuide: ((Int) -> Void)?
    /// 抓住导引器并将其移动（from，to）。如果可以移动，请返回 true（如果目的地已被占用，则返回 false）。
    var onMoveGuide: ((Int, Int) -> Bool)?
    /// 当您完成移动引导线（松开引导线）后，**请勿在拖动过程中拨打电话。**
    /// 如果逐位重新排列所有行，几千行之后就无法跟上了。
    var onGuideDragEnded: (() -> Void)?

    /// 允许放宽数字标签碰撞检测的范围（位数）。防止像素级识别细线。
    private let hitTolerance = 1

    /// 被按住的引导数字（仅在拖动时）。
    private var draggingColumn: Int?
    /// 你是否获取了**预先存在的指南**（否则，它只是用 mouseDown 添加的）。
    private var draggingExisting = false
    /// 被抓取后，它是否移动过哪怕一个数字？（如果没有移动，点击 = 切换）。
    private var didDrag = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { EditorTheme.isOpaqueBackground }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    /// 此视图坐标系中 x 处的数字。
    private func column(atViewX x: CGFloat) -> Int {
        ColumnRuler.column(atX: x - contentInset + horizontalOffset, columnWidth: columnWidth)
    }

    /// 查看数字 `col` 最左侧的坐标 x。
    private func viewX(ofColumn col: Int) -> CGFloat {
        contentInset - horizontalOffset + ColumnRuler.x(ofColumn: col, columnWidth: columnWidth)
    }

    /// 说明文字所占的宽度（将缩放比例提前停止该数值）。
    private func hintTextWidth() -> CGFloat {
        guard let hint, !hint.isEmpty else { return 0 }
        let size = NSAttributedString(string: hint,
                                      attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).size()
        return size.width + 14
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = EditorTheme.current()
        if !EditorTheme.isOpaqueBackground {
            NSColor.clear.set()
            dirtyRect.intersection(bounds).fill(using: .copy)
        }
        EditorTheme.withBackgroundOpacity(theme.chromeBackground).setFill()
        dirtyRect.intersection(bounds).fill()

        // 底部的分割线（与沟槽分割线颜色相同）。
        theme.separator.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        divider.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        divider.stroke()

        // 说明书应在**安装夹子之前**编写。秤的夹子右端有缝隙。
        // 如果你之后再画它，你最终会把它自己切掉（它实际上已经消失了）。
        drawHint(theme: theme)

        // 不要将比例尺绘制在正文开始位置的左侧（装订线上方）。
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let hintWidth = hintTextWidth()
        NSBezierPath(rect: NSRect(x: contentInset, y: 0,
                                  width: max(0, bounds.width - contentInset - hintWidth),
                                  height: bounds.height)).setClip()

        // 选定的数字范围（频段）。请放置在刻度线下方。
        if let sel = selectedColumns {
            let x0 = viewX(ofColumn: sel.lowerBound)
            let x1 = viewX(ofColumn: sel.upperBound + 1)
            theme.selection.setFill()
            NSRect(x: x0, y: 0, width: max(1, x1 - x0), height: bounds.height - 1).fill()
        }

        // 光标所在位置的项目（频段名称 + 数字范围）。将其放在光标所在数字之前。
        if let field = currentField {
            let x0 = viewX(ofColumn: field.lowerBound)
            let x1 = viewX(ofColumn: field.upperBound + 1)
            theme.currentLine.setFill()
            NSRect(x: x0, y: 0, width: max(1, x1 - x0), height: bounds.height - 1).fill()

            // 仅当宽度足够时才显示“9-14”（如果宽度不足，则只需显示带状区域即可）。
            let name = "\(field.lowerBound)-\(field.upperBound)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: theme.chromeSecondaryText,
            ]
            let label = NSAttributedString(string: name, attributes: attrs)
            let size = label.size()
            if size.width + 6 <= x1 - x0 {
                label.draw(at: NSPoint(x: x0 + ((x1 - x0) - size.width) / 2,
                                       y: max(0, (bounds.height - 6 - size.height) / 2)))
            }
        }

        // 插入符号数字（一个数字的阴影）。
        if let cur = currentColumn {
            let x0 = viewX(ofColumn: cur)
            theme.currentLine.setFill()
            NSRect(x: x0, y: 0, width: max(1, columnWidth), height: bounds.height - 1).fill()
        }

        drawTicks(theme: theme)
        drawGuideMarkers(theme: theme)
    }

    private func drawTicks(theme: EditorColorTheme) {
        let width = max(0, bounds.width - contentInset)
        let ticks = ColumnRuler.ticks(offset: horizontalOffset, width: width, columnWidth: columnWidth)
        guard !ticks.isEmpty else { return }

        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: theme.chromeSecondaryText,
        ]
        // 如果数字靠得太近以至于与下一个数字重叠，则不会显示数字，只会显示刻度。
        let majorSpacing = columnWidth * 10
        let showLabels = majorSpacing >= 26

        theme.chromeSecondaryText.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for tick in ticks {
            let x = floor(contentInset - horizontalOffset + tick.x) + 0.5
            let top = tick.isMajor ? bounds.height - 6 : bounds.height - 4
            path.move(to: NSPoint(x: x, y: top))
            path.line(to: NSPoint(x: x, y: bounds.height - 1))
        }
        path.stroke()

        guard showLabels else { return }
        for tick in ticks where tick.isMajor {
            let label = NSAttributedString(string: "\(tick.column)", attributes: labelAttrs)
            let size = label.size()
            let x = contentInset - horizontalOffset + tick.x
            // 将其放置在刻度线的右侧。将第一个数字稍微向右移动，使其不与刻度线重叠。
            label.draw(at: NSPoint(x: x + 2, y: max(0, (bounds.height - 6 - size.height) / 2)))
        }
    }

    /// 最右侧的单个单词。在刻度线之后绘制（它在剪辑之外，因此不会与数字重叠）。
    private func drawHint(theme: EditorColorTheme) {
        guard let hint, !hint.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: theme.chromeSecondaryText,
        ]
        let text = NSAttributedString(string: hint, attributes: attrs)
        let size = text.size()
        let x = bounds.width - size.width - 8
        guard x > contentInset else { return }        // 请勿在狭窄窗口中显示（请勿遮挡标记）。
        text.draw(at: NSPoint(x: x, y: max(0, (bounds.height - size.height) / 2)))
    }

    private func drawGuideMarkers(theme: EditorColorTheme) {
        guard !guides.isEmpty, guidesEditable else { return }
        theme.columnGuide(alpha: 0.85).setFill()
        for col in guides.columns {
            let x = floor(viewX(ofColumn: col))
            // 为了更容易抓握，将标记做得比线条本身更粗。
            NSRect(x: x - 1, y: 1, width: 3, height: bounds.height - 3).fill()
        }
    }

    // MARK: - 操作

    /// 点击放置/删除，拖动移动。
    ///
    /// **请勿允许“删除并替换”操作将数字偏移一位。** 如果您按压现有参考线……
    /// 只有按住它并松开且不移动它，它才会消失。如果在空白区域按下它……
    /// 将一根杆放置到位，**立即继续移动它**（放置和微调可以在一次操作中完成）。
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard guidesEditable, p.x >= contentInset else { return }
        let col = column(atViewX: p.x)
        didDrag = false
        if let hit = guides.nearest(to: col, within: hitTolerance) {
            draggingColumn = hit
            draggingExisting = true
        } else {
            draggingColumn = col
            draggingExisting = false
            onToggleGuide?(col)      // 按下即可放置（如果要移动，请继续拖动）。
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = draggingColumn else { return }
        let p = convert(event.locationInWindow, from: nil)
        let to = column(atViewX: max(contentInset, p.x))
        guard to != from else { return }
        if onMoveGuide?(from, to) == true {
            draggingColumn = to
            didDrag = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggingColumn = nil; draggingExisting = false; didDrag = false }
        if didDrag { onGuideDragEnded?(); return }
        guard let col = draggingColumn, draggingExisting else { return }
        // 如果释放位置与按下的数字不同，则表示中间 drag 事件未收到 = 移动。
        // 如果您在未查看此处的情况下将其删除，则当您快速抓取并移动它时，指南线将消失。
        let p = convert(event.locationInWindow, from: nil)
        let to = column(atViewX: max(contentInset, p.x))
        if to != col, onMoveGuide?(col, to) == true { onGuideDragEnded?(); return }
        onToggleGuide?(col)          // 现有指南已发布但未移动 = 已删除。
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: contentInset, y: 0,
                             width: max(0, bounds.width - contentInset), height: bounds.height),
                      cursor: .crosshair)
    }
}
