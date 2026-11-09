import AppKit

/// 在小文件编辑窗格左侧显示行号的装订线 (`NSTextView`)。
///
/// 大文件视图由 `DocumentView` 自行绘制可见行，因此也自行绘制行号栏；
/// 较小的文件位于 AppKit 布局上，因此它将被放置在 `NSRulerView` 上。
/// 外观（背景、分隔线、文本颜色、字体）应与 `DocumentView` 的间距相匹配。
final class LineNumberRulerView: NSRulerView {
    /// 逐行索引的来源。如果文本发生更改，它将返回由 `EditableViewer` 重建的版本。
    var lineIndexProvider: (() -> LineStartIndex)?
    /// 带有书签的行（从0开始计数）。标记位于数字的左侧。
    var bookmarkedLines: Set<Int> = []
    private let bookmarkColor = NSColor.systemOrange
    /// 边栏点击。参数是显示行（从 0 开始计数，与 `bookmarkedLines` 计数相同）。
    var onLineClick: ((Int, Int) -> Void)?   // (表示行, clickCount)

    /// 将显示行（从 0 开始）复制到实际图纸编号（从 1 开始）。
    /// 当仅显示匹配的行（筛选）时，文本会变得不连续，因此使用此功能来显示**原始行号**。
    /// 如果未设置，则按原样传递 = 显示顺序的序列号。大文件侧的装订线也会输出原始行号。
    var displayLineNumber: ((Int) -> Int)?
    /// 用于确定间距宽度的最大行号。由于筛选期间数字位数将大于显示的行数，因此该值必须从外部源传递。
    var maxLineNumberOverride: Int?

    private let rightPadding: CGFloat = 8
    private let leftPadding: CGFloat = 6

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 根据行数和字体确定装订线宽度（与 `DocumentView` 概念相同）。
    func updateThickness() {
        let font = EditorFont.current()
        let count = maxLineNumberOverride ?? lineIndexProvider?().lineCount ?? 1
        let digits = max(3, String(count).count)
        let width = ("0" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(width * CGFloat(digits)) + leftPadding + rightPadding
        if abs(thickness - ruleThickness) > 0.5 { ruleThickness = thickness }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onLineClick, let textView = clientView as? NSTextView else {
            super.mouseDown(with: event)
            return
        }
        let p = textView.convert(event.locationInWindow, from: nil)
        let index = lineIndexProvider?() ?? LineStartIndex("")
        let char = min(textView.characterIndexForInsertion(at: p), (textView.string as NSString).length)
        onLineClick(index.lineIndex(at: char), event.clickCount)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let lm = textView.layoutManager, let tc = textView.textContainer else { return }

        // 背景和右边缘分隔线（与正文侧的装订线颜色方案相同）。
        let theme = EditorTheme.current()
        EditorTheme.withBackgroundOpacity(theme.chromeBackground).setFill()
        bounds.fill()
        theme.separator.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        divider.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        divider.stroke()

        let font = EditorFont.current()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.chromeSecondaryText]
        let index = lineIndexProvider?() ?? LineStartIndex("")
        let text = textView.string as NSString

        // ：数字仅显示在可见范围内的逻辑行（即滚动位置）。
        let visible = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let lastVisibleChar = NSMaxRange(charRange)

        // 移动到标尺坐标的偏移量（滚动量 + 文本容器的边距）。
        let originY = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y

        var line = index.lineIndex(at: charRange.location)
        var charIndex = index.start(ofLine: line)
        while charIndex <= text.length {
            if charIndex > lastVisibleChar { break }
            let y: CGFloat
            if text.length == 0 || charIndex == text.length {
                // 如果结尾是换行符，则为其后面的空白行分配数字（extra line fragment）。
                let extra = lm.extraLineFragmentRect
                if extra.isEmpty { break }
                y = originY + extra.minY
            } else {
                let glyph = lm.glyphIndexForCharacter(at: charIndex)
                let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                // 如果增加行距，文本的基线会更靠近行底。数字也应该与文本的基线对齐。
                y = originY + frag.minY + lm.location(forGlyphAt: glyph).y - font.ascender
            }
            // 书签使用绝对行号存储。筛选时，请从显示的行复制到原始行号以检索书签。
            if bookmarkedLines.contains((displayLineNumber?(line) ?? (line + 1)) - 1) {
                bookmarkColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: y + (font.pointSize - 6) / 2,
                                            width: 6, height: 6)).fill()
            }
            let number = displayLineNumber?(line) ?? (line + 1)
            let label = NSAttributedString(string: "\(number)", attributes: attrs)
            let size = label.size()
            label.draw(at: NSPoint(x: max(2, ruleThickness - rightPadding - size.width), y: y))

            line += 1
            if charIndex == text.length { break }
            charIndex = NSMaxRange(text.lineRange(for: NSRange(location: charIndex, length: 0)))
        }
    }
}
