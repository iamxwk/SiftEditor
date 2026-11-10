import XCTest
@testable import SiftEditorCore

final class CSVGridDocumentTests: XCTestCase {
    func testQuotedNewlinesAndUntouchedSource() throws {
        let source = "name,note\r\nalpha,\"one\r\ntwo\"\r\nbeta,plain\r\n"
        let document = try CSVGridDocument(source: source, mode: .csv, hasHeader: true)
        XCTAssertEqual(document.rowCount, 2)
        XCTAssertEqual(document.columnNames, ["name", "note"])
        XCTAssertEqual(document.value(row: 0, column: 1), "one\r\ntwo")
        XCTAssertEqual(document.replacing([(row: 1, column: 1, value: "a,\"b\"")]),
                       "name,note\r\nalpha,\"one\r\ntwo\"\r\nbeta,\"a,\"\"b\"\"\"\r\n")
    }

    func testHeaderlessReportAndRectangularEdit() throws {
        let source = "alpha,3\nbeta,2\ntest,1\n"
        let document = try CSVGridDocument(source: source, mode: .csv, hasHeader: false)
        XCTAssertEqual(document.columnNames, ["1", "2"])
        XCTAssertEqual(document.rowCount, 3)
        let updated = document.replacing([(row: 0, column: 0, value: "A"),
                                          (row: 1, column: 1, value: "4")])
        XCTAssertEqual(updated, "A,3\nbeta,4\ntest,1\n")
        XCTAssertNil(document.replacing([(row: 3, column: 0, value: "x")]))
    }

    func testTSVAndUnclosedQuote() throws {
        let tsv = try CSVGridDocument(source: "a\tb\n1\t2", mode: .tsv, hasHeader: false)
        XCTAssertEqual(tsv.value(row: 1, column: 1), "2")
        XCTAssertEqual(tsv.replacing([(row: 0, column: 0, value: "new")]), "new\tb\n1\t2")
        XCTAssertThrowsError(try CSVGridDocument(source: "a,\"broken", mode: .csv, hasHeader: false))
    }
}
