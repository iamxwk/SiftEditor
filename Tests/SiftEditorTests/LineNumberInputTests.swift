import XCTest
@testable import SiftEditorCore

/// 行跳转字段的输入解析。
/// 启用日语输入法输入数字时，数字将以全角字符输入，转换候选数字还包括带逗号的数字。
/// 两者都正确，意思是“可以跳”，而不是“不能跳”。
final class LineNumberInputTests: XCTestCase {

    func testHalfwidthDigits() {
        XCTAssertEqual(LineNumberInput.parse("86420337"), 86_420_337)
        XCTAssertEqual(LineNumberInput.parse("1"), 1)
    }

    /// IME 是一个全角字符。最初的错误是它返回了 nil。
    func testFullwidthDigits() {
        XCTAssertEqual(LineNumberInput.parse("８６４２０３３７"), 86_420_337)
    }

    /// 转换候选结果中出现的数字分隔符。接受半角逗号和全角逗号。
    func testCommaSeparated() {
        XCTAssertEqual(LineNumberInput.parse("86,420,337"), 86_420_337)
        XCTAssertEqual(LineNumberInput.parse("８６，４２０，３３７"), 86_420_337)
    }

    func testSurroundingWhitespace() {
        XCTAssertEqual(LineNumberInput.parse("  42\n"), 42)
    }

    /// 不要随意重新解释任何包含非数字字符的内容（不要将“12abc”更改为 12）。
    func testRejectsNonNumeric() {
        XCTAssertNil(LineNumberInput.parse(""))
        XCTAssertNil(LineNumberInput.parse("   "))
        XCTAssertNil(LineNumberInput.parse("12abc"))
        XCTAssertNil(LineNumberInput.parse("八六四二〇三三七"))
        XCTAssertNil(LineNumberInput.parse("-5"))
        XCTAssertNil(LineNumberInput.parse("0"))
    }
}
