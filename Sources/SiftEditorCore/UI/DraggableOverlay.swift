import AppKit

/// 一种安装装置，允许您“抓取和移动”出现在主文本上方的小窗口。
///
/// 小窗口（搜索栏和横幅）通过 Auto Layout 固定在边缘。需要设置限制条件才能使其移动。
/// 如果您将其移除并将 frame 直接放置在表面上，则您必须自行处理所有窗口大小调整。
/// **保持约束不变，只移动常量。**溢出检测使用 `OverlayPlacement`（纯逻辑）完成。
///
/// 只能抓取**背景**。从按钮或文本框开始的拖动操作将不计入抓取次数。
/// （尝试在搜索栏中选择文本时，不会导致整个栏移动）。
final class DraggableOverlay: NSObject {
    /// 用于记住位置的名称（AppSettings 格式的键）。
    let name: String

    private weak var view: NSView?
    private weak var container: NSView?
    private let horizontal: NSLayoutConstraint
    private let vertical: NSLayoutConstraint
    private let horizontalAnchor: OverlayPlacement.Anchor
    private let verticalAnchor: OverlayPlacement.Anchor
    /// 未拖动时的常量（= 默认位置）。恢复到此值将“重置位置”。
    private let baseX: CGFloat
    /// 默认垂直位置。**调用用户可以移动此位置**（例如，在出现结构化横幅时将搜索栏向下移动一级）。
    /// 如果直接修改约束常量，抓取位置将会消失，所以必须通过这里进行修改。
    private var baseY: CGFloat
    /// 实际位移量（卷起放入窗户后）。
    private(set) var offset: CGPoint = .zero
    /// **用户所需的偏移量**（四舍五入前）。即使窗口太小无法放置偏移量，也请记住此值。
    /// 如果未将其分开，则在启动后大小尚未确定时，它将立即四舍五入为 0，并且记忆的位置将丢失。
    private var desired: CGPoint = .zero

    private var dragStart: CGPoint?
    private var dragOrigin: CGPoint = .zero

    init(name: String, view: NSView, container: NSView,
         horizontal: NSLayoutConstraint, horizontalAnchor: OverlayPlacement.Anchor,
         vertical: NSLayoutConstraint, verticalAnchor: OverlayPlacement.Anchor) {
        self.name = name
        self.view = view
        self.container = container
        self.horizontal = horizontal
        self.vertical = vertical
        self.horizontalAnchor = horizontalAnchor
        self.verticalAnchor = verticalAnchor
        self.baseX = horizontal.constant
        self.baseY = vertical.constant
        super.init()

        let pan = NSPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        applyStored()
    }

    // MARK: - 位置

    /// 猜猜你记得的位置（调整形状以适应窗口大小）。
    func applyStored() {
        set(offset: AppSettings.overlayOffset(for: name), save: false)
    }

    /// 当窗口大小改变时，重新定位所需位置以匹配当前大小。
    /// 由于它是从期望值而不是四舍五入值重新绘制的，因此扩展它会将其恢复到原始位置。
    func reclamp() {
        set(offset: desired, save: false)
    }

    /// 替换默认垂直位置（在保留与抓取位置的偏移量的同时重新定位）。
    func setBaseY(_ y: CGFloat) {
        guard y != baseY else { return }
        baseY = y
        set(offset: desired, save: false)
    }

    /// 返回默认位置（忘记所有已记住的位置）。
    func reset() {
        set(offset: .zero, save: true)
    }

    private func set(offset requested: CGPoint, save: Bool) {
        desired = requested
        guard let view, let container else { return }
        let clamped = OverlayPlacement.restore(offset: requested, baseX: baseX, baseY: baseY,
                                               size: view.frame.size, container: container.frame.size,
                                               horizontal: horizontalAnchor, vertical: verticalAnchor)
        offset = clamped
        horizontal.constant = baseX + clamped.x
        vertical.constant = baseY + clamped.y
        if save { AppSettings.setOverlayOffset(desired, for: name) }
    }

    // MARK: - 药物

    @objc private func panned(_ g: NSPanGestureRecognizer) {
        guard let view else { return }
        switch g.state {
        case .began:
            dragOrigin = offset
            dragStart = g.location(in: view.superview)
        case .changed:
            guard let start = dragStart else { return }
            let now = g.location(in: view.superview)
            // superview 没有反转（底部是原点），因此上下方向的符号被反转，以匹配“向下移动 = 增加常数”。
            set(offset: CGPoint(x: dragOrigin.x + (now.x - start.x),
                                y: dragOrigin.y - (now.y - start.y)), save: false)
        case .ended, .cancelled:
            dragStart = nil
            // 你需要记住的是**四舍五入后**的位置。如果你记住的是把它从窗口拉出来时的值，
            // 下次它在大窗口中打开时，它会飞得很远。
            set(offset: offset, save: true)
        default:
            break
        }
    }
}

extension DraggableOverlay: NSGestureRecognizerDelegate {
    /// **仅允许抓取可操作的部分。**其他所有内容（背景、标签、图标）均可抓取。
    ///
    /// 如果将其设置为“只能抓住栏杆的顶部”，即使看起来像一个缝隙，实际上那里也放置了一个数字标签。
    /// “无法把握任何事物”的问题确实存在。将判断置于**组件侧**可以消除此问题。
    func gestureRecognizerShouldBegin(_ g: NSGestureRecognizer) -> Bool {
        guard let view else { return false }
        let p = g.location(in: view)
        guard let hit = view.hitTest(view.convert(p, to: view.superview)) else { return true }
        var node: NSView? = hit
        while let n = node, n !== view {
            if Self.isInteractive(n) { return false }
            node = n.superview
        }
        return true
    }

    /// 这是一个可以按压、点击或选择的组件吗？标签（NSTextField，无法编辑或选择）不包含在内。
    private static func isInteractive(_ v: NSView) -> Bool {
        if let field = v as? NSTextField { return field.isEditable || field.isSelectable }
        if let text = v as? NSText { return text.isEditable || text.isSelectable }
        if v is NSButton || v is NSSegmentedControl || v is NSPopUpButton
            || v is NSSlider || v is NSStepper || v is NSComboBox { return true }
        return false
    }
}
