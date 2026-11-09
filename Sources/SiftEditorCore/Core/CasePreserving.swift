import Foundation

/// 替换中“保留原始单词大小写”的逻辑（一个独立于 UI 的纯函数）。
///
/// 当搜索运行时不区分大写字母和小写字母时，`Timeout` / `timeout` / `TIMEOUT` 被视为一个整体。
/// 可以使用该模式获得，但如果您只是简单地替换它，则所有结果都将具有相同的拼写。
/// 读取实际匹配字符串的格式，并将相同的格式转移到替换字符串。
enum CasePreserving {
    /// 格式信息可从匹配的字符串中读取。如果无法确定格式，则直接使用替换字符串 `mixed`。
    enum Style {
        case upper       // TIMEOUT
        case lower       // timeout
        case capitalized // Timeout
        case mixed       // timeOut / t1 / 仅符号等。
    }

    /// 读取匹配字符串 `matched` 的格式。如果没有字母（cased 个字符），则读取 `mixed`。
    static func style(of matched: String) -> Style {
        let cased = matched.filter { $0.isCased }
        guard !cased.isEmpty else { return .mixed }
        if cased.allSatisfy({ $0.isUppercase }) {
            // 单个大写字母“A”也可以被解释为capitalized，但如果将其视为upper
            // 替换字符串无论是一个字符还是多个字符，都会产生自然的结果。
            return .upper
        }
        if cased.allSatisfy({ $0.isLowercase }) { return .lower }
        if let first = cased.first, first.isUppercase,
           cased.dropFirst().allSatisfy({ $0.isLowercase }) { return .capitalized }
        return .mixed
    }

    /// 返回匹配字符串 `matched` 转换为 `replacement` 的格式。
    /// `mixed`（无法判断或没有英文字母）时，完全不修改替换文本。
    static func apply(_ replacement: String, matching matched: String) -> String {
        switch style(of: matched) {
        case .upper:  return replacement.uppercased()
        case .lower:  return replacement.lowercased()
        case .capitalized:
            // ：仅将首字母大写，其余字母保持不变（`newValue` → `NewValue`）。
            guard let i = replacement.firstIndex(where: { $0.isCased }) else { return replacement }
            return replacement.replacingCharacters(in: i...i, with: replacement[i].uppercased())
        case .mixed:  return replacement
        }
    }
}

private extension Character {
    /// 是否区分大小写？（日文字符、数字和符号不用于格式确定 = false）。
    var isCased: Bool { isUppercase || isLowercase }
}
