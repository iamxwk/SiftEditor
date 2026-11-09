import Foundation

/// 负责从传入的字节序列中提取**完整的行**。
///
/// `tail -f` 的输出大小与我们的需求无关。**数据块边界是
/// 它会在行中间丢失**，因此如果您将接收到的内容作为一行输出，则一行将被分成两行。
/// 它出现在屏幕上。此外，在跟踪日志时，断开的行可以解读为“这就是日志的内容”。
///
/// 因此，请保留该行，直到出现换行符。**尚未遇到换行符的行尾将不会被识别为一行。**
struct LineAccumulator {

    /// 小数部分等待换行。
    private var pending = Data()

    /// 如果小数部分过大，则放弃此限制。如果您持续收到不包含换行符的内容。
    /// 内存正在被耗尽（例如，当二进制文件为 tail 时）。
    static let maxPending = 4 << 20   // 4MB

    /// 将接收到的数据相加，并仅返回已完成的行。
    mutating func take(_ chunk: Data) -> [String] {
        guard !chunk.isEmpty else { return [] }
        pending.append(chunk)

        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let raw = pending[pending.startIndex..<nl]
            pending = pending[pending.index(after: nl)...]
            lines.append(Self.decode(raw))
        }
        // `pending` 是一个切片，因此除非重新打包，否则下标将继续扩展。
        pending = Data(pending)

        if pending.count > Self.maxPending { pending.removeAll(keepingCapacity: false) }
        return lines
    }

    /// 当流程结束时，提取最后一行不以换行符结尾的行。
    /// **如果未找到则为空**（不要强制创建行）。
    mutating func flush() -> [String] {
        guard !pending.isEmpty else { return [] }
        let last = Self.decode(pending)
        pending.removeAll(keepingCapacity: false)
        return [last]
    }

    /// CRLF 的 `\r` 将被丢弃。直接查看 Windows 写入的日志会发现行尾不可见。
    /// 文本保持不变，差异仅在比较时才会显现，导致格式混乱。
    private static func decode(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}
