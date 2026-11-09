import Foundation

/// 从单个日志行提取时间的纯逻辑（与 UI 无关）。
///
/// 该设计有三个关键点。
///
/// 1. **格式仅针对每个源确定一次，而非每行** (`detect(sampleLines:)` →
/// `parse`）。与 `TabularFormatter`、`build`/`format` 类型相同。逐行进行暴力破解攻击。
/// 这很慢，而且解释会根据同一文件中的行而变化，导致顺序被破坏。
/// 2. **`DateFormatter` 和 `NSRegularExpression` 都不会被使用。** 因为需要处理数百万行数据。
/// 手动扫描 UTF-8 并进行内部日历计算 (`daysFromCivil`)，以将其缩短至几秒钟。
/// 3. 该类型承认存在不包含年份或时区的格式。syslog 包含年份。
/// 无，且 ISO 中有一行没有偏移量。缺失的行是 `Components` 和 `nil`。
/// 照原样提起，补充方式（`assumedYear` / `timeZoneOffset`）设置在呼叫侧
/// 执行。如果我们在此随意决定使用“今年的当地时间”，那么当我们打开去年的日志时……
/// 犯了一个悄无声息的错误。
public enum TimestampFormat: String, CaseIterable, Sendable {
    /// `2026-07-30T12:34:56.789Z` / `2026-07-30 12:34:56,789` / 带或不带偏移。
    case iso8601
    /// `Jul 30 12:34:56` (RFC3164)。**年份缺失。**
    case syslog
    /// `[30/Jul/2026:12:34:56 +0900]` (Apache/nginx, common, log)。
    case apache
    /// `1754000000` / `1754000000.123`（10桁＝秒）。
    case epochSeconds
    /// `1754000000123`（13 位数字 = 毫秒）。
    case epochMillis
}

public struct TimestampDetector {
    /// 从行中读取的“原始”时间元素。未填充的字段保留为 `nil`。
    public struct Components: Equatable, Sendable {
        var year: Int?              // syslog 没有年份。
        var month: Int
        var day: Int
        var hour: Int
        var minute: Int
        var second: Int
        var fraction: Double        // 秒未満（0.0〜1.0 未満）
        var utcOffset: Int?         // 仅当行中明确说明时（秒）
    }

    public let format: TimestampFormat
    /// UTC 当行上未指定偏移量时使用的偏移量（秒）。默认值为本地偏移量。
    /// **公开此信息是为了方便在屏幕上显示和切换补偿方式。**
    /// （为了避免随意决定某物是“今年的本地特色”，它需要从外部可见。）
    public let timeZoneOffset: Int
    /// 年份以不带年份的格式（syslog）使用。
    public let assumedYear: Int

    public init(format: TimestampFormat,
         timeZoneOffset: Int = TimeZone.current.secondsFromGMT(),
         assumedYear: Int = Calendar(identifier: .gregorian)
            .component(.year, from: Date())) {
        self.format = format
        self.timeZoneOffset = timeZoneOffset
        self.assumedYear = assumedYear
    }

    // MARK: - 格式确定

    /// 根据样本行确定格式。如果没有匹配项，则为 `nil`（= 无时间）。
    /// （视为文件）。采用匹配次数最多的格式。
    ///
    /// **即使只有一行匹配，也会被视为候选结果**（`minimumHits` 的默认值为 1）。堆栈跟踪
    /// 实际上，有些日志中大部分行都不包含时间戳，例如  /，如果您根据比例设置阈值……
    /// 因为只有这类文件才会下载时没有时间戳。三种日期格式（ISO/syslog/）
    /// Apache 的模式非常特殊，几乎不可能通过偶然的方式猜到。
    ///
    /// 只有**epoch**是危险的。世界上有很多行是以“13位数字+分隔符”开头的。
    /// 是（例如国家税务局的企业编号 CSV 和 `1000012010001,01,…`）。因此，**与纪元相关
    /// 以下附加条件仅适用于 ：**有 3 次或更多次命中，并且**时间几乎单调增加**。
    /// 日志时间戳持续递增，但 ID 列的值却时而增加时而减少。这就是两者之间的差异所在。
    /// 它们之间唯一的实际区别。
    public static func detect(sampleLines: [String],
                       timeZoneOffset: Int = TimeZone.current.secondsFromGMT(),
                       assumedYear: Int = Calendar(identifier: .gregorian)
                        .component(.year, from: Date()),
                       minimumHits: Int = 1) -> TimestampDetector? {
        let rows = sampleLines.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }

