import Foundation

/// 要提供给  / diff 的“行列”。
///
/// 插入此卡后，可进入三个入口（2 个用于选择文件 / 2 个用于打开标签页 / ）
/// 剪贴板）即使存在，也只需要一个核心。文件仍然是 mmap，并且剪贴板
/// 字符串保持原样存储在内存中，并流入同一个口中。
protocol DiffSource {
    /// 显示名称（用于选项卡和标题）。
    var displayName: String { get }
    /// 行数。
    var lineCount: Int { get }
    /// 所有行的哈希列。输入 diff。
    ///
    /// 如果  / `mask` 为空，则原始字节哈希值 = **查找值** 为普通的 diff。如果不为空，则该行
    /// 规范化然后哈希 = **仅查看形状**“比较格式”（[[FormatMask]]）。
    /// 虽然有四个入口，但开关却在这个位置进行。
    func lineHashes(mask: FormatMask) -> [LineHash]
    /// 行  / i 的内容。**仅在绘制可见线时调用**（不应将整行转换为字符串）。
    func line(at index: Int) -> String

    /// 将行 [from, from+count) 的原始字节发送到输出目标，包括行尾（换行符）。
    ///
    /// 用于输出合并结果。**请勿将主文本加载到内存中**——因为它是以分块流式传输的，
    /// 合并文件  / 10GB 将只产生 1 个数据块 ([[DiffModel.writeMerged]])。
    /// 有些文件末尾没有换行符，所以如果末尾没有换行符，则添加 `eol`。
    func writeLines(from: Int, count: Int, eol: [UInt8], to out: FileHandle) throws
}

extension DiffSource {
    /// 一个正常的比较，同时也会显示值。
    func lineHashes() -> [LineHash] { lineHashes(mask: []) }
}

// MARK: - 哈希

/// 将字节序列转换为 128 位。将两个 FNV-1a 序列旋转到不同的基数上。
/// 如果发生冲突，diff 将忽略差异，因此不要在此处偷工减料（请参阅 [[LineHash]] 的解释）。
struct LineHasher {
    private var a: UInt64 = 0xcbf29ce484222325
    private var b: UInt64 = 0x9e3779b97f4a7c15

    mutating func feed(_ byte: UInt8) {
        a = (a ^ UInt64(byte)) &* 0x100000001b3
        b = (b ^ UInt64(byte)) &* 0xff51afd7ed558ccd
    }
    var value: LineHash { LineHash(a: a, b: b) }

    /// 原始字节序列被分割成 0x0A 段，并对每一行进行哈希处理。移除每一行的最后一个 0x0D 段。
    /// （为了避免仅仅因为 CRLF 和 LF 之间存在差异就说“所有线路都不同”）。
    static func hashLines(_ buf: UnsafeRawBufferPointer) -> [LineHash] {
        var out: [LineHash] = []
        out.reserveCapacity(max(16, buf.count / 64))
        guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return out }
        var h = LineHasher()
        var pending = false          // 当前行是否包含至少一个字节？（用于检查行尾是否存在空行）
        var prevCR = false
        for i in 0..<buf.count {
            let c = base[i]
            if c == 0x0A {
                out.append(h.value)
                h = LineHasher()
                pending = false
                prevCR = false
            } else {
                if prevCR { h.feed(0x0D) }        // CR 后面不是 LF 时，将其作为真正的 CR 输入
                if c == 0x0D { prevCR = true; pending = true; continue }
                prevCR = false
                h.feed(c)
                pending = true
            }
        }
        if pending || buf.count == 0 { out.append(h.value) }
        return out
    }
}

// MARK: - 文件（仍为 mmap）

/// mmap 文件并提供相关行。仅在需要时读取这些行的内容。
final class FileDiffSource: DiffSource {
    let displayName: String
    private let buffer: FileBuffer
    private let index: LineIndex
    private let encoding: DetectedEncoding

    /// **请勿从主线程调用。**直到索引完全创建后才会返回（对于 10GB 大约需要 9 秒）。
    /// `LineIndex` 的完成通知已转发到主线程，因此等待主线程将立即导致死锁。
    ///
    /// 如果传递  / `displayName`，则可以更改标题（从 URL 下载的文件不是临时文件名）
    /// 我想显示原始的 URL。（默认为文件名）。
    init?(url: URL, displayName: String? = nil) {
        precondition(!Thread.isMainThread, "不要在主线程创建 FileDiffSource（等待索引会阻塞界面）")
        guard let buffer = FileBuffer(url: url) else { return nil }
        self.buffer = buffer
        self.displayName = displayName ?? url.lastPathComponent
        // 对于 ，您只需要查看开头部分（将所有 10GB 更改为 Data 会适得其反）。
        let head = buffer.data(in: 0..<min(buffer.count, 64 << 10))
        self.encoding = EncodingDetector.detect(head)
        self.index = LineIndex(buffer: buffer)
        // 需要一个稀疏索引来检索行的内容。由于 diff 访问所有行，我们将在此处创建它。
        let done = DispatchSemaphore(value: 0)
        index.buildInBackground(progress: { _ in }, completion: { done.signal() })
        done.wait()
    }

