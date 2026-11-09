import AppKit

/// 入口 — 如果内容不是以文件形式提供，则负责将内容带到可以打开的地方的人员。
///
/// 此工具用于“查看大型日志”，但**这些日志只是原始文件**。
/// 通常不会散落在管道周围**。它要么在管道的另一侧，要么被压扁了。入口被堵塞了。
/// 如果它们存在，无论你在里面创建多少函数，它们都无法访问它们。
///
/// 转换后的内容保存到临时文件中。查看器使用索引 mmap 处理文件。
/// 它需要一个**物理文件**，而不仅仅是内存中的一个字节序列（这就是为什么它可以用 10 GB 打开的原因）。
public enum Intake {

    /// 标准输入是否以管道（或重定向文件）的形式连接？
    ///
    /// 仅凭  / `isatty` 不足以进行判断——即使从 Finder 或 Dock 启动，终端……
    /// 由于它不存在，所以它始终为真。此时，标准输入为 `/dev/null`（字符
    /// 由于它是  / 设备，因此它只接受 **FIFO 或常规文件**。
    public static func stdinIsPiped(_ fd: Int32 = STDIN_FILENO) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return false }
        let mode = st.st_mode & S_IFMT
        return mode == S_IFIFO || mode == S_IFREG
    }

    /// 检查内容，看看是否是  / gzip。扩展名可能具有欺骗性（可能是 `.log`，但 gzip 仍然存在）。
    /// `.gz`（但它只是纯文本，两者都实际存在）。前两个字节是魔数。
    public static func isGzip(_ head: [UInt8]) -> Bool {
        head.count >= 2 && head[0] == 0x1f && head[1] == 0x8b
    }

    /// 临时文件位置。即使标签页中显示 `stdin-3f2a.tmp`，文件名仍保留原始名称。
    /// 我不知道你在看什么。
    public static func scratchURL(named name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiftEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}

extension Intake {

    /// 我被告知要打开的东西是我拥有的还是远程的？
    ///
    /// **在一处完成判决。** 当你开始在各处区分“看起来像 ssh 的字符串”时，
    /// 根据您使用命令行、拖放还是“最近使用的项目”，行为会有所不同。
    public enum Source: Equatable {
        case local(URL)
        case remote(RemoteFile.Target)
    }

    /// 将字符串解析为目标。
    ///
    /// 只有  / `ssh host:/path` 和 `host:/path` 是远程路径。其他所有路径均为**本地路径**。
    /// Handle -- 当你远程击败某些模糊不清的东西时，包括 `C:/…` 和时间在内的名称会被发送到 ssh。
    public static func resolve(_ text: String) -> Source {
        if let target = RemoteFile.parse(text) { return .remote(target) }
        return .local(URL(fileURLWithPath: (text as NSString).expandingTildeInPath))
    }

    /// 完全读取标准输入，将其保存到临时文件，并返回其 URL 值。
    ///
    /// 打开文件前请先阅读所有内容。打开一个不断增长的文件（相当于 `tail -f`）由不同的函数处理。
    /// **只展示部分内容然后装作“这就是全部”更危险。**
    /// 如果没有字节到达，则 nil = 什么也不打开（避免只留下一个空标签页）。
    public static func drainStdin(chunk: Int = 1 << 20) -> URL? {
        let url = scratchURL(named: "stdin-\(Int(Date().timeIntervalSince1970))-\(getpid()).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let out = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? out.close() }

        let input = FileHandle.standardInput
        var total = 0
        while true {
            guard let data = try? input.read(upToCount: chunk), !data.isEmpty else { break }
            do { try out.write(contentsOf: data) } catch { break }
            total += data.count
        }
        guard total > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// 读取标准输入并将其追加到临时文件 (`tail -f … | sifteditor`・B15)。
    ///
    /// **收到第一个数据后立即呼叫 `onFirstData`**（即使在屏幕上显示未完成的输入）。
    /// 读取完毕后方可返回 (EOF)。调用方将通过 `onEnd` 获知读取完成。
    /// 如果没有收到任何消息，请删除临时文件，也不要拨打电话。
    public static func streamStdin(chunk: Int = 1 << 16,
                                   onFirstData: (URL) -> Void,
                                   onEnd: (URL) -> Void) {
        let url = scratchURL(named: "stdin-\(Int(Date().timeIntervalSince1970))-\(getpid()).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let out = try? FileHandle(forWritingTo: url) else { return }
        defer { try? out.close() }

        // `FileHandle.read(upToCount:)` 将不会返回到 EOF，直到累积到指定的字节数。
        // 对于像  `tail -f` 这样以小增量输入的数值，可以直接使用 read(2)，它会返回接收到的数值。
        var buf = [UInt8](repeating: 0, count: chunk)
        var started = false
        while true {
            let n = buf.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, chunk) }
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }
            do { try out.write(contentsOf: Data(buf[0..<n])) } catch { break }
            if !started { started = true; onFirstData(url) }
        }
        if started { onEnd(url) } else { try? FileManager.default.removeItem(at: url) }
    }

    /// 提取  / gzip 并将其保存为临时文件。如果提取失败，请打开 nil（调用者保持不变）。
    ///
    /// 我将把这项工作留给  / `/usr/bin/gzip`。如果我用 zlib 写同样的内容，它将涉及标头、多个成员，
    /// 你将自行负责处理损坏——这段文字可以写得比 macOS 中始终存在的实现方式更准确。
    /// 无前景。**由于数据以流的形式传递，即使展开后的数据量很大，也无法全部加载到内存中。**
    public static func gunzip(_ url: URL) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        let out = scratchURL(named: name.isEmpty ? "gunzipped" : name)
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let sink = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? sink.close() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        task.arguments = ["-dc", url.path]
        task.standardOutput = sink
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        task.waitUntilExit()
        // gzip 是一个损坏的文件，缺少结尾，但它仍然会展开到该点，并以非零值结尾。
        // 如果有任何已发布的内容，请打开它——丢弃的日志的结尾被截断是很常见的。
        // “它坏了，所以我什么都不能给你看”是使用此工具时你能给出的最糟糕的回复。
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }
}

