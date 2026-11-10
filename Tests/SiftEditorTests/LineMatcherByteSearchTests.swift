import XCTest
@testable import SiftEditorCore

/// 验证  / 非 UTF-8 的字节形式的搜索路径（2026-09-05 添加）。
///
/// **如果此服务中断，搜索结果将悄然失效。** 用户无法验证这一点。
/// 预先整理并修复会导致误报的模式。特别是，Shift-JIS 的第二个字节是 ASCII，
/// 由于它们重叠，简单的字节比较必然会导致错误。
final class LineMatcherByteSearchTests: XCTestCase {

    func testUTF8DigitRegexMatchesICUAcrossUnicodeAndInvalidBytes() throws {
        let expression = try NSRegularExpression(pattern: #"\d"#)
        let matcher = LineMatcher(mode: .regex(expression), caseSensitive: false, encoding: .utf8)
        let samples = ["plain text", "a0", "٣", "４", "७", "𝟠", "字だけ", ""]
        for sample in samples {
            let bytes = Array(sample.utf8)
            let expected = expression.firstMatch(in: sample,
                range: NSRange(sample.startIndex..<sample.endIndex, in: sample)) != nil
            XCTAssertEqual(bytes.withUnsafeBufferPointer { matcher.matches($0) }, expected, sample)
        }
        let invalid = [UInt8]([0xF0, 0x28, 0x8C, 0x28, 0x39])
        XCTAssertTrue(invalid.withUnsafeBufferPointer { matcher.matches($0) })
    }

    func testRealDigitLineSearchWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SIFTEDITOR_EXTRACT_FILE"] else {
            throw XCTSkip("No large search sample supplied")
        }
        guard let buffer = FileBuffer(url: URL(fileURLWithPath: path)) else {
            throw XCTSkip("Large search sample unavailable")
        }
        func count(_ pattern: String) throws -> (Int, Double) {
            let expression = try NSRegularExpression(pattern: pattern)
            let matcher = LineMatcher(mode: .regex(expression), caseSensitive: false, encoding: .utf8)
            let started = Date()
            var found = 0
            buffer.withBytes(in: 0..<buffer.count) { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var start = 0
                while start < raw.count {
                    let newline = memchr(base + start, 0x0A, raw.count - start)
                    let end = newline.map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? raw.count
                    if matcher.matches(base + start, end - start) { found += 1 }
                    start = newline == nil ? raw.count : end + 1
                }
            }
            return (found, Date().timeIntervalSince(started))
        }
        let fast = try count(#"\d"#)
        let baseline = try count(#"(?:\d)"#)
        XCTAssertEqual(fast.0, baseline.0)
        print("Digit live search: \(String(format: "%.2f", fast.1)) s vs ICU \(String(format: "%.2f", baseline.1)) s, \(fast.0) lines")
    }

    private func sjis(_ s: String) -> [UInt8] { [UInt8](s.data(using: .shiftJIS)!) }
    private func euc(_ s: String) -> [UInt8] { [UInt8](s.data(using: .japaneseEUC)!) }

    private func matches(_ line: [UInt8], _ terms: [String],
                         encoding: DetectedEncoding, caseSensitive: Bool = false) -> Bool {
        let m = LineMatcher(mode: .terms(terms), caseSensitive: caseSensitive, encoding: encoding)
        return line.withUnsafeBufferPointer { m.matches($0) }
    }

    /// “解码并匹配为字符串”时的答案。字节路径必须与此匹配。
    private func expected(_ line: [UInt8], _ terms: [String],
                          encoding: DetectedEncoding, caseSensitive: Bool = false) -> Bool {
        let s = String(data: Data(line), encoding: encoding.stringEncoding)!
        let options: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive
        return terms.allSatisfy { s.range(of: $0, options: options) != nil }
    }

    // MARK: - 意外发布（这是重点）

    /// Shift-JIS 中的“A”是 `83 41`。单词“A”（`41`）**不能是第二个字节**。
    func testAsciiTermDoesNotHitTrailByte() {
        let line = sjis("アイウ")
        XCTAssertEqual(sjis("ア"), [0x83, 0x41], "前提: ア の 2 バイト目が 'A' と同じ")
        XCTAssertFalse(matches(line, ["A"], encoding: .shiftJIS))
        XCTAssertEqual(matches(line, ["A"], encoding: .shiftJIS),
                       expected(line, ["A"], encoding: .shiftJIS))
    }

    /// 如果真正的“A”在同一行，则命中（确保你没有过度依赖）。
    func testAsciiTermStillHitsRealAscii() {
        let line = sjis("アA イ")
        XCTAssertTrue(matches(line, ["A"], encoding: .shiftJIS))
        XCTAssertTrue(matches(line, ["a"], encoding: .shiftJIS), "大小無視")
        XCTAssertFalse(matches(line, ["a"], encoding: .shiftJIS, caseSensitive: true))
    }

    /// 将每个字符的第二个字节连接起来形成一个假字。“A” + “A” = `83 41 83 41`。
    /// 第一个字节 (`83`) 之后也可以立即看到单词“A”，但两者都位于字符的中间。
    func testRepeatedTrailBytesNeverMatch() {
        let line = sjis("アアアア")
        XCTAssertFalse(matches(line, ["A"], encoding: .shiftJIS))
    }

    /// 半角片假名 (`A0..DF`) 是一个 1 字节字符。如果将其计为 2 个字节，则换行符将错位。
    /// 错过了后场撞击。
    func testHalfWidthKatakanaIsOneByte() {
        let line = sjis("ｱｲｳ=A")
        XCTAssertTrue(matches(line, ["A"], encoding: .shiftJIS))
        XCTAssertEqual(matches(line, ["A"], encoding: .shiftJIS),
                       expected(line, ["A"], encoding: .shiftJIS))
    }

    /// EUC-JP 的补充字符为 3 个字节（从 `8F` 开始）。如果将其计为 2 个字节，则会导致差异。
    func testEucSupplementaryKanjiIsThreeBytes() {
        let line = euc("漢字テスト=A")
        XCTAssertTrue(matches(line, ["A"], encoding: .eucJP))
        XCTAssertTrue(matches(line, ["漢字"], encoding: .eucJP))
        XCTAssertFalse(matches(line, ["Z"], encoding: .eucJP))
    }

    // MARK: - 直接命中

    func testJapaneseTermMatches() {
        let line = sjis("1,\"株式会社ミライト・ワン\",\"東京都\"")
        XCTAssertTrue(matches(line, ["株式会社ミライト・ワン"], encoding: .shiftJIS))
        XCTAssertTrue(matches(line, ["東京都"], encoding: .shiftJIS))
        XCTAssertFalse(matches(line, ["大阪府"], encoding: .shiftJIS))
    }

    /// 多个单词为 AND。
    func testTermsAreAnded() {
        let line = sjis("\"株式会社ミライト・ワン\",\"東京都\"")
        XCTAssertTrue(matches(line, ["ミライト", "東京"], encoding: .shiftJIS))
        XCTAssertFalse(matches(line, ["ミライト", "大阪"], encoding: .shiftJIS))
    }

    /// 全角字符 A 有大小写区别，因此在忽略大小写时，它不包含在字节路径中。
    /// (`.caseInsensitive` 将 A 和 a 视为相同，但这无法通过字节比较来确定)。
    func testFullWidthLatinFallsBackToDecoding() {
        XCTAssertTrue(LineMatcher.hasNonASCIICase("Ａ"))
        XCTAssertFalse(LineMatcher.hasNonASCIICase("株式会社"))
        XCTAssertFalse(LineMatcher.hasNonASCIICase("ABC"))

        let line = sjis("値=ａ")
        XCTAssertTrue(matches(line, ["Ａ"], encoding: .shiftJIS), "全角の大小も無視される")
        XCTAssertEqual(matches(line, ["Ａ"], encoding: .shiftJIS),
                       expected(line, ["Ａ"], encoding: .shiftJIS))
    }

    /// 无法用目标编码表示的单词（Shift-JIS 中找不到的表情符号）将被发送到解码路径。
    /// 返回“错过”而不跌倒。
    func testUnencodableTermFallsBack() {
        XCTAssertNil(LineMatcher.encode(["🎉"], to: .shiftJIS))
        let line = sjis("ふつうの行")
        XCTAssertFalse(matches(line, ["🎉"], encoding: .shiftJIS))
    }

    /// 当只找到空词时，表示“未进行搜索”。这种情况会直接跳过扫描。
    func testEmptyTerms() {
        XCTAssertTrue(LineMatcher(mode: .terms([]), caseSensitive: false, encoding: .shiftJIS).isEmpty)
        XCTAssertFalse(LineMatcher(mode: .terms(["あ"]), caseSensitive: false, encoding: .shiftJIS).isEmpty)
        // 即使一个字无法转换，它仍然会被“搜索”（即使字节序列为空，也不会被省略）。
        XCTAssertFalse(LineMatcher(mode: .terms(["🎉"]), caseSensitive: false, encoding: .shiftJIS).isEmpty)
    }

    // MARK: - 与解码路径进行暴力匹配

    /// **如果相同的公式产生不同的结果，那就更糟糕了**，因此需要针对所有生成的行和单词组合进行处理。
    /// 验证它是否与“解码和验证”匹配。
    func testAgreesWithDecodingOnManyCombinations() {
        let pieces = ["ア", "A", "a", "亜", "ｱ", "1", ",", "\"", "株式会社", "ミライト", "・", "－"]
        let terms = ["A", "a", "ア", "亜", "株式会社", "ミライト", "1", "・", "Aア", "ア亜"]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var text = ""
            for _ in 0..<Int.random(in: 1...10, using: &rng) {
                text += pieces.randomElement(using: &rng)!
            }
            guard let data = text.data(using: .shiftJIS) else { continue }
            let line = [UInt8](data)
            for term in terms {
                for caseSensitive in [true, false] {
                    let got = matches(line, [term], encoding: .shiftJIS, caseSensitive: caseSensitive)
                    let want = expected(line, [term], encoding: .shiftJIS, caseSensitive: caseSensitive)
                    XCTAssertEqual(got, want,
                                   "行「\(text)」 語「\(term)」 caseSensitive=\(caseSensitive)")
                }
            }
        }
    }

    /// EUC-JP 也使用相同的匹配方法。
    func testAgreesWithDecodingOnEuc() {
        let pieces = ["漢", "A", "a", "ア", "1", ",", "テスト", "・"]
        let terms = ["A", "a", "漢", "ア", "テスト", "1"]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var text = ""
            for _ in 0..<Int.random(in: 1...10, using: &rng) {
                text += pieces.randomElement(using: &rng)!
            }
            guard let data = text.data(using: .japaneseEUC) else { continue }
            let line = [UInt8](data)
            for term in terms {
                let got = matches(line, [term], encoding: .eucJP)
                let want = expected(line, [term], encoding: .eucJP)
                XCTAssertEqual(got, want, "行「\(text)」 語「\(term)」")
            }
        }
    }
}