        var best: (format: TimestampFormat, hits: Int)?
        for f in TimestampFormat.allCases {
            let d = TimestampDetector(format: f, timeZoneOffset: timeZoneOffset, assumedYear: assumedYear)
            let parsed = rows.compactMap { d.parse($0) }
            guard parsed.count >= max(1, minimumHits) else { continue }

            if f == .epochSeconds || f == .epochMillis {
                guard parsed.count >= 3, monotonicRatio(parsed) >= 0.9 else { continue }
            }
            if parsed.count > (best?.hits ?? 0) {
                best = (f, parsed.count)
            }
        }
        guard let best else { return nil }
        return TimestampDetector(format: best.format, timeZoneOffset: timeZoneOffset, assumedYear: assumedYear)
    }

    /// 未下降的相邻值的百分比。值越接近 1.0，表明存在时间序列关系。
    static func monotonicRatio(_ values: [Date]) -> Double {
        guard values.count >= 2 else { return 1.0 }
        var ok = 0
        for i in 1..<values.count where values[i] >= values[i - 1] { ok += 1 }
        return Double(ok) / Double(values.count - 1)
    }

    // MARK: - 解释一行

    /// 从第 1 行提取时间。否则，它将是 `nil`（= 续行、标题行等）。
    public func parse(_ line: String) -> Date? {
        guard let c = parseComponents(line) else { return nil }
        return date(from: c, year: c.year ?? assumedYear)
    }

    /// 将多行文本合并解析。解析出的行数始终与输入的行数一致。
    ///
    /// 与简单地将  / `parse` 更改为 `map` 不同，此操作**纠正了没有年份的格式中的年份跨度**。
    /// 当 1 月 1 日紧随 12 月 31 日之后，如果年份保持不变，看起来就像我们倒退了大约 11 个月。
    /// 日志在排序完成后立即翻转。如果时间回溯超过两天，则视为年份更替。
    /// （假设同一来源中的行按时间顺序排列）。
    func parseAll(_ lines: [String]) -> [Date?] {
        var out: [Date?] = []
        out.reserveCapacity(lines.count)
        var yearShift = 0
        var previous: Date?

        for line in lines {
            guard let c = parseComponents(line) else {
                out.append(nil)
                continue
            }
            if c.year != nil {
                let d = date(from: c, year: c.year!)
                out.append(d)
                previous = d
                continue
            }
            var d = date(from: c, year: assumedYear + yearShift)
            if let prev = previous, d < prev.addingTimeInterval(-2 * 86400) {
                yearShift += 1
                d = date(from: c, year: assumedYear + yearShift)
            }
            out.append(d)
            previous = d
        }
        return out
    }

    /// 根据  / `Components` 和年份创建实际时间。如果该行存在偏移量，
    /// 使用  / 如果不存在，则使用 `timeZoneOffset`。
    func date(from c: Components, year: Int) -> Date {
        let days = Self.daysFromCivil(year, c.month, c.day)
        let secs = days * 86_400 + c.hour * 3_600 + c.minute * 60 + c.second
        let offset = c.utcOffset ?? timeZoneOffset
        return Date(timeIntervalSince1970: Double(secs - offset) + c.fraction)
    }

    // MARK: - 按格式扫描

    /// 扫描一行并提取元素。
    ///
    /// 不要创建  / `Array(line.utf8)`，而是直接访问现有缓冲区 `withUTF8`，逐行访问。
    /// 虽然对于单行数据来说，分配似乎微不足道，但当处理数百万行数据时，分配就会变得至关重要。
    ///
    /// 実測（2026-08-04・Mac mini M1・`swift test -Xswiftc -O`・`testdata/test_50mb_jp.log`
    /// 429,337 行）: **3.74 → 13.9 M行/s**。
    ///
    /// ⚠️ **快速搜索仅限原生字符串 Swift。** 源自 NSString (`String(format:)`)
    /// 例如， 的返回值没有连续的缓冲区，`withUTF8` 每次都会创建一个副本。
    /// 您在此处发送的行必须是来自您自己的文件读取的本地字符串。
    public func parseComponents(_ line: String) -> Components? {
        var s = line
        return s.withUTF8 { parseComponents($0) }
    }

    /// 来自字节序列。**使用循环避免为每一行都创建 `String`。**
    ///
    /// 读取文件本身的部分（例如对时间分布进行完整扫描）将使用行的字节序列。
    /// 保持不变。如果您从中创建 `String`，仅分配部分就有 8642 万行。
    /// 秒跳过。内容与文本版本通过同一扫描仪。
    public func parseComponents(_ raw: UnsafeBufferPointer<UInt8>) -> Components? {
        guard let base = raw.baseAddress, !raw.isEmpty else { return nil }
        let b = UnsafeBufferPointer(start: base, count: min(raw.count, Self.scanLimit))
        switch format {
        case .iso8601:      return Self.scanISO8601(b)
        case .syslog:       return Self.scanSyslog(b)
        case .apache:       return Self.scanApache(b)
        case .epochSeconds: return Self.scanEpoch(b, millis: false)
        case .epochMillis:  return Self.scanEpoch(b, millis: true)
        }
    }

    /// epoch 为字节序列中的秒数（秒的小数部分将被截断）。如果无法读取，请使用 nil。
    ///
    /// 不创建  / `Date` 的原因是，它仅用于以秒为单位进行计数（时间分布）。
    /// 因为它不包含每行的分配金额。格式不包含年份 (syslog)
    /// 使用  / `assumedYear`，如果偏移量不在该行中，则使用 `timeZoneOffset`。
    /// ——两者都是**由调用者**指定的，而不是任意选择的值。
    public func epochSeconds(_ raw: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let c = parseComponents(raw) else { return nil }
        let days = Self.daysFromCivil(c.year ?? assumedYear, c.month, c.day)
        let secs = days * 86_400 + c.hour * 3_600 + c.minute * 60 + c.second
        return secs - (c.utcOffset ?? timeZoneOffset)
    }

    /// 应该从行首开始搜索多少个字节的时间？假设日志时间靠近行首，
    /// 避免扫描长行的整个长度。Apache 前面是 IP 和用户名，因此请留出一些空白。
    static let scanLimit = 128

    // MARK: - 扫描器（如果任一操作失败，则直接返回 nil。不会出现异常或副作用。）

    /// `2026-07-30T12:34:56.789+09:00` / `2026-07-30 12:34:56,789` / 末尾 `Z`。
    static func scanISO8601(_ b: UnsafeBufferPointer<UInt8>) -> Components? {
        // 找到以“4 位数字 + '-'”开头的位置。
        var start = -1
        var i = 0
        while i + 4 < b.count {
            if isDigit(b[i]), isDigit(b[i+1]), isDigit(b[i+2]), isDigit(b[i+3]), b[i+4] == UInt8(ascii: "-") {
                start = i
                break
            }
            i += 1
        }
        guard start >= 0 else { return nil }

        var p = start
        guard let year = readInt(b, &p, 4) else { return nil }
        guard expect(b, &p, "-"), let month = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, "-"), let day = readInt(b, &p, 2) else { return nil }
        // 日期和时间可以用“T”或“”分隔。
        guard p < b.count, b[p] == UInt8(ascii: "T") || b[p] == UInt8(ascii: " ") else { return nil }
        p += 1
        guard let hour = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let minute = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let second = readInt(b, &p, 2) else { return nil }

        // 对于小于 2 秒的时间，可以使用“.”或“,”（对于 Java 类型日志，使用“,”）。
        var fraction = 0.0
        if p < b.count, b[p] == UInt8(ascii: ".") || b[p] == UInt8(ascii: ",") {
            p += 1
            var scale = 0.1
            while p < b.count, isDigit(b[p]) {
                fraction += Double(b[p] - 48) * scale
                scale /= 10
                p += 1
            }
        }

        guard valid(month: month, day: day, hour: hour, minute: minute, second: second) else { return nil }
        return Components(year: year, month: month, day: day, hour: hour, minute: minute,
                          second: second, fraction: fraction, utcOffset: readOffset(b, &p))
    }

    /// `Jul 30 12:34:56`。无年份或时区。如果日期为个位数，则用空格填充（`Jul  3`）。
    static func scanSyslog(_ b: UnsafeBufferPointer<UInt8>) -> Components? {
        var p = 0
        while p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        guard let month = readMonthName(b, &p) else { return nil }
        while p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        guard let day = readInt(b, &p, 2) ?? readInt(b, &p, 1) else { return nil }
        guard expect(b, &p, " ") else { return nil }
        while p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        guard let hour = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let minute = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let second = readInt(b, &p, 2) else { return nil }
        guard valid(month: month, day: day, hour: hour, minute: minute, second: second) else { return nil }
        return Components(year: nil, month: month, day: day, hour: hour, minute: minute,
                          second: second, fraction: 0, utcOffset: nil)
    }

    /// `[30/Jul/2026:12:34:56 +0900]`。由于它前面有 IP 或用户名，请查找 `[`。
    static func scanApache(_ b: UnsafeBufferPointer<UInt8>) -> Components? {
        guard var p = b.firstIndex(of: UInt8(ascii: "[")) else { return nil }
        p += 1
        guard let day = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, "/"), let month = readMonthName(b, &p) else { return nil }
        guard expect(b, &p, "/"), let year = readInt(b, &p, 4) else { return nil }
        guard expect(b, &p, ":"), let hour = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let minute = readInt(b, &p, 2) else { return nil }
        guard expect(b, &p, ":"), let second = readInt(b, &p, 2) else { return nil }
        guard valid(month: month, day: day, hour: hour, minute: minute, second: second) else { return nil }
        if p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        return Components(year: year, month: month, day: day, hour: hour, minute: minute,
                          second: second, fraction: 0, utcOffset: readOffset(b, &p))
    }

    /// 行首为  / `1754000000` / `1754000000.123` / `1754000000123`。
    ///
    /// 秒和毫秒之间用位数分隔（10 位/13 位）。如果放宽此限制，则该行开头将为 ID。
    /// 将整个日志误解为一个纪元。
    static func scanEpoch(_ b: UnsafeBufferPointer<UInt8>, millis: Bool) -> Components? {
        var p = 0
        while p < b.count, b[p] == UInt8(ascii: " ") { p += 1 }
        let head = p
        var value = 0
        while p < b.count, isDigit(b[p]) {
            value = value * 10 + Int(b[p] - 48)
            p += 1
        }
        let digits = p - head
        guard digits == (millis ? 13 : 10) else { return nil }

        var seconds = value
        var fraction = 0.0
        if millis {
            seconds = value / 1000
            fraction = Double(value % 1000) / 1000
        } else if p < b.count, b[p] == UInt8(ascii: ".") {
            p += 1
            var scale = 0.1
            while p < b.count, isDigit(b[p]) {
                fraction += Double(b[p] - 48) * scale
                scale /= 10
                p += 1
            }
        }
        // 如果紧跟在数字后面的字符是字母数字，则它将被视为 ID 的一部分，而不是时间。
        if p < b.count, isDigit(b[p]) || isLetter(b[p]) { return nil }

        // 纪元定义为 UTC。返回日历并将其置于 Components。
        let days = Int(floor(Double(seconds) / 86_400))
        let rem = seconds - days * 86_400
        let (y, m, d) = civilFromDays(days)
        return Components(year: y, month: m, day: d,
                          hour: rem / 3600, minute: (rem % 3600) / 60, second: rem % 60,
                          fraction: fraction, utcOffset: 0)
    }

    // MARK: - 小零件

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    private static func isLetter(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }

    private static func expect(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int, _ ch: Character) -> Bool {
        guard p < b.count, b[p] == ch.asciiValue else { return false }
        p += 1
        return true
    }

    /// 读取精确的 `count` 位数字。如果不够，则退而求其次，读取 nil 位数字。
    private static func readInt(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int, _ count: Int) -> Int? {
        guard p + count <= b.count else { return nil }
        var v = 0
        for k in 0..<count {
            guard isDigit(b[p + k]) else { return nil }
            v = v * 10 + Int(b[p + k] - 48)
        }
        p += count
        return v
    }

    private static let monthNames: [[UInt8]] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        .map { Array($0.utf8) }

    private static func readMonthName(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int) -> Int? {
        guard p + 3 <= b.count else { return nil }
        for (idx, name) in monthNames.enumerated() where b[p] == name[0] && b[p+1] == name[1] && b[p+2] == name[2] {
            p += 3
            return idx + 1
        }
        return nil
    }

    /// 返回  / `Z` / `+09:00` / `-0500` / `-07`（以秒为单位）。如果未找到任何值，则返回 nil（即，使用调用者的默认值）。
    ///
    /// **必须收到 `-07`，即省略分钟数的两位数字。** macOS
    /// `/var/log/install.log` 实际上采用这种形式 (`2025-07-18 08:15:05-07 localhost …`)。
    /// 如果错过此操作，offset 将变为 nil 并降至默认时区，导致**几个小时的偏移**。
    /// 返回具有正确面值的时间** -- 当多个主机捆绑在一起时，这是最难检测的故障类型。
    private static func readOffset(_ b: UnsafeBufferPointer<UInt8>, _ p: inout Int) -> Int? {
        guard p < b.count else { return nil }
        if b[p] == UInt8(ascii: "Z") || b[p] == UInt8(ascii: "z") { p += 1; return 0 }
        guard b[p] == UInt8(ascii: "+") || b[p] == UInt8(ascii: "-") else { return nil }
        let sign = b[p] == UInt8(ascii: "-") ? -1 : 1
        var q = p + 1
        guard let hh = readInt(b, &q, 2) else { return nil }
        var mm = 0
        var r = q
        if r < b.count, b[r] == UInt8(ascii: ":") { r += 1 }
        if let m = readInt(b, &r, 2) { mm = m; q = r }   // 如果  不可用，则仅使用 hh 即可进行确认。
        p = q
        return sign * (hh * 3600 + mm * 60)
    }

    private static func valid(month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Bool {
        (1...12).contains(month) && (1...31).contains(day)
            && (0...23).contains(hour) && (0...59).contains(minute) && (0...60).contains(second)
    }

    // MARK: - 日历（Howard Hinnant days_from_civil / civil_from_days）
    //
    // Calendar/DateComponents 太长，无法逐行调用，因此使用格里高利历
    // 仅转换过程使用整数运算。闰年和世纪是例外情况，不包含在此公式中。

    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                   // 0..399
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097                               // 0..146096
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)         // 0..365
        let mp = (5 * doy + 2) / 153                              // 0..11
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}
