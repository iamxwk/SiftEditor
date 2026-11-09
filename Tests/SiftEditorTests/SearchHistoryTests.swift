import XCTest
import AppKit
@testable import SiftEditorCore

/// 搜索历史（积压“搜索历史”）。
///
/// `NSSearchField.recentsAutosaveName` 表示“`recentSearches` 将自动设置为用户默认值”。
/// 它只执行“读取和写入”操作。**将确认的单词添加到数组是我们的工作。**
/// （最初，我误解了这一点，以为它会自动与 Enter 一起累积，但它并没有在实际设备上累积）。
/// 在这里，我们只关注自定义逻辑：“堆叠、删除重复项、按最新排序，并在上限处截断”。
final class SearchHistoryTests: XCTestCase {
    /// `recentsAutosaveName` 将保留为用户默认值，因此 `SearchBarView()`
    /// 即使创建新的测试，它也会继承上次测试的历史记录。每次开始测试前请将其删除。
    private func freshBar() -> SearchBarView {
        let bar = SearchBarView()
        bar.resetHistoryForTesting()
        return bar
    }

    func testRecentsAutosaveNameEnabled() {
        let bar = freshBar()
        XCTAssertNotNil(bar._testSearchHistoryAutosaveName)
        XCTAssertFalse(bar._testSearchHistoryAutosaveName!.isEmpty)
    }

    /// 如果未设置菜单模板，“最近搜索”菜单本身不会出现在放大镜图标下。
    func testSearchMenuTemplateEnabled() {
        let bar = freshBar()
        XCTAssertTrue(bar._testSearchHistoryMenuEnabled)
        XCTAssertTrue(bar._testHistoryDropdownEnabled)
    }

    func testDropdownSelectionUpdatesActiveQuery() {
        let bar = freshBar()
        bar._testCommitSearch("alpha")
        bar._testCommitSearch("beta")
        var selected: String?
        bar.onQueryChange = { selected = $0 }

        bar._testSelectRecentSearch("alpha")

        XCTAssertEqual(bar.query, "alpha")
        XCTAssertEqual(selected, "alpha")
        XCTAssertEqual(bar._testRecentSearches, ["beta", "alpha"])
    }

    func testFindAssistMenuShowsAvailableAndMissingActions() {
        let bar = freshBar()
        bar._testCommitSearch("alpha")
        bar.selectedTextForFind = { "beta" }
        let menu = bar._testFindAssistMenu
        XCTAssertTrue(menu.items.contains { $0.title == L("search.assist.selection") && $0.isEnabled })
        XCTAssertTrue(menu.items.contains { $0.title == L("search.assist.lastUsed") && $0.isEnabled })
        XCTAssertTrue(menu.items.contains { $0.title == L("search.assist.wordAtCursor") + " *" && !$0.isEnabled })
        XCTAssertTrue(menu.items.contains { $0.title.contains(L("search.assist.beginLine")) && $0.isEnabled })
        XCTAssertTrue(menu.items.contains { $0.title.contains(L("search.assist.newline")) && !$0.isEnabled })
    }

    func testFindAssistRegexSnippetUpdatesQueryAndMode() {
        let bar = freshBar()
        bar.setQuery("DROP TABLE", regex: false, caseSensitive: false, filter: false)
        var received: String?
        bar.onQueryChange = { received = $0 }
        bar._testInsertRegexSnippet(".*")
        XCTAssertEqual(bar.query, "DROP TABLE.*")
        XCTAssertTrue(bar.isRegex)
        XCTAssertEqual(received, "DROP TABLE.*")
    }

    func testCommittedSearchIsRemembered() {
        let bar = freshBar()
        bar._testCommitSearch("alpha")
        XCTAssertEqual(bar._testRecentSearches, ["alpha"])
    }

    func testMostRecentComesFirst() {
        let bar = freshBar()
        bar._testCommitSearch("alpha")
        bar._testCommitSearch("bravo")
        XCTAssertEqual(bar._testRecentSearches, ["bravo", "alpha"])
    }

