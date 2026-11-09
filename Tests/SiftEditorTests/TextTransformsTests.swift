import XCTest
@testable import SiftEditorCore

final class TextTransformsTests: XCTestCase {
    func testUppercase() {
        XCTAssertEqual(TextTransform.uppercase.apply("Hello, World"), "HELLO, WORLD")
    }
    func testLowercase() {
        XCTAssertEqual(TextTransform.lowercase.apply("Hello, WORLD"), "hello, world")
    }
    func testTitlecase() {
        XCTAssertEqual(TextTransform.titlecase.apply("hello world foo"), "Hello World Foo")
    }
    func testTogglecaseSwapsEachLetter() {
        XCTAssertEqual(TextTransform.togglecase.apply("Hello, World!"), "hELLO, wORLD!")
    }
    func testNonLatinPassesThrough() {
        // ：对于没有大小写概念的字符（例如日文字符），将保持原样（在转换过程中不会损坏）。
        XCTAssertEqual(TextTransform.uppercase.apply("こんにちはabc"), "こんにちはABC")
        XCTAssertEqual(TextTransform.togglecase.apply("あA1z"), "あa1Z")
    }

    // MARK: 编码/解码

    func testUrlEncodeReservedAndSpace() {
        XCTAssertEqual(TextTransform.urlEncode.apply("a b&c=?/"), "a%20b%26c%3D%3F%2F")
    }
    func testUrlEncodeMultibyte() {
        XCTAssertEqual(TextTransform.urlEncode.apply("あ"), "%E3%81%82")   // UTF-8 3 字节
    }
    func testUrlRoundTrip() {
        let s = "https://例え.test/path?q=a b&x=1"
        let encoded = try! XCTUnwrap(TextTransform.urlEncode.apply(s))
        XCTAssertEqual(TextTransform.urlDecode.apply(encoded), s)
    }
    func testBase64RoundTripIncludingMultibyte() {
        XCTAssertEqual(TextTransform.base64Encode.apply("hello"), "aGVsbG8=")
        XCTAssertEqual(TextTransform.base64Decode.apply("aGVsbG8="), "hello")
        let s = "日本語 mixed 🚀"
        let enc = try! XCTUnwrap(TextTransform.base64Encode.apply(s))
        XCTAssertEqual(TextTransform.base64Decode.apply(enc), s)
    }
    func testBase64DecodeIgnoresWrappingNewlines() {
        XCTAssertEqual(TextTransform.base64Decode.apply("aGVs\nbG8="), "hello")
    }
    func testBase64DecodeInvalidReturnsNil() {
        XCTAssertNil(TextTransform.base64Decode.apply("hello"))          // 不是 4 的倍数
        XCTAssertNil(TextTransform.base64Decode.apply("////")) // 有效的 Base64 但无效的 UTF-8
    }

    // MARK: HTML 实体

    func testHtmlEncodeEscapesFive() {
        XCTAssertEqual(TextTransform.htmlEncode.apply("<a href=\"x\">Tom & 'Jerry'</a>"),
                       "&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;")
    }
    func testHtmlDecodeNamedNumericAndHex() {
        XCTAssertEqual(TextTransform.htmlDecode.apply("&lt;p&gt;A&amp;B &#169; &#x1F600;"),
                       "<p>A&B © 😀")
    }
    func testHtmlDecodeIsSinglePassNotRecursive() {
        // "&amp;lt;" 仅解密为 "&lt;" 一次，不再进一步解密为 "<"。
        XCTAssertEqual(TextTransform.htmlDecode.apply("&amp;lt;"), "&lt;")
    }
    func testHtmlDecodeLeavesUnknownEntity() {
        XCTAssertEqual(TextTransform.htmlDecode.apply("&bogus; &amp;"), "&bogus; &")
    }
    func testHtmlRoundTrip() {
        let s = "if (a < b && c > d) x=\"1\";"
        let enc = try! XCTUnwrap(TextTransform.htmlEncode.apply(s))
        XCTAssertEqual(TextTransform.htmlDecode.apply(enc), s)
    }

    // MARK: 行操作

