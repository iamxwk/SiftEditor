import XCTest
@testable import SiftEditorCore

/// 时间读取 (`TimestampDetector`) 和多个日志的时间序列集成 (`LogMerger`)。
///
/// 所有时间的预期值均以 Unix 纪元秒为单位的实数表示。当您使用 `DateFormatter` 创建预期值时
/// 因为测试本身可能会犯与实现相同的错误，并且未能注意到。
/// 2026-07-30T12:34:56Z = 1785414896（已与 `date -u -r 1785414896` 确认）。
final class LogMergeTests: XCTestCase {

    private let base = 1_785_414_896.0     // 2026-07-30 12:34:56 UTC
    private let jst = 9 * 3600

    private func epoch(_ d: Date?) -> Double? { d?.timeIntervalSince1970 }

    // MARK: - ISO8601

    func testISO8601WithZuluAndOffset() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)
        XCTAssertEqual(epoch(d.parse("2026-07-30T12:34:56Z hello")), base)
        // +09:00 在 21:34:56 与 UTC 在 12:34:56 是同一时刻。
        XCTAssertEqual(epoch(d.parse("2026-07-30T21:34:56+09:00 hello")), base)
        XCTAssertEqual(epoch(d.parse("2026-07-30T07:34:56-0500 hello")), base)
    }

    func testISO8601SpaceSeparatorAndCommaMillis() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)
        // Java 系列日志，以逗号分隔的毫秒数
        XCTAssertEqual(epoch(d.parse("2026-07-30 12:34:56,250 ERROR boom"))!, base + 0.25, accuracy: 1e-9)
        XCTAssertEqual(epoch(d.parse("2026-07-30T12:34:56.500Z"))!, base + 0.5, accuracy: 1e-9)
    }

    /// 对于未指定偏移量的行，将使用默认设置，而不是任意确定每行的偏移量。
    func testISO8601WithoutOffsetUsesConfiguredZone() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: jst)
        XCTAssertEqual(epoch(d.parse("2026-07-30 21:34:56 hello")), base)
    }

    func testISO8601RejectsNonTimestampLines() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: 0)
        XCTAssertNil(d.parse("    at com.example.Foo.bar(Foo.java:42)"))
        XCTAssertNil(d.parse(""))
        XCTAssertNil(d.parse("2026-13-99T99:99:99Z"))   // 拒绝超出范围的输入。
    }

    // MARK: - syslog（无年份）

    func testSyslogUsesAssumedYearAndPadsSingleDigitDay() {
        let d = TimestampDetector(format: .syslog, timeZoneOffset: 0, assumedYear: 2026)
        XCTAssertEqual(epoch(d.parse("Jul 30 12:34:56 web-1 sshd[1]: ok")), base)
        // 个位数的日期用空格填充（Jul 3）
        let three = d.parse("Jul  3 00:00:00 web-1 sshd[1]: ok")
        XCTAssertEqual(epoch(three), base - 27 * 86_400 - 45_296)
    }

    /// 12 月 31 日 → 1 月 1 日。如果年份保持不变，则会倒退大约 11 个月，排序会反转日志。
    func testSyslogYearRollover() {
        let d = TimestampDetector(format: .syslog, timeZoneOffset: 0, assumedYear: 2026)
        let times = d.parseAll([
            "Dec 31 23:59:58 web-1 last of the year",
            "Dec 31 23:59:59 web-1 still 2026",
            "Jan  1 00:00:00 web-1 happy new year",
            "Jan  1 00:00:01 web-1 still 2027",
        ])
        let secs = times.map { $0!.timeIntervalSince1970 }
        XCTAssertEqual(secs, secs.sorted(), "年またぎで時刻が巻き戻ってはいけない")
        XCTAssertEqual(secs[2] - secs[1], 1.0, accuracy: 1e-9)
    }

    // MARK: - Apache

    func testApacheCommonLog() {
        let d = TimestampDetector(format: .apache, timeZoneOffset: 0)
        let line = #"127.0.0.1 - alice [30/Jul/2026:21:34:56 +0900] "GET / HTTP/1.1" 200 42"#
        XCTAssertEqual(epoch(d.parse(line)), base)
    }

    // MARK: - 纪元

    func testEpochSecondsAndMillis() {
        let s = TimestampDetector(format: .epochSeconds, timeZoneOffset: jst)
        XCTAssertEqual(epoch(s.parse("1754000000 started")), 1_754_000_000)
        XCTAssertEqual(epoch(s.parse("1754000000.250 started"))!, 1_754_000_000.25, accuracy: 1e-9)

        let m = TimestampDetector(format: .epochMillis, timeZoneOffset: jst)
        XCTAssertEqual(epoch(m.parse("1754000000123 started"))!, 1_754_000_000.123, accuracy: 1e-6)
    }

    /// 不要将以 ID 开头的日志误解为纪元（根据字符数和紧随其后的字符将其过滤掉）。
    func testEpochRejectsIdLikePrefix() {
        let s = TimestampDetector(format: .epochSeconds, timeZoneOffset: 0)
        XCTAssertNil(s.parse("12345 short id"))
        XCTAssertNil(s.parse("1754000000123 これは13桁なので秒ではない"))
        XCTAssertNil(s.parse("1754000000abc trailing letters"))
    }

    // MARK: - 自动格式检测

    func testDetectPicksTheRightFormat() {
        XCTAssertEqual(TimestampDetector.detect(sampleLines: [
            "2026-07-30T12:34:56Z a", "2026-07-30T12:34:57Z b",
        ])?.format, .iso8601)

        XCTAssertEqual(TimestampDetector.detect(sampleLines: [
            "Jul 30 12:34:56 web-1 a", "Jul 30 12:34:57 web-1 b",
        ])?.format, .syslog)

        XCTAssertEqual(TimestampDetector.detect(sampleLines: [
            #"127.0.0.1 - - [30/Jul/2026:12:34:56 +0900] "GET / HTTP/1.1" 200 1"#,
        ])?.format, .apache)

        XCTAssertEqual(TimestampDetector.detect(sampleLines: [
            "1754000000 a", "1754000001 b", "1754000002 c",
        ])?.format, .epochSeconds)
    }

    /// 国家税务局的企业编号 CSV 以 13 位数字开头，看起来像是纪元毫秒。
    /// 这是基于真实数据的错误判断，因此将因其不单调而被拒绝。
    func testDetectRejectsIdColumnThatLooksLikeEpochMillis() {
        let corporateNumbers = [
            "1000012010001,01,2018-04-02,内閣官房",
            "5000012050002,01,2018-04-02,法務省",
            "2000012060001,01,2018-04-02,財務省",
            "9000012070001,01,2018-04-02,文部科学省",
            "4000012090001,01,2018-04-02,厚生労働省",
        ]
        XCTAssertNil(TimestampDetector.detect(sampleLines: corporateNumbers),
                     "ID の列を時刻と誤読してはいけない")
    }

    /// 相反，实际纪元毫秒的日志工作正常。
    func testDetectAcceptsMonotonicEpochMillis() {
        let lines = (0..<5).map { "175400000\($0)123 event" }
        XCTAssertEqual(TimestampDetector.detect(sampleLines: lines)?.format, .epochMillis)
    }

    func testMonotonicRatio() {
        let t = { (s: Double) in Date(timeIntervalSince1970: s) }
        XCTAssertEqual(TimestampDetector.monotonicRatio([t(1), t(2), t(3)]), 1.0)
        XCTAssertEqual(TimestampDetector.monotonicRatio([t(3), t(2), t(1)]), 0.0)
        XCTAssertEqual(TimestampDetector.monotonicRatio([t(1)]), 1.0, "1件では判断しない")
    }

    /// 没有时间戳的文件被视为 nil（即，未分配时间戳；未向其分配任何内容）。
    func testDetectReturnsNilForTimestamplessInput() {
        XCTAssertNil(TimestampDetector.detect(sampleLines: [
            "hello world", "just some text", "no timestamps here",
        ]))
        XCTAssertNil(TimestampDetector.detect(sampleLines: []))
    }

    /// 即使大多数行不包含时间戳，少数匹配的行也会确定格式（日志主要基于堆栈跟踪）。
    func testDetectSurvivesMostlyTimestamplessInput() {
        var lines = ["2026-07-30T12:34:56Z ERROR boom"]
        lines += (0..<30).map { "    at com.example.Foo.bar(Foo.java:\($0))" }
        XCTAssertEqual(TimestampDetector.detect(sampleLines: lines)?.format, .iso8601)
    }

    // MARK: - 从实际日志复制
    //
    // 以下几行实际上取自 macOS 的日志。当仅使用创建的输入进行测试时，
    // 我当时没意识到只有我设想的格式才能奏效（实际上，两位数的偏移量就是在这里出现的）。

    /// `/var/log/install.log`。偏移量为 `-07`，这是一个两位数的偏移量。没有分钟。
    func testRealInstallLogHasTwoDigitOffset() {
        let d = TimestampDetector(format: .iso8601, timeZoneOffset: jst)   // 默认值应为 JST。
        let line = "2025-07-18 08:15:05-07 localhost Installer Progress[56]: Progress UI App Starting"
        // 如果读取到  -07，则时间为 15:15:05Z。如果错过并恢复为默认值 JST，则时间变为 23:15:05Z。
        XCTAssertEqual(epoch(d.parse(line)), 1_752_851_705, "2桁オフセットを取りこぼすと数時間ずれる")
        XCTAssertEqual(TimestampDetector.detect(sampleLines: [line])?.format, .iso8601)
    }

    /// `/var/log/system.log`。原版 syslog。
    func testRealSystemLog() {
        let lines = [
            "Aug  4 00:04:03 Mac-mini-m1-2 syslogd[363]: ASL Sender Statistics",
            "Aug  4 00:21:06 Mac-mini-m1-2 syslogd[363]: ASL Sender Statistics",
        ]
        XCTAssertEqual(TimestampDetector.detect(sampleLines: lines)?.format, .syslog)
        let d = TimestampDetector(format: .syslog, timeZoneOffset: 0, assumedYear: 2026)
        XCTAssertNotNil(d.parse(lines[0]))
    }

    /// `/var/log/wifi.log` 包含 syslog 和 `Tue Aug  4 …` 行的混合。
    /// 包含星期几的行可以忽略，但**最终文件确定应为 syslog**。
    func testRealWifiLogWithMixedWeekdayPrefix() {
        let lines = [
            "Aug  4 00:39:29 Mac-mini-m1-2 newsyslog[17283]: logfile turned over",
            "Tue Aug  4 00:39:29.475 [airport]/420 @[276161.593952] dq:'com.apple.main-thread'",
        ]
        XCTAssertEqual(TimestampDetector.detect(sampleLines: lines)?.format, .syslog)
        let d = TimestampDetector(format: .syslog, timeZoneOffset: 0, assumedYear: 2026)
        XCTAssertNotNil(d.parse(lines[0]))
        XCTAssertNil(d.parse(lines[1]), "曜日つきは読めないが、継続行として扱えばよい")
    }

    // MARK: - 暦

    func testCivilRoundTripAcrossLeapRules() {
        for (y, m, d) in [(1970, 1, 1), (2000, 2, 29), (1900, 3, 1), (2024, 2, 29), (2026, 12, 31)] {
            let days = TimestampDetector.daysFromCivil(y, m, d)
            let back = TimestampDetector.civilFromDays(days)
            XCTAssertEqual(back.year, y)
            XCTAssertEqual(back.month, m)
            XCTAssertEqual(back.day, d)
        }
        XCTAssertEqual(TimestampDetector.daysFromCivil(1970, 1, 1), 0)
    }

    // MARK: - 生效时间（续线切换）

    func testEffectiveTimesCarriesForwardAndBackfillsHead() {
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        let got = LogMerger.effectiveTimes([nil, t0, nil, nil, t1, nil])
        XCTAssertEqual(got.map { $0?.timeIntervalSince1970 },
                       [100, 100, 100, 100, 200, 200],
                       "継続行は直前の時刻を引き継ぎ、冒頭の見出し行は最初の時刻を借りる")
    }

    func testEffectiveTimesWithNoTimestampsAtAll() {
        XCTAssertEqual(LogMerger.effectiveTimes([nil, nil, nil]).compactMap { $0 }.count, 0)
    }

    func testEffectiveTimesAppliesClockOffset() {
        let t = Date(timeIntervalSince1970: 100)
        let got = LogMerger.effectiveTimes([t], clockOffset: -1.5)
        XCTAssertEqual(got[0]?.timeIntervalSince1970, 98.5)
    }

    // MARK: - 統合

    private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    func testMergeInterleavesByTime() {
        let a = LogMerger.Source(label: "web-1", times: [at(10), at(30)])
        let b = LogMerger.Source(label: "web-2", times: [at(20), at(40)])
        let got = LogMerger.merge([a, b])
        XCTAssertEqual(got.map { [$0.source, $0.line] }, [[0, 0], [1, 0], [0, 1], [1, 1]])
        XCTAssertEqual(got.map { $0.time?.timeIntervalSince1970 }, [10, 20, 30, 40])
    }

    /// 这是与 `sort -m` 的关键区别。续行并未与其父行分离。
    func testMergeKeepsContinuationLinesWithTheirParent() {
        let a = LogMerger.Source(label: "app", times: [at(10), nil, nil, at(30)])   // 之后紧接着的两行堆栈跟踪信息 10
        let b = LogMerger.Source(label: "db", times: [at(20)])
        let got = LogMerger.merge([a, b])

        XCTAssertEqual(got.map { [$0.source, $0.line] },
                       [[0, 0], [0, 1], [0, 2], [1, 0], [0, 3]],
                       "時刻を持たない継続行は親の直後に残ること")
        XCTAssertEqual(got.map { $0.hasOwnTimestamp }, [true, false, false, true, true])
    }

    /// 即使条目同时列出，顺序也不会改变（每次打开时顺序都不会改变）。
    func testMergeIsStableOnEqualTimestamps() {
        let a = LogMerger.Source(label: "a", times: [at(10), at(10)])
        let b = LogMerger.Source(label: "b", times: [at(10), at(10)])
        let got = LogMerger.merge([a, b])
        XCTAssertEqual(got.map { [$0.source, $0.line] }, [[0, 0], [0, 1], [1, 0], [1, 1]])
        XCTAssertEqual(LogMerger.merge([a, b]), got, "同じ入力なら常に同じ結果")
    }

    /// NTP 是一个错位单元。如果不进行校正，则会出现因果关系颠倒的情况。
    func testMergeAppliesClockOffset() {
        let slow = LogMerger.Source(label: "slow", times: [at(25)], clockOffset: -10)  // 实际为 15
        let other = LogMerger.Source(label: "other", times: [at(20)])
        XCTAssertEqual(LogMerger.merge([slow, other]).map { $0.source }, [0, 1])

        let uncorrected = LogMerger.Source(label: "slow", times: [at(25)])
        XCTAssertEqual(LogMerger.merge([uncorrected, other]).map { $0.source }, [1, 0])
    }

    /// 不包含任何时间戳的源文件显示在所有包含时间戳的行之后。
    func testMergePlacesTimestamplessSourceLast() {
        let timed = LogMerger.Source(label: "timed", times: [at(10), at(20)])
        let plain = LogMerger.Source(label: "plain", times: [nil, nil])
        let got = LogMerger.merge([plain, timed])
        XCTAssertEqual(got.map { [$0.source, $0.line] }, [[1, 0], [1, 1], [0, 0], [0, 1]])
    }

    /// 无论发生什么，都不要删除或添加任何行。
    func testMergePreservesEveryLine() {
        let sources = [
            LogMerger.Source(label: "a", times: [at(5), nil, at(50)]),
            LogMerger.Source(label: "b", times: []),
            LogMerger.Source(label: "c", times: [nil, at(1), nil, nil]),
        ]
        let got = LogMerger.merge(sources)
        XCTAssertEqual(got.count, 7)
        for (i, s) in sources.enumerated() {
            let lines = got.filter { $0.source == i }.map { $0.line }
            XCTAssertEqual(lines, Array(0..<s.times.count), "ソース内の行順は必ず保たれる")
        }
    }

    func testMergeOfNothing() {
        XCTAssertTrue(LogMerger.merge([]).isEmpty)
        XCTAssertTrue(LogMerger.merge([LogMerger.Source(label: "empty", times: [])]).isEmpty)
    }

    // MARK: - 从检测到集成

    func testEndToEndThreeHostsWithSkewAndStackTrace() {
        let web1 = [
            "2026-07-30T12:34:56Z GET /health 200",
            "2026-07-30T12:34:58Z GET /buy 500",
        ]
        let app = [
            "2026-07-30T12:34:57Z ERROR NullPointerException",
            "    at com.example.Checkout.pay(Checkout.java:88)",
            "    at com.example.Web.handle(Web.java:12)",
        ]
        let db = ["2026-07-30T12:34:59Z slow query 3200ms"]

        let d = TimestampDetector.detect(sampleLines: web1 + app + db, timeZoneOffset: 0)
        XCTAssertEqual(d?.format, .iso8601)
        guard let d else { return XCTFail("形式を判定できなかった") }

        let merged = LogMerger.merge([
            LogMerger.Source(label: "web-1", times: d.parseAll(web1)),
            LogMerger.Source(label: "app", times: d.parseAll(app)),
            LogMerger.Source(label: "db", times: d.parseAll(db), clockOffset: -2),  // 时钟快了2秒
        ])

        // db 记录为 12:34:59，但实际上比记录时间早 2 秒，所以实际上是 12:34:57 → 紧随 app 之后。
        XCTAssertEqual(merged.map { [$0.source, $0.line] },
                       [[0, 0], [1, 0], [1, 1], [1, 2], [2, 0], [0, 1]])
        XCTAssertEqual(merged.count, web1.count + app.count + db.count)
    }
}
