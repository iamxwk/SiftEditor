import XCTest
import AppKit
@testable import SiftEditorCore

/// 验证会话恢复的核心逻辑（恢复先前打开的列表 = 侧边栏）。
/// - `SessionState.make`: viewers → 组装到已保存的数据中（空的新跳过，活动位置更改）。
/// - `AppSettings.session`：持续往返于 UserDefaults 和 JSON。
/// - `EditableViewer.restoreUntitled` / `restorableText`：重建新的、未保存的文本。
///
/// `AppSettings.session` 修改 UserDefaults.standard，因此在每次测试中都会将其恢复为原始值。
final class SessionRestoreTests: XCTestCase {

    private var savedSession: SessionState?

    override func setUp() {
        super.setUp()
        savedSession = AppSettings.session
    }

    override func tearDown() {
        AppSettings.session = savedSession
        super.tearDown()
    }

    // MARK: - SessionState.make（純粋関数）

    /// 已保存的项目已传递，未保存的新项目包含文本。空的新项目将被丢弃。活动位置将更改为 entries。
    func testMakeSkipsEmptyUntitledAndRemapsActive() {
        let fileA = URL(fileURLWithPath: "/tmp/a.txt")
        let fileB = URL(fileURLWithPath: "/tmp/b.txt")
        let docs: [(url: URL?, text: String?, draftID: String?, dirty: Bool)] = [
            (fileA, nil, nil, false),          // 0：已保存
            (nil, "", "D0", false),            // 1：空新 → 跳过
            (nil, "メモ", "D1", true),          // 2：新建未保存的帖子（含文本）← 活动
            (fileB, nil, nil, false),          // 3：已保存
        ]
        let s = SessionState.make(docs: docs, activeIndex: 2)

        // （1）被删除，剩下3。
        XCTAssertEqual(s.entries.count, 3)
        XCTAssertEqual(s.entries[0].path, fileA.path)
        XCTAssertNil(s.entries[0].text)
        XCTAssertNil(s.entries[1].path)
        XCTAssertEqual(s.entries[1].draftID, "D1")   // 正文未包含在会话中（它包含在 draft 文件中）。
        XCTAssertNil(s.entries[1].text)
        XCTAssertTrue(s.entries[1].dirty)
        XCTAssertEqual(s.entries[2].path, fileB.path)

        // docs[2] 被 entries 中的第一个位置替换。
        XCTAssertEqual(s.activeIndex, 1)
    }

    /// 导入 (`| sifteditor`) 选项卡不会保留在之前的会话中。其他临时文件（例如 gz 提取）和
    /// 位于指定位置之外的名为 `stdin-` 的文件将保持不变。
    func testMakeSkipsPipedStreamTabsOnly() {
        let piped = Intake.scratchURL(named: "stdin-1791769573-61228.log")
        let expanded = Intake.scratchURL(named: "sample.log")
        let lookalike = URL(fileURLWithPath: "/tmp/stdin-notes.log")
        let docs: [(url: URL?, text: String?, draftID: String?, dirty: Bool)] = [
            (URL(fileURLWithPath: "/tmp/a.txt"), nil, nil, false),
            (piped, nil, nil, false),          // ← 已激活（将被跳过）
            (expanded, nil, nil, false),
            (lookalike, nil, nil, false),
        ]
        let s = SessionState.make(docs: docs, activeIndex: 1)
        XCTAssertEqual(s.entries.map(\.path), ["/tmp/a.txt", expanded.path, lookalike.path])
        XCTAssertEqual(s.activeIndex, -1)
    }

    /// 如果 Active 指向一个空的新（跳过的）条目，则 activeIndex 为 -1。
    func testMakeActiveOnSkippedUntitledBecomesNone() {
        let docs: [(url: URL?, text: String?, draftID: String?, dirty: Bool)] = [
            (URL(fileURLWithPath: "/tmp/a.txt"), nil, nil, false),
            (nil, "", "D0", false),   // 已激活，但将被跳过
        ]
        let s = SessionState.make(docs: docs, activeIndex: 1)
        XCTAssertEqual(s.entries.count, 1)
        XCTAssertEqual(s.activeIndex, -1)
    }

    /// 如果没有任何打开的内容，则会话为空。
    func testMakeEmpty() {
        let s = SessionState.make(docs: [], activeIndex: -1)
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertEqual(s.activeIndex, -1)
    }

    // MARK: - AppSettings.session（UserDefaults 永続化往復）

    /// 已保存的文件 + 未保存的新文件（含文本）可以写入 UserDefaults 并读取出来。
    func testAppSettingsSessionPersistRoundTrip() {
        let state = SessionState(entries: [
            SessionEntry(path: "/tmp/x.log", draftID: nil, dirty: false, text: nil),
            SessionEntry(path: nil, draftID: "D9", dirty: true, text: nil),
        ], activeIndex: 1)

        AppSettings.session = state
        let read = AppSettings.session
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.entries.count, 2)
        XCTAssertEqual(read?.entries[0].path, "/tmp/x.log")
        XCTAssertEqual(read?.entries[1].draftID, "D9")
        XCTAssertEqual(read?.entries[1].dirty, true)
        XCTAssertEqual(read?.activeIndex, 1)
    }

    /// 替换  / nil 将删除已保存的数据（这意味着下次将无法恢复）。
    func testAppSettingsSessionClear() {
        AppSettings.session = SessionState(entries: [SessionEntry(path: "/tmp/x", draftID: nil, dirty: false, text: nil)], activeIndex: 0)
        XCTAssertNotNil(AppSettings.session)
        AppSettings.session = nil
        XCTAssertNil(AppSettings.session)
    }

    // MARK: - EditableViewer 未保存的新复制

    /// 可以恢复，文本内容完整保留，但未保存的印章和未确认的密码也会被保留。可以使用 restorableText 提取文本。
    func testRestoreUntitledSetsTextAndDirty() {
        let v = EditableViewer()
        v.restoreUntitled(text: "ううううう", dirty: true)
        XCTAssertNil(v.fileURL)                       // 密码尚未确认
        XCTAssertTrue(v.isDirty)
        XCTAssertEqual(v._testText, "ううううう")
        XCTAssertEqual(v.restorableText, "ううううう") // 用于持久化的正文文本
    }

    /// dirty=false 也可以恢复，文本保持不变（非空的新条目将保留）。
    func testRestoreUntitledCleanKeepsText() {
        let v = EditableViewer()
        v.restoreUntitled(text: "clean note", dirty: false)
        XCTAssertFalse(v.isDirty)
        XCTAssertEqual(v.restorableText, "clean note")
    }

    /// restorableText 在结构化显示中返回原始逻辑文本，而不是格式化的外观。
    /// （保证 CSV/JSON 的内容即使在恢复后也不会损坏）。
    func testRestorableTextDuringStructuredReturnsOriginal() throws {
        let text = "name,age\nAlice,30\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-sr-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try text.data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        XCTAssertTrue(v.open(url: url))
        v.setStructuredMode(.csv)
        XCTAssertNotEqual(v._testText, text)          // 格式化后显示
        XCTAssertEqual(v.restorableText, text)         // 原始 CSV 将被保留。
    }
}
