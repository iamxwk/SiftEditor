import AppKit

/// 位于左右列之间的合并条。
///
/// 绘制 **→** 每个差异块（汉克），**单击以捕获右侧**。再次按下可撤销。
/// 如果你只使用键盘（⌥→），没有人会注意到，所以把可以按的东西放在显眼的地方。
/// 格式与 FileMerge、Beyond 和 Compare 相同。
final class MergeGutter: NSView {

    /// 每个可见行的状态。按从上到下的顺序排列（组合使用 `DiffViewer.refresh`）。
    struct Row {
        /// 此行所属的代码块（下标为 op）。非差异行的下标为 nil。
        ///
        /// **请将此内容添加到汉克的所有台词中，而不仅仅是第一行。** 箭头只画在开头。
        /// 可以在 Hank 的任何一行上接收点击——如果只能点击第一行 (14pt)，
        /// 可以用手指移除（实际上，稍微按压箭头下方没有反应）。
        let hunkOp: Int?
        /// 这是汉克的线（带箭头的线）的开头吗？
        let isHead: Bool
        /// 你已经雇佣了汉克吗？
        let adopted: Bool
        /// 你现在选择的是汉克吗？
        let current: Bool
    }

    var rows: [Row] = [] { didSet { needsDisplay = true } }
    var lineHeight: CGFloat = 16 { didSet { needsDisplay = true } }

    /// 按下箭头时调用（传递下标 op）。
    var onToggle: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    /// 即使在非活动窗口中，也要让箭头在第一次单击时生效。
    ///
    /// 默认情况下，第一次单击非键盘窗口只会将其置于最前面并使其消失。
    /// 对于从其他应用程序返回并按下箭头的用户，**似乎什么都不会发生**。
    ///（实际上导致验证失败 4 次）。导入操作应该只需要单击一次。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 箭头大小。**请勿超出线外**——如果超出线外，即使您按压超出线外的部分……
    /// 检测到它在相邻行，并且变得无响应（实际上有人告诉我“我按它时什么也没发生”）。
    private var markSize: CGFloat { min(16, max(10, lineHeight - 2)) }

    private var background: NSColor { EditorTheme.current().chromeBackground }
    private var separator: NSColor { EditorTheme.current().separator }
    private var arrowIdle: NSColor { NSColor.secondaryLabelColor }
    private var arrowCurrent: NSColor { NSColor.systemTeal }
    private var arrowAdopted: NSColor { NSColor.systemBlue }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.intersection(bounds).fill()

        separator.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0.5, y: 0))
        line.line(to: NSPoint(x: 0.5, y: bounds.height))
        line.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
        line.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
        line.stroke()

        for (i, row) in rows.enumerated() {
            guard row.isHead else { continue }
            let y = CGFloat(i) * lineHeight
            let rect = NSRect(x: (bounds.width - markSize) / 2,
                              y: y + (lineHeight - markSize) / 2,
                              width: markSize, height: markSize)
            drawArrow(in: rect, adopted: row.adopted, current: row.current)
        }
    }

    /// 已接受的项目会填写完整，未接受的项目仅勾勒轮廓。做出选择后的汉克会改变颜色。
    private func drawArrow(in rect: NSRect, adopted: Bool, current: Bool) {
        let color = adopted ? arrowAdopted : (current ? arrowCurrent : arrowIdle)
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        if adopted {
            color.setFill()
            circle.fill()
        } else {
            color.withAlphaComponent(current ? 0.9 : 0.45).setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
        }

        // → 这是格式。已接受的项目以白色高亮显示。
        let arrow = NSBezierPath()
        let mid = rect.midY
        let x0 = rect.minX + 4.5, x1 = rect.maxX - 4.5
        arrow.move(to: NSPoint(x: x0, y: mid))
        arrow.line(to: NSPoint(x: x1, y: mid))
        arrow.move(to: NSPoint(x: x1 - 3.5, y: mid - 3.5))
        arrow.line(to: NSPoint(x: x1, y: mid))
        arrow.line(to: NSPoint(x: x1 - 3.5, y: mid + 3.5))
        arrow.lineWidth = 1.4
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        (adopted ? NSColor.white : color.withAlphaComponent(current ? 1.0 : 0.6)).setStroke()
        arrow.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / max(1, lineHeight))
        guard i >= 0, i < rows.count, let op = rows[i].hunkOp else { return }
        onToggle?(op)
    }

    /// 当您位于差分线上时，将指针更改为手指形状（这样您就知道可以点击它）。
    override func resetCursorRects() {
        discardCursorRects()
        for (i, row) in rows.enumerated() where row.hunkOp != nil {
            let y = CGFloat(i) * lineHeight
            addCursorRect(NSRect(x: 0, y: y, width: bounds.width, height: lineHeight),
                          cursor: .pointingHand)
        }
    }

    // MARK: - 无障碍

    /// **将箭头发布为真正的按钮**。
    ///
    /// 现在可以按下  / VoiceOver 按钮（实用功能）。同时，E2E 测试将**不再依赖坐标**。
    /// 现在您可以按名称点击 -- 坐标点击验证显示窗口位置偏移了 4pt。
    /// 仅使用  / 将产生错误的结果（我实际上连续被骗了四次）。
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityChildren() -> [Any]? {
        rows.enumerated().compactMap { i, row -> MergeArrowElement? in
            guard row.isHead, let op = row.hunkOp else { return nil }
            let e = MergeArrowElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel(L(row.adopted ? "diff.a11y.undo" : "diff.a11y.take"))
            e.setAccessibilityIdentifier("merge-arrow-\(op)")
            e.setAccessibilityFrameInParentSpace(
                NSRect(x: 0, y: CGFloat(i) * lineHeight, width: bounds.width, height: lineHeight))
            e.onPress = { [weak self] in self?.onToggle?(op) }
            return e
        }
    }
}

/// 一个装订箭头。可按压（来自 VoiceOver / E2E）。
final class MergeArrowElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
