import XCTest
@testable import SiftEditorCore

/// 验证未保存文本的保护（[[DraftStore]] 和恢复计划）。
///
/// 这里观察到一个不变的条件：
/// **无论会话状态如何（nil、已损坏、已覆盖），实际的 draft 始终会被恢复。**
/// 1.0 中的数据丢失错误是由于主文本与会话存储在同一个容器中而导致的。
/// 测试证实了  / Session 只是一个索引，而真相在于磁盘上的 draft 文件。
final class DraftStoreTests: XCTestCase {

    private var root: URL!
    private var store: DraftStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-drafts-\(UUID().uuidString)")
        store = DraftStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - DraftStore（正文容器）

    /// 可读写。即使目录不存在，也可以创建目录。
    func testWriteThenRead() {
        let id = DraftStore.newID()
        store.write(id: id, text: "未保存の下書き\n2行目")
        XCTAssertEqual(store.read(id: id), "未保存の下書き\n2行目")
        XCTAssertEqual(store.allIDs(), [id])
    }

    /// 可覆盖（每次按键更新到最新版本）。
    func testWriteOverwrites() {
        let id = DraftStore.newID()
        store.write(id: id, text: "old")
        store.write(id: id, text: "new")
        XCTAssertEqual(store.read(id: id), "new")
        XCTAssertEqual(store.allIDs().count, 1)
    }

    /// 空主体不包含文件（它不会恢复仅打开新标签页的状态）。
    func testEmptyTextRemovesFile() {
        let id = DraftStore.newID()
        store.write(id: id, text: "something")
        store.write(id: id, text: "")
        XCTAssertNil(store.read(id: id))
        XCTAssertTrue(store.allIDs().isEmpty)
    }

    /// discard 是删除正文的唯一方法。
    func testDiscardRemoves() {
        let id = DraftStore.newID()
        store.write(id: id, text: "捨てる")
        store.discard(id)
        XCTAssertNil(store.read(id: id))
        XCTAssertTrue(store.allIDs().isEmpty)
    }

    /// 读取不存在的 draft 或 discard 不会造成任何破坏。
    func testMissingDraftIsHarmless() {
        XCTAssertNil(store.read(id: "no-such-id"))
        store.discard("no-such-id")   // 不要抛出异常。
        XCTAssertTrue(store.allIDs().isEmpty)
    }

    /// 来自先前版本（最晚至 1.0.1）的旧会话（直接包含正文的会话）将被移动到 draft 文件。它们在更新过程中不会丢失。
    func testMigratingLegacyTextMovesBodyIntoDraftFile() throws {
        let legacy = SessionState(entries: [
            SessionEntry(path: "/tmp/a.txt", draftID: nil, dirty: false, text: nil),
            SessionEntry(path: nil, draftID: nil, dirty: true, text: "旧版の未保存の本文"),
        ], activeIndex: 1)

        let migrated = store.migratingLegacyText(in: legacy)

        let id = try XCTUnwrap(migrated.entries[1].draftID)
        XCTAssertNil(migrated.entries[1].text)                      // 主文本将从会话中移除。
        XCTAssertEqual(store.read(id: id), "旧版の未保存の本文")      // 移至文件
        XCTAssertEqual(migrated.entries[0].path, "/tmp/a.txt")      // 已保存的项目保持不变。
    }

    // MARK: - restorePlan（启动时打开的内容）——数据保护的关键

    /// 正常启动：按创建顺序打开会话，并保持活动状态。
    func testPlanFollowsSessionOrder() {
        let session = SessionState(entries: [
            SessionEntry(path: "/tmp/a.txt", draftID: nil, dirty: false, text: nil),
            SessionEntry(path: nil, draftID: "D1", dirty: true, text: nil),
        ], activeIndex: 1)

        let plan = SessionState.restorePlan(session: session, draftIDs: ["D1"], hasOpenDocuments: false)

        XCTAssertEqual(plan.items, [.file(path: "/tmp/a.txt"), .draft(id: "D1", dirty: true)])
        XCTAssertEqual(plan.activeIndex, 1)
    }

    /// **即使没有会话，现有的 draft 也会始终打开。**（首次启动，设置已清除，加载失败）
    func testPlanWithoutSessionStillRestoresDrafts() {
        let plan = SessionState.restorePlan(session: nil, draftIDs: ["D1", "D2"], hasOpenDocuments: false)
        XCTAssertEqual(plan.items, [.draft(id: "D1", dirty: true), .draft(id: "D2", dirty: true)])
    }

    /// **即使会话已被其他内容覆盖，draft 也始终会打开。**
    /// 这正是为了防止 1.0 版本中数据丢失问题的再次发生（系统启动时打开会话时崩溃）。
    func testPlanRestoresOrphanDraftsWhenSessionWasOverwritten() {
        // 会话已终止，仅与“small.txt”相关。不再有任何对 draft 的引用。
        let clobbered = SessionState(entries: [
            SessionEntry(path: "/tmp/small.txt", draftID: nil, dirty: false, text: nil),
        ], activeIndex: 0)

        let plan = SessionState.restorePlan(session: clobbered, draftIDs: ["D1"], hasOpenDocuments: false)

        XCTAssertTrue(plan.items.contains(.draft(id: "D1", dirty: true)), "孤児 draft を拾えていない")
    }