    /// 如果重复输入同一个单词，则会将其移到开头而不会重复。
    func testRepeatedSearchMovesToFrontWithoutDuplicate() {
        let bar = freshBar()
        bar._testCommitSearch("alpha")
        bar._testCommitSearch("bravo")
        bar._testCommitSearch("alpha")
        XCTAssertEqual(bar._testRecentSearches, ["alpha", "bravo"])
    }

    func testDropdownRemovesStoredDuplicatesKeepingNewest() {
        let bar = freshBar()
        bar._testLoadRecentSearches(["DROP TABLE.*", "alpha", "DROP TABLE.*",
                                     "DROP TABLE .*", "alpha"])

        let titles = bar._testHistoryDropdownMenu.items.map(\.title)

        XCTAssertEqual(titles, ["DROP TABLE.*", "alpha", "DROP TABLE .*"])
        XCTAssertEqual(bar._testRecentSearches, titles)
    }

    func testDropdownCollapsesConsecutiveIntermediateQueriesWithoutDeletingHistory() {
        let bar = freshBar()
        let searches = ["DROP TABLE.*", "DROP TABLE.", "DROP TABLE .*", "DROP TABLE .",
                        "DROP TABLE", "a", "beta", "alpha", "alph", "al"]
        bar._testLoadRecentSearches(searches)

        XCTAssertEqual(bar._testHistoryDropdownMenu.items.map(\.title),
                       ["DROP TABLE.*", "a", "beta", "alpha"])
        XCTAssertEqual(bar._testRecentSearches, searches)
    }

    func testEmptyQueryIsNotRemembered() {
        let bar = freshBar()
        bar._testCommitSearch("")
        XCTAssertTrue(bar._testRecentSearches.isEmpty)
    }

    func testHistoryIsCappedAtMaximumRecents() {
        let bar = freshBar()
        for i in 0..<20 { bar._testCommitSearch("term\(i)") }
        XCTAssertLessThanOrEqual(bar._testRecentSearches.count, 10)
        XCTAssertEqual(bar._testRecentSearches.first, "term19")
    }

    /// 从历史记录菜单中选择时，仅 `stringValue` 会更改，`controlTextDidChange`
    /// (=`onQueryChange`) 将不会被发送。`_testCommitSearch` 不会经过该路径（因为没有被按下）。
    /// stringValue（更改 → 确认）将被重现。如果此处未执行同步，则搜索字段中的显示与实际显示将不一致。
    /// 搜索词不正确（显示屏显示所选词，但搜索结果仍然是前一个词；这是一个故障）。
    func testCommitSyncsQueryEvenWhenSetProgrammatically() {
        let bar = freshBar()
        var received: [String] = []
        bar.onQueryChange = { received.append($0) }
        bar._testCommitSearch("os")
        XCTAssertEqual(received, ["os"])
    }

    func testSelectedTextPrefillsLiteralSearchAndUpdatesViewer() {
        let bar = freshBar()
        bar.setQuery("old.*", regex: true, caseSensitive: true, filter: false)
        var receivedQuery: String?
        var receivedRegex: Bool?
        bar.onQueryChange = { receivedQuery = $0 }
        bar.onRegexToggle = { receivedRegex = $0 }

        bar.prefillFromSelection("DROP TABLE")

        XCTAssertEqual(bar.query, "DROP TABLE")
        XCTAssertFalse(bar.isRegex)
        XCTAssertTrue(bar.isCaseSensitive)
        XCTAssertEqual(receivedRegex, false)
        XCTAssertEqual(receivedQuery, "DROP TABLE")
    }

    func testChoosingRegexForExtractionUpdatesFindMode() {
        let bar = freshBar()
        var received: Bool?
        bar.onRegexToggle = { received = $0 }
        bar.selectRegexMode()
        XCTAssertTrue(bar.isRegex)
        XCTAssertEqual(received, true)
    }
}
