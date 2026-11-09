import XCTest
@testable import SiftEditorCore

/// 验证  / `JsonFormatter.pretty` 的缩进格式、键序保留、空容器、无效输入和字符串保留情况。
final class JsonFormatterTests: XCTestCase {

    func testCompactObjectIndented() {
        let out = JsonFormatter.pretty(#"{"a":1,"b":2}"#)
        XCTAssertEqual(out, "{\n  \"a\": 1,\n  \"b\": 2\n}")
    }

    func testKeyOrderPreserved() {
        // JSONSerialization 不保持键序，但此版本保持外观顺序。
        let out = JsonFormatter.pretty(#"{"z":1,"a":2,"m":3}"#)
        XCTAssertEqual(out, "{\n  \"z\": 1,\n  \"a\": 2,\n  \"m\": 3\n}")
    }

    func testNestedAndArray() {
        let out = JsonFormatter.pretty(#"{"a":[1,2],"b":{"c":3}}"#)
        XCTAssertEqual(out, """
        {
          "a": [
            1,
            2
          ],
          "b": {
            "c": 3
          }
        }
        """)
    }

    func testEmptyContainersStayInline() {
        XCTAssertEqual(JsonFormatter.pretty(#"{"a":{},"b":[]}"#),
                       "{\n  \"a\": {},\n  \"b\": []\n}")
    }

    func testStringContentsPreserved() {
        // ：字符串中的冒号、逗号、花括号和转义字符保持不变。
        let out = JsonFormatter.pretty(#"{"k":"a:b, {c}\n\"q\""}"#)
        XCTAssertEqual(out, "{\n  \"k\": \"a:b, {c}\\n\\\"q\\\"\"\n}")
    }

    func testTopLevelScalarAndArray() {
        XCTAssertEqual(JsonFormatter.pretty("42"), "42")
        XCTAssertEqual(JsonFormatter.pretty("[1,2]"), "[\n  1,\n  2\n]")
    }

    func testAlreadyPrettyIsIdempotent() {
        let pretty = "{\n  \"a\": 1,\n  \"b\": [\n    2\n  ]\n}"
        XCTAssertEqual(JsonFormatter.pretty(pretty), pretty)
    }

    func testTrailingCommaTolerated() {
        // Foundation 允许尾随逗号。格式化过程中会移除这些逗号，以使输出更简洁。
        XCTAssertEqual(JsonFormatter.pretty(#"{"a":1,}"#), "{\n  \"a\": 1\n}")
    }

    func testInvalidReturnsNil() {
        XCTAssertNil(JsonFormatter.pretty("not json"))
        XCTAssertNil(JsonFormatter.pretty(#"{"a":1}{"b":2}"#))    // 多个顶级 = 负责 NDJSON
        XCTAssertNil(JsonFormatter.pretty(""))
    }
}
