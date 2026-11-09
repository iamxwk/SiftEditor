import XCTest
@testable import SiftEditorCore

/// 本文件验证了/AI协作（BYOK）的纯核心部分。网络传输和GUI不包含在内。
/// `AIConfig`（默认/覆盖/仅限 https）・`AIRequestBuilder`（汇编/分析/错误）・
/// `AIPrompts.extractRegex`（围栏/围墙/说明移除）受到攻击。
final class AITests: XCTestCase {

    // MARK: - AIConfig

    func testDefaultConfig() {
        let c = AIConfig.default
        XCTAssertEqual(c.provider, .anthropic)
        XCTAssertEqual(c.model, "claude-opus-4-8")
        XCTAssertEqual(c.baseURL, URL(string: "https://api.anthropic.com"))
    }

    func testBaseURLOverrideHTTPSOnly() {
        // ：有效的 https 覆盖已接受。
        var c = AIConfig(provider: .openAI, model: "m", baseURLOverride: "https://proxy.example.com")
        XCTAssertEqual(c.baseURL, URL(string: "https://proxy.example.com"))
        // 纯文本 http 被拒绝 = 回退到默认值（分发 .app 中 ATS 没有例外）。
        c.baseURLOverride = "http://insecure.example.com"
        XCTAssertEqual(c.baseURL, AIProvider.openAI.defaultBaseURL)
        // 空也是默认值。
        c.baseURLOverride = ""
        XCTAssertEqual(c.baseURL, AIProvider.openAI.defaultBaseURL)
    }

    /// `AppSettings.aiConfig` 经 JSON 编码保存在 Keychain；往返必须保留用户选择。
    func testConfigCodableRoundTrip() throws {
        let c = AIConfig(provider: .gemini, model: "gemini-flash-latest",
                         baseURLOverride: "https://proxy.example.com")
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(AIConfig.self, from: data)
        XCTAssertEqual(decoded, c)
    }

    /// **可以通过 [[Keychain]] 重新加载提供商模型选择。
    ///
    /// 验证提供商选择可从 Keychain 恢复，避免意外回退到默认提供商。
    func testAIConfigRoundTripsThroughKeychain() {
        let saved = AppSettings.aiConfig
        defer { AppSettings.aiConfig = saved }

        let c = AIConfig(provider: .gemini, model: "gemini-flash-latest", baseURLOverride: "")
        AppSettings.aiConfig = c
        XCTAssertEqual(AppSettings.aiConfig, c)

        // 只需查看  Keychain 即可读取相同的值（确认它不依赖于 UserDefaults）。
        guard let json = Keychain.get(account: "ai.sharedConfig") else {
            return XCTFail("Keychain に複製されていない")
        }
        let decoded = try? JSONDecoder().decode(AIConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, c)
    }

    // MARK: - AIRequestBuilder（組立）

    private func body(_ req: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testMakeAnthropicRequest() throws {
        let cfg = AIConfig(provider: .anthropic, model: "claude-opus-4-8", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "hello", maxTokens: 512), config: cfg, apiKey: "sk-ant-XXX")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-XXX")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let b = body(req)
        XCTAssertEqual(b["model"] as? String, "claude-opus-4-8")
        XCTAssertEqual(b["max_tokens"] as? Int, 512)
        XCTAssertEqual(b["system"] as? String, "SYS")
        let msgs = b["messages"] as? [[String: Any]]
        XCTAssertEqual(msgs?.first?["role"] as? String, "user")
        XCTAssertEqual(msgs?.first?["content"] as? String, "hello")
    }

    func testMakeOpenAIRequest() throws {
        let cfg = AIConfig(provider: .openAI, model: "gpt-4o", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "hi", maxTokens: 256), config: cfg, apiKey: "sk-XXX")
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-XXX")
        XCTAssertNil(req.value(forHTTPHeaderField: "x-api-key"))
        let msgs = body(req)["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?.count, 2)
        XCTAssertEqual(msgs?[0]["role"], "system")
        XCTAssertEqual(msgs?[1]["role"], "user")
        XCTAssertEqual(msgs?[1]["content"], "hi")
    }

