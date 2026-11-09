import Foundation

/// 将行跳转字段中输入的字符串读取为行号。
///
/// 默认情况下，`Int(_:)` 肯定会给日本用户带来问题。如果在启用日语输入法的情况下输入数字……
/// IME 变为全角字符，从转换候选中选出的“86420337”和“86,420,337”被转换为全角字符。
/// 直接输入。由于 `Int(_:)` 都返回 nil，因此跳转静默失败。
///
/// 全角字符会被折叠成半角字符，数字分隔符和空格会在读取前被移除。如果其中混杂了非数字字符，则会显示为 nil。
enum LineNumberInput {

    static func parse(_ raw: String) -> Int? {
        let halfwidth = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        let digits = halfwidth.filter { !$0.isWhitespace && $0 != "," }
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(digits), n > 0
        else { return nil }
        return n
    }
}
