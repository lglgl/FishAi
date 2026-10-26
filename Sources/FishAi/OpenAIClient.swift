import Foundation

/// OpenAI 兼容的 Chat Completions 客户端，支持流式输出
enum OpenAIClient {
    struct Config {
        var baseURL: String
        var apiKey: String
        var model: String
        var systemPrompt: String
        var userPrompt: String
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 提示词中可用的变量：{from} 源语言、{to} 目标语言、{text} 原文
    static func translate(
        _ text: String, from: String, to: String, config: Config,
        onDelta: @MainActor (String) -> Void
    ) async throws {
        let fill = { (template: String) in
            template
                .replacingOccurrences(of: "{from}", with: from)
                .replacingOccurrences(of: "{to}", with: to)
                .replacingOccurrences(of: "{text}", with: text)
        }
        var messages: [[String: String]] = []
        let system = fill(config.systemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": fill(config.userPrompt)])

        var request = URLRequest(url: try endpoint(config.baseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "stream": true,
            "messages": messages,
        ] as [String: Any])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse

        // 非流式响应（报错或服务端不支持 stream）：读完整个 body 再解析
        if http?.statusCode != 200 || http?.mimeType != "text/event-stream" {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard http?.statusCode == 200 else {
                let detail = (json?["error"] as? [String: Any])?["message"] as? String
                    ?? String(data: data, encoding: .utf8) ?? ""
                throw APIError(message: "HTTP \(http?.statusCode ?? 0)：\(detail)")
            }
            let choice = (json?["choices"] as? [[String: Any]])?.first
            guard let content = (choice?["message"] as? [String: Any])?["content"] as? String else {
                throw APIError(message: "无法解析响应")
            }
            await onDelta(content)
            return
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (json["choices"] as? [[String: Any]])?.first,
                  let content = (choice["delta"] as? [String: Any])?["content"] as? String,
                  !content.isEmpty else { continue }
            await onDelta(content)
        }
    }

    /// 接受 `https://host/v1` 或完整的 `.../chat/completions`
    private static func endpoint(_ baseURL: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base), url.scheme?.hasPrefix("http") == true else {
            throw APIError(message: "Base URL 无效")
        }
        return url
    }
}
