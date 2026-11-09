import Foundation

/// 一个容器 (B12)，用于保存远程屏幕上已更正的行。
///
/// **请逐行输入，并标明行号。** 只允许替换内容不包含换行符。
/// 无论你先写哪一个，其他行的数字都不会改变（你不需要担心顺序）。
///
/// 它包含“打开时的文本”和“修改后的文本”。**两者都会在打开时发送给对方**。
/// 如果错了，我就不再写在那里了（`RemoteFile.replaceLineCommand`）。
public struct RemoteEdits: Equatable {

    public struct Edit: Equatable {
        public let line: Int
        /// 打开时的主要文本（包括 `\r`，以字节形式）。
        public let original: String
        /// 修订文本（包括 `\r`，以书面形式）。
        public let edited: String

        /// 字节长度会改变吗？如果会，请在对方端重新创建文件。
        public var changesLength: Bool { original.utf8.count != edited.utf8.count }
    }

    private var byLine: [Int: Edit] = [:]

    public init() {}

    public var isEmpty: Bool { byLine.isEmpty }
    public var count: Int { byLine.count }

    /// 按行号升序排序。
    public var all: [Edit] { byLine.values.sorted { $0.line < $1.line } }

    /// 修改长度的次数。**如果次数为 1 或以上，请在保存前告知他人。**
    public var rewriteCount: Int { byLine.values.filter(\.changesLength).count }

    public func edit(at line: Int) -> Edit? { byLine[line] }

    /// 1 行的文本将不再修改（因为它将在命令行中显示）。
    public static let maxLineBytes = 60_000

    /// 可以修改这一行吗？
    ///
    /// - 没有行号的行无法编辑（我还没有统计过。**我无法确定哪些行需要重写。**）
    /// 包含  / - `U+FFFD` 的行无法修复。因为无法读取为 UTF-8 的字节已被转换为替换字符。
    /// 更正和重写它将**丢失原始字节**。
    /// - 过长的行无法编辑。
    public static func isEditable(_ line: RemoteLine) -> Bool {
        guard line.number != nil else { return false }
        guard !line.text.contains("\u{FFFD}"), !line.text.contains("\0") else { return false }
        return line.text.utf8.count <= maxLineBytes
    }

    /// 屏幕上要显示的主要文本。当 `\r`（文件 CRLF）出现在输入字段中时，不要在行尾显示它。
    /// 此字符将呈现无法识别的形状。写入时，请使用 `raw(display:original:)` 恢复其形状。
    public static func display(_ raw: String) -> String {
        raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
    }

    /// 将输入字段中的字符串转换为书面格式。如果原始行以 `\r` 结尾，则恢复为 `\r`。
    /// 如果它包含换行符，nil = **这不是单行替换**，因此不会被接受。
    public static func raw(display: String, original: String) -> String? {
        guard !display.contains("\n"), !display.contains("\r") else { return nil }
        return original.hasSuffix("\r") ? display + "\r" : display
    }

    /// 我会保留修改后的内容。如果您恢复到原文，我会丢弃我保留的内容。
    /// 返回值在接收（或丢弃）后是否处于“已纠正”状态？
    @discardableResult
    public mutating func stage(line: Int, original: String, edited: String) -> Bool {
        // 即使多次更正同一行，基线仍与**首次打开时的文本**相同。
        let base = byLine[line]?.original ?? original
        if edited == base {
            byLine[line] = nil
            return false
        }
        byLine[line] = Edit(line: line, original: base, edited: edited)
        return true
    }

    /// 丢弃已写入的行。
    public mutating func commit(line: Int) { byLine[line] = nil }

    public mutating func removeAll() { byLine.removeAll() }

    /// 列表中显示的主要文本。如果已更正，请使用更正后的版本。
    public func text(for line: RemoteLine) -> String {
        guard let n = line.number, let e = byLine[n] else { return line.text }
        return e.edited
    }
}
