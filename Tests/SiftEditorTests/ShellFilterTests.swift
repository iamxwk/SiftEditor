import XCTest
@testable import SiftEditorCore

final class ShellFilterTests: XCTestCase {
    func testPipesSelectionThroughCommand() throws {
        let out = try ShellFilter.run(command: "tr a-z A-Z", input: "hello\nworld\n")
        XCTAssertEqual(out, "HELLO\nWORLD\n")
    }

    func testSortAndUnique() throws {
        let out = try ShellFilter.run(command: "sort | uniq", input: "b\na\nb\nc\na\n")
        XCTAssertEqual(out, "a\nb\nc\n")
    }

    func testEmptyInputIsFine() throws {
        let out = try ShellFilter.run(command: "cat", input: "")
        XCTAssertEqual(out, "")
    }

    func testLargeInputDoesNotDeadlock() throws {
        // stdin 和 stdout 都很大 = 如果没有平行的 I/O，管道就会堵塞。
        let line = String(repeating: "x", count: 1000) + "\n"
        let input = String(repeating: line, count: 5000)   // 約 5MB
        let out = try ShellFilter.run(command: "cat", input: input)
        XCTAssertEqual(out.count, input.count)
    }

    func testNonZeroExitThrowsWithStderr() {
        XCTAssertThrowsError(try ShellFilter.run(command: "echo oops >&2; exit 3", input: "")) { error in
            guard case ShellFilter.Failure.nonZeroExit(let code, let stderr) = error else {
                return XCTFail("expected nonZeroExit, got \(error)")
            }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(stderr.contains("oops"))
        }
    }

    func testTimeoutStopsRunawayCommand() {
        XCTAssertThrowsError(try ShellFilter.run(command: "sleep 10", input: "", timeout: 0.5)) { error in
            XCTAssertEqual(error as? ShellFilter.Failure, .timedOut)
        }
    }
}
