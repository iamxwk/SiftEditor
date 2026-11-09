import AppKit

/// 一个绘制凹槽中差异位置的滚动器 (knob slot)。
///
/// 当有 8600 万行  数据排列在一起时，要查看“差异在哪里”，唯一的办法就是使用滚动条。
/// 整体画面一目了然，顶部有三处不同，底部有一处不同。
/// 对于巨型文件 diff，它与正文一样有效。
final class DiffScroller: NSScroller {

    /// 差值位置（0 和 1 之间的相对位置及其类型）。在凹槽中以彩色标尺绘制。
    struct Marker {
        enum Kind { case delete, insert, replace }
        let position: Double
        let kind: Kind
    }

    var markers: [Marker] = [] { didSet { needsDisplay = true } }

    private func color(_ k: Marker.Kind) -> NSColor {
        switch k {
        case .delete:  return NSColor.systemRed.withAlphaComponent(0.75)
        case .insert:  return NSColor.systemGreen.withAlphaComponent(0.75)
        case .replace: return NSColor.systemYellow.withAlphaComponent(0.75)
        }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        super.drawKnobSlot(in: slotRect, highlight: flag)
        guard !markers.isEmpty else { return }

        // 刻度尺的最小高度应为 2pt（以便即使一行的差异也清晰可见）。
        let h = max(2.0, slotRect.height / 400)
        for m in markers {
            let y = slotRect.minY + CGFloat(m.position) * (slotRect.height - h)
            color(m.kind).setFill()
            NSRect(x: slotRect.minX + 2, y: y, width: slotRect.width - 4, height: h).fill()
        }
    }
}