    /// 打开文件并启动它时（Finder / 参数）：之前保存的文件将不会重新打开，
    /// **请务必恢复所有未保存的 draft**。
    func testPlanWithOpenDocumentsKeepsDraftsAndDropsFiles() {
        let session = SessionState(entries: [
            SessionEntry(path: "/tmp/a.txt", draftID: nil, dirty: false, text: nil),
            SessionEntry(path: nil, draftID: "D1", dirty: true, text: nil),
        ], activeIndex: 0)

        let plan = SessionState.restorePlan(session: session, draftIDs: ["D1"], hasOpenDocuments: true)

        XCTAssertEqual(plan.items, [.draft(id: "D1", dirty: true)])
    }

    /// 即使会话指向  / 已保存/已丢弃的 draft，如果没有内容，也不会打开（不会出现幽灵标签）。
    func testPlanDropsSessionEntryWhoseDraftIsGone() {
        let session = SessionState(entries: [
            SessionEntry(path: nil, draftID: "GONE", dirty: true, text: nil),
        ], activeIndex: 0)

        let plan = SessionState.restorePlan(session: session, draftIDs: [], hasOpenDocuments: false)

        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.activeIndex, -1)
    }

    /// **不变条件（摘要）：无论给定哪个会话，所有现有的 draft 都将包含在计划中。**
    func testInvariantEveryExistingDraftIsAlwaysRestored() {
        let draftIDs = ["D1", "D2", "D3"]
        let sessions: [SessionState?] = [
            nil,                                                                     // 不可用
            SessionState(entries: [], activeIndex: -1),                              // 空
            SessionState(entries: [                                                  // 我只知道其中的一部分。
                SessionEntry(path: nil, draftID: "D2", dirty: false, text: nil),
            ], activeIndex: 0),
            SessionState(entries: [                                                  // 已被其他内容覆盖
                SessionEntry(path: "/tmp/x.txt", draftID: nil, dirty: false, text: nil),
            ], activeIndex: 0),
            SessionState(entries: [                                                  // 指的是不存在的 draft。
                SessionEntry(path: nil, draftID: "STALE", dirty: true, text: nil),
            ], activeIndex: 0),
        ]

        for session in sessions {
            for open in [false, true] {
                let plan = SessionState.restorePlan(session: session, draftIDs: draftIDs, hasOpenDocuments: open)
                for id in draftIDs {
                    let restored = plan.items.contains { item in
                        if case .draft(let i, _) = item { return i == id }
                        return false
                    }
                    XCTAssertTrue(restored, "draft \(id) が復元計画から漏れた（hasOpenDocuments=\(open)）")
                }
            }
        }
    }

    // MARK: - EditableViewer 包含 draft

    /// 新文档的标识符从 draft 到 id 被分配（如果正文为空，则不会创建文件）。
    func testNewDocumentGetsDraftIDButNoFileWhileEmpty() {
        let v = EditableViewer()
        v.draftStore = store
        v.newDocument()

        XCTAssertNotNil(v.draftID)
        v.flushDraft()
        XCTAssertTrue(store.allIDs().isEmpty, "空の新規でファイルを作ってはいけない")
    }

    /// 如果磁盘上有文本，它将以 flushDraft 的形式保留在磁盘上（即使系统崩溃也可以恢复）。
    func testFlushDraftWritesBody() {
        let v = EditableViewer()
        v.draftStore = store
        let id = DraftStore.newID()
        v.restoreDraft(id: id, text: "落ちても残る本文", dirty: true)

        v.flushDraft()

        XCTAssertEqual(store.read(id: id), "落ちても残る本文")
        XCTAssertEqual(v.draftID, id)
        XCTAssertTrue(v.isDirty)
    }

    /// draft 仅在关闭（丢弃）时消失。
    func testDiscardDraftRemovesFileAndID() {
        let v = EditableViewer()
        v.draftStore = store
        let id = DraftStore.newID()
        v.restoreDraft(id: id, text: "捨てる本文", dirty: true)
        v.flushDraft()
        XCTAssertNotNil(store.read(id: id))

        v.discardDraft()

        XCTAssertNil(store.read(id: id))
        XCTAssertNil(v.draftID)
    }

    /// 如果可以保存到实际文件中，则不需要 draft（它是可以删除的两个路径之一）。
    func testSavingToFileDiscardsDraft() throws {
        let v = EditableViewer()
        v.draftStore = store
        let id = DraftStore.newID()
        v.restoreDraft(id: id, text: "保存する本文\n", dirty: true)
        v.flushDraft()
        XCTAssertNotNil(store.read(id: id))

        let url = root.appendingPathComponent("saved-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(v._testWrite(to: url))

        XCTAssertNil(store.read(id: id), "保存したのに draft が残っている")
        XCTAssertNil(v.draftID)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "保存する本文\n")
    }

    /// 打开实际文件的窗格没有 draft（没有重复的已保存文本）。
    func testOpeningFileClearsDraftID() throws {
        let url = root.appendingPathComponent("open-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "ファイルの中身".data(using: .utf8)!.write(to: url)

        let v = EditableViewer()
        v.draftStore = store
        v.newDocument()
        XCTAssertNotNil(v.draftID)

        XCTAssertTrue(v.open(url: url))

        XCTAssertNil(v.draftID)
    }
}