extension Intake {

    /// 检查内容是否为  / zip。`PK\x03\x04` 为正常，`PK\x05\x06` 为空库。
    public static func isZip(_ head: [UInt8]) -> Bool {
        guard head.count >= 4, head[0] == 0x50, head[1] == 0x4b else { return false }
        return (head[2] == 0x03 && head[3] == 0x04) || (head[2] == 0x05 && head[3] == 0x06)
    }

    /// 压缩包中的文件名。**删除 macOS 目录及其所有关联文件。**
    ///
    /// `__MACOSX/` 和 `.DS_Store` 与 Finder 一起压缩时始终包含在内。列出时，
    /// “要打开哪个”的选项数量翻了一番，而且，内容都是没人想看的东西。
    ///
    /// 使用  / Windows 创建的日语文件名（CP932 / Shift-JIS）也能正确恢复，不会出现字符损坏（B16）。
    public static func zipEntries(_ url: URL) -> [String] {
        guard let entries = ZipReader.readEntries(at: url) else { return [] }
        return entries
            .filter { entry in
                !entry.isDirectory
                    && !entry.name.hasPrefix("__MACOSX/")
                    && !entry.name.hasSuffix(".DS_Store")
                    && !entry.name.isEmpty
            }
            .map(\.name)
    }

    /// 从压缩包中检索一个文件并将其保存为临时文件。使用**压缩包中的名称**作为文件名。
    /// 即使 `archive.zip` 出现在标签页中，也无法确定正在查看的是哪一个。
    public static func unzip(_ url: URL, entry: String) -> URL? {
        guard let entries = ZipReader.readEntries(at: url),
              let target = entries.first(where: { $0.name == entry }) else {
            return nil
        }
        let leaf = entry.split(separator: "/").last.map(String.init) ?? entry
        let out = scratchURL(named: leaf.isEmpty ? "unzipped" : leaf)
        guard ZipReader.extract(entry: target, from: url, to: out) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }
}


extension Intake {

    /// 向当前运行的我自己版本（同一捆绑包 ID）传输数据的信号。
    ///
    /// `| sifteditor` 直接启动应用程序的可执行文件，因此如果无人值守，每次单击它都会启动它。
    /// 它会成为一个独立的进程和独立的窗口（草稿也会被读取两次）。**从第二次开始，
    /// 我只会将已读取完毕的临时文件的路径传递给仍然清醒的自我，然后我将关闭。**
    ///
    /// **请在通知名称中包含捆绑包 ID。** 分布式通知会到达同一台机器上的所有进程，因此如果名称很常见，
    /// 当不同 Bundle ID 的应用版本同时打开时，发送给其中一个版本的内容
    /// 它在两个应用程序中都能打开。
    public static var pipeNotification: Notification.Name {
        pipeNotificationName("pipe", bundleID: Bundle.main.bundleIdentifier)
    }
    /// 输入完成的信号（您可以停止跟踪）。
    public static var pipeEndNotification: Notification.Name {
        pipeNotificationName("pipeEnd", bundleID: Bundle.main.bundleIdentifier)
    }

    /// 信号的名称。如果捆绑包 ID 不同，则名称也会不同（如果没有捆绑包 = 开发启动时没有捆绑包，则使用通用基本名称）。
    static func pipeNotificationName(_ kind: String, bundleID: String?) -> Notification.Name {
        let base = "app.iamxwk.SiftEditor.\(kind)"
        guard let id = bundleID, !id.isEmpty else { return Notification.Name(base) }
        return Notification.Name("\(base).\(id)")
    }

    /// 是否有其他进程与我使用相同的捆绑包 ID 运行？
    public static func otherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// 您提供的临时文件是否来自我们的存储位置？由于任何人都可以发送分布式通知，
    /// 防止访问指定存储区域之外的路径。
    public static func isScratchFile(_ url: URL) -> Bool {
        let dir = scratchURL(named: "x").deletingLastPathComponent().resolvingSymlinksInPath()
        return url.resolvingSymlinksInPath().deletingLastPathComponent() == dir
    }

    /// 这是流入流 (`| sifteditor`) 的临时文件吗？因为它是一个片段，一旦原始管道运行完毕就不会再创建了，
    /// 不要保存到之前的会话（恢复它只会导致日志显示它已停止）。
    public static func isPipedStream(_ url: URL) -> Bool {
        isScratchFile(url) && url.lastPathComponent.hasPrefix("stdin-")
    }

    /// 如果标准输入是一个管道并且我正在运行，则读取整个输出并将其传递，然后返回 true。
    ///（调用到此结束）。如果无法送达或未收到任何字节，请使用 false。
    public static func handOffStdinToRunningInstance() -> Bool {
        guard stdinIsPiped(), otherInstanceRunning() else { return false }
        // 初始数据已传递，并持续添加直至完成（即使输入尚未完成，仍会显示在屏幕上）。
        // 如果不输入任何内容，程序将结束而不打开任何内容。
        let center = DistributedNotificationCenter.default()
        streamStdin(onFirstData: { url in
            center.postNotificationName(pipeNotification, object: nil,
                                        userInfo: ["path": url.path], deliverImmediately: true)
        }, onEnd: { url in
            center.postNotificationName(pipeEndNotification, object: nil,
                                        userInfo: ["path": url.path], deliverImmediately: true)
        })
        return true
    }
}
