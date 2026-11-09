import Foundation

/// 负责**范围读取**并与  / `ssh host:/path` 之外的某个项目进行交互的人员是 B5。
///
/// **禁止降价开通**（决定日期：2026年8月30日 - notes/ROADMAP.md M6）。降价后……
/// 如果在本地打开，`scp` 就足够了，所以应用程序没有必要使用它。其含义是 `tail -f` / `more`。
///
/// **实现方法为 `/usr/bin/ssh`、shell、out。** 完全解释 `ssh_config`、ProxyJump、多阶段。
/// 2FA、ssh-agent、Match/Include 免费包含 = “如果可以通过终端连接，就可以连接。”
/// libssh2 / swift-nio-ssh 被拒绝（由于 `ssh_config` 自身的解释，ProxyJump/Include 是地狱）。
/// 负责密钥管理，并有义务遵守 CVE 的规定。**私钥不会被存储。**
///
/// **取决于对方的命令。** 在 BusyBox、受限 shell 和 `rbash` 等嵌入式设备中……
/// 它可能缺失，而“如果通过终端连接，它就会连接”的承诺在这一点上被打破了。
/// 仅在连接后立即检测一次功能，并将未找到的功能折叠 ── **同时显示折叠原因。**
/// 如果你一声不响地消失，看起来就像你出了问题。
public enum RemoteFile {

    // MARK: - 宛先

    /// 这是  / `ssh host:/path` / `host:/path` 的修改版本。**请勿连接此处。**
    public struct Target: Equatable {
        /// `user@host` 或 `host`。直接将其传递给 ssh（`ssh_config` 的别名 Host 也有效）。
        public let host: String
        /// 另一边的绝对传球。
        public let path: String

        public init(host: String, path: String) {
            self.host = host
            self.path = path
        }
    }

