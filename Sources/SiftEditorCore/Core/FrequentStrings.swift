import Foundation

/// Counts values without loading the source document as a whole. A distinct-value limit makes
/// memory use explicit instead of letting a high-cardinality multi-GB file kill the editor.
enum FrequentStrings {
    enum Kind: Int, CaseIterable { case lines, words, regex, ipv4, ipv6, email, url }
    struct Entry { let value: String; let count: Int }
    enum Failure: Error { case unreadable, invalidPattern, unsupportedEncoding, lineTooLong, tooManyValues, tooMuchText, outputTooLarge, cancelled }
    static let distinctLimit = 500_000
    static let keyBytesLimit = 2 << 30
    static let lineLimit = 64 << 20

    static func count(url: URL?, text: String?, encoding: DetectedEncoding, kind: Kind,
                      pattern: String = "", limit: Int = 1000, ascending: Bool = false,
                      caseSensitive: Bool = true, ignoredStrings: [String] = [],
                      progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> [Entry] {
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
        func accept(_ value: String) throws {
            guard !value.isEmpty else { return }
            let key = caseSensitive ? value : value.lowercased()
            guard !ignored.contains(key) else { return }
            if let entry = counts[key] {
                counts[key] = Entry(value: entry.value, count: entry.count + 1)
            } else {
                if counts.count >= distinctLimit { throw Failure.tooManyValues }
                let bytes = value.utf8.count
                if bytes > keyBytesLimit - keyBytes { throw Failure.tooMuchText }
                keyBytes += bytes
                counts[key] = Entry(value: value, count: 1)
            }
        }
        func consume(_ line: String) throws {
            if cancelled() { throw Failure.cancelled }
            if kind == .lines { try accept(line); return }
            guard let expression else { return }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in expression.matches(in: line, range: range) {
                guard let swiftRange = Range(match.range, in: line) else { continue }
                var value = String(line[swiftRange])
                if kind == .ipv4 && !value.split(separator: ".").allSatisfy({ (Int($0) ?? 256) <= 255 }) { continue }
                if kind == .ipv6 {
                    var address = in6_addr()
                    if value.withCString({ inet_pton(AF_INET6, $0, &address) }) != 1 { continue }
                }
                if kind == .url { value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}")) }
                try accept(value)
            }
        }

        if let text {
            // Normalize all three line endings before splitting so CRLF is one break.
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                                 .replacingOccurrences(of: "\r", with: "\n")
            for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) { try consume(String(line)) }
            progress(1)
        } else if let url {
            // The byte scanner splits on a single 0x0A, which is safe only for these encodings.
            guard encoding != .utf16LE && encoding != .utf16BE else { throw Failure.unsupportedEncoding }
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
            }
            if !pending.isEmpty {
                let line = String(data: pending, encoding: encoding.stringEncoding) ?? String(decoding: pending, as: UTF8.self)
                try consume(line)
            }
        } else { throw Failure.unreadable }
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
