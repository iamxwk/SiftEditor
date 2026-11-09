import Foundation

/// 负责实际启动 `/usr/bin/ssh` 并使其达到可以打开单个远程文件的程度。
///
/// `RemoteFile` 决定“在那里运行什么”，而“它在这里运行并被接收”。
/// 之所以将其分开，是因为**组装好的字符串无需服务器即可进行测试**。
/// （我已经验证过 `RemoteFileTests` 和我 `/bin/sh` 上使用的字符串相同）。
///
/// **通过 `Data` 接收。** 测距结果不一定会返回文本。
/// 当传递字符串时，无效的字节序列将被替换为替换字符，**检索到的内容将静默更改。**
public final class RemoteSession {

    public let target: RemoteFile.Target
    /// 存在的命令。如果缺失，则为用于折叠该功能的材质 (`degraded`)。
    public let capabilities: RemoteFile.Capabilities
    /// 目标是文件还是文件夹？如果不是文件，`connect` 将停止该操作。
    /// 只有 `.file` 或 `.directory` 才能来这里。
    public let kind: RemoteFile.Kind

    public enum Failure: Error, Equatable {
        /// ssh 无法启动（例如，缺少 `/usr/bin/ssh`）。
        case launchFailed(String)
        /// 无响应。**远程连接无法区分“慢”和“死机”，**因此我会在一段时间后断开连接。
        case timedOut
        /// ssh 或另一端的命令执行失败。请保持 stderr 不变。
        /// "Permission denied" 和 "No such file" 人类读者可以理解，因此我们不会在这里重新表述它们。
        case failed(status: Int32, stderr: String)
        /// 连接已建立，但对方没有读取数据所需的命令。
        case cannotRead
        /// 无收件人（如果您没有访问父文件夹的权限，也会显示此信息）。
        case missing
        /// 文件存在但无法读取。
        case unreadable
        /// 它既不是普通文件也不是文件夹。
        case notRegular
    }

    private init(target: RemoteFile.Target, capabilities: RemoteFile.Capabilities, kind: RemoteFile.Kind) {
        self.target = target
        self.capabilities = capabilities
        self.kind = kind
    }

    /// 连接并检测功能。**只需一次往返即可询问所有问题。**
    public static func connect(
        to target: RemoteFile.Target,
        timeout: TimeInterval = 20
    ) throws -> RemoteSession {
        // 询问同一往返行程中的功能和目的地类型（不增加往返次数）。
        let out = try run(
            host: target.host,
            command: RemoteFile.capabilityCommand() + "; " + RemoteFile.kindCommand(target.path),
            timeout: timeout
        )
        let text = String(decoding: out, as: UTF8.self)
        let caps = RemoteFile.Capabilities.parse(text)
        // 如果它不是可读格式，**不要将空列表显示为成功**，并在此处返回原因。
        // 如果无法读取类型（旧版本），则按文件正常处理。
        let kind = RemoteFile.parseKind(text) ?? .file
        switch kind {
        case .missing:    throw Failure.missing
        case .unreadable: throw Failure.unreadable
        case .special:    throw Failure.notRegular
        case .directory:  return RemoteSession(target: target, capabilities: caps, kind: kind)
        case .file:
            guard caps.canRead else { throw Failure.cannotRead }
            return RemoteSession(target: target, capabilities: caps, kind: kind)
        }
    }

    /// 总字节数。如果找不到此值，请输入 nil = **"未知"**（不要输入 0）。
    public func size(timeout: TimeInterval = 20) -> Int? {
        guard capabilities.canSize else { return nil }
        guard let out = try? Self.run(
            host: target.host,
            command: RemoteFile.sizeCommand(target.path),
            timeout: timeout
        ) else { return nil }
        return RemoteFile.parseSize(String(decoding: out, as: UTF8.self))
    }

