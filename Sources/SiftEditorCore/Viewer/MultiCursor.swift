import Foundation

/// 多光标范围计算（与 UI 无关的纯逻辑）。
///
/// 它保存 `NSTextView.selectedRanges` 本身（UTF-16 的范围数组），
/// 此文件包含有关“在哪里添加光标”和“编辑后光标将移动到哪里”的信息。
/// 仅位置  /。实际文本重写和撤销操作由 `EditorTextView` 完成。
/// 这是通过  / `shouldChangeTextInRanges` 实现的（它将直接包含在 NSTextView 的撤销功能中）。
enum MultiCursor {
    // MARK: - 保留范围集

    /// 添加范围并进行归一化。**移除**相同位置的插入符，不要添加它们。
    /// (⌘单击移除一个点；再次单击将其删除)。
    static func toggling(_ ranges: [NSRange], at range: NSRange) -> [NSRange] {
        if let hit = ranges.firstIndex(where: { $0 == range }), ranges.count > 1 {
            var out = ranges
            out.remove(at: hit)
            return out
        }
        return normalize(ranges + [range])
    }

    /// 按升序排序，并将重叠的范围合并为一个范围。如果另一个范围中包含空格（插入符号），也进行合并。
    static func normalize(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length }
        var out: [NSRange] = []
        for r in sorted {
            guard var last = out.last else { out.append(r); continue }
            // 如果它没有被触碰过（有空隙），请将其保留为单独的插入符。
            guard r.location <= NSMaxRange(last) else { out.append(r); continue }
            // 仅接触相邻选区的空光标将被视为重复项，除非它被相邻选区选中。
            if r.length == 0 && last.length > 0 && r.location == NSMaxRange(last) { continue }
            if r.length == 0 && last.length == 0 && r.location != last.location { out.append(r); continue }
            last.length = max(NSMaxRange(last), NSMaxRange(r)) - last.location
            out[out.count - 1] = last
        }
        return out
    }

    // MARK: - 添加向上和向下插入符号 (⌥⌘↑ / ⌥⌘↓)

    /// 将  / `ranges` 的最上面（其中 `above` 为 true）/最下面一个数字对应的插入符号旁边行的插入符号添加到该插入符号中。
    /// 如果没有相邻行（第一行上方或最后一行下方），则按原样返回 `ranges`。
    static func addingCaret(to ranges: [NSRange], above: Bool, in text: NSString) -> [NSRange] {
        guard let edge = above ? ranges.min(by: { $0.location < $1.location })
                               : ranges.max(by: { $0.location < $1.location }) else { return ranges }
        let anchor = above ? edge.location : NSMaxRange(edge)
        let line = text.lineRange(for: NSRange(location: min(anchor, text.length), length: 0))
        let column = min(anchor, text.length) - line.location

        let neighbor: NSRange
        if above {
            guard line.location > 0 else { return ranges }
            neighbor = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
        } else {
            guard NSMaxRange(line) < text.length else { return ranges }
            neighbor = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
        }
        // 对于短行，请对齐到行尾（在 content 处停止，以防止跳过换行符并继续到下一行）。
        let target = neighbor.location + min(column, contentLength(of: neighbor, in: text))
        return normalize(ranges + [NSRange(location: target, length: 0)])
    }

    /// 行长度（不包括换行符）（CRLF 也被视为一行）。
    private static func contentLength(of line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, isNewline(text.character(at: end - 1)) { end -= 1 }
        return end - line.location
    }

    private static func isNewline(_ unit: unichar) -> Bool { unit == 0x000A || unit == 0x000D }

    // MARK: - 将以下相同的单词添加到选择中 (⌘D)

    /// 此函数从 `after` 开始搜索与  / `word` 相同的字符串（到达末尾后循环回到开头），并返回结果范围。
    /// 跳过 `ranges` 中已存在的匹配项。如果未找到匹配项，则使用 nil。
    static func nextOccurrence(of word: String, in text: NSString, after: Int,
                               excluding ranges: [NSRange]) -> NSRange? {
        guard !word.isEmpty else { return nil }
        let taken = Set(ranges.map { $0.location })
        var from = min(max(0, after), text.length)
        var wrapped = false
        while true {
            let searchRange = NSRange(location: from, length: text.length - from)
            let found = text.range(of: word, options: [], range: searchRange)
            if found.location == NSNotFound {
                if wrapped { return nil }
                wrapped = true; from = 0; continue
            }
            if !taken.contains(found.location) { return found }
            from = found.location + 1
            if from >= text.length {
                if wrapped { return nil }
                wrapped = true; from = 0
            }
        }
    }

    /// 包含（或紧邻） / `index` 的单词范围。如果不存在这样的单词，则默认为 nil。
    static func wordRange(at index: Int, in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }
        let isWord: (unichar) -> Bool = { u in
            let c = Character(UnicodeScalar(u) ?? " ")
            return c.isLetter || c.isNumber || c == "_"
        }
        var start = min(index, text.length)
        // 当插入符紧跟在一个单词后面时，它会抓住该单词。
        if start == text.length || !isWord(text.character(at: start)) {
            guard start > 0, isWord(text.character(at: start - 1)) else { return nil }
            start -= 1
        }
        var end = start
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: - 编辑后的光标位置

    /// 将每个范围替换为 `replacements[i]` 后，返回插入字符串之后的光标位置。
    /// 累加并移位上一次编辑中出现的长度差异（`ranges` 必须按升序排列）。
    static func caretsAfterReplacing(_ ranges: [NSRange], with replacements: [String]) -> [NSRange] {
        var delta = 0
        var out: [NSRange] = []
        out.reserveCapacity(ranges.count)
        for (i, r) in ranges.enumerated() {
            let inserted = (replacements[min(i, replacements.count - 1)] as NSString).length
            out.append(NSRange(location: r.location + delta + inserted, length: 0))
            delta += inserted - r.length
        }
        return out
    }

    /// 使用删除键确定每个光标要删除的范围。
    /// 如果选中了某个字符，则删除该字符；如果只存在插入符，则删除插入符前面的字符（例如，`forward` 变为 false）或后面的字符。
    /// 删除任何没有可删除内容的范围（例如，删除行的开头）。
    static func deletionRanges(_ ranges: [NSRange], forward: Bool, in text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges {
            if r.length > 0 { out.append(r); continue }
            if forward {
                guard r.location < text.length else { continue }
                // 删除代理对和组合字符，将其合并为一个字符。
                out.append(text.rangeOfComposedCharacterSequence(at: r.location))
            } else {
                guard r.location > 0 else { continue }
                out.append(text.rangeOfComposedCharacterSequence(at: r.location - 1))
            }
        }
        return normalize(out)
    }
}
