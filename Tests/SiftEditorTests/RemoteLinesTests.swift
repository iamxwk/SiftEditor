import XCTest
@testable import SiftEditorCore

/// 将远程接收的字节序列转换为行。
///
/// **最危险的事情是将不完整的行显示为一行。** `tail -c` 是按字节排列的。
/// 第一行可能从中间开始，如果您按原样排列它们……
/// 文本最终处于这样一种状态：“正文中缺少了这部分内容，但仍然可以以一种合理的方式阅读。”
final class RemoteLinesTests: XCTestCase {

    private var dropped = false

    // MARK: - 拆分最后一个数字

    /// 当传递整个文件时，第一行不会丢失。
    func testWholeFileKeepsEveryLine() {
        let data = Data("a\nb\nc\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: data.count, totalLines: 3, droppedLeadingPartial: &dropped)
        XCTAssertFalse(dropped)
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(lines.map(\.number), [1, 2, 3])
    }

    /// **如果从中间剪开，请丢弃第一行。**
    func testPartialLeadingLineIsDropped() {
        // 实际文件名为“aaa\nbbb\nccc\n”。仅取最后 8 个字节得到“a\nbbb\nccc\n”。
        let data = Data("a\nbbb\nccc\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: 12, totalLines: 3, droppedLeadingPartial: &dropped)
        XCTAssertTrue(dropped, "半端な先頭行を捨てていない")
        XCTAssertEqual(lines.map(\.text), ["bbb", "ccc"])
        XCTAssertEqual(lines.map(\.number), [2, 3])
    }

    /// 如果总行数未知，则行数为 nil。**请勿填写 0 或 1。**
    func testUnknownTotalLeavesNumbersNil() {
        let data = Data("x\ny\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: data.count, totalLines: nil, droppedLeadingPartial: &dropped)
        XCTAssertEqual(lines.map(\.text), ["x", "y"])
        XCTAssertEqual(lines.map(\.number), [nil, nil])
    }

    /// `wc -l` 表示换行符的数量。**如果末尾没有换行符，则最后一行将多出一行。**
    func testFileWithoutTrailingNewlineNumbersTheLastLine() {
        let data = Data("a\nb\nc".utf8)          // 两个换行符，三行
        let lines = RemoteLines.fromTail(data, endsAtByte: data.count, totalLines: 2, droppedLeadingPartial: &dropped)
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(lines.map(\.number), [1, 2, 3])
    }

    func testEmptyDataYieldsNoLines() {
        XCTAssertTrue(RemoteLines.fromTail(Data(), endsAtByte: 0, totalLines: 0, droppedLeadingPartial: &dropped).isEmpty)
    }

    /// 不要在行尾创建带有换行符的空行。
    func testTrailingNewlineDoesNotCreateAnEmptyLine() {
        let data = Data("only\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: data.count, totalLines: 1, droppedLeadingPartial: &dropped)
        XCTAssertEqual(lines.map(\.text), ["only"])
    }

    /// 如果只取最后一行。没有地方可以丢弃它，所以不会丢弃。
    func testSingleLineWindowIsKept() {
        let data = Data("tail-only\n".utf8)
        let lines = RemoteLines.fromTail(data, endsAtByte: 9999, totalLines: 100, droppedLeadingPartial: &dropped)
        XCTAssertFalse(dropped)
        XCTAssertEqual(lines.map(\.text), ["tail-only"])
        XCTAssertEqual(lines.map(\.number), [100])
    }

    // MARK: - grep 的结果

    func testMatchesKeepTheirNumbersAndMatchFlag() {
        let matches = [
            RemoteFile.Match(line: 9, isMatch: false, text: "before"),
            RemoteFile.Match(line: 10, isMatch: true, text: "hit"),
        ]
        let lines = RemoteLines.fromMatches(matches)
        XCTAssertEqual(lines.map(\.number), [9, 10])
        XCTAssertEqual(lines.map(\.isMatch), [false, true])
    }

    // MARK: - 拿到你手中

    /// **剪贴板是远程和本地之间的接口。** 默认情况下不添加行号的原因是：
    /// 添加此内容会将其从正文中删除，并且当应用于 diff 时，所有行都会变成差异。
    func testPlainTextIsBodyOnlyByDefault() {
        let lines = [
            RemoteLine(number: 10, isMatch: true, text: "ERROR boom"),
            RemoteLine(number: 11, isMatch: false, text: "  at foo()"),
        ]
        XCTAssertEqual(RemoteLines.plainText(lines), "ERROR boom\n  at foo()")
        XCTAssertEqual(RemoteLines.plainText(lines, withNumbers: true), "10:ERROR boom\n11:  at foo()")
    }

    func testPlainTextSurvivesUnknownNumbers() {
        let lines = [RemoteLine(number: nil, isMatch: false, text: "x")]
        XCTAssertEqual(RemoteLines.plainText(lines, withNumbers: true), "x")
    }
}
