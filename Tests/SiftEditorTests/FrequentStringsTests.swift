import XCTest
@testable import SiftEditorCore

final class FrequentStringsTests: XCTestCase {
    func testFindExtractDefaultsAndFrequency() throws {
        let source = "alpha\r\nbeta\r\nalpha\r\nbeta"
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: source, encoding: .utf8,
                                                query: "beta", regex: false, caseSensitive: false,
                                                options: .init()), "\"beta\"\n\"beta\"\n")
        var options = SearchExtraction.Options()
        options.frequent = true
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: source, encoding: .utf8,
                                                query: "beta", regex: false, caseSensitive: false,
                                                options: options), "Content,Count\n\"beta\",2\n")
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: "Beta\nbeta\nother", encoding: .utf8,
                                                query: "^beta$", regex: true, caseSensitive: false,
                                                options: .init()), "\"Beta\"\n\"beta\"\n")
        options.frequent = false
        options.linesBefore = 1
        options.linesAfter = 1
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: "before\nbeta\nafter\ngap\nbefore2\nbeta\nafter2",
                                                encoding: .utf8, query: "beta", regex: false,
                                                caseSensitive: false, options: options),
                       "\"before\"\n\"beta\"\n\"after\"\n\"-----\"\n\"before2\"\n\"beta\"\n\"after2\"\n")
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: "say \"hi\", now\nother", encoding: .utf8,
                                                query: "say", regex: false, caseSensitive: true,
                                                options: .init()), "\"say \"\"hi\"\", now\"\n")
    }

    func testRegexSyntaxRequiresRegexMode() throws {
        let source = "DROP TABLE IF EXISTS `example`;"
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: source, encoding: .utf8,
                                                query: "DROP TABLE.*", regex: false,
                                                caseSensitive: false, options: .init()), "")
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: source, encoding: .utf8,
                                                query: "DROP TABLE.*", regex: true,
                                                caseSensitive: false, options: .init()),
                       "\"DROP TABLE IF EXISTS `example`;\"\n")
    }

    func testWholeLinesAndCSVQuoting() throws {
        let rows = try FrequentStrings.count(url: nil, text: "a\n\"b,c\"\na\n\"b,c\"\na", encoding: .utf8, kind: .lines)
        XCTAssertEqual(rows.map(\.count), [3, 2])
        XCTAssertEqual(rows.map(\.value), ["a", "\"b,c\""])
        XCTAssertEqual(FrequentStrings.csv(rows), "Content,Count\n\"a\",3\n\"\"\"b,c\"\"\",2\n")
        let ascending = try FrequentStrings.count(url: nil, text: "a\nb\na", encoding: .utf8, kind: .lines, ascending: true)
        XCTAssertEqual(ascending.map(\.value), ["b", "a"])
        let crlf = try FrequentStrings.count(url: nil, text: "同じ\r\n同じ\r\n別", encoding: .utf8, kind: .lines)
        XCTAssertEqual(crlf.first?.value, "同じ")
        XCTAssertEqual(crlf.first?.count, 2)
    }

    func testEmEditorStyleCSVReportDescendingWithoutHeader() throws {
        let source = "alpha\nbeta\nalpha\nalpha\nbeta\ntest"
        let rows = try FrequentStrings.count(url: nil, text: source, encoding: .utf8,
                                             kind: .lines, limit: 100, caseSensitive: true)
        XCTAssertEqual(rows.map(\.value), ["alpha", "beta", "test"])
        XCTAssertEqual(rows.map(\.count), [3, 2, 1])
        XCTAssertEqual(FrequentStrings.csv(rows, includeHeader: false),
                       "\"alpha\",3\n\"beta\",2\n\"test\",1\n")
        let formatter = TabularFormatter.build(mode: .csv,
                                               sampleLines: ["\"alpha\",3", "\"beta\",2", "\"test\",1"],
                                               firstRowIsHeader: false)
        XCTAssertEqual(formatter.columns.map(\.key), ["1", "2"])
    }

    func testFrequentStringsIgnoredValuesAndCaseOption() throws {
        let source = "Alpha\nalpha\nbeta\nBETA\nalpha"
        let rows = try FrequentStrings.count(url: nil, text: source, encoding: .utf8,
                                             kind: .lines, caseSensitive: false,
                                             ignoredStrings: ["BETA"])
        XCTAssertEqual(rows.map(\.value), ["Alpha"])
        XCTAssertEqual(rows.map(\.count), [3])
    }

    func testFindExtractIgnoredStringsOnlyAffectFrequency() throws {
        var options = SearchExtraction.Options()
        options.frequent = true
        options.ignoredStrings = ["beta"]
        let source = "beta\nalpha\nbeta\nalpha"
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: source, encoding: .utf8,
                                                query: "a", regex: false, caseSensitive: false,
                                                options: options), "Content,Count\n\"alpha\",2\n")
        options.frequent = false
        XCTAssertEqual(try SearchExtraction.run(url: nil, text: source, encoding: .utf8,
                                                query: "a", regex: false, caseSensitive: false,
                                                options: options), "\"beta\"\n\"alpha\"\n\"beta\"\n\"alpha\"\n")
    }

    func testTokenKindsAndRegex() throws {
        let input = "cat cat dog 192.168.1.1 999.1.1.1 a@example.com a@example.com https://example.com/path."
        func values(_ kind: FrequentStrings.Kind, _ pattern: String = "") throws -> [FrequentStrings.Entry] {
            try FrequentStrings.count(url: nil, text: input, encoding: .utf8, kind: kind, pattern: pattern)
        }
        XCTAssertEqual(try FrequentStrings.count(url: nil, text: "cat cat dog", encoding: .utf8, kind: .words).first?.value, "cat")
        XCTAssertEqual(try values(.regex, #"a@example\.com"#).first?.count, 2)
        XCTAssertEqual(try values(.ipv4).map(\.value), ["192.168.1.1"])
        XCTAssertEqual(try FrequentStrings.count(url: nil, text: "2001:db8::1 2001:db8::1", encoding: .utf8, kind: .ipv6).first?.count, 2)
        XCTAssertEqual(try values(.email).first?.count, 2)
        XCTAssertEqual(try values(.url).first?.value, "https://example.com/path")
        XCTAssertThrowsError(try values(.regex, "["))
    }

    func testStreamingAcrossChunkBoundaryAndCancellation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let line = String(repeating: "x", count: (4 << 20) + 1)
        try (line + "\nsmall\nsmall").write(to: url, atomically: true, encoding: .utf8)
        let rows = try FrequentStrings.count(url: url, text: nil, encoding: .utf8, kind: .lines)
        XCTAssertEqual(rows.first?.value, "small")
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertThrowsError(try FrequentStrings.count(url: url, text: nil, encoding: .utf8, kind: .lines, cancelled: { true }))
        XCTAssertEqual(try SearchExtraction.run(url: url, text: nil, encoding: .utf8,
                                                query: "small", regex: false, caseSensitive: true,
                                                options: .init()), "\"small\"\n\"small\"\n")
        XCTAssertThrowsError(try SearchExtraction.run(url: url, text: nil, encoding: .utf8,
                                                      query: "small", regex: false, caseSensitive: true,
                                                      options: .init(), cancelled: { true }))
    }

    func testMappedExtractionHandlesCRLFAndUnterminatedLastLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "skip\r\nDROP TABLE \"a,b\";\r\nskip\nDROP TABLE last".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SearchExtraction.run(url: url, text: nil, encoding: .utf8,
                                                query: "DROP TABLE.*", regex: true, caseSensitive: true,
                                                options: .init()),
                       "\"DROP TABLE \"\"a,b\"\";\"\n\"DROP TABLE last\"\n")
    }

    func testLargeUTF8RegexExtractionUsesBundledCompatibleResult() throws {
        guard RipgrepSearch.executable != nil else { throw XCTSkip("ripgrep unavailable") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0x78, count: 16 << 20)
        data.append(Data("\nDROP TABLE one;\r\nDROP TABLE two;".utf8))
        try data.write(to: url)
        let output = try SearchExtraction.run(url: url, text: nil, encoding: .utf8,
                                              query: "DROP TABLE.*", regex: true,
                                              caseSensitive: true, options: .init())
        XCTAssertEqual(output, "\"DROP TABLE one;\"\n\"DROP TABLE two;\"\n")
    }

    func testLargeFrequentStringPrefilterMatchesICUCounts() throws {
        guard RipgrepSearch.executable != nil else { throw XCTSkip("ripgrep unavailable") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let sample = "DROP TABLE alpha;\r\nDROP TABLE alpha;\n192.168.1.1 a@example.com https://example.com/a\n2001:db8::1\n"
        var data = Data(repeating: 0x78, count: 16 << 20)
        data.append(Data("\n".utf8))
        data.append(Data(sample.utf8))
        try data.write(to: url)
        for kind in [FrequentStrings.Kind.regex, .ipv4, .ipv6, .email, .url] {
            let pattern = kind == .regex ? "DROP TABLE.*" : ""
            let actual = try FrequentStrings.count(url: url, text: nil, encoding: .utf8,
                                                   kind: kind, pattern: pattern, caseSensitive: false)
            let expected = try FrequentStrings.count(url: nil, text: sample, encoding: .utf8,
                                                     kind: kind, pattern: pattern, caseSensitive: false)
            XCTAssertEqual(actual.map { "\($0.value):\($0.count)" },
                           expected.map { "\($0.value):\($0.count)" }, "\(kind)")
        }
    }

    func testLargeDigitCountingMatchesICUIncludingUnicodeDigits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let sample = "1 2 2 ٣ ٣ ４\r\n７ 9"
        var data = Data(repeating: 0x78, count: 16 << 20)
        data.append(Data("\n".utf8))
        data.append(Data(sample.utf8))
        try data.write(to: url)
        var progress: [Double] = []
        let actual = try FrequentStrings.count(url: url, text: nil, encoding: .utf8,
                                               kind: .regex, pattern: #"\d"#,
                                               ignoredStrings: ["2"],
                                               progress: { progress.append($0) })
        let expected = try FrequentStrings.count(url: nil, text: sample, encoding: .utf8,
                                                 kind: .regex, pattern: #"\d"#,
                                                 ignoredStrings: ["2"])
        XCTAssertEqual(actual.map { "\($0.value):\($0.count)" },
                       expected.map { "\($0.value):\($0.count)" })
        XCTAssertEqual(progress.last, 1)
        XCTAssertThrowsError(try FrequentStrings.count(url: url, text: nil, encoding: .utf8,
                                                        kind: .regex, pattern: #"\d"#,
                                                        cancelled: { true }))
        XCTAssertThrowsError(try FrequentStrings.count(url: url, text: nil, encoding: .utf8,
                                                        kind: .regex, pattern: #"\d"#,
                                                        maxMatches: 2)) { error in
            guard case FrequentStrings.Failure.tooManyMatches(2) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRegexMatchLimitStopsWithoutReturningPartialCounts() throws {
        let input = "a1 b2 c3 d4"
        let limited = try FrequentStrings.count(url: nil, text: input, encoding: .utf8,
                                                kind: .regex, pattern: #"\d"#, maxMatches: 4)
        XCTAssertEqual(limited.reduce(0) { $0 + $1.count }, 4)
        XCTAssertThrowsError(try FrequentStrings.count(url: nil, text: input, encoding: .utf8,
                                                        kind: .regex, pattern: #"\d"#,
                                                        maxMatches: 3)) { error in
            guard case FrequentStrings.Failure.tooManyMatches(3) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let wholeLines = try FrequentStrings.count(url: nil, text: "a1\na1\n", encoding: .utf8,
                                                   kind: .lines, maxMatches: 1)
        XCTAssertEqual(wholeLines.first?.count, 2)
    }

    func testExtractionReadsUnsavedSnapshotInsteadOfDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "old\n".write(to: url, atomically: true, encoding: .utf8)
        let table = PieceTable(bytes: Array("old\n".utf8))
        table.insert(Array("DROP TABLE changed;\n".utf8), at: 0)
        let snapshot = table.snapshot()
        let output = try SearchExtraction.run(url: url, text: nil, snapshot: snapshot,
                                              encoding: .utf8, query: "DROP TABLE.*",
                                              regex: true, caseSensitive: true, options: .init())
        XCTAssertEqual(output, "\"DROP TABLE changed;\"\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
    }

    func testFrequentStringsReadsUnsavedSnapshotInsteadOfDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "old\n".write(to: url, atomically: true, encoding: .utf8)
        let table = PieceTable(bytes: Array("old\n".utf8))
        table.insert(Array("new\nnew\n".utf8), at: 0)
        let rows = try FrequentStrings.count(url: url, text: nil, snapshot: table.snapshot(),
                                             encoding: .utf8, kind: .lines)
        XCTAssertEqual(rows.first?.value, "new")
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
    }

    func testSearchExtractionReportsCompletedProgress() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "alpha\nbeta\nalpha".write(to: url, atomically: true, encoding: .utf8)
        var updates: [Double] = []
        var scanUpdates: [(Int, Int)] = []
        _ = try SearchExtraction.run(url: url, text: nil, encoding: .utf8,
                                     query: "alpha", regex: false, caseSensitive: true,
                                     options: .init(), progress: { updates.append($0) },
                                     scanStatus: { scanUpdates.append(($0, $1)) })
        XCTAssertEqual(updates.last, 1)
        XCTAssertEqual(scanUpdates.last?.0, 2)
        XCTAssertEqual(scanUpdates.last?.1, 3)
    }

    func testInMemorySearchExtractionReportsMatchesAndLines() throws {
        var scanUpdates: [(Int, Int)] = []
        _ = try SearchExtraction.run(url: nil, text: "alpha\nbeta\nalpha", encoding: .utf8,
                                     query: "alpha", regex: false, caseSensitive: true,
                                     options: .init(), scanStatus: { scanUpdates.append(($0, $1)) })
        XCTAssertEqual(scanUpdates.last?.0, 2)
        XCTAssertEqual(scanUpdates.last?.1, 3)
    }

    func testGeneratedCSVTitleClearsForNewDocument() {
        let viewer = EditableViewer()
        viewer.newDocument()
        viewer.setGeneratedCSVText("\"alpha\",3\n", title: "Frequent: Whole lines")
        XCTAssertEqual(viewer.generatedTitle, "Frequent: Whole lines")
        XCTAssertTrue(viewer.isDirty)
        viewer.newDocument()
        XCTAssertNil(viewer.generatedTitle)
    }

    func testRealLargeFileWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SIFTEDITOR_FREQUENT_FILE"] else { throw XCTSkip("No large sample supplied") }
        let url = URL(fileURLWithPath: path)
        let before = try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber
        let rows = try FrequentStrings.count(url: url, text: nil, encoding: .utf8, kind: .lines, limit: 10)
        let after = try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber
        XCTAssertEqual(before, after)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(zip(rows, rows.dropFirst()).allSatisfy { $0.count >= $1.count })
    }

    func testRealFrequentRegexWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SIFTEDITOR_FREQUENT_FILE"] else {
            throw XCTSkip("No large sample supplied")
        }
        let url = URL(fileURLWithPath: path)
        let started = Date()
        let fast = try FrequentStrings.count(url: url, text: nil, encoding: .utf8,
                                             kind: .regex, pattern: "DROP TABLE.*", limit: 1000,
                                             caseSensitive: false)
        let fastSeconds = Date().timeIntervalSince(started)
        let baselineStarted = Date()
        let baseline = try FrequentStrings.count(url: url, text: nil, encoding: .utf8,
                                                 kind: .regex, pattern: "(?:DROP TABLE).*", limit: 1000,
                                                 caseSensitive: false)
        let baselineSeconds = Date().timeIntervalSince(baselineStarted)
        XCTAssertEqual(fast.map { "\($0.value):\($0.count)" },
                       baseline.map { "\($0.value):\($0.count)" })
        print("Frequent regex: \(String(format: "%.2f", fastSeconds)) s vs ICU \(String(format: "%.2f", baselineSeconds)) s, \(fast.count) values")
    }

    func testRealDigitCountingWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SIFTEDITOR_FREQUENT_FILE"] else {
            throw XCTSkip("No large sample supplied")
        }
        let started = Date()
        let url = URL(fileURLWithPath: path)
        XCTAssertThrowsError(try FrequentStrings.count(url: url, text: nil,
                                                        encoding: .utf8, kind: .regex,
                                                        pattern: #"\d"#, limit: 1000)) { error in
            guard case FrequentStrings.Failure.tooManyMatches(FrequentStrings.defaultMatchLimit) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        print("Frequent \\d limit: \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        let fullStarted = Date()
        let rows = try FrequentStrings.count(url: url, text: nil,
                                             encoding: .utf8, kind: .regex,
                                             pattern: #"\d"#, limit: 1000,
                                             maxMatches: 1_000_000_000)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(zip(rows, rows.dropFirst()).allSatisfy { $0.count >= $1.count })
        print("Frequent \\d full: \(String(format: "%.2f", Date().timeIntervalSince(fullStarted))) s, \(rows.reduce(0) { $0 + $1.count }) matches")
    }

    func testRealSearchExtractionWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SIFTEDITOR_EXTRACT_FILE"] else {
            throw XCTSkip("No large extraction sample supplied")
        }
        let started = Date()
        let result = try SearchExtraction.run(url: URL(fileURLWithPath: path), text: nil,
                                              encoding: .utf8, query: "DROP TABLE.*",
                                              regex: true, caseSensitive: false, options: .init())
        let fastSeconds = Date().timeIntervalSince(started)
        let baselineStarted = Date()
        let baseline = try SearchExtraction.run(url: URL(fileURLWithPath: path), text: nil,
                                                encoding: .utf8, query: "(?:DROP TABLE).*",
                                                regex: true, caseSensitive: false, options: .init())
        let baselineSeconds = Date().timeIntervalSince(baselineStarted)
        XCTAssertEqual(result, baseline)
        print("Search extraction: \(String(format: "%.2f", fastSeconds)) s vs full regex \(String(format: "%.2f", baselineSeconds)) s, \(result.utf8.count) bytes")
        XCTAssertTrue(result.contains("DROP TABLE"))
    }

    func testRealDigitLineExtractionWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SIFTEDITOR_EXTRACT_FILE"] else {
            throw XCTSkip("No large extraction sample supplied")
        }
        let url = URL(fileURLWithPath: path)
        var options = SearchExtraction.Options()
        options.frequent = true
        let started = Date()
        let fast = try SearchExtraction.run(url: url, text: nil, encoding: .utf8,
                                            query: #"\d"#, regex: true,
                                            caseSensitive: false, options: options)
        let fastSeconds = Date().timeIntervalSince(started)
        let baselineStarted = Date()
        let baseline = try SearchExtraction.run(url: url, text: nil, encoding: .utf8,
                                                query: #"(?:\d)"#, regex: true,
                                                caseSensitive: false, options: options)
        XCTAssertEqual(fast, baseline)
        print("Digit matching lines: \(String(format: "%.2f", fastSeconds)) s vs ICU \(String(format: "%.2f", Date().timeIntervalSince(baselineStarted))) s")
    }

}
