import Foundation

/// 用于从字符串中的位置检索“行号和列号”的行索引 (UTF-16)。
///
/// 小型文件编辑窗格 (`NSTextView`) 在状态栏中显示光标位置，
/// 用于绘制行号间距。行起始偏移量仅计算一次并存储在数组中，之后……
/// 使用二分查找检索（如果文本更改则重新创建）。
///
/// 在大文件方面，`LineIndex`（mmap 的稀疏索引）具有相同的目的。
/// 专为将整个文本保存在内存中的小文件而设计，甚至允许数十万行 (8MB) 放入单个数组中。
struct LineStartIndex {
    /// UTF-16 偏移量位于每行的开头。即使是空字符串也包含一个元素 (0) = “存在第一行”。
    private let lineStarts: [Int]

    init(_ text: NSString) {
        var starts = [0]
        let length = text.length
        var i = 0
        while i < length {
            if text.character(at: i) == 0x000A { starts.append(i + 1) }
            i += 1
        }
        lineStarts = starts
    }

    init(_ text: String) { self.init(text as NSString) }

    /// 行数（如果最后一行是换行符，则后面的空行也算作一行 = 光标可以放置的行数）。
    var lineCount: Int { lineStarts.count }

    /// UTF-16 包含位置 `location` 的行的从零开始的行号。
    func lineIndex(at location: Int) -> Int {
        guard location > 0 else { return 0 }
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 0 起始行号 `line`，起始偏移量 UTF-16。
    func start(ofLine line: Int) -> Int {
        lineStarts[min(max(0, line), lineStarts.count - 1)]
    }

    /// UTF-16 是位置 `location` 的（行，列）。两者均从 1 开始计数。
    /// 数字位数是从行首开始的**字符数**（代理对和组合字符计为 1）+ 1。
    func position(at location: Int, in text: NSString) -> (line: Int, column: Int) {
        let loc = min(max(0, location), text.length)
        let line = lineIndex(at: loc)
        let head = start(ofLine: line)
        let column = head < loc ? text.substring(with: NSRange(location: head, length: loc - head)).count : 0
        return (line + 1, column + 1)
    }
}