    /// 总行数。**由于他们那边已经计算完毕，所以传输次数为零**，但如果是 10GB，他们那边还需要几秒钟才能处理完毕。
    /// 因此，与其等待打开，不如稍后使用它来填写信息。
    public func lineCount(timeout: TimeInterval = 180) -> Int? {
        guard capabilities.canSize else { return nil }
        guard let out = try? Self.run(
            host: target.host,
            command: RemoteFile.lineCountCommand(target.path),
            timeout: timeout
        ) else { return nil }
        return RemoteFile.parseSize(String(decoding: out, as: UTF8.self))
    }

    /// 返回最后 N 个字节作为一行。**这是您首先看到的内容**——错误位于末尾。
    ///
    /// 如果可以获取尺寸，则读取范围 (`count - N ..< count`) 和
    /// 如果无法获取，请将其设置为 `tail -c`。如果设置为 `totalLines`，则会获取实际的行号。
    public func tailLines(bytes: Int = 64 << 10, totalLines: Int? = nil) -> [RemoteLine] {
        let total = size()
        let data: Data?
        let endsAt: Int
        if let total, total > 0 {
            let from = max(0, total - bytes)
            data = read(offset: from, length: total - from)
            endsAt = total
        } else {
            data = tail(bytes: bytes)
            endsAt = data?.count ?? 0     // 整体位置未知 = 无法确定是否存在缺陷。
        }
        guard let data else { return [] }

        var dropped = false
        return RemoteLines.fromTail(data, endsAtByte: endsAt, totalLines: totalLines, droppedLeadingPartial: &dropped)
    }

    /// 返回筛选后的结果行，以便进行排序。
    public func searchLines(pattern: String, context: Int = 0, ignoreCase: Bool = false, regex: Bool = false) -> [RemoteLine]? {
        guard let matches = grep(pattern: pattern, context: context, ignoreCase: ignoreCase, regex: regex) else {
            return nil
        }
        return RemoteLines.fromMatches(matches)
    }

    /// 仅检索一次范围。最短返回值为 EOF。失败返回值为 nil。
    public func read(offset: Int, length: Int, timeout: TimeInterval = 30) -> Data? {
        guard length > 0 else { return Data() }
        return try? Self.run(
            host: target.host,
            command: RemoteFile.readCommand(target.path, offset: offset, length: length),
            timeout: timeout
        )
    }

    /// **他们会把它挤到那边去。** 最有效的远程操作——无需传输 10GB 的任何一个字节，
    /// 仅返回匹配的行和行号。比用我的 mmap 扫描快（因为它不发送数据）。
    ///
    /// 如果  / `grep` 不存在，则使用 nil。调用者随后会通过选择自己的手来缩小范围（结果为 `degraded`）。
    public func grep(
        pattern: String,
        context: Int = 0,
        ignoreCase: Bool = false,
        regex: Bool = false,
        maxMatches: Int = 5000,
        timeout: TimeInterval = 120
    ) -> [RemoteFile.Match]? {
        guard capabilities.canFilter, !pattern.isEmpty else { return nil }
        let command = RemoteFile.grepCommand(
            target.path, pattern: pattern, context: context,
            ignoreCase: ignoreCase, regex: regex, maxMatches: maxMatches
        )
        // 由于正在处理一个大文件，所以需要一些时间。即使如此，内容仍然会被截断。
        // 因为远程操作无法区分“慢”和“死”。
        guard let out = try? Self.run(host: target.host, command: command, timeout: timeout) else {
            return nil
        }
        return RemoteFile.parseGrep(String(decoding: out, as: UTF8.self))
    }

