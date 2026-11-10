import Foundation

/// 搜索模式。
/// 一个搜索引擎，它以流式扫描的方式扫描大型文件，以收集匹配的行。
///
/// 逐行扫描（以 0x0A 分隔）。UTF-8 直接搜索查询的字节序列（速度快）。
/// 非 UTF-8 (Shift-JIS/EUC) 解码行并执行字符串匹配（精确）。
/// 不要将整个文本加载到内存中（只需读取 mmap）。保留匹配的行，直到达到上限。
final class SearchEngine {
    struct Result {
        var lines: [Int] = []      // 匹配行号（升序排列，直至上限）
        var lineCount = 0          // 匹配行总数（包括超过上限的行数）
        var isComplete = false
        var capped = false
        /// 上一行以换行符结尾的下一行（字节位置，行号）。扩展文件的延续。
        /// 重新扫描时的起始点。最后一行没有换行符的部分不包含在内（它仍然可能会展开）。
        var resumeByte = 0
        var resumeLine = 0
    }

    private let buffer: ByteSource
    private let encoding: DetectedEncoding
    private let lineCap = 1_000_000
    private let queue = DispatchQueue(label: "SiftEditor.search", qos: .userInitiated)

    /// 生成计数器。每次重新搜索/取消操作都会递增此计数器，当计数器值发生变化时，扫描端终止。
    /// (aligned Int 被读取为 arm64，这是一个原子操作。这是一个良性竞争，但取消操作会延迟。)
    private var generation = 0

    init(buffer: ByteSource, encoding: DetectedEncoding) {
        self.buffer = buffer
        self.encoding = encoding
    }

    /// 终止正在进行的搜索。
    func cancel() { generation += 1 }

    /// 以指定模式扫描整个系统。progress / completion 在主线程中调用。
    /// `caseSensitive` 在 terms 模式下有效（选择 compile 时确定 regex）。
    ///
    /// 如果将完成的结果传递给  / `resume`，它将仅从起始点开始扫描并将其附加到记录 (`tail -f`)。
    /// （适用于不断增长的文件）。最后一行没有换行符的内容将从之前的结果中排除并重新计数。
    func search(_ mode: SearchMode, caseSensitive: Bool = false,
                resume: Result? = nil,
                progress: @escaping (Result, Double) -> Void,
                completion: @escaping (Result) -> Void) {
        generation += 1
        let gen = generation
        let total = buffer.count
        let cap = lineCap
        // 匹配规则仅在 `LineMatcher` 中（它与交叉搜索通过同一个点）。
        let matcher = LineMatcher(mode: mode, caseSensitive: caseSensitive, encoding: encoding)
        guard !matcher.isEmpty else {
            DispatchQueue.main.async { if self.generation == gen { completion(Result(isComplete: true)) } }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            if case .regex(let expression) = mode, resume == nil,
               RipgrepSearch.canUseFastPath(expression.pattern),
               self.encoding == .utf8, let file = self.buffer as? FileBuffer,
               total >= 16 << 20, RipgrepSearch.executable != nil {
                var fast = Result()
                do {
                    try RipgrepSearch.scan(url: file.url, pattern: expression.pattern,
                                           caseSensitive: caseSensitive,
                                           cancelled: { self.generation != gen }) { number, _ in
                        fast.lineCount += 1
                        if fast.lines.count < cap { fast.lines.append(number) }
                        else { fast.capped = true }
                    }
                    guard self.generation == gen else { return }
                    fast.isComplete = true
                    let final = fast
                    DispatchQueue.main.async { if self.generation == gen { completion(final) } }
                    return
                } catch {
                    // Some ICU expressions are not accepted by ripgrep's engines.
                    // Preserve existing Find semantics with the in-process matcher.
                    if self.generation != gen { return }
                }
            }
            var res = Result()
            var lineNo = 0
            var start = 0
            if let r = resume, r.isComplete, r.resumeByte > 0, r.resumeByte <= total {
                res = r
                res.isComplete = false
                let kept = r.lines.filter { $0 < r.resumeLine }
                res.lineCount -= r.lines.count - kept.count
                res.lines = kept
                lineNo = r.resumeLine
                start = r.resumeByte
            }
            var reported = start
            var cancellationChecked = start

            self.buffer.withBytes(in: 0..<total) { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = start
                while i < total {
                    let nl = memchr(base + i, 0x0A, total - i)
                    let lineEnd = nl != nil ? (UnsafeRawPointer(nl!) - UnsafeRawPointer(base)) : total
                    let lineLen = lineEnd - i

                    if matcher.matches(base + i, lineLen) {
                        res.lineCount += 1
                        if res.lines.count < cap { res.lines.append(lineNo) } else { res.capped = true }
                    }
                    lineNo += 1
                    i = (nl != nil) ? lineEnd + 1 : total
                    if nl != nil { res.resumeByte = i; res.resumeLine = lineNo }

                    if i - cancellationChecked >= (4 << 20) {
                        if self.generation != gen { return }
                        cancellationChecked = i
                    }

                    if i - reported >= (64 << 20) {        // 每个 64 MB 报告一次进度
                        if self.generation != gen { return }
                        reported = i
                        let snapshot = res
                        let p = Double(i) / Double(max(total, 1))
                        DispatchQueue.main.async { if self.generation == gen { progress(snapshot, p) } }
                    }
                }
            }
            if self.generation != gen { return }
            res.isComplete = true
            let final = res
            DispatchQueue.main.async { if self.generation == gen { completion(final) } }
        }
    }

}
