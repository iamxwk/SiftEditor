import XCTest
@testable import SiftEditorCore

/// 浮动面板的位移量必须符合窗户内部的尺寸要求。
///
/// **如果这个设置太松，它会在移动时“消失在屏幕外，并且永远无法找回”。**
/// 当你缩小窗口时，也会发生同样的情况；如果你应用你记住的相同位置，它将保持在窗口外。
final class OverlayPlacementTests: XCTestCase {

    // 考虑容器大小为 1000，小窗口大小为 440。

    func testLeadingAnchorStaysInside() {
        // 位于距离左侧边缘 14pt 的位置。它只能向左移动 14 个空格。
        let c = OverlayPlacement.clamp(offset: -100, base: 14, size: 440, container: 1000, anchor: .leading)
        XCTAssertEqual(c, -14)
        // 向右，向上到 1000 - 440 - 14 = 546。
        XCTAssertEqual(OverlayPlacement.clamp(offset: 900, base: 14, size: 440, container: 1000, anchor: .leading), 546)
    }

    func testLeadingAnchorPassesThroughInsideRange() {
        XCTAssertEqual(OverlayPlacement.clamp(offset: 120, base: 14, size: 440, container: 1000, anchor: .leading), 120)
    }

    func testTrailingAnchorStaysInside() {
        // 从最右边的位置开始，坐标为 28pt（约束常量为 -28）。您只能向右移动 28 个单位。
        XCTAssertEqual(OverlayPlacement.clamp(offset: 500, base: -28, size: 440, container: 1000, anchor: .trailing), 28)
        // 向左移动，直到 440-1000+28 = -532。
        XCTAssertEqual(OverlayPlacement.clamp(offset: -900, base: -28, size: 440, container: 1000, anchor: .trailing), -532)
    }

    /// 如果窗口比小窗口窄，请勿移动（无论放在哪里都会凸出来，所以请将其保留在默认位置）。
    func testTooSmallContainerKeepsDefault() {
        XCTAssertEqual(OverlayPlacement.clamp(offset: 200, base: 14, size: 440, container: 300, anchor: .leading), 0)
        XCTAssertEqual(OverlayPlacement.clamp(offset: -200, base: -28, size: 440, container: 300, anchor: .trailing), 0)
    }

    /// 将记住的位置重新定位到缩小的窗口上（不要留下任何外部空间）。
    func testRestoreClampsBothAxes() {
        let p = OverlayPlacement.restore(offset: CGPoint(x: -900, y: 800),
                                         baseX: -28, baseY: 10,
                                         size: CGSize(width: 440, height: 32),
                                         container: CGSize(width: 1000, height: 600),
                                         horizontal: .trailing, vertical: .leading)
        XCTAssertEqual(p.x, -532)
        XCTAssertEqual(p.y, 600 - 32 - 10)
    }

    /// 如果未移动（0），则保持 0（默认位置）。
    func testZeroOffsetStaysZero() {
        let p = OverlayPlacement.restore(offset: .zero, baseX: -28, baseY: 10,
                                         size: CGSize(width: 440, height: 32),
                                         container: CGSize(width: 1000, height: 600),
                                         horizontal: .trailing, vertical: .leading)
        XCTAssertEqual(p, .zero)
    }
}