    var lineCount: Int { index.displayLineCount }

    func lineHashes(mask: FormatMask) -> [LineHash] {
        buffer.withBytes(in: 0..<buffer.count) {
            mask.isEmpty ? LineHasher.hashLines($0) : mask.hashLines($0)
        }
    }

    func line(at i: Int) -> String {
        guard i >= 0, i < lineCount else { return "" }
        let data = buffer.data(in: byteRange(from: i, count: 1))
        let text = String(data: data, encoding: encoding.stringEncoding)
            ?? String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }

    /// 行 [from, from+count) 的字节范围（包括行尾的换行符）。
    private func byteRange(from: Int, count: Int) -> Range<Int> {
        let start = index.byteOffset(ofLineStart: from)
        let endLine = from + count
        let end = (endLine < lineCount) ? index.byteOffset(ofLineStart: endLine) : buffer.count
        return start..<max(start, end)
    }

    func writeLines(from: Int, count: Int, eol: [UInt8], to out: FileHandle) throws {
        guard count > 0, from >= 0, from < lineCount else { return }
        let range = byteRange(from: from, count: min(count, lineCount - from))
        guard !range.isEmpty else { return }

        // 8MB 将分批播放（不要将整个内容转换为 Data）。
        let chunk = 8 << 20
        var pos = range.lowerBound
        while pos < range.upperBound {
            let end = min(pos + chunk, range.upperBound)
            try out.write(contentsOf: buffer.data(in: pos..<end))
            pos = end
        }
        // 某些文件末尾缺少换行符。如果后面还有文件，请添加换行符。
        if buffer.count > 0, range.upperBound == buffer.count {
            let last = buffer.data(in: (buffer.count - 1)..<buffer.count)
            if last.first != 0x0A { try out.write(contentsOf: Data(eol)) }
        }
    }
}

// MARK: - 内存中的文本（剪贴板、未保存的标签页）

/// 将字符串分割成多行。用于剪贴板比较和未保存标签页的比较。
final class TextDiffSource: DiffSource {
    let displayName: String
    private let lines: [String]

    init(text: String, displayName: String) {
        self.displayName = displayName
        // ：文件末尾的单个换行符不会增加行数（与文件处理方式一致）。
        var t = text
        if t.hasSuffix("\r\n") { t.removeLast(2) } else if t.hasSuffix("\n") { t.removeLast() }
        self.lines = t.isEmpty ? [""] : t.components(separatedBy: .newlines)
    }

    var lineCount: Int { lines.count }

    func lineHashes(mask: FormatMask) -> [LineHash] {
        lines.map { line in
            if !mask.isEmpty { return mask.hashLine(Array(line.utf8)) }
            var h = LineHasher()
            for b in line.utf8 { h.feed(b) }
            return h.value
        }
    }

    func line(at i: Int) -> String { (i >= 0 && i < lines.count) ? lines[i] : "" }

    func writeLines(from: Int, count: Int, eol: [UInt8], to out: FileHandle) throws {
        guard count > 0, from >= 0, from < lines.count else { return }
        let end = min(from + count, lines.count)
        var bytes: [UInt8] = []
        for i in from..<end {
            bytes.append(contentsOf: Array(lines[i].utf8))
            bytes.append(contentsOf: eol)
        }
        try out.write(contentsOf: Data(bytes))
    }
}

// MARK: - URL（下载至 mmap）