    func testMakeGeminiRequest() throws {
        let cfg = AIConfig(provider: .gemini, model: "gemini-2.5-flash", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "hi", maxTokens: 256), config: cfg, apiKey: "AIza-XXX")
        // 模型进入路径（冒号未转换为 %3A）/ 键为 x-goog-api-key。
        XCTAssertEqual(req.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-XXX")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let b = body(req)
        XCTAssertNotNil(b["system_instruction"])
        let contents = b["contents"] as? [[String: Any]]
        let parts = contents?.first?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "hi")
        let gen = b["generationConfig"] as? [String: Any]
        XCTAssertEqual(gen?["maxOutputTokens"] as? Int, 256)
    }

    func testParseGeminiResponse() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"likely OOM"}],"role":"model"}}]}"#
        let text = try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .gemini)
        XCTAssertEqual(text, "likely OOM")
    }

    func testParseGeminiErrorResponse() {
        let json = #"{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}"#
        XCTAssertThrowsError(try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .gemini)) { err in
            XCTAssertEqual((err as? AIRequestBuilder.AIError)?.message, "API key not valid")
        }
    }

    func testMissingKeyThrows() {
        XCTAssertThrowsError(try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 10), config: .default, apiKey: ""))
    }

    // MARK: - Ollama（无需本地密钥。B18）

    func testOllamaDoesNotRequireAPIKey() {
        XCTAssertFalse(AIProvider.ollama.requiresAPIKey)
        for p: AIProvider in [.anthropic, .openAI, .gemini] { XCTAssertTrue(p.requiresAPIKey) }
    }

    /// 即使使用空密钥也不会发送（其他提供商按 `testMissingKeyThrows` 发送）。
    func testMakeOllamaRequestWithoutKey() throws {
        let cfg = AIConfig(provider: .ollama, model: "llama3.2", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "hi", maxTokens: 256), config: cfg, apiKey: "")
        XCTAssertEqual(req.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        // 即使为空，Bearer 标头本身也会被附加（未检查 Ollama 端）。
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ")
        let msgs = body(req)["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?[1]["content"], "hi")
    }

    /// 默认值仍为 http（loopback 会以 ATS 和 NSAllowsLocalNetworking 的形式出现）。
    func testOllamaDefaultBaseURLIsPlainHTTP() {
        let cfg = AIConfig(provider: .ollama, model: "llama3.2", baseURLOverride: "")
        XCTAssertEqual(cfg.baseURL, URL(string: "http://localhost:11434"))
    }

    /// 如果目标是 loopback（例如，在不同的端口上运行时），则覆盖也会通过 http。
    /// 除了  / loopback 之外的 http 将被像以前一样拒绝，并恢复为默认设置。
    func testBaseURLOverrideAllowsLoopbackHTTP() {
        var cfg = AIConfig(provider: .ollama, model: "m", baseURLOverride: "http://127.0.0.1:1234")
        XCTAssertEqual(cfg.baseURL, URL(string: "http://127.0.0.1:1234"))
        cfg.baseURLOverride = "http://localhost:9999"
        XCTAssertEqual(cfg.baseURL, URL(string: "http://localhost:9999"))
        cfg.baseURLOverride = "http://not-local.example.com"
        XCTAssertEqual(cfg.baseURL, AIProvider.ollama.defaultBaseURL)
    }

    func testParseOllamaResponse() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"try -Xmx"}}]}"#
        let text = try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .ollama)
        XCTAssertEqual(text, "try -Xmx")
    }

    func testDecodeOllamaStream() {
        var d = AIStreamDecoder(provider: .ollama)
        let events = feed(&d, """
        data: {"choices":[{"delta":{"content":"try "}}]}

        data: {"choices":[{"delta":{"content":"-Xmx"}}]}

        data: [DONE]

        """)
        XCTAssertEqual(events, [.delta("try "), .delta("-Xmx"), .done])
    }

    // MARK: - AIRequestBuilder（解析）

    func testParseAnthropicResponse() throws {
        let json = #"{"content":[{"type":"text","text":"root cause: OOM"}],"stop_reason":"end_turn"}"#
        let text = try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .anthropic)
        XCTAssertEqual(text, "root cause: OOM")
    }

    func testParseOpenAIResponse() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"try -Xmx"}}]}"#
        let text = try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .openAI)
        XCTAssertEqual(text, "try -Xmx")
    }

    func testParseErrorResponse() {
        let json = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        XCTAssertThrowsError(try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .anthropic)) { err in
            XCTAssertEqual((err as? AIRequestBuilder.AIError)?.message, "invalid x-api-key")
        }
    }

    // MARK: - 模型候选（下拉菜单内容）

    func testSuggestedModelsIncludeDefault() {
        for provider in AIProvider.allCases {
            XCTAssertFalse(provider.suggestedModels.isEmpty, "\(provider) の候補が空")
            XCTAssertTrue(provider.suggestedModels.contains(provider.defaultModel),
                          "\(provider) の既定 \(provider.defaultModel) が候補に無い")
            // 列表是一个线索 = 如果存在重复项，则很难选择。
            XCTAssertEqual(Set(provider.suggestedModels).count, provider.suggestedModels.count)
        }
    }

    /// ID（OpenAI 兼容服务器等的专有型号）即使未列入候选名单，也将被接受。
    func testArbitraryModelIsUsedVerbatim() throws {
        let cfg = AIConfig(provider: .openAI, model: "my-local-llama", baseURLOverride: "https://llm.example.com")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8), config: cfg, apiKey: "k")
        XCTAssertEqual(body(req)["model"] as? String, "my-local-llama")
        XCTAssertEqual(req.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
    }

    // 输出  MARK: - OpenAI 的上限参数

    /// 在实际硬件 400 上发现：推理系统（o4-mini 等）拒绝 `max_tokens`，
    /// 请求  / `max_completion_tokens`。请始终发送新名称，不要按型号名称排序。
    func testOpenAIUsesMaxCompletionTokens() throws {
        for model in ["o4-mini", "gpt-4o", "gpt-4.1-mini", "my-local-llama"] {
            let cfg = AIConfig(provider: .openAI, model: model, baseURLOverride: "")
            let req = try AIRequestBuilder.makeRequest(
                AIPrompt(system: "SYS", user: "x", maxTokens: 2048), config: cfg, apiKey: "k")
            let b = body(req)
            XCTAssertEqual(b["max_completion_tokens"] as? Int, 2048, model)
            XCTAssertNil(b["max_tokens"], "\(model) に非推奨の max_tokens を送ってはいけない")
        }
    }

    /// 连接测试的上限包含一个思考缓冲区（以防止推理系统因文本为空而做出错误判断）。
    func testConnectionTestLeavesRoomForReasoning() {
        XCTAssertGreaterThanOrEqual(AIPrompts.connectionTest().maxTokens, 2048)
    }

    // MARK: - 2xx，但文本为空。

    /// 如果仅通过推理用完所有标记，即使有 200 个标记也无法生成文本。不要用英语，而要用用户的语言表达。
    func testEmptyResponseIsLocalized() {
        for json in ["{\"content\":[]}", "{\"content\":[{\"type\":\"text\",\"text\":\"\"}]}"] {
            XCTAssertThrowsError(
                try AIRequestBuilder.parseResponse(json.data(using: .utf8)!, provider: .anthropic)
            ) { error in
                XCTAssertEqual(error as? AIRequestBuilder.AIError, .emptyResponse)
                XCTAssertTrue((error as? AIRequestBuilder.AIError)?.isEmptyResponse == true)
            }
        }
        XCTAssertEqual(AIClient.ClientError.emptyResponse.errorDescription, L("ai.error.empty"))
        XCTAssertFalse(L("ai.error.empty").isEmpty)
        XCTAssertNotEqual(L("ai.error.empty"), "ai.error.empty")   // 密钥未按原样显示。
    }

    // MARK: - 针对思想令牌的对策 (Anthropic)

    /// Opus 5 及更高版本默认为“思考中”，除非另有说明 = 思考会消耗 max_tokens，并且主要文本不会出现在简短诊断中。
    /// 由于是问答形式，我将明确地将其截断。
    func testAnthropicDisablesThinking() throws {
        let cfg = AIConfig(provider: .anthropic, model: "claude-opus-5", baseURLOverride: "")
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: "SYS", user: "x", maxTokens: 2048), config: cfg, apiKey: "k")
        XCTAssertEqual((body(req)["thinking"] as? [String: String])?["type"], "disabled")
    }

    /// 具有始终开启思维的型号（Fable / Mythos）不会发送“关闭”消息，因为“关闭”设置本身为 400。
    func testAlwaysThinkingModelsGetNoThinkingField() throws {
        for model in ["claude-fable-5", "claude-mythos-5"] {
            let cfg = AIConfig(provider: .anthropic, model: model, baseURLOverride: "")
            let req = try AIRequestBuilder.makeRequest(
                AIPrompt(system: nil, user: "x", maxTokens: 2048), config: cfg, apiKey: "k")
            XCTAssertNil(body(req)["thinking"], "\(model) に thinking を送っている")
        }
        // 由型号 ID 确定（因为也可以输入不在列表中的 ID）。
        XCTAssertTrue(AIRequestBuilder.thinkingIsAlwaysOn("claude-fable-5"))
        XCTAssertFalse(AIRequestBuilder.thinkingIsAlwaysOn("claude-opus-5"))
    }

    // MARK: - 我亲自验证过的型号注册信息

    func testRememberedModelsComeFirstAndDeduplicate() {
        let p = AIProvider.gemini
        let choices = p.modelChoices(remembered: ["my-tuned-model", "gemini-pro-latest"])
        XCTAssertEqual(choices.first, "my-tuned-model")            // 我的条目排在最前面
        XCTAssertEqual(choices.filter { $0 == "gemini-pro-latest" }.count, 1)  // 未重复
        for suggested in p.suggestedModels { XCTAssertTrue(choices.contains(suggested)) }
    }

    func testModelChoicesIgnoreBlanks() {
        let choices = AIProvider.openAI.modelChoices(remembered: ["", "   ", "custom"])
        XCTAssertEqual(choices.first, "custom")
        XCTAssertFalse(choices.contains(""))
    }

    func testModelChoicesWithoutRememberedIsJustSuggestions() {
        for p in AIProvider.allCases {
            XCTAssertEqual(p.modelChoices(remembered: []), p.suggestedModels)
        }
    }

    /// 候选人数不应“太少”（选择范围不依赖于打字）。
    func testSuggestedModelsAreEnoughToChooseFrom() {
        for provider in AIProvider.allCases {
            XCTAssertGreaterThanOrEqual(provider.suggestedModels.count, 3,
                                        "\(provider) の候補が少なすぎる")
        }
    }

    /// 如果思维过程被打断，内部标签可能会泄露到正文中，因此提示符端也会阻止这种情况。
    func testErrorCausePromptForbidsInternalTags() {
        let p = AIPrompts.errorCause("x", language: "Japanese")
        XCTAssertTrue(p.system?.contains("XML") ?? false)
    }

    // MARK: - 失败中使用的词语（日文标题 + 提供商原文）

    func testProviderErrorSpeaksUserLanguage() {
        let raw = "models/gemini-does-not-exist is not found for API version v1beta"
        let text = AIClient.ClientError.provider(code: 404, message: raw).errorDescription ?? ""
        // ：第 1 行 = 发生了什么（用户语言），第 2 行及以后 = 原始文本（诊断线索）。
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("404"))
        XCTAssertNotEqual(lines[0], raw)                 // 标题并非原文的直接复制。
        XCTAssertTrue(text.contains(raw))                // 请勿丢弃原文。
    }

    func testProviderErrorHeadlineVariesByStatus() {
        func headline(_ code: Int) -> String {
            let d = AIClient.ClientError.provider(code: code, message: "x").errorDescription ?? ""
            return d.split(separator: "\n").first.map(String.init) ?? ""
        }
        // 401 / 404 / 429 / 5xx 是表达错误的不同方式（它们并非都是同一个 HTTP 错误）。
        let heads = [headline(401), headline(404), headline(429), headline(503)]
        XCTAssertEqual(Set(heads).count, 4, "状態ごとの言い分けが足りない: \(heads)")
        for (code, h) in zip([401, 404, 429, 503], heads) { XCTAssertTrue(h.contains("\(code)")) }
    }

    // MARK: - 连接测试

    func testConnectionTestPromptIsTiny() {
        let p = AIPrompts.connectionTest()
        XCTAssertFalse(p.user.isEmpty)
        XCTAssertNotNil(p.system)
        // 对请求的响应长度为 2 个字符，但上限是“思想 + 文本”的总和 = 推理模型通过思考将其全部消耗掉。
        // 没有上限（您只需为使用的量付费），因此请预留与诊断中相同的余地，以防止误诊。
        XCTAssertGreaterThan(p.maxTokens, 0)
        XCTAssertLessThanOrEqual(p.maxTokens, AIPrompts.errorCause("x", language: "English").maxTokens)
    }

    // MARK: - 流式传输（汇编）

    func testStreamRequestsOptIn() throws {
        let anthropic = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8),
            config: AIConfig(provider: .anthropic, model: "m", baseURLOverride: ""), apiKey: "k", stream: true)
        XCTAssertEqual(body(anthropic)["stream"] as? Bool, true)

        let openAI = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8),
            config: AIConfig(provider: .openAI, model: "m", baseURLOverride: ""), apiKey: "k", stream: true)
        XCTAssertEqual(body(openAI)["stream"] as? Bool, true)

        // 使用方法名称和 ?alt=sse 切换  Gemini（不要在正文中包含 stream）。
        let gemini = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8),
            config: AIConfig(provider: .gemini, model: "gemini-flash-latest", baseURLOverride: ""),
            apiKey: "k", stream: true)
        XCTAssertEqual(gemini.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:streamGenerateContent?alt=sse")
        XCTAssertNil(body(gemini)["stream"])
    }

    func testNonStreamRequestsUnchanged() throws {
        // 默认值（省略 stream）与之前相同 = 非流。
        let req = try AIRequestBuilder.makeRequest(
            AIPrompt(system: nil, user: "x", maxTokens: 8), config: .default, apiKey: "k")
        XCTAssertNil(body(req)["stream"])
    }

    // MARK: - 流媒体（SSE 的解释）

    private func feed(_ decoder: inout AIStreamDecoder, _ text: String) -> [AIStreamEvent] {
        decoder.consume(Data(text.utf8))
    }

    func testDecodeAnthropicStream() {
        var d = AIStreamDecoder(provider: .anthropic)
        var events = feed(&d, """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OOM "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"が原因"}}

        event: message_stop
        data: {"type":"message_stop"}

        """)
        events.append(contentsOf: d.finish())
        XCTAssertEqual(events, [.delta("OOM "), .delta("が原因"), .done])
    }

    func testDecodeOpenAIStream() {
        var d = AIStreamDecoder(provider: .openAI)
        let events = feed(&d, """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"try "}}]}

        data: {"choices":[{"delta":{"content":"-Xmx"}}]}

        data: [DONE]

        """)
        XCTAssertEqual(events, [.delta("try "), .delta("-Xmx"), .done])
    }

    func testDecodeGeminiStream() {
        var d = AIStreamDecoder(provider: .gemini)
        let events = feed(&d, """
        data: {"candidates":[{"content":{"parts":[{"text":"ヒープ"}],"role":"model"}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"不足"}],"role":"model"}}]}

        """)
        XCTAssertEqual(events, [.delta("ヒープ"), .delta("不足")])
    }

    /// 数据块到达时在行中间断开。它们可以被带过并重新构建成一个单独的差异。
    func testDecodeSplitAcrossChunks() {
        var d = AIStreamDecoder(provider: .anthropic)
        XCTAssertEqual(feed(&d, #"data: {"type":"content_block_delta","delta":{"type":"text_"#), [])
        XCTAssertEqual(feed(&d, "delta\",\"text\":\"半分\"}}\n"), [.delta("半分")])
    }

    /// CRLF：即使丢弃注释行和空行，正文仍然保留。
    func testDecodeIgnoresNoiseLines() {
        var d = AIStreamDecoder(provider: .openAI)
        let events = feed(&d, ": ping\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\r\n")
        XCTAssertEqual(events, [.delta("ok")])
    }

    /// 过程中发生的错误事件将被视为失败。
    func testDecodeMidStreamError() {
        var d = AIStreamDecoder(provider: .anthropic)
        let events = feed(&d, """
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """)
        XCTAssertEqual(events, [.failure("Overloaded")])
    }

    func testErrorMessageFromBody() {
        let json = #"{"error":{"message":"invalid x-api-key"}}"#
        XCTAssertEqual(AIRequestBuilder.errorMessage(in: Data(json.utf8)), "invalid x-api-key")
        XCTAssertNil(AIRequestBuilder.errorMessage(in: Data("not json".utf8)))
    }

    // MARK: - AIPrompts.extractRegex

    func testExtractRegexPlain() {
        XCTAssertEqual(AIPrompts.extractRegex(from: #"ERROR|FATAL"#), "ERROR|FATAL")
    }

    func testExtractRegexTrimsWhitespace() {
        XCTAssertEqual(AIPrompts.extractRegex(from: "  \n\\d{3}\n  "), #"\d{3}"#)
    }

    func testExtractRegexStripsCodeFence() {
        let raw = "```regex\n^(?!.*200 ).*POST.*$\n```"
        XCTAssertEqual(AIPrompts.extractRegex(from: raw), "^(?!.*200 ).*POST.*$")
    }

    func testExtractRegexStripsBareFence() {
        XCTAssertEqual(AIPrompts.extractRegex(from: "```\nfoo.*bar\n```"), "foo.*bar")
    }

    func testExtractRegexStripsSlashes() {
        XCTAssertEqual(AIPrompts.extractRegex(from: "/^abc$/"), "^abc$")
    }

    func testExtractRegexTakesFirstNonEmptyLine() {
        // 当解释混杂在一起时，使用第一个非空行。
        XCTAssertEqual(AIPrompts.extractRegex(from: "\n\n\\bwarn\\b\nthis matches warnings"), #"\bwarn\b"#)
    }

    // MARK: - AIPrompts（模板内容）

    func testErrorCausePromptCarriesSelection() {
        let p = AIPrompts.errorCause("NullPointerException at Foo.bar", language: "Japanese")
        XCTAssertEqual(p.user, "NullPointerException at Foo.bar")
        XCTAssertNotNil(p.system)
        XCTAssertTrue(p.system?.contains("Japanese") ?? false)   // UI 被指示以该语言返回。
        XCTAssertGreaterThan(p.maxTokens, 0)
    }

    func testRegexPromptBudget() {
        let p = AIPrompts.naturalLanguageToRegex("4xx 以外の POST")
        XCTAssertEqual(p.user, "4xx 以外の POST")
        // regex 主体较短，但需要一些空间来容纳推理标记。它小于错误诊断值且大于 0。
        XCTAssertGreaterThan(p.maxTokens, 0)
        XCTAssertLessThanOrEqual(p.maxTokens, AIPrompts.errorCause("x", language: "English").maxTokens)
    }
}
