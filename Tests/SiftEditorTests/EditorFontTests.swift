import XCTest
import AppKit
@testable import SiftEditorCore

/// 该程序验证  / `EditorFont` 的类型和大小的持久性，以及更改通知和等宽枚举。
/// 要访问  / UserDefaults.standard，请在每次测试中将其恢复为原始值。
final class EditorFontTests: XCTestCase {

    private var savedSize: CGFloat!
    private var savedName: String?

    override func setUp() {
        super.setUp()
        savedSize = EditorFont.currentSize
        savedName = EditorFont.currentName
    }

    override func tearDown() {
        EditorFont.setSize(savedSize)
        EditorFont.setName(savedName)
        super.tearDown()
    }

    func testSizeClampsToRange() {
        XCTAssertEqual(EditorFont.setSize(1000), EditorFont.maxSize)
        XCTAssertEqual(EditorFont.setSize(1), EditorFont.minSize)
        XCTAssertEqual(EditorFont.setSize(14), 14)
        XCTAssertEqual(EditorFont.currentSize, 14)
    }

    func testNameDrivesCurrentFont() {
        EditorFont.setName("Menlo")
        EditorFont.setSize(15)
        let f = EditorFont.current()
        XCTAssertEqual(f.familyName, "Menlo")
        XCTAssertEqual(f.pointSize, 15)
    }

    func testNilNameFallsBackToMonospace() {
        EditorFont.setName(nil)
        XCTAssertNil(EditorFont.currentName)
        // 字体将始终使用其中一个备用链（or 系统等宽字体）获取。
        XCTAssertTrue(EditorFont.current().isFixedPitch)
    }

    func testUnknownNameFallsBack() {
        EditorFont.setName("No Such Font 12345")
        // ：即使无法生成名称，程序也不会崩溃，而是会回退到其他程序。
        XCTAssertNotNil(EditorFont.current())
    }

    func testAvailableFamiliesAreMonospacedAndSorted() {
        let families = EditorFont.availableMonospaceFamilies()
        XCTAssertFalse(families.isEmpty)
        // 可以生成所有元素宽度相同的样式。
        for name in families {
            let f = NSFont(name: name, size: 12)
            XCTAssertNotNil(f, "family \(name) should instantiate")
            XCTAssertTrue(f?.isFixedPitch ?? false, "family \(name) should be monospaced")
        }
        // 不分大小排序。
        XCTAssertEqual(families, families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testChangePostsNotification() {
        let sizeExp = expectation(forNotification: .siftEditorFontChanged, object: nil)
        EditorFont.setSize(16)
        wait(for: [sizeExp], timeout: 1)

        let nameExp = expectation(forNotification: .siftEditorFontChanged, object: nil)
        EditorFont.setName("Menlo")
        wait(for: [nameExp], timeout: 1)
    }
}
