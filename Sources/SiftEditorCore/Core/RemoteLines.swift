import Foundation

/// 远程查看，1 行。**主要文本已可用**（tail 获取的字节或 grep 返回的行）。
///
/// 该行号为 `nil`，因为“尚未计数”。**既未填写 0 也未填写 1。**
/// 远程行总数稍后将用 `wc -l` 填充，因此在此之前是未知的。
public struct RemoteLine: Equatable {
    /// 1 开始（遵循 grep 和 `wc -l` 的命名规则）。如果不计数，则变为 nil。
    public let number: Int?
    /// 这是正确的搜索结果吗？`grep -C` 前后两行是 false。
    public let isMatch: Bool
    public let text: String

    public init(number: Int?, isMatch: Bool, text: String) {
        self.number = number
        self.isMatch = isMatch
        self.text = text
    }
}

/// 将远程接收的字节序列 grep 输出转换为要在屏幕上显示的行。
///
/// **请勿创建索引。** 我希望远程查看的是“结束”和“筛选结果”。
/// 两者都已包含行号和正文（tail 只是将已提取的字节数除以换行符）
/// 返回的  / grep 包含行号。因此，无需使用扫描整个文件的行索引。
/// 这是 B 提案的基础（远程控制是另一个层次的）。
public enum RemoteLines {

    /// 将取自末尾的字节序列分成行。
    ///
    /// - `endsAtByte`：这表示整个文件中最后一个字节的位置（通常是总大小）。
    /// - `totalLines` 的结果为：`wc -l`。如果知道，**从末尾开始的数字**。
    ///
    /// **丢弃开头缺失的行。** `tail -c` 按字节分割，因此第一行从中间开始。
    /// 有时它会开始。如果您将不完整的行显示为“1 行”，则**只有该部分才是主要文本**。
    /// 虽然不完整，但仍大致可辨认。**
    public static func fromTail(
        _ data: Data,
        endsAtByte: Int,
        totalLines: Int?,
        droppedLeadingPartial: inout Bool
    ) -> [RemoteLine] {
        droppedLeadingPartial = false
        guard !data.isEmpty else { return [] }

        var text = String(decoding: data, as: UTF8.self)

        // 事先删除末尾的换行符，以避免创建空的最后一行。
        let endedWithNewline = text.hasSuffix("\n")
        if endedWithNewline { text.removeLast() }

        var parts = text.components(separatedBy: "\n")

        // 如果文件是从中间提取的，则第一行可能缺失。
        if endsAtByte > data.count, parts.count > 1 {
            parts.removeFirst()
            droppedLeadingPartial = true
        }
        guard !parts.isEmpty else { return [] }

        // 编号从末尾开始分配。如果总行数未知，则保留为 nil。
        var numbers = [Int?](repeating: nil, count: parts.count)
        if let total = totalLines {
            // `wc -l` 表示换行符的数量。如果末尾没有换行符，则末尾会多出一行。
            let lastNumber = endedWithNewline ? total : total + 1
            for i in stride(from: parts.count - 1, through: 0, by: -1) {
                let n = lastNumber - (parts.count - 1 - i)
                numbers[i] = n > 0 ? n : nil
            }
        }

        return parts.enumerated().map {
            RemoteLine(number: numbers[$0.offset], isMatch: false, text: $0.element)
        }
    }

    /// 找到  / `grep -n` 对应的结果行。**直接使用 grep 返回的行号。**
    public static func fromMatches(_ matches: [RemoteFile.Match]) -> [RemoteLine] {
        matches.map { RemoteLine(number: $0.line, isMatch: $0.isMatch, text: $0.text) }
    }

    /// 将选定的行转换为可以直接粘贴的格式。
    ///
    /// **剪贴板是远程和本地之间的连接点。** 将筛选后的结果复制到此处。
    /// 可用于比较文档和剪贴板条目（可通过 ⇧⌘D 访问） --
    /// 这就是为什么即使你构建了一个单独的远程界面，它仍然可以连接到现有的工具。
    ///
    /// 默认情况下不包含行号。如果包含行号，粘贴时文本将不再被视为正文的一部分。
    /// 当应用于  / diff 时，所有行都变为差异。
    public static func plainText(_ lines: [RemoteLine], withNumbers: Bool = false) -> String {
        lines.map { line in
            guard withNumbers, let n = line.number else { return line.text }
            return "\(n):\(line.text)"
        }.joined(separator: "\n")
    }
}
