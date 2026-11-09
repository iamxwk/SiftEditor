import Foundation

/// 对齐行以进行数字引导分配（与 UI 无关的纯逻辑）。
///
/// **如果将第一行格式化为 Tab，则可以将该除法应用于该行的其余部分。** 如果没有此操作，
/// 确定位数后，您最终不得不手动对齐数百行，最后不得不打开 `awk` 或 `column -t`。
///
/// 项目分隔符用**一系列空格**表示（转换为固定长度之前的数据通常用空格或制表符分隔）
///（已分隔）。分隔符本身由 `ColumnGuides` 持有，所以这里
/// 仅接收“将其放置在哪个数字中”的信息。
enum ColumnAlign {
    /// 数字计数单位为**显示宽度**（全角 = 2）。如果按字符数进行压缩，则只有包含全角字符的行将无法对齐。
    private static func width(_ s: String) -> Int { TabularFormatter.displayWidth(s) }

    /// 将  / `text` 的每一行与 `fieldStarts` 对齐（从 1 开始的数字顺序，升序）。
    ///
    /// - 使用空格/制表符将列分成多个项目，并将第 i 个项目从第 `fieldStarts[i]` 列开始放置。
    /// - **请勿删除字符。** 如果前一项的位数超过指定位数，请留一个空格并继续。
    /// （数字有些失真，但总比完全消失好。你可以看到哪些行失真了。）
    /// - 如果项目数超过定义数量，则剩余部分将以一个空格作为分隔符。
    /// - 空行和仅包含空格的行保持不变。
    /// - 删除尾随空格（压缩后不要留下任何多余空格）。保留换行符的类型和位置。
    static func align(_ text: String, to fieldStarts: [Int]) -> String {
        let starts = fieldStarts.filter { $0 >= 1 }.sorted()
        guard !starts.isEmpty else { return text }
        // 使用 components 可以保留行尾的换行符的存在与否，即使按换行符分割也是如此。
        let lines = text.components(separatedBy: "\n")
        return lines.map { alignLine($0, to: starts) }.joined(separator: "\n")
    }

    /// 根据内容创建数字分割（当还没有分割点时）。
    ///
    /// **这是为了让您能够立即按下 ⌥Tab。** 用空格/制表符分隔项目。
    /// 根据每个类别中最长项目的宽度确定数字位数（与 `column -t` 的概念相同）。
    /// 项目之间留一个空格——如果它们靠得太近，就会变得难以阅读，并且在将它们作为固定长度数据提取时需要边界。
    static func inferFieldStarts(from lines: [String]) -> [Int] {
        var widths: [Int] = []
        for line in lines {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for (i, token) in tokens.enumerated() {
                let w = width(token)
                if i < widths.count { widths[i] = max(widths[i], w) } else { widths.append(w) }
            }
        }
        guard widths.count >= 2 else { return [] }        // 1 件物品没有分割的意义。
        var starts: [Int] = [1]
        for w in widths.dropLast() { starts.append(starts.last! + w + 1) }
        return starts
    }

    /// 是否有调整它们的空间（即，如果我现在按下 ⌥Tab，会有什么变化吗）？
    ///
    /// **用于确定何时发布公告。** 当整个文本被重建并进行比较时，每次击键都会变成 8MB。
    /// 它运行正常，所以只需查看前几行即可。我想显示的消息是“尚未完成”。
    /// 并非“没有一行是完整的”，所以这样就足够了。
    static func needsAlignment(_ lines: [String], to fieldStarts: [Int]) -> Bool {
        let starts = fieldStarts.filter { $0 >= 1 }.sorted()
        guard !starts.isEmpty else { return false }
        return lines.contains { alignLine($0, to: starts) != $0 }
    }

    /// 对齐线条。保持 `\r`（CRLF 的残余部分）不变，并将其移至末尾。
    static func alignLine(_ line: String, to starts: [Int]) -> String {
        let hasCR = line.hasSuffix("\r")
        let body = hasCR ? String(line.dropLast()) : line
        let tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return line }          // 仅包含空格的行保持不变。

        var out = ""
        var column = 1                                       // 现在要写入的数字（从 1 开始）
        for (i, token) in tokens.enumerated() {
            let target = i < starts.count ? starts[i] : column + 1   // 如果项目数量超过规定数量，请留一个空格并继续。
            if target > column {
                out += String(repeating: " ", count: target - column)
                column = target
            } else if i > 0 {
                out += " "                                   // 上一项超出限制 = 请至少留一个空格。
                column += 1
            }
            out += token
            column += width(token)
        }
        return out + (hasCR ? "\r" : "")
    }
}
