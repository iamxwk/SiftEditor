import XCTest
@testable import SiftEditorCore

/// 验证更新检查的核心（GitHub 和 JSON 的版本比较和分析）。
/// 请勿触碰网络。
final class UpdateCheckerTests: XCTestCase {

    // MARK: - 版本比较

    func testComponentsStripsTagPrefix() {
        XCTAssertEqual(UpdateChecker.components("v1.2"), [1, 2])
        XCTAssertEqual(UpdateChecker.components("1.2.3"), [1, 2, 3])
        XCTAssertEqual(UpdateChecker.components("v0.7"), [0, 7])
    }

    /// 1.0 比 0.7 新。但是，字符串比较并未显示“1.0” < “0.7”。
    /// "0.10" < "0.7", 因此需要对它们进行数值比较。
    func testNewerAcrossMajorBump() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.7"))
        XCTAssertFalse(UpdateChecker.isNewer("0.7", than: "1.0"))
    }

    /// 两位数次要编号被认为比一位数次要编号更新（字符串比较陷阱）。
    func testNewerWithTwoDigitMinor() {
        XCTAssertTrue(UpdateChecker.isNewer("0.10", than: "0.7"))
        XCTAssertFalse(UpdateChecker.isNewer("0.7", than: "0.10"))
    }

    /// 即使位数不同，也可以进行比较。同一版本并非“新版本”。
    func testNewerWithDifferentDepthAndEquality() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.7", than: "0.7"))
    }

    // MARK: - GitHub JSON 分析

    func testParsePicksTagPageAndDmg() throws {
        let json = """
        {
          "tag_name": "v1.0",
          "html_url": "https://github.com/iamxwk/SiftEditor/releases/tag/v1.0",
          "assets": [
            {"browser_download_url": "https://example.com/notes.txt"},
            {"browser_download_url": "https://example.com/SiftEditor-1.0.dmg"}
          ]
        }
        """.data(using: .utf8)!

        let r = try XCTUnwrap(UpdateChecker.parse(json))
        XCTAssertEqual(r.version, "1.0")                       // “v”将失败。
        XCTAssertEqual(r.dmgURL?.lastPathComponent, "SiftEditor-1.0.dmg")
        XCTAssertEqual(r.pageURL.lastPathComponent, "v1.0")
    }

    /// 即使  / dmg 没有附加到版本中，页面仍然可以打开，因此被视为成功。
    func testParseWithoutDmgStillSucceeds() throws {
        let json = """
        {"tag_name": "v1.0",
         "html_url": "https://github.com/iamxwk/SiftEditor/releases/tag/v1.0",
         "assets": []}
        """.data(using: .utf8)!
        let r = try XCTUnwrap(UpdateChecker.parse(json))
        XCTAssertNil(r.dmgURL)
        XCTAssertEqual(r.version, "1.0")
    }

    /// 响应损坏 - 没有编号的标签将导致 nil（= 静默失败）。
    func testParseRejectsGarbage() {
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"latest","html_url":"https://x.test/"}"#.utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"html_url":"https://x.test/"}"#.utf8)))
    }

    /// **版本号位数变更**。如果 1.0.3 的用户没有被告知 1.1 是“新”版本，
    /// 更新通知将失败（字符串比较可能导致“1.1”<“1.0.3”）。
    func testVersionComparisonAcrossDigitCounts() {
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0.3"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.0.3"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.3", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1.1"))
    }

    // MARK: - 分销来源（feed 声明）

    /// 软件包声明更新地址；未声明时不执行更新检查。
    func testUpdateFeedComesFromBundleDeclaration() {
        XCTAssertEqual(AppInfo.updateFeed(from: "https://api.github.com/repos/iamxwk/SiftEditor/releases/latest"),
                       URL(string: "https://api.github.com/repos/iamxwk/SiftEditor/releases/latest"))
        XCTAssertNil(AppInfo.updateFeed(from: nil))          // 无声明
        XCTAssertNil(AppInfo.updateFeed(from: ""))           // 空字符串表示“无”
        XCTAssertNil(AppInfo.updateFeed(from: "   "))        // 也没有任何空格。
        XCTAssertNil(AppInfo.updateFeed(from: 42))           // 不是字符串
    }

    /// 如果未声明，则采集过程将不会运行，并将立即返回 `notConfigured`（不联系网络）。
    func testFetchWithoutFeedFailsAsNotConfigured() {
        guard AppInfo.updateFeedURL == nil else {
            // 该测试在不打包的情况下运行，因此通常不会出现在这里（如果出现在这里，则说明缺少声明）。
            return XCTFail("テスト実行環境が feed を宣言している")
        }
        let done = expectation(description: "fetch")
        var error: UpdateChecker.CheckError?
        UpdateChecker.fetchLatest { result in
            if case .failure(let e) = result { error = e }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        guard case .notConfigured = error else { return XCTFail("notConfigured ではない: \(String(describing: error))") }
        XCTAssertFalse(UpdateChecker.isAvailable)
    }
}