/// 用于比较的 URL 的解释。**请勿信任此输入**——请移除空格并使用 **https**。
/// 仅允许与主机建立连接（阻止 file:// 和 javascript:）。与 `LineNumberInput` 类似，
/// 仅处理纯转换，以便于测试。
///
/// **为什么只有 https：** 分发的 .app 已签名并经过公证，而 Info.plist 对 ATS 有例外。
/// 不可用。默认值 ATS 拒绝加载明文 http（测量值为：NSURLErrorDomain -1022）。
/// 即使  / http 被接受，实际设备也会毫无解释地失效，因此会在入口点被拒绝，并立即返回原因。
/// （对内部 http 服务器和 localhost 服务器的支持将作为一项单独的功能稍后添加，该功能有意添加了 ATS 例外。）
enum CompareURL {
    static func normalize(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s),
              u.scheme?.lowercased() == "https",
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }

    /// 要在选项卡和标题中显示的简短名称。如果路径末尾可用，则使用该末尾；否则，使用主机名。
    static func displayName(for url: URL) -> String {
        let last = url.lastPathComponent
        return (last.isEmpty || last == "/") ? (url.host ?? url.absoluteString) : last
    }
}

/// URL 的内容保存到临时文件并与 `FileDiffSource` 进行比较。
///
/// 与剪贴板不同，**并非所有文本都会加载到内存中** -- `downloadTask` 是流式传输的
/// 因为它写入临时文件，即使远程日志是 1GB，也可以将其处理为 mmap。
/// **请勿从主线程调用**（等待同步下载。原因与 FileDiffSource 相同）。
/// 如果失败（响应错误、网络错误、超时），则为 nil。
func downloadDiffSource(from url: URL, displayName: String, timeout: TimeInterval = 30) -> DiffSource? {
    precondition(!Thread.isMainThread, "不要在主线程调用 downloadDiffSource（同步下载会阻塞界面）")
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }

    var saved: URL?
    let done = DispatchSemaphore(value: 0)
    let task = session.downloadTask(with: url) { tmp, response, _ in
        defer { done.signal() }
        guard let tmp else { return }
        // 除了  2xx 之外的所有内容都是错误页面，而非正文。比较它们毫无意义，因此已将其排除在外。
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        // 回调函数退出时，临时文件  downloadTask 将被删除。请将其移动到稳定位置。
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("sifteditor-diff-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            saved = dest
        } catch { }
    }
    task.resume()
    done.wait()

    guard let file = saved else { return nil }
    // 执行  mmap 后，磁盘上的文件不再需要。即使执行 unlink 后，页面仍然会保留（这也起到了清理作用）。
    defer { try? FileManager.default.removeItem(at: file) }
    return FileDiffSource(url: file, displayName: displayName)
}

// MARK: - 内存预算

/// diff 存储的索引每行 16 字节（128 位哈希值）。与浏览不同，
/// 这是应用程序实际使用的内存，所以首先要检查它是否适合机器。
///
/// 行数没有固定限制的原因是 8GB 中有 MacBook Air，64GB 中有 Mac Studio。
/// 最糟糕的情况是同一操作仅在一侧失败。**根据已安装的 RAM 确定预算。**
enum DiffBudget {

    /// 可用于 diff 的物理内存百分比。
    static let fraction = 0.25

    /// 哈希字符串实际累积的总金额的乘数（16B/ 行 × 2 个文件）。
    ///
    /// **测量值**（2026-07-13，与发行版相同的优化版本，1GB × 2 = 8,712,081 行）：
    /// 行哈希 270 MB → 峰值实际内存 1,765 MB = **6.5 倍**。
    /// 大部分差异在于 `LineDiff.uniqueAnchors` 为每个区间创建的发生表 (Dictionary)。
    ///
    /// 最初设定为 2.5，但这只是**一个估计值，低估了 2.6 倍**。
    /// 当我强制使用  / 10GB × 2 进行判断时，实际上失败了，因为它超过了 8.8GB。
    /// （此系数将正确拒绝该项）。请先测量数字再记录。
    static let overheadFactor = 6.5

    static func estimatedBytes(leftLines: Int, rightLines: Int) -> Int {
        Int(Double((leftLines + rightLines) * MemoryLayout<LineHash>.size) * overheadFactor)
    }

    static var allowedBytes: Int {
        Int(Double(ProcessInfo.processInfo.physicalMemory) * fraction)
    }

    /// 问题能解决吗？如果不能，不要只是默默拒绝，而要给出理由并拒绝。
    static func fits(leftLines: Int, rightLines: Int) -> Bool {
        estimatedBytes(leftLines: leftLines, rightLines: rightLines) <= allowedBytes
    }

    static func describe(leftLines: Int, rightLines: Int) -> String {
        let needMB = Double(estimatedBytes(leftLines: leftLines, rightLines: rightLines)) / 1_048_576
        let haveMB = Double(allowedBytes) / 1_048_576
        return L("diff.memoryLimit", Double(leftLines + rightLines), needMB, haveMB)
    }
}
