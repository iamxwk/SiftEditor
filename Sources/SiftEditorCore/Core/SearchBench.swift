import Foundation

/// 使用 **release 版本** 测量搜索速度的入口点。
///
/// 也可以通过测试测量，但 `swift test -c release` 可借助 `#if DEBUG` 进行测试。
/// 它被包围了，无法通过。仅从 debug 这个数字和构建设置来看，判断它“慢”是合理的。
/// 我无法判断这是实现方式的问题还是其他原因——Swift 的 debug 正在进行这种密集扫描
/// 数字会改变。因此，请使用 release 创建一条路由。
public enum SearchBench {
    public struct Result: Sendable {
        public let bytes: Int
        public let encoding: String
        public let matchedLines: Int
        public let seconds: Double
    }

    /// 无需任何匹配，只需用 mmap 扫描整个文件并计算换行符。
    /// **用于判断搜索速度慢是否由 mmap（页面错误）引起的下限。**
    /// 如果速度很快，那么我们就知道速度慢的问题出在匹配端，而不是读取端。
    public static func scan(path: String) -> Result? {
        let url = URL(fileURLWithPath: path)
        guard let buffer = FileBuffer(url: url) else { return nil }
        let total = buffer.count
        let started = Date()
        var lines = 0
        buffer.withBytes(in: 0..<total) { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = 0
            while i < total {
                guard let nl = memchr(base + i, 0x0A, total - i) else { break }
                lines += 1
                i = UnsafeRawPointer(nl) - UnsafeRawPointer(base) + 1
            }
        }
        return Result(bytes: total, encoding: "(未匹配)", matchedLines: lines,
                      seconds: Date().timeIntervalSince(started))
    }

    /// 打开  / `path`，使用 `term` 执行完整扫描，并返回所用秒数（不显示）。
    public static func run(path: String, term: String) -> Result? {
        let url = URL(fileURLWithPath: path)
        guard let buffer = FileBuffer(url: url),
              let head = try? FileHandle(forReadingFrom: url) else { return nil }
        let encoding = EncodingDetector.detect(head.readData(ofLength: 64 << 10))
        try? head.close()

        let engine = SearchEngine(buffer: buffer, encoding: encoding)
        let started = Date()
        var matched = 0
        let done = DispatchSemaphore(value: 0)
        engine.search(.terms([term]), progress: { _, _ in }, completion: {
            matched = $0.lineCount
            done.signal()
        })
        // completion 由 main 呼叫。如果呼叫方屏蔽了 main，则呼叫将无法接通。
        // 在此处旋转 run loop 并等待。
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return Result(bytes: buffer.count, encoding: encoding.displayName,
                      matchedLines: matched, seconds: Date().timeIntervalSince(started))
    }
}
