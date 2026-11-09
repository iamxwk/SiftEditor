import Foundation

/// 支持  / BYOK（用户提供的密钥）的 AI 提供程序。
/// 费用由用户密钥持有者承担 = 该应用程序将其作为免费功能提供（M3.5 的故事引擎）。
enum AIProvider: String, CaseIterable, Codable {
    case anthropic
    case openAI
    case gemini
    /// 本地 Ollama（OpenAI 兼容 API）。无需密钥。B18。
    case ollama

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI:    return "OpenAI"
        case .gemini:    return "Google (Gemini)"
        case .ollama:    return "Ollama (local)"
        }
    }

    /// 您需要钥匙吗？**只有 Ollama 不需要钥匙**（它是本地的，所以没有人用钥匙保护它）。
    /// 有关  / [[AIClient]] 密钥要求保护和 [[AIRequestBuilder.makeRequest]] 空密钥拒绝，请参见此处。
    var requiresAPIKey: Bool { self != .ollama }

    /// 默认端点。可由 baseURLOverride 或 config 覆盖，并指向与 OpenAI 兼容的服务器。
    /// Ollama 是默认值，但使用 http 而不是本地 ATS 例外 (NSAllowsLocalNetworking)。
    /// 由于它已被添加到  / Info.plist，因此接收者将收到 127.0.0.1 / localhost / .local。
    var defaultBaseURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://api.anthropic.com")!
        case .openAI:    return URL(string: "https://api.openai.com")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com")!
        case .ollama:    return URL(string: "http://localhost:11434")!
        }
    }

    /// 要在“模型”下拉菜单中显示的候选模型。**第一个是默认值。**
    /// 该列表是一个线索，而不是一个限制（该字段是可编辑的 = 您也可以输入此处未列出的 ID）。
    /// 该型号将被重命名并停用，因此如果有别名，则别名将在列表中优先使用。
    var suggestedModels: [String] {
        switch self {
        case .anthropic:
            return ["claude-opus-5", "claude-sonnet-5",
                    "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
                    "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "o4-mini"]
        case .gemini:
            // `-latest` 是一个别名，始终指代当前版本。**请勿列出已修复版本**：确认时
            // gemini-2.5-flash 已显示 404 错误（已停止对新用户开放）。Google 是版本号。
            // 由于这些版本正在陆续停用，因此将修复版本添加到列表中会导致其失效。需要使用该版本的用户只需手动输入即可。
            // 如果连接测试成功， 下次将出现在列表中。
            return ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"]
        case .ollama:
            // 不同用户安装的型号可能有所不同。`ollama list` 安装的型号是正确的。
            // 这只是“通用名称”的一个线索。
            return ["llama3.2", "qwen2.5", "mistral", "gemma2"]
        }
    }

    /// 下拉菜单中实际显示的内容 = **我亲自验证过的模型（最新优先）+ 默认候选模型**。
    /// 如果您输入  / ID（该 ID 不在列表中），并且连接测试通过，那么从那以后您只需选择它即可。
    /// 重复项将被删除，已验证的项将显示在顶部（对于输入该项的人而言，这是“他们自己的列表”）。
    func modelChoices(remembered: [String]) -> [String] {
        var seen = Set<String>()
        return (remembered + suggestedModels).filter { model in
            let m = model.trimmingCharacters(in: .whitespaces)
            guard !m.isEmpty, !seen.contains(m) else { return false }
            seen.insert(m)
            return true
        }
    }

    /// 默认型号（初始值，可在首选项中更改）。**不一定是列表中的第一个**：
    /// 列表将按最新排序，但默认设置仍为在实际设备上测试的版本（您将无法切换版本）。
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openAI:    return "gpt-4o"
        case .gemini:    return "gemini-flash-latest"
        case .ollama:    return "llama3.2"
        }
    }

    /// API 是 Keychain 的帐户名，用于存储密钥（每个提供商可以有单独的帐户名）。
    var keychainAccount: String { "ai.\(rawValue).apiKey" }
}

/// AI 链接设置（**不包含密钥主体**。密钥放置在 [[Keychain]] 中，而不是纯文本 UserDefaults）。
/// `Codable` 用于在 UserDefaults 与 Keychain 间保存提供商设置（参见 [[AppSettings.aiConfig]]）。
struct AIConfig: Equatable, Codable {
    var provider: AIProvider
    var model: String
    /// OpenAI 用于指向兼容服务器等的基准。URL 覆盖（空 = 默认值）。**仅限 https。
    /// 但是，loopback/.local 也允许 http 通过**（分布式 .app 将是 ATS）
    /// 由于  / `NSAllowsLocalNetworking` 已被添加，因此只有该部分将以纯文本形式提供。
    /// 其他 http 值在实际设备上会导致 -1022。[[ats-url-fetch-https-only]])。
    var baseURLOverride: String

    static let `default` = AIConfig(provider: .anthropic,
                                    model: AIProvider.anthropic.defaultModel,
                                    baseURLOverride: "")

    /// Loopback / mDNS 等，`NSAllowsLocalNetworking` 或 ATS 是否是允许明文传输的对手？
    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    /// 实际使用的基础 URL。若覆盖值为有效的 HTTPS URL，或指向 loopback 的 HTTP URL，则使用该值；
    /// 如果未找到，则使用提供商默认值（这不起作用，因为 Ollama 的默认值是 http）。
    var baseURL: URL {
        if let u = URL(string: baseURLOverride), let host = u.host,
           u.scheme == "https" || (u.scheme == "http" && Self.isLocalHost(host)) {
            return u
        }
        return provider.defaultBaseURL
    }
}
