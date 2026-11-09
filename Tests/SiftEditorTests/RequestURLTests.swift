import XCTest
@testable import SiftEditorCore

/// 请求提交点。只有声明了请求地址的捆绑包才会显示菜单。
final class RequestURLTests: XCTestCase {

    func testUndeclaredOrBlankMeansNoRequestMenu() {
        XCTAssertNil(AppInfo.declaredURL(from: nil))        // 无声明
        XCTAssertNil(AppInfo.declaredURL(from: ""))
        XCTAssertNil(AppInfo.declaredURL(from: "   \n"))
        XCTAssertNil(AppInfo.declaredURL(from: 42))         // 不是字符串
        XCTAssertEqual(AppInfo.declaredURL(from: " https://example.com/x ")?.absoluteString, "https://example.com/x")
    }

    func testTheUpdateFeedStillBehavesTheSame() {
        XCTAssertNil(AppInfo.updateFeed(from: nil))
        XCTAssertNil(AppInfo.updateFeed(from: "  "))
        XCTAssertEqual(AppInfo.updateFeed(from: "https://api.github.com/x")?.absoluteString, "https://api.github.com/x")
    }

    func testVersionAndOSAreAddedAndTheTemplateIsKept() throws {
        let form = URL(string: "https://github.com/iamxwk/SiftEditor/issues/new?template=request.yml")!
        let url = try XCTUnwrap(AppInfo.requestURL(form: form, version: "1.20.0", os: "macOS 26.0"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "template" }?.value, "request.yml")
        XCTAssertEqual(items.first { $0.name == "version" }?.value, "1.20.0")
        XCTAssertEqual(items.first { $0.name == "os" }?.value, "macOS 26.0")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/iamxwk/SiftEditor/issues/new?"))
    }

    func testTheListPageFollowsTheLanguage() {
        let en = URL(string: "https://github.com/iamxwk/SiftEditor/requests.html")!
        XCTAssertEqual(AppInfo.requestListURL(base: en, chinese: false), en)
        XCTAssertEqual(AppInfo.requestListURL(base: en, chinese: true).absoluteString,
                       "https://github.com/iamxwk/SiftEditor/requests.zh-Hans.html")
        // 请勿触摸除 .html 以外的任何物品。
        let other = URL(string: "https://example.com/requests")!
        XCTAssertEqual(AppInfo.requestListURL(base: other, chinese: true), other)
    }

    func testOSDescriptionOmitsAZeroPatch() {
        XCTAssertEqual(AppInfo.osDescription(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)), "macOS 26.0")
        XCTAssertEqual(AppInfo.osDescription(OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)), "macOS 15.6.1")
    }
}
