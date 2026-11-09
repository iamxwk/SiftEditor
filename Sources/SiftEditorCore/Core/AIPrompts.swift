import Foundation

/// 一组专门用于日志/文本查看器的单行提示。**纯函数 = 可测试**。
/// 这不是通用聊天室，而是专门用于“将 AI 引导至您当前正在查看的位置”。
enum AIPrompts {

    /// 选定错误 / 堆栈跟踪 / 对神秘日志行的原因的推测。
    /// - Parameter language: 用于响应的语言名称（UI 应用程序的语言。即使日志是英文的，也会以用户的语言返回）。
    static func errorCause(_ selection: String, language: String) -> AIPrompt {
        let system = """
        You are a debugging assistant embedded in a log/text viewer. \
        Given a log excerpt, stack trace, or error message, explain concisely: \
        (1) what went wrong, (2) the most likely root cause, (3) one concrete next step to fix or investigate. \
        Reply in \(language), regardless of the language of the excerpt. \
        Be brief and specific; do not repeat the input back. \
        Use plain text only — no Markdown, no asterisks, no backticks, no headings. \
        Do not include internal or system XML tags in your response.
        """
        // 2048：推理模型（例如 Gemini 和 flash-latest）使用标记进行思考，而使用 1024 个标记时，答案可能会在中途被截断。
        return AIPrompt(system: system, user: selection, maxTokens: 2048)
    }

    /// 连接测试（首选项中的“连接测试”按钮）。
    /// 关键型号 ID，基本型号 URL，SSE：使用与实际生产环境相同的路线执行一次往返，直到收到为止，以此验证流程。
    /// 我不会查看答案的内容（收到答案本身就是答案），所以请尽可能简短地回复。
    static func connectionTest() -> AIPrompt {
        let system = "Reply with exactly the two characters: OK"
        // 上限为“思想 + 文本”之和 = 推理系统模型（Gemini flash、OpenAI o 系统，思想不会中断）
        // 如果键正确但文本为空，则  Claude Fable 等）可解释为失败。
        // 没有上限（您只需为实际使用的量付费），因此请像进行诊断一样预留足够的余地。
        return AIPrompt(system: system, user: "ping", maxTokens: 2048)
    }

    /// 自然语言 → 正则表达式。如果直接将其输入到搜索/筛选窗口中，则仅返回 regex 正文。
    static func naturalLanguageToRegex(_ description: String) -> AIPrompt {
        let system = """
        You convert a natural-language description into a single regular expression \
        for searching and filtering log lines. Output ONLY the regular expression itself — \
        no explanation, no code fences, no surrounding delimiters, no flags. \
        Use ICU / NSRegularExpression syntax (the viewer supports lookahead and lookbehind).
        """
        // 输出 regex 本身很短，但推理模型（Gemini、flash-latest 等）使用标记进行思考，
        // 使用  256 会耗尽思考过程中的所有数据，导致输出为空。请预留一些余量（因为只提取 regex 主体，所以浪费较少）。
        return AIPrompt(system: system, user: description, maxTokens: 1024)
    }

    /// 从模型输出中提取 regex 主单元（删除代码围栏、周围的斜杠、前导和尾随空格以及说明行）。
    /// 即使模型未遵循说明，而是用代码块或 `/pattern/` 包裹正则，也会格式化为可填入搜索栏的内容。
    static func extractRegex(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // “`...`” 移除围栏。
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])            // ```regex 垂线
            } else {
                s = String(s.dropFirst(3))
            }
            if let close = s.range(of: "```", options: .backwards) {
                s = String(s[..<close.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 如果还有多行，则取第一行非空行（以防解释混入其中）。
        if let firstLine = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            s = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // / 从  /pattern/ 中删除周围的斜杠。
        if s.count >= 2, s.hasPrefix("/"), let last = s.lastIndex(of: "/"), last != s.startIndex {
            let inner = String(s[s.index(after: s.startIndex)..<last])
            if !inner.isEmpty { s = inner }
        }
        return s
    }
}
