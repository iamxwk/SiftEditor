import CoreGraphics

/// 计算出现在主文本上方的小窗口（搜索栏和各种横幅）的位置（与 UI 无关的纯逻辑）。
///
/// 随着你向浮点数中添加更多对象，你会添加“要向下发送哪个对象”，组合的数量等于组合的数量。
/// 它崩溃了（当我启用搜索功能时，即使在 1.11 版本中进行了结构化设置，右上角的两个元素也重叠了）。
/// **与其增加逃脱的方法，不如让玩家能够抓住并移动它们。** 这是为了实现这个目的。
/// 它只执行计算以确定“偏移量是否会超出窗口”。
enum OverlayPlacement {
    /// 小窗口所附着的边。约束常量的含义因边而异，因此用类型表示。
    enum Anchor {
        /// 距左上边缘的距离（正值）。
        case leading
        /// 距顶部/右边缘的距离（**负值**。trailing 约束的常量）。
        case trailing
    }

    /// 将偏移量取整，使小窗口能够放入容器内。
    ///
    /// - Parameters:
    /// - offset: 用户通过拖动移动的量。
    /// - base: 是拖动前的约束常量（符号根据 `Anchor` 而变化）。
    /// - size: 小窗户侧面的长度（宽度或高度）。
    /// - container: 容器侧面的长度。
    /// - Returns: 偏移量取值范围，四舍五入后为 0（= 默认位置），当容器小于小窗口时。
    static func clamp(offset: CGFloat, base: CGFloat, size: CGFloat,
                      container: CGFloat, anchor: Anchor) -> CGFloat {
        guard container > size else { return 0 }
        switch anchor {
        case .leading:
            // 左端（上端）＝ base + offset。0 以上、container - size 以下。
            return min(max(offset, -base), container - size - base)
        case .trailing:
            // 右端（下端）＝ container + base + offset。size 以上、container 以下。
            return min(max(offset, size - container - base), -base)
        }
    }

    /// 将记住的偏移量重新应用到当前窗口大小。
    /// 这是为了防止小窗口在主窗口调整大小时停留在屏幕外。
    static func restore(offset: CGPoint, baseX: CGFloat, baseY: CGFloat,
                        size: CGSize, container: CGSize,
                        horizontal: Anchor, vertical: Anchor) -> CGPoint {
        CGPoint(x: clamp(offset: offset.x, base: baseX, size: size.width,
                         container: container.width, anchor: horizontal),
                y: clamp(offset: offset.y, base: baseY, size: size.height,
                         container: container.height, anchor: vertical))
    }
}