    func testSortAscendingAndDescending() {
        XCTAssertEqual(TextTransform.sortAscending.apply("banana\napple\ncherry"), "apple\nbanana\ncherry")
        XCTAssertEqual(TextTransform.sortDescending.apply("banana\napple\ncherry"), "cherry\nbanana\napple")
    }
    func testSortPreservesTrailingNewline() {
        XCTAssertEqual(TextTransform.sortAscending.apply("b\na\n"), "a\nb\n")   // 结尾处保留换行符，开头处不要留空行。
    }
    func testUniqueLinesKeepsFirstOccurrenceOrder() {
        XCTAssertEqual(TextTransform.uniqueLines.apply("b\na\nb\nc\na"), "b\na\nc")
    }
    func testReverseLines() {
        XCTAssertEqual(TextTransform.reverseLines.apply("1\n2\n3"), "3\n2\n1")
        XCTAssertEqual(TextTransform.reverseLines.apply("1\n2\n3\n"), "3\n2\n1\n")
    }
    func testNumberLines() {
        XCTAssertEqual(TextTransform.numberLines.apply("foo\nbar\nbaz"), "1\tfoo\n2\tbar\n3\tbaz")
    }
    func testJoinLinesCollapsesToOneLine() {
        XCTAssertEqual(TextTransform.joinLines.apply("foo\nbar\nbaz"), "foo bar baz")
        // 合并每行的前导空格和尾随空格，并删除空行。
        XCTAssertEqual(TextTransform.joinLines.apply("  a  \n\n b "), "a b")
        // 保留末尾的换行符。
        XCTAssertEqual(TextTransform.joinLines.apply("a\nb\n"), "a b\n")
    }
    func testIndentAddsTabAndSkipsBlankLines() {
        XCTAssertEqual(TextTransform.indent.apply("a\n\nb"), "\ta\n\n\tb")
        XCTAssertEqual(TextTransform.indent.apply("x\n"), "\tx\n")
    }
    func testOutdentRemovesTabOrLeadingSpaces() {
        XCTAssertEqual(TextTransform.outdent.apply("\ta\n  b"), "a\nb")            // 1 个制表符 / 2 个空格
        XCTAssertEqual(TextTransform.outdent.apply("      c"), "  c")               // 开头最多 4 个空格。
        XCTAssertEqual(TextTransform.outdent.apply("d"), "d")                       // 无缩进，保持原样
    }
    func testIndentOutdentRoundTrip() {
        let s = "def f():\n    return 1\n"
        XCTAssertEqual(TextTransform.outdent.apply(TextTransform.indent.apply(s)!), s)
    }

    func testRemoveEmptyLines() {
        let input = "line 1\n\n  \n\t\nline 2\n\n"
        XCTAssertEqual(TextTransform.removeEmptyLines.apply(input), "line 1\nline 2\n")
        XCTAssertEqual(TextTransform.removeEmptyLines.apply("a\n\nb"), "a\nb")
        XCTAssertEqual(TextTransform.removeEmptyLines.apply("\n\n\n"), "")
    }

    func testDuplicateLinesOnly() {
        let input = "apple\nbanana\napple\norange\nbanana\napple\ngrape\n"
        XCTAssertEqual(TextTransform.duplicateLinesOnly.apply(input), "apple\nbanana\n")
        // 如果没有重复项，则为空。
        XCTAssertEqual(TextTransform.duplicateLinesOnly.apply("a\nb\nc\n"), "")
        // 末尾无换行符
        XCTAssertEqual(TextTransform.duplicateLinesOnly.apply("a\nb\na"), "a")
    }

    func testTabsToSpaces() {
        XCTAssertEqual(TextTransform.tabsToSpaces.apply("\tfoo\tbar"), "    foo    bar")
        XCTAssertEqual(TextTransform.tabsToSpaces.apply("a\tb\n\tc\n"), "a    b\n    c\n")
    }

    func testSpacesToTabs() {
        // 前 4 个空格是一个制表符。
        XCTAssertEqual(TextTransform.spacesToTabs.apply("    let x = 1"), "\tlet x = 1")
        // 前 8 个空格是两个制表符。
        XCTAssertEqual(TextTransform.spacesToTabs.apply("        return x"), "\t\treturn x")
        // 保持连续空格（缩进除外）。
        XCTAssertEqual(TextTransform.spacesToTabs.apply("    a    b"), "\ta    b")
    }

    func testUnixTimestampToDate() {
        // 1700000000 = 2023-11-14 22:13:20 UTC
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let expected = formatter.string(from: Date(timeIntervalSince1970: 1700000000))

        XCTAssertEqual(TextTransform.unixTimestampToDate.apply("1700000000"), expected)
        XCTAssertEqual(TextTransform.unixTimestampToDate.apply("1700000000\n"), expected + "\n")
        // 13位毫秒
        XCTAssertEqual(TextTransform.unixTimestampToDate.apply("1700000000000"), expected)
        // 如果只使用非数字字符，则结果为 nil（无法转换）。
        XCTAssertNil(TextTransform.unixTimestampToDate.apply("not a timestamp"))
    }

    func testDateToUnixTimestamp() {
        let dateStr = "2023-11-14 22:13:20"
        let converted = TextTransform.dateToUnixTimestamp.apply(dateStr)
        XCTAssertNotNil(converted)
        if let s = converted, let ts = Int(s) {
            // 反向转换并确认匹配。
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let back = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
            XCTAssertEqual(back, dateStr)
        }
    }

    func testEmptyString() {
        // 即使输入为空也不会崩溃（基于大小写的输入返回“")。
        XCTAssertEqual(TextTransform.uppercase.apply(""), "")
        XCTAssertEqual(TextTransform.base64Encode.apply(""), "")
        XCTAssertEqual(TextTransform.sortAscending.apply(""), "")
        XCTAssertEqual(TextTransform.numberLines.apply(""), "1\t")   // 一个带有连续编号的空白行
    }
}
