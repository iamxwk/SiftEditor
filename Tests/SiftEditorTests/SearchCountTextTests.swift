import XCTest
@testable import SiftEditorCore

/// 在搜索栏中显示搜索结果数量。**确保显示内容安全，以便“完成后”字样可见。**
///
/// 发现于 2026 年 9 月 5 日，当时当事人说：“我不知道什么时候会结束。”
/// 当匹配到 `total == 0` 时，它只显示“正在搜索... N%”，所以一旦找到哪怕一个匹配项……
/// 已切换至“13 件商品”，**即使扫描仍在进行中，也显示已确认**。1GB
/// 此后文件中的条目数量继续增加，所以这几乎肯定是谎言。
final class SearchCountTextTests: XCTestCase {

    private func text(current: Int = 0, total: Int, searching: Bool, progress: Int = 0,
                      invalid: Bool = false, capped: Bool = false) -> String {
        SearchBarView.countText(query: "あ", current: current, total: total,
                                searching: searching, progress: progress,
                                invalid: invalid, capped: capped)
    }

    /// 扫描时，只显示结果数量，扫描似乎没有完成。
    func testSearchingShowsProgressAlongsideCount() {
        let t = text(total: 13, searching: true, progress: 42)
        XCTAssertTrue(t.contains("13"), "見つかった件数は出す: \(t)")
        XCTAssertTrue(t.contains("42"), "進み具合も出す: \(t)")
    }

    /// 进度条完成后将消失。**进度条消失表示任务已完成。**
    func testFinishedDropsProgress() {
        let t = text(total: 13, searching: false)
        XCTAssertTrue(t.contains("13"))
        XCTAssertFalse(t.contains("%"), "終わったら % は出さない: \(t)")
    }

    /// 即使物品数量相同，扫描过程中的文字和扫描完成后的文字也会发生变化（否则，就无法区分它们）。
    func testSearchingAndFinishedDiffer() {
        XCTAssertNotEqual(text(total: 13, searching: true, progress: 90),
                          text(total: 13, searching: false))
    }

    /// 扫描过程中未显示“商品编号”。这是因为扫描杆不够宽，末端被截断了。
    /// （在实际设备上，它连同右括号一起消失了，显示“2/1,365,193 个结果（0% 搜索）”）。
    /// 运行过程中你需要知道的是物品的数量和进度；开始移动后，你可以读取是哪个物品。
    ///
    /// **不要以字数来判断。** 我最初是这么写的，但结果发现用日语写很短，用英语写却很长。
    /// 只有  / CI（英文版）运行失败。无论语言如何，都可以说“不显示位置”。
    func testSearchingDropsThePosition() {
        let atThird = text(current: 3, total: 1_365_193, searching: true, progress: 55)
        let atStart = text(current: 0, total: 1_365_193, searching: true, progress: 55)
        XCTAssertEqual(atThird, atStart, "走査中は何件目かで文言が変わらない: \(atThird)")
        XCTAssertTrue(atThird.contains("55"), "進み具合は出す: \(atThird)")

        let done = text(current: 3, total: 1_365_193, searching: false)
        XCTAssertNotEqual(done, text(current: 0, total: 1_365_193, searching: false),
                          "終わったら何件目かを出す: \(done)")
    }

    /// 只要还没有找到匹配项，它就会像以前一样显示“正在搜索... N%”。
    /// 不要明确表示“0 个结果”（因为扫描尚未完成，结果仍然未知）。
    func testNoMatchYet() {
        let t = text(total: 0, searching: true, progress: 7)
        XCTAssertTrue(t.contains("7"), "\(t)")
        XCTAssertNotEqual(t, text(total: 0, searching: false), "終わったときと同じ文言にしない: \(t)")
    }

    /// 如果流程完成后没有结果，则会显示“未找到匹配项”。不会显示进度。
    func testFinishedWithNoMatch() {
        let t = text(total: 0, searching: false)
        XCTAssertFalse(t.contains("%"), "\(t)")
        XCTAssertFalse(t.isEmpty)
    }

    /// 当达到扫描数量上限且扫描过程终止时，将显示“N 或更多商品”。如果扫描仍在进行中，进度也会显示在此处。
    func testCappedKeepsItsOwnWording() {
        let capped = text(total: 1_000_000, searching: false, capped: true)
        let plain = text(total: 1_000_000, searching: false, capped: false)
        XCTAssertNotEqual(capped, plain, "打ち切りを断言と同じ文言にしない")
        XCTAssertTrue(text(total: 1_000_000, searching: true, progress: 30, capped: true).contains("30"))
    }

    /// 如果单词为空，则不显示任何内容。如果公式出错，则仅指示该事实（不显示进度）。
    func testEmptyAndInvalid() {
        XCTAssertEqual(SearchBarView.countText(query: "", current: 0, total: 0, searching: true,
                                               progress: 50, invalid: false, capped: false), "")
        let bad = text(total: 0, searching: true, progress: 50, invalid: true)
        XCTAssertFalse(bad.contains("50"), "\(bad)")
    }
}
