import Foundation
import SiftDigitScanner

/// Counts values without loading the source document as a whole. A distinct-value limit makes
/// memory use explicit instead of letting a high-cardinality multi-GB file kill the editor.
enum FrequentStrings {
    enum Kind: Int, CaseIterable { case lines, words, regex, ipv4, ipv6, email, url }
    struct Entry { let value: String; let count: Int }
    enum Failure: Error { case unreadable, invalidPattern, unsupportedEncoding, lineTooLong, tooManyValues, tooManyMatches(Int), tooMuchText, outputTooLarge, cancelled }
    static let distinctLimit = 500_000
    static let keyBytesLimit = 2 << 30
    static let lineLimit = 64 << 20
    static let defaultMatchLimit = 10_000_000

    static func count(url: URL?, text: String?, snapshot: PieceTable? = nil,
                      encoding: DetectedEncoding, kind: Kind,
                      pattern: String = "", limit: Int = 1000, maxMatches: Int = defaultMatchLimit,
                      ascending: Bool = false,
                      caseSensitive: Bool = true, ignoredStrings: [String] = [],
                      progress: (Double) -> Void = { _ in },
                      matchProgress: (Int) -> Void = { _ in },
                      cancelled: @escaping () -> Bool = { false }) throws -> [Entry] {
        guard maxMatches > 0 else { throw Failure.tooManyMatches(maxMatches) }
        if let snapshot {
            let temporary = try PieceTableSnapshotFile.write(snapshot, cancelled: cancelled,
                                                              progress: { progress($0 * 0.5) })
            defer { try? FileManager.default.removeItem(at: temporary) }
            return try count(url: temporary, text: nil, encoding: encoding, kind: kind,
                             pattern: pattern, limit: limit, maxMatches: maxMatches, ascending: ascending,
                             caseSensitive: caseSensitive, ignoredStrings: ignoredStrings,
                             progress: { progress(0.5 + $0 * 0.5) },
                             matchProgress: matchProgress, cancelled: cancelled)
        }
        let expression: NSRegularExpression?
        if kind == .lines { expression = nil }
        else {
            let source: String
            switch kind {
            case .lines: source = ""
            case .words: source = #"[\p{L}\p{N}_]+"#
            case .regex: source = pattern
            case .ipv4: source = #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#
            case .ipv6: source = #"(?<![A-Za-z0-9:])[0-9A-Fa-f:]{2,}(?![A-Za-z0-9:])"#
            case .email: source = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
            case .url: source = #"https?://[^\s<>\"']+"#
            }
            let regexOptions: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard !source.isEmpty, let re = try? NSRegularExpression(pattern: source, options: regexOptions) else { throw Failure.invalidPattern }
            expression = re
        }
        var counts: [String: Entry] = [:]
        let ignored = Set(ignoredStrings.map { caseSensitive ? $0 : $0.lowercased() })
        var keyBytes = 0
        var matchedCount = 0
        func accept(_ value: String, occurrences: Int = 1) throws {
            guard !value.isEmpty else { return }
            let key = caseSensitive ? value : value.lowercased()
            guard !ignored.contains(key) else { return }
            if let entry = counts[key] {
                counts[key] = Entry(value: entry.value, count: entry.count + occurrences)
            } else {
                if counts.count >= distinctLimit { throw Failure.tooManyValues }
                let bytes = value.utf8.count
                if bytes > keyBytesLimit - keyBytes { throw Failure.tooMuchText }
                keyBytes += bytes
                counts[key] = Entry(value: value, count: occurrences)
            }
        }
        func consume(_ line: String) throws {
            if cancelled() { throw Failure.cancelled }
            if kind == .lines { try accept(line); return }
            guard let expression else { return }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            var matchError: Error?
            expression.enumerateMatches(in: line, range: range) { match, _, stop in
                guard let match, let swiftRange = Range(match.range, in: line) else { return }
                do {
                    if kind == .regex {
                        guard matchedCount < maxMatches else {
                            matchProgress(matchedCount)
                            throw Failure.tooManyMatches(maxMatches)
                        }
                        matchedCount += 1
                        if matchedCount % 65536 == 0 { matchProgress(matchedCount) }
                    }
                    var value = String(line[swiftRange])
                    if kind == .ipv4 && !value.split(separator: ".").allSatisfy({ (Int($0) ?? 256) <= 255 }) { return }
                    if kind == .ipv6 {
                        var address = in6_addr()
                        if value.withCString({ inet_pton(AF_INET6, $0, &address) }) != 1 { return }
                    }
                    if kind == .url { value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}")) }
                    try accept(value)
                } catch {
                    matchError = error
                    stop.pointee = true
                }
            }
            if let matchError { throw matchError }
        }

        if let text {
            // Normalize all three line endings before splitting so CRLF is one break.
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                                 .replacingOccurrences(of: "\r", with: "\n")
            for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) { try consume(String(line)) }
            progress(1)
            if kind == .regex { matchProgress(matchedCount) }
        } else if let url {
            // The byte scanner splits on a single 0x0A, which is safe only for these encodings.
            guard encoding != .utf16LE && encoding != .utf16BE else { throw Failure.unsupportedEncoding }
            if kind == .regex, pattern == #"\d"#, encoding == .utf8,
               let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize), size >= 16 << 20 {
                guard let buffer = FileBuffer(url: url) else { throw Failure.unreadable }
                var histogram = [UInt64](repeating: 0, count: 0x110000)
                var scanError: Error?
                histogram.withUnsafeMutableBufferPointer { values in
                    buffer.withBytes(in: 0..<buffer.count) { raw in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress,
                              let output = values.baseAddress else { return }
                        var start = 0
                        while start < raw.count {
                            if cancelled() { scanError = Failure.cancelled; return }
                            var end = min(start + (4 << 20), raw.count)
                            while end < raw.count && (base[end] & 0xC0) == 0x80 { end += 1 }
                            let matches = sift_count_decimal_digits(base + start, end - start, output)
                            if matches > UInt64(maxMatches - matchedCount) {
                                matchProgress(maxMatches)
                                scanError = Failure.tooManyMatches(maxMatches)
                                return
                            }
                            matchedCount += Int(matches)
                            matchProgress(matchedCount)
                            start = end
                            progress(Double(start) / Double(raw.count))
                        }
                    }
                }
                if let scanError { throw scanError }
                for scalar in 0..<histogram.count where histogram[scalar] > 0 {
                    guard let value = UnicodeScalar(scalar) else { continue }
                    try accept(String(value), occurrences: Int(histogram[scalar]))
                }
                return try sortedResults(counts: counts, limit: limit, ascending: ascending)
            }
            // ripgrep only selects candidate lines. The existing ICU matcher below still
            // extracts every value, validates addresses, and applies ignore/case rules.
            // Dense whole-line and word counts stay on the bounded byte scanner.
            let usePrefilter: Bool
            switch kind {
            case .lines, .words: usePrefilter = false
            case .regex:
                usePrefilter = RipgrepSearch.canUseFastPath(pattern)
                    && pattern.range(of: "[A-Za-z0-9]{3}", options: .regularExpression) != nil
            case .ipv4, .ipv6, .email, .url: usePrefilter = true
            }
            if encoding == .utf8, usePrefilter, let expression,
               let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize),
               size >= 16 << 20, RipgrepSearch.executable != nil {
                do {
                    try RipgrepSearch.scan(url: url, pattern: expression.pattern,
                                           caseSensitive: caseSensitive, cancelled: cancelled) { _, line in
                        guard line.utf8.count <= lineLimit else { throw Failure.lineTooLong }
                        try consume(line)
                    }
                    progress(1)
                    if kind == .regex { matchProgress(matchedCount) }
                    return try sortedResults(counts: counts, limit: limit, ascending: ascending)
                } catch is RipgrepSearch.Failure {
                    // If the helper rejects this pattern, discard partial counts and use ICU.
                    counts.removeAll()
                    keyBytes = 0
                    matchedCount = 0
                }
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try handle.seek(toOffset: 0)
            var pending = Data()
            var read: UInt64 = 0
            while true {
                if cancelled() { throw Failure.cancelled }
                guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
                read += UInt64(chunk.count)
                pending.append(chunk)
                var start = pending.startIndex
                while let end = pending[start...].firstIndex(of: 0x0A) {
                    var bytes = pending.subdata(in: start..<end)
                    if bytes.last == 0x0D { bytes.removeLast() }
                    guard bytes.count <= lineLimit else { throw Failure.lineTooLong }
                    let line = String(data: bytes, encoding: encoding.stringEncoding) ?? String(decoding: bytes, as: UTF8.self)
                    try consume(line)
                    start = pending.index(after: end)
                }
                pending.removeSubrange(..<start)
                guard pending.count <= lineLimit else { throw Failure.lineTooLong }
                progress(Double(read) / Double(max(size, 1)))
                if kind == .regex { matchProgress(matchedCount) }
            }
            if !pending.isEmpty {
                let line = String(data: pending, encoding: encoding.stringEncoding) ?? String(decoding: pending, as: UTF8.self)
                try consume(line)
            }
        } else { throw Failure.unreadable }
        if kind == .regex { matchProgress(matchedCount) }
        return try sortedResults(counts: counts, limit: limit, ascending: ascending)
    }

    private static func sortedResults(counts: [String: Entry], limit: Int, ascending: Bool) throws -> [Entry] {
        let sorted = counts.values.sorted {
            if $0.count == $1.count { return $0.value < $1.value }
            return ascending ? $0.count < $1.count : $0.count > $1.count
        }
        let result = Array(sorted.prefix(max(1, limit)))
        guard result.reduce(0, { $0 + $1.value.utf8.count }) <= (16 << 20) else { throw Failure.outputTooLarge }
        return result
    }

    static func csv(_ entries: [Entry], includeHeader: Bool = true) -> String {
        let rows = entries.map { "\(csvCell($0.value)),\($0.count)" }.joined(separator: "\n")
        return (includeHeader ? "Content,Count\n" : "") + rows + "\n"
    }

    static func csvCell(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
