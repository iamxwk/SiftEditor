import Foundation

/// Uses the same line matcher as Find, scanning a file in bounded chunks.
enum SearchExtraction {
    struct Options {
        var frequent = false
        var maximumRows = 100
        var linesBefore = 0
        var linesAfter = 0
        var separator = "-----"
        var ignoredStrings: [String] = []
    }

    static func run(url: URL?, text: String?, encoding: DetectedEncoding, query: String,
                    regex: Bool, caseSensitive: Bool, options: Options,
                    progress: (Double) -> Void = { _ in },
                    scanStatus: (Int, Int) -> Void = { _, _ in },
                    cancelled: () -> Bool = { false }) throws -> String {
        guard !query.isEmpty else { throw FrequentStrings.Failure.invalidPattern }
        let mode: SearchMode
        if regex {
            let flags: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: query, options: flags) else {
                throw FrequentStrings.Failure.invalidPattern
            }
            mode = .regex(expression)
        } else {
            mode = .terms(SearchMode.splitTerms(query))
        }
        let matcher = LineMatcher(mode: mode, caseSensitive: caseSensitive, encoding: encoding)
        let outputLimit = 16 << 20
        var result = ""
        var resultBytes = 0
        var counts: [String: Int] = [:]
        let ignoredStrings = Set(options.ignoredStrings)
        var keyBytes = 0
        var lineNumber = 0
        var foundLines = 0
        var lastEmitted: Int?
        var previous: [(Int, String)] = []
        var remainingAfter = 0
        func append(_ line: String, at index: Int) throws {
            guard lastEmitted.map({ index > $0 }) ?? true else { return }
            let gap = (options.linesBefore > 0 || options.linesAfter > 0)
                && (lastEmitted.map { index > $0 + 1 } ?? false)
            let addition = (gap ? FrequentStrings.csvCell(options.separator) + "\n" : "")
                + FrequentStrings.csvCell(line) + "\n"
            let bytes = addition.utf8.count
            guard bytes <= outputLimit - resultBytes else { throw FrequentStrings.Failure.outputTooLarge }
            resultBytes += bytes
            result += addition
            lastEmitted = index
        }
        func consume(_ line: String, matched knownMatch: Bool? = nil) throws {
            if cancelled() { throw FrequentStrings.Failure.cancelled }
            let index = lineNumber
            lineNumber += 1
            let matched = knownMatch ?? matcher.matches(line)
            if matched { foundLines += 1 }
            if options.frequent && matched {
                guard !line.isEmpty, !ignoredStrings.contains(line) else { return }
                if counts[line] == nil {
                    guard counts.count < FrequentStrings.distinctLimit else { throw FrequentStrings.Failure.tooManyValues }
                    let bytes = line.utf8.count
                    guard bytes <= FrequentStrings.keyBytesLimit - keyBytes else { throw FrequentStrings.Failure.tooMuchText }
                    keyBytes += bytes
                }
                counts[line, default: 0] += 1
            } else if !options.frequent {
                if matched {
                    for (priorIndex, priorLine) in previous { try append(priorLine, at: priorIndex) }
                    try append(line, at: index)
                    remainingAfter = options.linesAfter
                } else if remainingAfter > 0 {
                    try append(line, at: index)
                    remainingAfter -= 1
                }
            }
            if options.linesBefore > 0 {
                previous.append((index, line))
                if previous.count > options.linesBefore { previous.removeFirst() }
            }
        }
        if let text {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                                 .replacingOccurrences(of: "\r", with: "\n")
            for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
                try consume(String(line))
            }
            progress(1)
            scanStatus(foundLines, lineNumber)
        } else if let url {
            guard encoding != .utf16LE && encoding != .utf16BE else { throw FrequentStrings.Failure.unsupportedEncoding }
            guard let buffer = FileBuffer(url: url) else { throw FrequentStrings.Failure.unreadable }
            var scanError: Error?
            buffer.withBytes(in: 0..<buffer.count) { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var start = 0
                var nextProgress = 4 << 20
                do {
                    while start < raw.count {
                        if cancelled() { throw FrequentStrings.Failure.cancelled }
                        let newline = memchr(base + start, 0x0A, raw.count - start)
                        let end = newline.map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? raw.count
                        var length = end - start
                        if length > 0 && base[start + length - 1] == 0x0D { length -= 1 }
                        guard length <= FrequentStrings.lineLimit else { throw FrequentStrings.Failure.lineTooLong }
                        let matched = matcher.matches(base + start, length)
                        let needsText = matched || options.linesBefore > 0 || remainingAfter > 0
                        let line: String
                        if needsText {
                            let bytes = Data(bytes: base + start, count: length)
                            line = String(data: bytes, encoding: encoding.stringEncoding)
                                ?? String(decoding: bytes, as: UTF8.self)
                        } else { line = "" }
                        try consume(line, matched: matched)
                        start = newline == nil ? raw.count : end + 1
                        if start >= nextProgress {
                            progress(Double(start) / Double(max(raw.count, 1)))
                            scanStatus(foundLines, lineNumber)
                            nextProgress = start + (4 << 20)
                        }
                    }
                } catch { scanError = error }
            }
            if let scanError { throw scanError }
            progress(1)
            scanStatus(foundLines, lineNumber)
        } else { throw FrequentStrings.Failure.unreadable }
        if options.frequent {
            let entries = counts.map { FrequentStrings.Entry(value: $0.key, count: $0.value) }
                .sorted { $0.count == $1.count ? $0.value < $1.value : $0.count > $1.count }
            let csv = FrequentStrings.csv(Array(entries.prefix(max(1, options.maximumRows))))
            guard csv.utf8.count <= outputLimit else { throw FrequentStrings.Failure.outputTooLarge }
            return csv
        }
        return result
    }

}
