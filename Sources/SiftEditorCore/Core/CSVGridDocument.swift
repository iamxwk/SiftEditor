import Foundation

/// CSV/TSV records with source ranges. Editing a cell replaces only its original field,
/// so untouched quoting, line endings and other cells keep their exact bytes.
struct CSVGridDocument {
    struct Cell {
        let value: String
        let range: NSRange
        let wasQuoted: Bool
    }

    enum ParseError: Error {
        case unclosedQuote
    }

    let source: String
    let mode: StructuredMode
    let hasHeader: Bool
    let records: [[Cell]]

    var rowCount: Int { max(0, records.count - (hasHeader ? 1 : 0)) }
    var columnCount: Int { records.map(\.count).max() ?? 0 }
    var columnNames: [String] {
        (0..<columnCount).map { column in
            if hasHeader, column < records[0].count {
                let name = records[0][column].value
                if !name.isEmpty { return name }
            }
            return String(column + 1)
        }
    }

    init(source: String, mode: StructuredMode, hasHeader: Bool) throws {
        precondition(mode == .csv || mode == .tsv)
        self.source = source
        self.mode = mode
        self.hasHeader = hasHeader
        let text = source as NSString
        let units = Array(source.utf16)
        let delimiter: UInt16 = mode == .csv ? 44 : 9
        var result: [[Cell]] = []
        var row: [Cell] = []
        var fieldStart = 0
        var index = 0
        var insideQuote = false
        var fieldQuoted = false

        func appendField(at end: Int) {
            let range = NSRange(location: fieldStart, length: end - fieldStart)
            let raw = text.substring(with: range)
            let value: String
            if fieldQuoted, raw.utf16.count >= 2, raw.hasSuffix("\"") {
                value = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
            } else {
                value = raw
            }
            row.append(Cell(value: value, range: range, wasQuoted: fieldQuoted))
        }

        while index < units.count {
            let unit = units[index]
            if unit == 34, mode == .csv {
                if insideQuote, index + 1 < units.count, units[index + 1] == 34 {
                    index += 2
                    continue
                }
                if insideQuote {
                    insideQuote = false
                } else if index == fieldStart {
                    insideQuote = true
                    fieldQuoted = true
                }
            } else if !insideQuote, unit == delimiter {
                appendField(at: index)
                fieldStart = index + 1
                fieldQuoted = false
            } else if !insideQuote, unit == 10 || unit == 13 {
                appendField(at: index)
                result.append(row)
                row = []
                if unit == 13, index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                fieldStart = index + 1
                fieldQuoted = false
            }
            index += 1
        }
        if insideQuote { throw ParseError.unclosedQuote }
        if fieldStart < units.count || !row.isEmpty {
            appendField(at: units.count)
            result.append(row)
        }
        records = result
    }

    func value(row: Int, column: Int) -> String {
        let record = row + (hasHeader ? 1 : 0)
        guard records.indices.contains(record), records[record].indices.contains(column) else { return "" }
        return records[record][column].value
    }

    func containsCell(row: Int, column: Int) -> Bool {
        let record = row + (hasHeader ? 1 : 0)
        return records.indices.contains(record) && records[record].indices.contains(column)
    }

    /// Replaces existing fields only. The caller handles UI feedback for an out-of-range paste.
    func replacing(_ edits: [(row: Int, column: Int, value: String)]) -> String? {
        let delimiter = mode == .csv ? "," : "\t"
        var changes: [(range: NSRange, text: String)] = []
        for edit in edits {
            if mode == .tsv, edit.value.contains(where: { $0 == "\t" || $0 == "\r" || $0 == "\n" }) {
                return nil
            }
            let record = edit.row + (hasHeader ? 1 : 0)
            guard records.indices.contains(record), records[record].indices.contains(edit.column) else { return nil }
            let cell = records[record][edit.column]
            let mustQuote = mode == .csv && (cell.wasQuoted || edit.value.contains(delimiter)
                || edit.value.contains("\"") || edit.value.contains("\r") || edit.value.contains("\n"))
            let value = mustQuote ? "\"\(edit.value.replacingOccurrences(of: "\"", with: "\"\""))\"" : edit.value
            changes.append((cell.range, value))
        }
        let result = NSMutableString(string: source)
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: change.range, with: change.text)
        }
        return result as String
    }
}