    /// 将行  / `line` 中的 `old` 改为 `new` (B12)。**仅写入成功信息。**
    /// （冲突、权限问题、缺少工具和尺寸不匹配等问题将在另一侧进行替换之前停止）。
    ///
    /// 返回结果会是“立即覆盖”还是“重新创建”？如果停止，则抛出 `EditFailure` 异常。
    /// 呼叫者将其翻译成人类语言。
    public func replaceLine(
        _ line: Int, old: String, new: String, timeout: TimeInterval = 180
    ) throws -> RemoteFile.EditOutcome {
        do {
            _ = try Self.run(
                host: target.host,
                command: RemoteFile.replaceLineCommand(target.path, line: line, old: old, new: new),
                timeout: timeout
            )
            return .overwrote
        } catch Failure.failed(let status, let stderr) {
            if let outcome = RemoteFile.EditOutcome(rawValue: status) {
                if outcome == .rewrote || outcome == .overwrote { return outcome }
                throw EditFailure(outcome: outcome, detail: stderr)
            }
            throw Failure.failed(status: status, stderr: stderr)
        }
    }

    /// 重写在此处停止的原因。它在 `outcome` 处分支，而 `detail` 在另一端保留为 stderr。
    public struct EditFailure: Error, Equatable {
        public let outcome: RemoteFile.EditOutcome
        public let detail: String
    }

    /// 列出文件夹下的内容。它不链接到文件的 session（只需要主机名）。
    public static func listDirectory(
        host: String, path: String, timeout: TimeInterval = 30
    ) throws -> (entries: [RemoteFile.DirectoryEntry], truncated: Bool) {
        let out = try run(host: host, command: RemoteFile.listCommand(path), timeout: timeout)
        return RemoteFile.parseList(String(decoding: out, as: UTF8.self))
    }

    /// 在文件夹中搜索文件名中包含 `term` 的文件（返回相对路径）。
    public static func findFiles(
        host: String, root: String, term: String, timeout: TimeInterval = 60
    ) throws -> (paths: [String], truncated: Bool) {
        let out = try run(host: host, command: RemoteFile.findCommand(root, term: term), timeout: timeout)
        return RemoteFile.parseFind(String(decoding: out, as: UTF8.self))
    }

    /// 距离末尾 N 字节。**无法获取大小时的解决方法**（如果可以获取大小，则范围读取就足够了）。
    public func tail(bytes: Int, timeout: TimeInterval = 30) -> Data? {
        guard capabilities.canFollow, bytes > 0 else { return nil }
        return try? Self.run(
            host: target.host,
            command: RemoteFile.tailCommand(target.path, bytes: bytes),
            timeout: timeout
        )
    }

    /// 打开要传递给查看器的缓冲区。**这是首次在本地创建稀疏文件。**
    /// 如果无法确定大小，则无法打开 - 长度未知的文件无法复制到稀疏文件。
    /// (类似于 `FileBuffer`，这是 internal。它仅在查看器中使用。)
    func openBuffer() -> RemoteBuffer? {
        guard let total = size() else { return nil }
        let name = "remote-\(abs(target.host.hashValue &+ target.path.hashValue)).cache"
        let url = Intake.scratchURL(named: name)
        return RemoteBuffer(count: total, cacheURL: url) { [weak self] offset, length in
            self?.read(offset: offset, length: length)
        }
    }

    // 起始  MARK: - ssh

    /// 直接启动  / `/usr/bin/ssh`。**请勿在中间使用 `/bin/sh -c`。**
    /// 当你用括号括起来时，shell 会将参数解释得更进一步，而你加在参数周围的引号会失去意义。
    /// 只在另一端向 shell 传递一次是正确的（`RemoteFile.shellQuote` 是用于此目的的包）。
    static func run(host: String, command: String, timeout: TimeInterval) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = RemoteFile.sshArguments(host: host, remoteCommand: command)

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardInput = FileHandle.nullDevice   // 请勿申请设备。
        proc.standardError = errPipe

        do { try proc.run() }
        catch { throw Failure.launchFailed(error.localizedDescription) }

        // 并行读取  stdout/stderr（以防止管道堵塞和相互堵塞）。
        var outData = Data(), errData = Data()
        let io = DispatchGroup()
        io.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); io.leave() }
        io.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); io.leave() }

        if io.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = io.wait(timeout: .now() + 2)
            throw Failure.timedOut
        }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw Failure.failed(
                status: proc.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return outData
    }
}
