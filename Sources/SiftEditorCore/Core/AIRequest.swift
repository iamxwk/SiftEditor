import Foundation

/// 对  / AI 进行一次性查询（单次解析）。与提供商无关的内部表示。
/// 调用方负责限制输入范围；当前仅发送用户选定的文本。
struct AIPrompt: Equatable {
    var system: String?
    var user: String
    var maxTokens: Int
}

/// 一组纯函数，用于将提示符转换为提供商特定的 HTTP 格式，并进行响应分析。**无副作用 = 可测试**。
/// 实际传输由 GUI 层的 AIClient (URLSession) 处理。
enum AIRequestBuilder {
    struct AIError: Error, Equatable {
        let message: String
        /// HTTP 成功，但没有正文要显示（例如，推理标记的限制已用完）。
        /// 添加一个标记，使其与提供商的措辞区分开来，以便可以用用户的语言重新表述。
        var isEmptyResponse = false
        static let emptyResponse = AIError(message: "empty response", isEmptyResponse: true)
    }

    /// 汇编  / URLRequest。调用者从 [[Keychain]] 获取密钥并将其传递。
    /// 如果  / `stream` 为真，则会收到 SSE (`text/event-stream`) = 用于显示差异。
    static func makeRequest(_ prompt: AIPrompt, config: AIConfig, apiKey: String,
                            stream: Bool = false) throws -> URLRequest {
        guard !apiKey.isEmpty || !config.provider.requiresAPIKey else {
            throw AIError(message: "missing API key")
        }
        switch config.provider {
        case .anthropic: return anthropic(prompt, config: config, apiKey: apiKey, stream: stream)
        // Ollama 与 `/v1/chat/completions` 的发音相同，并且与 OpenAI 兼容。即使密钥为空。
        // 只需添加  `Authorization: Bearer `，Ollama 端就看不到它，所以不会造成任何损害。
        case .openAI, .ollama: return openAI(prompt, config: config, apiKey: apiKey, stream: stream)
        case .gemini:    return try gemini(prompt, config: config, apiKey: apiKey, stream: stream)
        }
    }

    private static func anthropic(_ p: AIPrompt, config: AIConfig, apiKey: String, stream: Bool) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": p.maxTokens,
            "messages": [["role": "user", "content": p.user]],
        ]
        if let system = p.system { body["system"] = system }
        // 关闭“思考”功能。除非另有说明，较新的 Claude（Opus 5 及更高版本）默认开启“思考”功能。
        // max_tokens 对“想法 + 正文”的总字数有限制 = 如果诊断很短，则可能在不显示正文的情况下达到字数上限。
        // 本节需要速度，因为它是问答格式，所以我们会明确地将其截断（并且还要防止在 [[AIPrompts]] 侧遗漏 XML 标签）。
        // 但是，对于始终处于思考状态的型号（Fable / Mythos），“关闭”设置本身是 400，所以不要碰它。
        if !Self.thinkingIsAlwaysOn(config.model) {
            body["thinking"] = ["type": "disabled"]
        }
        if stream { body["stream"] = true }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func openAI(_ p: AIPrompt, config: AIConfig, apiKey: String, stream: Bool) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var messages: [[String: String]] = []
        if let system = p.system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": p.user])
        // 输出的上限为 `max_completion_tokens`。`max_tokens` 已弃用，且为推理模型。
        // 发送时，（例如，o4-mini）将播放为 400“Unsupported parameter: 'max_tokens'”。
        // 请勿按型号名称排序（您可以输入列表中没有的型号 = 如果您按名称判断，肯定会遗漏一些型号）。
        // 新名称总是发送到当前的 chat/completions，因为它是普遍接受的。
        // 注意，在推理系统中，思维标记也包含在这个上限中 = 如果它们太短，文本将为空。
        var body: [String: Any] = [
            "model": config.model,
            "max_completion_tokens": p.maxTokens,
            "messages": messages,
        ]
        if stream { body["stream"] = true }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Gemini (generativelanguage)。型号为 URL，进入路径 (`models/<model>:generateContent`)。
    /// 键在头部为 `x-goog-api-key`。system 为 `system_instruction`，主体为 `contents`。
    /// 流方法名称已更改 (`:streamGenerateContent`)，需要 `?alt=sse` 才能将其更改为 SSE。
    private static func gemini(_ p: AIPrompt, config: AIConfig, apiKey: String, stream: Bool) throws -> URLRequest {
        // 模型路径包含冒号，因此我们避免使用 appendingPathComponent（它会将冒号转换为 %3A），而是将其构造为字符串。
        let base = config.baseURL.absoluteString.hasSuffix("/")
            ? String(config.baseURL.absoluteString.dropLast()) : config.baseURL.absoluteString
        let method = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        guard let url = URL(string: "\(base)/v1beta/models/\(config.model):\(method)") else {
            throw AIError(message: "invalid Gemini URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        var body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": p.user]]]],
            "generationConfig": ["maxOutputTokens": p.maxTokens],
        ]
        if let system = p.system {
            body["system_instruction"] = ["parts": [["text": system]]]
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 这是个无法停止思考的模型吗？（Claude Fable / Mythos 一直在思考，）
    /// 发送  / `thinking: {"type":"disabled"}` 将返回 400。即使它不在列表中，您也可以输入。
    /// 这是根据  / 型号 ID 确定的。
    static func thinkingIsAlwaysOn(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("claude-fable") || m.hasPrefix("claude-mythos")
    }

    /// 获取提供商的错误格式 (`error.message`)。这三个错误格式相同。
    static func errorMessage(in obj: [String: Any]) -> String? {
        (obj["error"] as? [String: Any])?["message"] as? String
    }

    /// JSON：从正文中提取错误消息（如果正文不是 JSON，则为 nil）。
    static func errorMessage(in data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return errorMessage(in: obj)
    }

    /// 从  / 响应 JSON 中提取文本。同时捕获并发送提供商的错误格式 (`error.message`)。
    static func parseResponse(_ data: Data, provider: AIProvider) throws -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError(message: "invalid response")
        }
        if let msg = errorMessage(in: obj) { throw AIError(message: msg) }
        switch provider {
        case .anthropic:
            guard let content = obj["content"] as? [[String: Any]] else {
                throw AIError.emptyResponse
            }
            let text = content.compactMap { block -> String? in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }.joined()
            guard !text.isEmpty else { throw AIError.emptyResponse }
            return text
        case .openAI, .ollama:
            guard let choices = obj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String, !text.isEmpty else {
                throw AIError.emptyResponse
            }
            return text
        case .gemini:
            guard let candidates = obj["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw AIError.emptyResponse
            }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AIError.emptyResponse }
            return text
        }
    }
}
