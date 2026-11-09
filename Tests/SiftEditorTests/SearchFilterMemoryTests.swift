import XCTest
import AppKit
@testable import SiftEditorCore

/// 漏斗（仅显示匹配的行）按钮状态管理。
///
/// 普通的⌘F键会高亮显示命中位置，同时保持文本内容不变。漏斗形高亮显示仅在明确按下时才会显示。
/// 切换到匹配行显示。设置将保留以保证导出兼容性。
final class SearchFilterMemoryTests: XCTestCase {
    private var saved: Bool = false

    override func setUp() {
        super.setUp()
        saved = AppSettings.searchFilterOn
    }

    override func tearDown() {
        AppSettings.searchFilterOn = saved
        super.tearDown()
    }

    func testDefaultsToOffSoNothingChangesForSomeoneWhoNeverFilters() {
        UserDefaults.standard.removeObject(forKey: "SiftEditor.searchFilterOn")
        XCTAssertFalse(AppSettings.searchFilterOn)
    }

    func testRemembersWhatWasPressed() {
        AppSettings.searchFilterOn = true
        XCTAssertTrue(AppSettings.searchFilterOn)
        AppSettings.searchFilterOn = false
        XCTAssertFalse(AppSettings.searchFilterOn)
    }

    /// 当您移动到无法使用漏斗的窗格时，**只需降低栏杆**，不要触碰设置值。
    /// 如果假设用户按下了按钮，则只需在窗格之间移动即可更改用户设置。
    func testMovingToAPaneThatCannotFilterDoesNotRewriteTheSetting() {
        AppSettings.searchFilterOn = true

        let bar = SearchBarView()
        var userToggles: [Bool] = []
        var forcedOff = 0
        bar.onFilterToggle = { userToggles.append($0) }
        bar.onFilterUnavailable = { forcedOff += 1 }

        bar.setFilterAvailable(true)
        bar.setFilterOn(true)
        bar.setFilterAvailable(false)   // 已移至结构化窗格

        XCTAssertEqual(forcedOff, 1, "使えなくなったことは伝わる")
        XCTAssertTrue(userToggles.isEmpty, "本人が押したことにしてはいけない")
        XCTAssertTrue(AppSettings.searchFilterOn, "意図は残る")
    }

    /// 当漏斗隐藏时无法站立（仅当隐形按钮处于 on 状态时）
    /// 当您返回到可用窗格时，会发生无法解释的筛选。
    func testCannotRaiseTheFunnelWhileItIsHidden() {
        let bar = SearchBarView()
        bar.setFilterAvailable(false)
        bar.setFilterOn(true)
        bar.setFilterAvailable(true)
        var reported: [Bool] = []
        bar.onFilterToggle = { reported.append($0) }
        bar.setFilterOn(true)
        XCTAssertTrue(reported.isEmpty, "外から立てるのは通知を伴わない")
    }
}