    /// 如果字符串指定远程位置，则将其拆分。否则，将 nil 视为本地路径。
    ///
    /// 仅接受两种路径：`ssh host:/path` 和 `host:/path`。**不接受相对路径。**
    /// 另一端的当前目录对人类不可见，`~` 的展开由 shell 控制并波动，
    /// 您打算开设的店铺位置与实际店铺位置不符。
    ///
    /// 为避免与  / Windows 的驱动器号 (`C:\...`) 混淆，host 至少需要两个字符。
    public static func parse(_ text: String) -> Target? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("ssh ") { s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces) }

        guard let colon = s.firstIndex(of: ":") else { return nil }
        let host = String(s[s.startIndex..<colon])
        let path = String(s[s.index(after: colon)...])

        guard host.count >= 2, !host.contains("/"), !host.contains(" ") else { return nil }
        guard path.hasPrefix("/") else { return nil }
        return Target(host: host, path: path)
    }

    // MARK: - 在另一端运行的命令

    /// 请将字符串用单引号括起来。**由于这是 shell 环境，如果不加括，路径将被视为命令。**
    /// 单引号本身被关闭，然后又被重新打开，使用 `'\''`（这是避免 POSIX sh 的唯一方法）。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 请求总字节数。`wc -c` 表示 POSIX，而实际实现中通常会降至 fstat。
    /// `stat` 未使用，因为它的格式与 BSD 和 GNU 不同。
    static func sizeCommand(_ path: String) -> String {
        "wc -c < \(shellQuote(path))"
    }

    /// 将  / `wc -c` 的输出转换为数字。
    ///
    /// **`wc` 中的 BSD 开头有空格** (`"    4096\n"`)。GNU 没有空格。
    /// 我不知道是哪一边，所以我会在阅读之前删除两端的空格和换行符。
    /// 如果无法读取为数字，则 nil = **大小“未知”**。请勿写入 0（这有不同的含义，表示无法检索）。
    static func parseSize(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        return Int(trimmed)
    }

    /// 询问线路总数。**他们会在后台进行计数，因此转账金额为零。**
    ///
    /// 我最初决定发布一个未知行数的版本，但结果发现**需要转发才能计数**。
    /// 这是基于前提得出的结论。不需要——`wc -l` 会在那里运行。如果是 10GB 的话……
    /// 他们那边需要几秒钟时间，但我们只会收到一个号码。所以即使是远程操作。
    /// **此处可显示实际行号。**
    ///
    /// 但是，这需要一些时间，所以不要让我等它打开（我稍后会填写）。
    static func lineCountCommand(_ path: String) -> String {
        "wc -l < \(shellQuote(path))"
    }

    /// 任意位置的量程读数。**`tail -c +N | head -c L`。**
    ///
    /// `dd skip=` 必须与块边界对齐，而 `iflag=skip_bytes` 专用于 GNU。
    /// `tail -c +N` 也以字节单位表示为 POSIX 和 BusyBox。`+N` 是从 1 开始计数的。
    /// 将偏移量加 1（如果出错，文本将显示为 1 字节偏移）。
    static func readCommand(_ path: String, offset: Int, length: Int) -> String {
        let q = shellQuote(path)
        // 如果从头开始，请勿插入 tail（以防止在大文件中重新计数到 tail）
        if offset <= 0 { return "head -c \(length) < \(q)" }
        return "tail -c +\(offset + 1) < \(q) | head -c \(length)"
    }

    /// 距离末尾还有 N 字节。**无法请求大小时的变通方法。**
    /// 如果可以的话，读取范围（`count - N ..< count`）就足够了，所以请使用它。
    static func tailCommand(_ path: String, bytes: Int) -> String {
        "tail -c \(bytes) < \(shellQuote(path))"
    }

    /// 持续跟踪末尾 (`tail -c N -f`)。**除非停止，否则不会返回。**
    ///
    /// 在本地跟踪时，我使用 `fstat` 来查看其扩展情况，然后添加 mmap，但如果我远程执行此操作……
    /// 我会继续使用 `wc -c` 来测试它的性能。对比他们的 `tail -f`。
    /// 顺其自然更直接，延迟更低。
    ///
    /// 将  / `-c N` 放在第一位的原因是**在开始跟踪之前显示最新数据**。
    ///
    /// **当值为 0 时，请显式指定 `-n 0`。**默认值为 `tail -f`，包含最后 10 行。
    /// 由于它是在输出后才开始跟踪的，如果您将其添加到已经显示结束的屏幕中，则会出现相同的行。
    /// 出现过两次**（在实际设备上）。“仅限新品”功能不会通过简单等待获得。
    /// **请确保断开连接时，另一端也停止连接。** 由于 PTY 未被分配（`-T`），
    /// 即使断开连接，命令 SIGHUP 也不会发送到对方。`tail -f` 是
    /// 除非没有帖子，否则 EPIPE 将不会被注意到，并且**将继续存在于其他人的服务器上**。
    /// （我在实际设备上留下了三个）。
    ///
    /// 因此我们让它监视标准输入——当 ssh 故障时，另一个 `cat` 会接收 EOF 的信号，
    /// 它会在终止  / `tail` 后结束。不使用 PTY 的原因是，将其赋值给它会转换换行符。
    /// **正文将更改**。
    static func followCommand(_ path: String, bytes: Int) -> String {
        let q = shellQuote(path)
        let tail = bytes > 0 ? "tail -c \(bytes) -f \(q)" : "tail -n 0 -f \(q)"
        return "\(tail) & p=$!; cat > /dev/null; kill $p 2>/dev/null"
    }

    /// **我们将从那里开始挤压它。** 这是远距离作战中最有效的策略。
    /// 返回  / 10GB，不传输任何字节，只传输匹配的行和行号。
    ///
    /// - `context` 等价于 `grep -C`（前一行和后一行）。**“命中”的含义通常在前一行中可以找到。**
    /// - 正则表达式为 `grep -E`（POSIX 扩展）。**不支持前瞻和后瞻。**
    /// 我的本地搜索引擎支持它，所以这是唯一受限的领域。我会将这些限制告知其他人。
    /// - 如果是固定字符串，请使用 `-F`。您可以直接搜索包含 `.` 或 `*` 的单词。
    static func grepCommand(
        _ path: String,
        pattern: String,
        context: Int = 0,
        ignoreCase: Bool = false,
        regex: Bool = false,
        maxMatches: Int = 5000
    ) -> String {
        var flags = ["-n"]                       // 行号为必填项。没有行号，您将无法跳转到该页面。
        flags.append(regex ? "-E" : "-F")
        if ignoreCase { flags.append("-i") }
        if context > 0 { flags.append("-C \(context)") }
        if maxMatches > 0 { flags.append("-m \(maxMatches)") }
        // 如果没有匹配项，grep 以 1 结尾。在这里，“没有匹配项”并不是失败，所以我们继续。
        // **2 个或更多（无效/无法读取的正则表达式）将不会被保留。** 如果保留，则会变为“未匹配”。
        // ：我无法意识到公式是错误的。
        return "grep \(flags.joined(separator: " ")) -e \(shellQuote(pattern)) \(shellQuote(path)); s=$?; [ $s -le 1 ] || exit $s"
    }

    // MARK: - 重写 1 行 (B12)

    /// 重写结果。另一个脚本返回退出代码。
    public enum EditOutcome: Int32, Equatable {
        /// 由于长度相同，因此当场覆盖（`dd conv=notrunc`）。
        case overwrote = 0
        /// 长度发生了变化，所以我重新创建并替换了他们那边的数据。
        case rewrote = 20
        /// 这行代码和刚打开时不一样了。**我停止了输入。**
        case conflict = 10
        /// 不是常规文件 / 符号链接 / 无法写入。
        case notWritable = 11
        /// 另一端缺少必需的命令（sed / cp / mv / dd 等）。
        case missingTool = 12
        /// 无法在同一文件夹中创建临时文件（仅编辑更改长度的文件）。
        case cannotCreateTemp = 13
        /// 我写出的结果与计算结果不符。**我已将其丢弃，未作替换。**
        case writeFailed = 14
        /// 行号超出范围。
        case noSuchLine = 15
    }

    /// 重写一行并将其转换为字符串，以便在另一侧运行。
    ///
    /// **只会传输和重写一行。** 10GB，但另一边可以使用的行是 `sed` / `head` / `tail`。
    /// 旧文本和新文本应作为参数包含（因为使用标准输入会增加 ssh 的输入/输出路径数量）。
    ///
    /// 订单及原因：
    /// 1. **这是一个可写入的普通文件，而非符号链接。** 替换文件 (`mv`) 为
    /// 替换链接本身，而不是链接的目标地址。
    /// 2. **第 `line` 行必须与 `old` 行匹配。** 如果您打开后有人在上面写了字，
    /// 行号错位导致另一行数据损坏。如果行号不匹配，则停止写入 (`conflict`)。
    /// 3. 如果字节长度相同，**立即覆盖** (`dd bs=1 seek=… conv=notrunc`)。
    /// 不需要额外的空间，所有者、权限和 inode 保持不变。
    /// 4. 如果不行，请在**同一文件夹**中创建一个临时文件，然后将 `mv` 复制到不同的文件系统。
    /// 创建它将使 `mv` 变为非原子文件。临时文件创建为 `cp -p`，因此必须相应地设置权限和所有权。
    /// 接管。**如果书写尺寸与计算结果不符，则丢弃该尺寸，无需更换。**
    ///
    /// 将整个过程包装在 `sh -c` 中，以便即使登录 shell 不是 POSIX（fish / csh）也能正常工作。
    /// **`head -c 0` 与 BSD 冲突**（这发生在实际设备上），因此当 `head` 是第一行时，不会调用它。
    /// 呼叫者将拒绝包含换行符 (`\n`) 的文本。这是单行替换。
    static func replaceLineCommand(_ path: String, line: Int, old: String, new: String) -> String {
        let oldLen = old.utf8.count
        let newLen = new.utf8.count
        let newQ = shellQuote(new)

        // 空行与“不存在的行”无法区分（两者都具有空的 `$(sed …)`），因此只有在这种情况下才会被计数。
        let existence = old.isEmpty
            ? "cnt=$(sed -n '$=' \"$f\"); [ \"${cnt:-0}\" -ge \"$n\" ] || { echo 'no such line' >&2; exit 15; }\n"
            : ""

        let write: String
        if oldLen == newLen {
            write = """
            printf '%s' \(newQ) | dd of="$f" bs=1 seek=$off conv=notrunc 2>/dev/null || { echo 'write failed' >&2; exit 14; }
            [ "$(sed -n "${n}{p;q;}" "$f")" = \(newQ) ] || { echo 'verify failed' >&2; exit 14; }
            exit 0
            """
        } else {
            write = """
            t="$f.sifteditor-tmp.$$"
            total=$(( $(wc -c < "$f") ))
            cp -p "$f" "$t" 2>/dev/null || { echo 'cannot create temp file' >&2; exit 13; }
            { { [ "$off" -eq 0 ] || head -c $off "$f"; } && printf '%s' \(newQ) && tail -c +$((off+\(oldLen)+1)) "$f"; } > "$t" || { rm -f "$t"; echo 'write failed' >&2; exit 14; }
            [ $(( $(wc -c < "$t") )) -eq $((total-\(oldLen)+\(newLen))) ] || { rm -f "$t"; echo 'size mismatch' >&2; exit 14; }
            mv "$t" "$f" || { rm -f "$t"; echo 'replace failed' >&2; exit 14; }
            exit 20
            """
        }

        let script = """
        f=\(shellQuote(path)); n=\(line)
        for c in sed cp mv dd head tail wc printf; do command -v $c >/dev/null 2>&1 || { echo "missing $c" >&2; exit 12; }; done
        [ -f "$f" ] && [ ! -L "$f" ] && [ -w "$f" ] || { echo 'not a writable regular file' >&2; exit 11; }
        \(existence)cur=$(sed -n "${n}{p;q;}" "$f")
        [ "$cur" = \(shellQuote(old)) ] || { echo 'line changed' >&2; exit 10; }
        [ "$n" -le 1 ] && off=0 || off=$(( $(head -n $((n-1)) "$f" | wc -c) ))
        \(write)
        """
        return "sh -c \(shellQuote(script))"
    }

    /// `grep -n -C` 的一行结果，包含行号以及它是匹配行还是上下文行。
    public struct Match: Equatable {
        public let line: Int          // 1 开端（grep 的风格）
        public let isMatch: Bool      // false = -C - 它前后的行
        public let text: String
    }

    /// 将  的输出除以 `grep -n`。
    ///
    /// **正确匹配项为 `123:本文`，其周围字符为 `123-本文`。** 该组字符由行 `--` 分隔。
    /// `:` 通常也包含在正文中，因此**仅除以第一个分隔符**（如果弄错了）
    /// URL（包含时间戳的行已损坏）。
    public static func parseGrep(_ output: String) -> [Match] {
        var out: [Match] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty || line == "--" { continue }

            // 读取第一个数字
            var digits = ""
            var idx = line.startIndex
            while idx < line.endIndex, line[idx].isNumber {
                digits.append(line[idx])
                idx = line.index(after: idx)
            }
            guard !digits.isEmpty, idx < line.endIndex, let number = Int(digits) else { continue }

            let sep = line[idx]
            guard sep == ":" || sep == "-" else { continue }
            let text = String(line[line.index(after: idx)...])
            out.append(Match(line: number, isMatch: sep == ":", text: text))
        }
        return out
    }

    /// 能力检测。**在单个连接中提出所有问题**（每个连接一个命令，无需往返）。
    /// 只返回存在的内容作为行 = 不存在的内容将被静默删除。
    static func capabilityCommand() -> String {
        let names = ["wc", "head", "tail", "grep"]
        return names.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ")
    }

    /// 一个原本存在的命令。如果缺少某些内容，则可能导致该功能被折叠。
    public struct Capabilities: Equatable {
        public let hasWc: Bool
        public let hasHead: Bool
        public let hasTail: Bool
        public let hasGrep: Bool

        /// 一个无法打开的组合。没有 `head`，一个字节都无法检索。
        public var canRead: Bool { hasHead }
        /// 请问总共有多少字节？如果不能，请将行数和进度报告为“未知”（不要写 0）。
        public var canSize: Bool { hasWc }
        /// 末尾追従。
        public var canFollow: Bool { hasTail }
        /// 在此处缩小搜索结果范围（筛选显示/搜索）。如果未找到任何内容，您需要下拉并在此处缩小搜索结果范围。
        public var canFilter: Bool { hasGrep }

        /// 用于向他人解释折叠功能的措辞及其原因。如果没有东西需要折叠，则折叠处为空。
        public var degraded: [String] {
            var out: [String] = []
            if !hasWc { out.append(L("remote.degraded.noWc")) }
            if !hasTail { out.append(L("remote.degraded.noTail")) }
            if !hasGrep { out.append(L("remote.degraded.noGrep")) }
            return out
        }

        public init(hasWc: Bool, hasHead: Bool, hasTail: Bool, hasGrep: Bool) {
            self.hasWc = hasWc
            self.hasHead = hasHead
            self.hasTail = hasTail
            self.hasGrep = hasGrep
        }

        /// 根据  / `capabilityCommand()` 的输出构建（每行一个命令名称）。
        public static func parse(_ output: String) -> Capabilities {
            let found = Set(output.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            return Capabilities(
                hasWc: found.contains("wc"),
                hasHead: found.contains("head"),
                hasTail: found.contains("tail"),
                hasGrep: found.contains("grep")
            )
        }
    }

    // MARK: - ssh 的参数

    /// Unix：域套接字 (`sun_path`) 的路径长度上限。macOS 为 104。
    /// **如果越过此点，ssh 将被 `unix_listener: path too long` 立即杀死。**
    static let socketPathLimit = 104
    /// ssh 是 `%C`（40 位数字）加上用户添加的临时后缀 (`.XXXXXXXXXXXXXXXX`) 的展开结果。
    static let controlPathExpansion = 40 - "%C".count + 17

    /// `ControlMaster` 的位置。**使用多路复用连接，避免每次读取范围时都重新连接。**
    /// 每次滚动页面时，感觉就像在来回握手三次一样，导致所有延迟都像是这个应用程序的问题。
    ///
    /// **`NSTemporaryDirectory()` 不可用。** macOS 和 `/var/folders/…` 一样长。
    /// 添加  / `%C` 扩展超出套接字路径长度限制（这种情况首先发生在实际的 ssh 上）。
    /// （这无法通过  / `/bin/sh` 测试确定）。创建您自己的专属空间，只有您可以书写。
    static func controlPath() -> String {
        let dir = URL(fileURLWithPath: "/tmp/sifteditor-\(getuid())", isDirectory: true)
        // 0700。/tmp 可以由任何人写入，因此如果此限制被放宽，则该插槽位置将被接管。
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("s-%C").path
    }

    /// 我们应该放弃冗余吗？**如果超过限制，则崩溃** -- ControlMaster 速度很快
    /// 这虽然是个技巧，但即使没有它也能读取。如果因为长度问题导致读取困难，那么即使速度慢，最好还是连接上。
    static func controlPathFits(_ path: String) -> Bool {
        path.utf8.count + controlPathExpansion <= socketPathLimit
    }

    /// 传递给  / `/usr/bin/ssh` 的参数。**不要终止 `ssh_config`** -- 添加多路复用和
    /// 只需声明“不需要设备”，Host（别名）和 ProxyJump 即可按照用户的设置通过。
    ///
    /// 不设置 `BatchMode`，否则密码认证或未知主机密钥会立即失败。
    /// 我将向 `SSH_ASKPASS` 询问 GUI（因为我没有终端）。
    static func sshArguments(host: String, remoteCommand: String) -> [String] {
        var args: [String] = []
        let path = controlPath()
        if controlPathFits(path) {
            args += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(path)",
                "-o", "ControlPersist=60",
            ]
        }
        args += [
            "-T",                       // 请勿分配伪终端（这不是人）
            host,
            remoteCommand,
        ]
        return args
    }
}
