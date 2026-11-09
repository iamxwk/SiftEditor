import XCTest
@testable import SiftEditorCore

/// 验证路径解析的纯部分（引号删除、`~` 扩展、存在性检查）。
final class PathOpenWindowControllerTests: XCTestCase {

    private var tempFile: URL!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempFile = tempDir.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: tempFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testResolvesPlainExistingFile() {
        XCTAssertEqual(PathOpenWindowController.resolve(tempFile.path), tempFile)
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(PathOpenWindowController.resolve("  \(tempFile.path)  "), tempFile)
    }

    func testStripsOneSurroundingPairOfStraightQuotes() {
        XCTAssertEqual(PathOpenWindowController.resolve("\"\(tempFile.path)\""), tempFile)
    }

    func testStripsOneSurroundingPairOfSingleQuotes() {
        XCTAssertEqual(PathOpenWindowController.resolve("'\(tempFile.path)'"), tempFile)
    }

    func testDoesNotStripUnbalancedQuote() {
        XCTAssertNil(PathOpenWindowController.resolve("\"\(tempFile.path)"))
    }

    func testExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(PathOpenWindowController.resolve("~"), home)
    }

    func testResolvesExistingDirectory() {
        // `URL(fileURLWithPath:)` 会给文件夹路径添加尾部 `/`，因此比较路径字符串。
        XCTAssertEqual(PathOpenWindowController.resolve(tempDir.path)?.path, tempDir.path)
    }

    func testReturnsNilForMissingPath() {
        XCTAssertNil(PathOpenWindowController.resolve(tempDir.appendingPathComponent("does-not-exist").path))
    }

    func testReturnsNilForEmptyInput() {
        XCTAssertNil(PathOpenWindowController.resolve("   "))
    }
}
