import AppKit

/// `NSTextView` 的一个衍生版本，用于编辑小文件。标准功能（IME、撤销、选择）包括
/// 保持不变，但仅替换插入符形状和当前行高亮显示，并与 config 结合使用。
/// 此外，它还包含多光标功能（⌘单击 / ⌥⌘↑↓ / ⌘D）。多光标的实际实现方式是
/// NSTextView 具有固有的 `selectedRanges`（不连续选择），范围计算使用 `MultiCursor` 完成。
final class EditorTextView: NSTextView {
    var cursorShape: CursorShape = AppSettings.cursorShape
    var highlightCurrentLine: Bool = AppSettings.highlightCurrentLine
    /// 是否应将不可见字符（制表符、换行符、全角空格和尾随空格）显示为符号？
    var showInvisibles: Bool = AppSettings.showInvisibles

    private var caretWidth: CGFloat {
        EditorStyle.caretWidth(for: font ?? EditorFont.current())
    }

    // MARK: - 当前行高亮显示

    /// 用于绘制辅助线的数字（从 1 开始）。如果为空，则不绘制辅助线。数字计算与 `ColumnRuler` 共享。
    var columnGuides = ColumnGuides() { didSet { if columnGuides != oldValue { needsDisplay = true } } }
    /// 隐藏参考线（结构化显示正在进行中）。**定义是原始文本中的列数**，因此格式化后的显示将是……
    /// 当重叠时，它指向不同的位置。定义本身不会被删除，只是绘图会停止。
    var columnGuidesHidden = false { didSet { if columnGuidesHidden != oldValue { needsDisplay = true } } }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLineHighlight(in: rect)
        drawColumnGuides(in: rect)
    }

    /// 列引导线。**绘制在正文下方（背景阶段）。** 小文件侧将绘制文本。
    /// 因为我把它留给了  / AppKit，所以以后没办法覆盖它，但也不用担心它会被腰封遮挡住。
    private func drawColumnGuides(in rect: NSRect) {
        guard !columnGuides.isEmpty, !columnGuidesHidden,
              let tc = textContainer, !tc.widthTracksTextView else { return }
        let width = EditorStyle.columnWidth(for: font ?? EditorFont.current())
        let originX = textContainerOrigin.x + tc.lineFragmentPadding
        let theme = EditorTheme.current()

        // 每隔一个项目涂上浅色。**这个例子中，当你画线时，列会立即弹出。**
        // 不会进行任何格式设置（固定长度文本已经包含对齐的数字），因此正文仍可编辑。
        // **请填写数据至数字处。** 如果填写到屏幕右边缘，只需画一条线即可。
        // 看起来像是“右半部分被涂上了颜色”，而且看起来不像一列文字。目前还不清楚正文有多少内容。
        // AppKit 已经测量过了，所以我们将使用它（不要自己重新计算所有行）。
        var lastVisible = ColumnRuler.column(atX: rect.maxX - originX, columnWidth: width)
        if let lm = layoutManager {
            let used = lm.usedRect(for: tc).width - tc.lineFragmentPadding * 2
            lastVisible = min(lastVisible, ColumnRuler.column(atX: used, columnWidth: width))
        }
        theme.columnGuide(alpha: 0.13).setFill()
        for span in columnGuides.stripes(upTo: lastVisible) {
            let x0 = originX + ColumnRuler.x(ofColumn: span.lowerBound, columnWidth: width)
            let x1 = originX + ColumnRuler.x(ofColumn: span.upperBound + 1, columnWidth: width)
            NSRect(x: x0, y: rect.minY, width: max(0, x1 - x0), height: rect.height).fill()
        }

        theme.columnGuide(alpha: 0.45).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for col in columnGuides.columns {
            let x = floor(originX + ColumnRuler.x(ofColumn: col, columnWidth: width)) + 0.5
            guard x >= rect.minX - 1, x <= rect.maxX + 1 else { continue }
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x, y: rect.maxY))
        }
        path.stroke()
    }

    /// 这些符号是在**主文本及其选定高亮部分绘制完成后**叠加的。如果在背景阶段绘制，
    /// 当您选择它时，选择栏会填充，符号会消失（在实际设备上发现）。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showInvisibles { drawInvisibles(in: dirtyRect) }
        drawExtraCarets()
    }

    deinit { caretBlinkTimer?.invalidate() }

    // MARK: - 测试钩子（selectedRanges 不支持多光标，因此需要专用端口）

    func _testSetCarets(_ ranges: [NSRange]) { applyCarets(ranges) }
    var _testCarets: [NSRange] { carets.isEmpty ? [selectedRange()] : carets }

    private func drawCurrentLineHighlight(in rect: NSRect) {
        guard highlightCurrentLine, selectedRange().length == 0,
              let lm = layoutManager, let tc = textContainer else { return }
        let len = (string as NSString).length
        let loc = min(selectedRange().location, len)
        let glyph = lm.glyphIndexForCharacter(at: loc)
        var frag: NSRect
        if lm.numberOfGlyphs == 0 {
            frag = lm.extraLineFragmentRect            // 空白文档
        } else {
            frag = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
        }
        frag.origin.x = 0
        frag.size.width = bounds.width
        frag = frag.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        _ = tc
        EditorTheme.current().currentLine.setFill()
        frag.fill()
    }

    // MARK: - 不可視文字

    /// 扫描可见的线条，并在制表符、全角空格、尾随空格和换行符的位置叠加符号。
    /// **请勿重写正文**（因为替换正文会破坏制表符对齐和选择位置）。
    private func drawInvisibles(in rect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let text = string as NSString
        guard text.length > 0 else { return }

        let font = EditorFont.current()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: EditorTheme.current().chromeSecondaryText.withAlphaComponent(0.7),
        ]
        let origin = textContainerOrigin
        let glyphRange = lm.glyphRange(forBoundingRect: rect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        /// 字符位置 `index` 处的字形矩形（视图坐标）。
        func glyphRect(_ index: Int) -> NSRect {
            let g = lm.glyphIndexForCharacter(at: index)
            return lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                .offsetBy(dx: origin.x, dy: origin.y)
        }

        var lineStart = text.lineRange(for: NSRange(location: charRange.location, length: 0)).location
        while lineStart < min(NSMaxRange(charRange) + 1, text.length) {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            // 正文部分（不包括换行符）（符号计算是在不换行符的单行上进行的）。
            let contentEnd = NSMaxRange(lineRange)
            var end = contentEnd
            while end > lineStart, isNewline(text.character(at: end - 1)) { end -= 1 }

            let line = text.substring(with: NSRange(location: lineStart, length: end - lineStart))
            for marker in InvisibleGlyphs.markers(in: line) {
                let r = glyphRect(lineStart + marker.utf16Index)
                NSAttributedString(string: marker.glyph, attributes: attrs)
                    .draw(at: NSPoint(x: r.minX, y: r.minY))
            }
            // 换行符（仅当此行以换行符结尾时才有效）。
            if end < contentEnd {
                let r = glyphRect(end)
                NSAttributedString(string: InvisibleGlyphs.eol, attributes: attrs)
                    .draw(at: NSPoint(x: r.minX, y: r.minY))
            }
            if NSMaxRange(lineRange) == lineStart { break }   // 未进展 = 结束
            lineStart = NSMaxRange(lineRange)
        }
    }

    private func isNewline(_ unit: unichar) -> Bool { unit == 0x000A || unit == 0x000D }

    /// 当选择（光标）移动时，重新绘制当前行高亮显示。
    /// **源自 AppKit 的选择更改禁用多光标**（使用普通单击或箭头键返回原始状态）。
    /// 当您自己放置多个插入符时，您直接从 `applyCarets` 调用 `super`，因此您不会经过这里。
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !carets.isEmpty { carets = []; needsDisplay = true }
        if highlightCurrentLine { needsDisplay = true }
        syncCaretBlink()
    }

    // MARK: - 多光标

    /// 多个插入符（UTF-16，升序排列）。**当为空时 = 单个插入符的正常状态**。
    ///
    /// NSTextView 的 `selectedRanges` **不能有多个长度为 0 的范围**（它们被合并为一个范围），
    /// 插入符列单独存放于此。长度范围（使用 ⌘D 收集的单词）也会传递给 AppKit。
    /// 绘制选择栏，然后仅使用 `drawExtraCarets` 绘制长度为 0 的光标。
    private var carets: [NSRange] = []

    /// 是否使用了多个光标？
    var hasMultipleCarets: Bool { carets.count > 1 }

    /// 编辑和添加操作的当前范围（多选时为所有光标，单选时为选区本身）。
    private var activeRanges: [NSRange] { hasMultipleCarets ? carets : [selectedRange()] }

    /// 辅助光标闪烁阶段（AppKit 仅使主光标闪烁）。
    private var extraCaretsOn = true
    private var caretBlinkTimer: Timer?

    /// 确认光标所在列并在显示中反映出来。折叠到单选时恢复正常单选模式。
    private func applyCarets(_ new: [NSRange]) {
        let normalized = MultiCursor.normalize(new)
        guard let primary = normalized.last else { return }
        carets = normalized.count > 1 ? normalized : []

        // 当存在多个特定长度的范围时，它们被放置在 AppKit 的不连续选择上（以绘制带状区域）。
        let selections = normalized.filter { $0.length > 0 }
        let handOff = selections.count > 1 ? selections : [normalized.count > 1 ? (selections.first ?? primary) : primary]
        super.setSelectedRanges(handOff.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)

        needsDisplay = true
        syncCaretBlink()
    }

    /// 当在只读模式（结构化视图等）下双击行或按下 Return 时。
    var onActivateLineEditing: (() -> Void)?

    /// ⌘单击添加插入符 / 再次单击同一位置移除插入符。
    /// ⌥标准的拖放矩形选择（AppKit）仍然存在，这意味着它也可以作为多个区域进行编辑。
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !isEditable, onActivateLineEditing != nil {
            super.mouseDown(with: event)
            onActivateLineEditing?()
            return
        }
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift), isEditable else {
            super.mouseDown(with: event); return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        applyCarets(MultiCursor.toggling(activeRanges, at: NSRange(location: index, length: 0)))
    }

    /// 将插入符号添加到上一行/下一行的相同数字上（⌥⌘↑ / ⌥⌘↓）。
    func addCaret(above: Bool) {
        applyCarets(MultiCursor.addingCaret(to: activeRanges, above: above, in: string as NSString))
    }

    /// 将与当前选中单词相同的下一个单词添加到选中状态 (⌘D)。如果没有选中任何单词，则选中光标所在位置的单词。
    func selectNextOccurrence() {
        let text = string as NSString
        let current = activeRanges
        guard let last = current.max(by: { NSMaxRange($0) < NSMaxRange($1) }) else { return }
        guard last.length > 0 else {
            // 首先是掌握单词的阶段（与 VSCode 中的 ⌘D 的第一次相同）。
            guard let word = MultiCursor.wordRange(at: last.location, in: text) else { NSSound.beep(); return }
            applyCarets([word])
            return
        }
        let word = text.substring(with: last)
        guard let found = MultiCursor.nextOccurrence(of: word, in: text, after: NSMaxRange(last),
                                                     excluding: current) else { NSSound.beep(); return }
        applyCarets(current + [found])
        scrollRangeToVisible(found)
    }

    /// 使用现有多选区机制选择查找结果，保留各匹配项的独立范围。
    func selectSearchMatches(_ ranges: [NSRange]) {
        guard !ranges.isEmpty else { NSSound.beep(); return }
        applyCarets(ranges)
        scrollRangeToVisible(ranges[0])
    }

    /// Esc 禁用多光标功能（合并为一个主光标）。如果选择单个光标，则恢复为标准行为。
    override func cancelOperation(_ sender: Any?) {
        guard hasMultipleCarets else { super.cancelOperation(sender); return }
        applyCarets([carets.last ?? selectedRange()])
    }

    override func keyDown(with event: NSEvent) {
        if !isEditable, onActivateLineEditing != nil {
            if event.keyCode == 36 || event.characters == "\r" || event.characters == "\n" {
                onActivateLineEditing?()
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - 编辑多个光标（撤销功能直接使用 NSTextView 机制实现）

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // IME：转换过程中，仅以主光标为目标（marked 和 text 只能放置在一个位置）。
        guard !hasMarkedText(), applyToAllCarets(replacing: nil, with: text) else {
            super.insertText(string, replacementRange: replacementRange); return
        }
    }

    override func insertNewline(_ sender: Any?) {
        guard applyToAllCarets(replacing: nil, with: "\n") else { super.insertNewline(sender); return }
    }

    /// 当存在数字引导时，Tab 表示“跳转到下一项”。**绘制的线条将成为制表符位置。**
    /// 如果返回值为 true，则表示它已被移动，因此不要包含制表符。
    var onFieldTab: ((_ backwards: Bool) -> Bool)?

    override func insertTab(_ sender: Any?) {
        if onFieldTab?(false) == true { return }
        guard applyToAllCarets(replacing: nil, with: "\t") else { super.insertTab(sender); return }
    }

    override func insertBacktab(_ sender: Any?) {
        if onFieldTab?(true) == true { return }
        super.insertBacktab(sender)
    }

    /// ⌥Tab 将出现在这里，而不是 `insertTab:`。在菜单中，key 和 equivalent 将引导您前往……
    /// 无法拾取（TextView 已将其消耗），并且包含一个普通的制表符。此处已接收。
    var onAlignAll: (() -> Bool)?

    override func insertTabIgnoringFieldEditor(_ sender: Any?) {
        if onAlignAll?() == true { return }
        super.insertTabIgnoringFieldEditor(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        guard applyToAllCarets(replacing: false, with: "") else { super.deleteBackward(sender); return }
    }

    override func deleteForward(_ sender: Any?) {
        guard applyToAllCarets(replacing: true, with: "") else { super.deleteForward(sender); return }
    }

    /// 对所有插入符号应用相同的编辑。如果 `forward` 为 nil，则选择（如果是插入符号则选择 0 个字符）。
    /// 替换为  / `text`；如果不是 nil，则删除。如果只有一个光标，则返回 false 并进行标准处理。
    private func applyToAllCarets(replacing forward: Bool?, with text: String) -> Bool {
        guard hasMultipleCarets, isEditable, let storage = textStorage else { return false }
        let targets: [NSRange] = {
            guard let forward else { return MultiCursor.normalize(carets) }
            return MultiCursor.deletionRanges(carets, forward: forward, in: string as NSString)
        }()
        guard !targets.isEmpty else { return true }   // 无需擦除 = 直接将其碾碎

        let replacements = Array(repeating: text, count: targets.count)
        guard shouldChangeText(inRanges: targets.map { NSValue(range: $0) },
                               replacementStrings: replacements) else { return true }
        let inserted = NSAttributedString(string: text, attributes: typingAttributes)
        storage.beginEditing()
        // 如果从背面应用，则前面的偏移量不会改变。
        for r in targets.reversed() { storage.replaceCharacters(in: r, with: inserted) }
        storage.endEditing()
        didChangeText()
        applyCarets(MultiCursor.caretsAfterReplacing(targets, with: replacements))
        return true
    }

    // MARK: - 辅助光标绘图（包括自定义闪烁）

    /// 闪烁计时器仅在有两个或两个以上光标时启动。
    private func syncCaretBlink() {
        let needed = hasMultipleCarets && carets.contains { $0.length == 0 }
        if needed, caretBlinkTimer == nil {
            extraCaretsOn = true
            caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.56, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.extraCaretsOn.toggle()
                self.setNeedsDisplay(self.extraCaretsBounds)
            }
        } else if !needed, caretBlinkTimer != nil {
            caretBlinkTimer?.invalidate()
            caretBlinkTimer = nil
            extraCaretsOn = true
        }
    }

    /// 重绘范围包括辅助光标（以防止在闪烁时重绘整个屏幕）。
    private var extraCaretsBounds: NSRect {
        extraCaretRects().reduce(NSRect.zero) { $0.isEmpty ? $1 : $0.union($1) }
    }

    /// 自定义绘制的插入符矩形。它不会与 AppKit 绘制的主插入符重叠（当进行空选时）。
    private func extraCaretRects() -> [NSRect] {
        guard hasMultipleCarets else { return [] }
        let primary = selectedRange()
        let drawnByAppKit = primary.length == 0 ? primary.location : -1
        return carets.filter { $0.length == 0 && $0.location != drawnByAppKit }
                     .compactMap { caretRect(atCharIndex: $0.location) }
    }

    /// 插入符矩形（视图坐标）表示字符位置 `ci`。也适用于行尾、空文本以及行尾换行符之后的位置。
    private func caretRect(atCharIndex ci: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let text = string as NSString
        let len = text.length
        let index = min(max(0, ci), len)
        let origin = textContainerOrigin
        let width = cursorShape == .bar ? 1.5 : caretWidth

        func atEndOfText() -> NSRect {
            if len == 0 || isNewline(text.character(at: len - 1)) {
                var r = lm.extraLineFragmentRect
                r.size.width = width
                return r
            }
            let g = lm.glyphIndexForCharacter(at: len - 1)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let box = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            return NSRect(x: box.maxX, y: frag.minY, width: width, height: frag.height)
        }

        var rect: NSRect
        if index >= len {
            rect = atEndOfText()
        } else {
            let g = lm.glyphIndexForCharacter(at: index)
            guard g < lm.numberOfGlyphs else { rect = atEndOfText(); return rect.offsetBy(dx: origin.x, dy: origin.y) }
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let p = lm.location(forGlyphAt: g)
            rect = NSRect(x: frag.minX + p.x, y: frag.minY, width: width, height: frag.height)
        }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// 绘制辅助插入符（形状与主插入符相同，链接到 config）。
    private func drawExtraCarets() {
        guard extraCaretsOn, hasMultipleCarets else { return }
        let color = insertionPointColor ?? .textColor
        for var r in extraCaretRects() {
            switch cursorShape {
            case .bar:
                color.setFill()
            case .block:
                color.withAlphaComponent(0.4).setFill()
            case .underline:
                r.origin.y = r.maxY - 2
                r.size.height = 2
                color.setFill()
            }
            r.fill()
        }
    }

    // MARK: - 插入符号

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard cursorShape != .bar else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        guard flag else { return }
        var r = rect
        r.size.width = caretWidth
        if cursorShape == .block {
            color.withAlphaComponent(0.4).setFill()
        } else { // underline
            r.origin.y = rect.maxY - 2
            r.size.height = 2
            color.setFill()
        }
        r.fill()
    }

    /// 块和下划线有宽度，因此删除范围会扩大一个字符。
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = invalidRect
        if cursorShape != .bar { r.size.width += caretWidth }
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }
}
