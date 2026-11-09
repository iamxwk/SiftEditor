import Foundation

/// 流期间收到的项目。主文本差异、成功完成情况和提供商端错误。
enum AIStreamEvent: Equatable {
    case delta(String)
    case done
    case failure(String)
}

/// 将  / SSE (`text/event-stream`) 的字节序列拆分为行，并从每个提供商提取事件数据。
/// 一个纯粹的解码器，仅提取正文中的差异。**无副作用 = 可测试**。
/// 实际接收由 [[AIClient]] 的 URLSession 代表处理。
///
/// 数据块到达时在行中间断开，因此不完整的行被传递到下一个 `consume`。
/// 除  / `data:`（`event:` - 注释，`:` - 空行）之外的行将被丢弃 = 吸收提供商差异。
struct AIStreamDecoder {
    let provider: AIProvider
    private var pending = Data()

    init(provider: AIProvider) { self.provider = provider }

    /// 此函数接收接收到的数据块，并返回从已确认的行中提取的事件。
    mutating func consume(_ chunk: Data) -> [AIStreamEvent] {
        pending.append(chunk)
        var events: [AIStreamEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {   // \n
            let line = String(data: pending[..<newline], encoding: .utf8) ?? ""
            pending = Data(pending[pending.index(after: newline)...])
            events.append(contentsOf: self.events(fromLine: line))
        }
        return events
    }

    /// 接收完成。正在提取最后一行未以换行符结尾的数据。
    mutating func finish() -> [AIStreamEvent] {
        guard !pending.isEmpty else { return [] }
        let line = String(data: pending, encoding: .utf8) ?? ""
        pending = Data()
        return events(fromLine: line)
    }

    private func events(fromLine raw: String) -> [AIStreamEvent] {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }        // CRLF
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return [] }
        if payload == "[DONE]" { return [.done] }             // OpenAI 结束
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            return []
        }
        // 中间出现的错误（例如 Anthropic 中的 `event: error`）对于所有三个都是相同的形式。
        if let message = AIRequestBuilder.errorMessage(in: obj) { return [.failure(message)] }

        switch provider {
        case .anthropic:
            switch obj["type"] as? String {
            case "content_block_delta":
                guard let delta = obj["delta"] as? [String: Any],
                      (delta["type"] as? String) == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.delta(text)]
            case "message_stop":
                return [.done]
            default:
                return []                                     // ping / message_start / usage 等
            }
        case .openAI, .ollama:
            guard let choices = obj["choices"] as? [[String: Any]] else { return [] }
            let text = choices.compactMap { ($0["delta"] as? [String: Any])?["content"] as? String }.joined()
            return text.isEmpty ? [] : [.delta(text)]
        case .gemini:
            guard let candidates = obj["candidates"] as? [[String: Any]] else { return [] }
            let text = candidates.compactMap { candidate -> String? in
                guard let content = candidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else { return nil }
                return parts.compactMap { $0["text"] as? String }.joined()
            }.joined()
            return text.isEmpty ? [] : [.delta(text)]
        }
    }
}
