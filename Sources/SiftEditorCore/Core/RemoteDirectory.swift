import Foundation

/// 如何浏览远程文件夹：在另一端使用的字符串以及如何读取其输出。
///
/// 该列表未使用 `ls`。`ls -l` 的格式与 BSD 和 GNU 不同，`ls -F` 的标记是名称和
/// 无法区分（存在一个名为 `a*` 的文件）。仅使用 shell 命令无法判断它是否是一个文件夹？
/// 通过检查  / 的每个实例，您可以正确确定符号链接是否指向文件夹。
extension RemoteFile {

    /// 收件人是谁？连接后立即询问一次即可。
    public enum Kind: Equatable {
        case file
        case directory
        /// 未找到。即使您没有访问父文件夹的权限，从 shell 中也会出现相同的结果。
        case missing
        /// 文件存在但无法读取。
        case unreadable
        /// 不是常规文件或文件夹（设备、管道等）。
        case special
    }

    /// 一步获取目标类型。将其封装在 `sh -c` 中，以便即使登录 shell 不是 POSIX 也能正常工作。
    static func kindCommand(_ path: String) -> String {
        let script = """
        p=\(shellQuote(path))
        if [ -d "$p" ]; then echo kind:dir
        elif [ -f "$p" ]; then if [ -r "$p" ]; then echo kind:file; else echo kind:unreadable; fi
        elif [ -e "$p" ]; then echo kind:special
        else echo kind:missing; fi
        """
        return "sh -c \(shellQuote(script))"
    }

    /// 从  / `kindCommand` 的输出中读取类型。如果无法读取，则使用 nil（即使是旧版本也不会被丢弃）。
    static func parseKind(_ output: String) -> Kind? {
        for raw in output.split(whereSeparator: \.isNewline) {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "kind:dir":        return .directory
            case "kind:file":       return .file
            case "kind:unreadable": return .unreadable
            case "kind:special":    return .special
            case "kind:missing":    return .missing
            default:                continue
            }
        }
        return nil
    }

    /// 列表中的最大条目数。如果超过此限制，条目列表将被终止。
    static let listLimit = 5000
    /// 名称搜索返回的最大结果数。
    static let findLimit = 500

    /// 一次性枚举其下方文件夹的内容。`d 名前` / `f 名前`，如果完成，则最后是 `t`。
    ///
    /// 使用  / `printf '%s\n'` 的原因是 `echo` 根据实现方式解释 `\`。
    /// `.[!.]* ..?* *` 是选择所有文件（包括隐藏文件）的标准方法，但不包括 `.` 和 `..`。
    /// 如果没有中奖组合，则图案保持不变，因此将其丢弃为 `-e` / `-L`。
    static func listCommand(_ path: String) -> String {
        let script = """
        cd \(shellQuote(path)) 2>/dev/null || { echo 'cannot enter the folder' >&2; exit 2; }
        n=0
        for f in .[!.]* ..?* *; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          n=$((n+1))
          if [ $n -gt \(listLimit) ]; then echo t; break; fi
          if [ -d "$f" ]; then printf '%s\\n' "d $f"; else printf '%s\\n' "f $f"; fi
        done
        """
        return "sh -c \(shellQuote(script))"
    }

    /// 列表中有 1 项。
    public struct DirectoryEntry: Equatable {
        public let name: String
        public let isDirectory: Bool
    }

    /// 读取  / `listCommand` 的输出。
    public static func parseList(_ output: String) -> (entries: [DirectoryEntry], truncated: Bool) {
        var entries: [DirectoryEntry] = []
        var truncated = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line == "t" { truncated = true; continue }
            guard line.count > 2 else { continue }
            let kind = line.first
            let name = String(line.dropFirst(2))
            guard kind == "d" || kind == "f" else { continue }
            entries.append(DirectoryEntry(name: name, isDirectory: kind == "d"))
        }
        return (entries, truncated)
    }

    /// 在应用模式  / `-iname` 之前，禁用任何具有通配符效果的字符。
    /// 一个人输入的是“包含这些字符的名称”，而不是一个模式。
    static func escapeGlob(_ term: String) -> String {
        var out = ""
        for c in term {
            if c == "\\" || c == "*" || c == "?" || c == "[" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// 在文件夹内搜索文件名中包含“`term`”的文件（大小无关紧要）。
    /// 不读取文件正文；这里只支持按名称打开。
    static func findCommand(_ root: String, term: String) -> String {
        let pattern = "*" + escapeGlob(term) + "*"
        let script = """
        cd \(shellQuote(root)) 2>/dev/null || { echo 'cannot enter the folder' >&2; exit 2; }
        find . \\( -type f -o -type l \\) -iname \(shellQuote(pattern)) 2>/dev/null | head -n \(findLimit + 1)
        """
        return "sh -c \(shellQuote(script))"
    }

    /// 将  / `find` (`./a/b`) 的输出转换为相对路径。如果超出限制，则指示进程将被终止。
    public static func parseFind(_ output: String) -> (paths: [String], truncated: Bool) {
        var paths = output.split(separator: "\n", omittingEmptySubsequences: true).map { raw -> String in
            let s = String(raw)
            return s.hasPrefix("./") ? String(s.dropFirst(2)) : s
        }
        let truncated = paths.count > findLimit
        if truncated { paths.removeLast(paths.count - findLimit) }
        return (paths, truncated)
    }
}
