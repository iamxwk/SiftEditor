import Foundation

/// 实际向  / AI 发送单个查询的层 (URLSession)。组装和分析纯粹是 [[AIRequestBuilder]]。
/// 密钥为 [[Keychain]]，此部分仅负责发送/接收消息和错误消息。
/// 必须始终在主线程上调用完成（与 [[UpdateChecker]] 的样式相同）。
enum AIClient {

    enum ClientError: LocalizedError {
        case notConfigured          // 密钥未设置
        case network(Error)
        case http(Int)              // 2xx（如果无法从正文中检索消息）
        case api(String)            // 提供商错误消息（HTTP - 状态未知的情况）
        case emptyResponse          // 2xx，但没有文本可显示（例如，推理已达到其上限）。
        case provider(code: Int, message: String)   // 2xx（除此以外）+ 提供商消息

        var errorDescription: String? {
            switch self {
            case .notConfigured: return L("ai.error.notConfigured")
            case .network(let e): return e.localizedDescription
            case .http(let code): return L("ai.error.http", code)
            case .api(let msg):   return msg
            case .emptyResponse:  return L("ai.error.empty")
            // 服务提供商的消息是英文的。事件经过已用日语清楚地说明。
            // 原文如下，作为诊断线索（删除它将使调查变得不可能）。
            case .provider(let code, let message):
                return "\(Self.headline(code))\n\(message)"
            }
        }

        /// HTTP 根据状态，用用户的语言描述“发生了什么”。
        private static func headline(_ code: Int) -> String {
            switch code {
            case 401, 403: return L("ai.error.badKey", code)
            case 404:      return L("ai.error.notFound", code)
            case 429:      return L("ai.error.rateLimit", code)
            case 500...599: return L("ai.error.server", code)
            default:       return L("ai.error.http", code)
            }
        }
    }

    /// **流** prompt 使用当前设置 + Keychain 密钥。
    /// `onDelta` 是接收到的文本（主线程）的差异，`completion` 是结束（全文，or 失败）。
    /// 返回值句柄允许在中间取消（面板关闭/分析重新启动）。
    @discardableResult
    static func stream(_ prompt: AIPrompt,
                       onDelta: @escaping (String) -> Void,
                       completion: @escaping (Result<String, ClientError>) -> Void) -> AIStreamHandle {
        let handle = AIStreamHandle(onDelta: onDelta, completion: completion)
        let config = AppSettings.aiConfig
        let storedKey = Keychain.get(account: config.provider.keychainAccount) ?? ""
        guard !config.provider.requiresAPIKey || !storedKey.isEmpty else {
            handle.failLater(.notConfigured)
            return handle
        }
        let key = storedKey
        let request: URLRequest
        do {
            var r = try AIRequestBuilder.makeRequest(prompt, config: config, apiKey: key, stream: true)
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            // 等待第一份兼职工作的时间。每次收到差值时，此值都会更新。
            r.timeoutInterval = 60
            request = r
        } catch {
            handle.failLater(.notConfigured)
            return handle
        }
        handle.start(request: request, provider: config.provider)
        return handle
    }

    /// 使用当前设置 (AppSettings) + Keychain 键发送 prompt。
    static func send(_ prompt: AIPrompt,
                     completion: @escaping (Result<String, ClientError>) -> Void) {
        let config = AppSettings.aiConfig
        let key = Keychain.get(account: config.provider.keychainAccount) ?? ""
        guard !config.provider.requiresAPIKey || !key.isEmpty else {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }
        send(prompt, config: config, apiKey: key, completion: completion)
    }

    /// 发送时需明确指定设置和密钥（分开，以便在测试期间插入不同的提供商）。
    static func send(_ prompt: AIPrompt,
                     config: AIConfig,
                     apiKey: String,
                     completion: @escaping (Result<String, ClientError>) -> Void) {
        let request: URLRequest
        do {
            var r = try AIRequestBuilder.makeRequest(prompt, config: config, apiKey: apiKey)
            r.timeoutInterval = 60
            request = r
        } catch {
            DispatchQueue.main.async { completion(.failure(.notConfigured)) }
            return
        }

        let provider = config.provider
        let finish: (Result<String, ClientError>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error {
                finish(.failure(.network(error)))
                return
            }
            let data = data ?? Data()
            // 首先，分析文本。如果是提供商错误，则优先显示 message。
            do {
                let text = try AIRequestBuilder.parseResponse(data, provider: provider)
                finish(.success(text))
            } catch let e as AIRequestBuilder.AIError {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if e.isEmptyResponse { finish(.failure(.emptyResponse)) }
                else if (200...299).contains(code) || code == 0 { finish(.failure(.api(e.message))) }
                else { finish(.failure(.provider(code: code, message: e.message))) }
            } catch {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                finish(.failure(.http(code)))
            }
        }.resume()
    }
}

/// 指向当前流的句柄，也是 URLSession 的代理。
/// 委托队列为 main = 差分操作和已完成操作均在主线程上接收（遵循 [[AIClient]] 约定）。
/// 一旦关闭，将不会再调用任何函数（即使是 `cancel()` 之后的延迟差异也会被丢弃）。
final class AIStreamHandle: NSObject, URLSessionDataDelegate {
    private var onDelta: ((String) -> Void)?
    private var completion: ((Result<String, AIClient.ClientError>) -> Void)?
    private var session: URLSession?
    private var decoder: AIStreamDecoder?
    private var text = ""
    private var status = 200
    private var errorBody = Data()      // 当  不是 2xx 时会显示消息（错误信息为 JSON 而不是 SSE）

    init(onDelta: @escaping (String) -> Void,
         completion: @escaping (Result<String, AIClient.ClientError>) -> Void) {
        self.onDelta = onDelta
        self.completion = completion
    }

    fileprivate func start(request: URLRequest, provider: AIProvider) {
        decoder = AIStreamDecoder(provider: provider)
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        session.dataTask(with: request).resume()
    }

    /// 发送前发现故障（例如，密钥未设置）。通知将在调用方收到句柄后发送。
    fileprivate func failLater(_ error: AIClient.ClientError) {
        DispatchQueue.main.async { [weak self] in self?.finish(.failure(error)) }
    }

    /// 停止进一步的差异比较和补全。当面板关闭或分析重新启动时调用。
    func cancel() {
        onDelta = nil
        completion = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func finish(_ result: Result<String, AIClient.ClientError>) {
        guard let completion else { return }
        self.completion = nil
        onDelta = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion(result)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard completion != nil else { return }
        guard (200...299).contains(status) else { errorBody.append(data); return }
        for event in decoder?.consume(data) ?? [] {
            switch event {
            case .delta(let chunk):
                text += chunk
                onDelta?(chunk)
            case .done:
                break                       // 最后一步将在 didCompleteWithError 端统一。
            case .failure(let message):
                finish(.failure(.api(message)))
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard completion != nil else { return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { cancel(); return }
            finish(.failure(.network(error)))
            return
        }
        guard (200...299).contains(status) else {
            if let message = AIRequestBuilder.errorMessage(in: errorBody) {
                finish(.failure(.provider(code: status, message: message)))
            } else {
                finish(.failure(.http(status)))
            }
            return
        }
        // 我在结束之前挤出了最后一行没有换行符的文字。
        for event in decoder?.finish() ?? [] {
            if case .delta(let chunk) = event {
                text += chunk
                onDelta?(chunk)
            }
        }
        guard !text.isEmpty else { finish(.failure(.emptyResponse)); return }
        finish(.success(text))
    }
}
