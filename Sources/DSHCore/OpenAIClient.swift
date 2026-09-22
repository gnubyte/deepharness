import Foundation

// MARK: - OpenAI-compatible streaming client
//
// Talks to any server that speaks the OpenAI chat-completions API
// (OpenAI, OpenRouter, Ollama `/v1`, LM Studio, vLLM/SGLang on a DGX Spark,
// llama.cpp server, ...). The engine stays provider-agnostic through the
// `LLMClient` protocol; this is the only real-network implementation.
//
// Two tool-call shapes are understood:
//   1. native `tool_calls` deltas (OpenAI, vLLM, OpenRouter, LM Studio), and
//   2. the Qwen/DeepSeek XML convention emitted inside plain text, for
//      backends that lack function-calling (see `XMLToolCalls`).

public struct OpenAIClient: LLMClient {
    public let profile: ProviderProfile
    private let session: URLSession

    public init(profile: ProviderProfile, session: URLSession = .shared) {
        self.profile = profile
        var cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120   // per-chunk; idle streams time out
        cfg.timeoutIntervalForResource = 3_600
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
    }

    // MARK: LLMClient

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await client.runTurn(request) { delta in
                        continuation.yield(.text(delta))
                    }
                    continuation.yield(.done(calls: result.calls,
                                             finish: result.finish,
                                             usage: result.usage))
                    continuation.finish()
                } catch let e as URLError where e.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        guard let url = URL(string: profile.endpoint(path: "models")) else {
            throw LLMError.unsupported("bad base URL: \(profile.baseURL)")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        applyHeaders(&req)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else {
            throw LLMError.sse("unexpected /models payload")
        }
        return arr.compactMap { $0["id"] as? String }
    }

    /// Probe the server for the active model's metadata (context window, etc.).
    /// Returns `nil` rather than throwing so the caller can fall back to the
    /// well-known tables — a `/models` miss (wrong name, server that omits the
    /// field, or a 404) is not an error worth surfacing.
    public func modelInfo(_ model: String? = nil) async -> ModelInfo? {
        let id = model?.isEmpty == false ? model! : profile.model
        var limit: Int? = nil
        var maxOut: Int? = nil
        if let url = URL(string: profile.endpoint(path: "models")) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            applyHeaders(&req)
            do {
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = obj["data"] as? [[String: Any]] {
                    for entry in arr {
                        guard let eid = entry["id"] as? String, Self.matchesModel(eid, id) else { continue }
                        limit = Self.contextWindow(from: entry)
                        maxOut = (entry["max_tokens"] as? Int) ?? (entry["top_k"] as? Int)
                        // Ollama's full list can contain a "name" alias; prefer the exact hit.
                        if eid == id { break }
                    }
                }
            } catch {
                // Network down / 404 / unsupported route: fall through to tables.
            }
        }
        limit = limit ?? FallbackContextWindow.limit(for: id)
        return ModelInfo(id: id, contextWindow: limit, maxTokens: maxOut)
    }

    /// Match the active model name against a `/models` entry id, tolerating the
    /// common shapes: exact, "vendor/model" vs "model", and Ollama tags.
    static func matchesModel(_ entryID: String, _ requested: String) -> Bool {
        if entryID == requested { return true }
        let base = requested.components(separatedBy: "/").last ?? requested
        let entryBase = entryID.components(separatedBy: "/").last ?? entryID
        return entryID == base || entryBase == base
    }

    /// Pull a context-window figure out of the assorted field names servers use.
    static func contextWindow(from entry: [String: Any]) -> Int? {
        if let v = entry["context"] as? Int, v > 0 { return v }                 // Ollama
        if let v = entry["context_length"] as? Int, v > 0 { return v }          // some vLLM
        if let v = entry["max_context_length"] as? Int, v > 0 { return v }      // LM Studio
        if let v = entry["context_window"] as? Int, v > 0 { return v }          // OpenRouter
        return nil
    }

    // MARK: One streaming turn

    struct TurnResult: Sendable {
        let text: String
        let calls: [ToolCall]
        let finish: String?
        let usage: LLMUsage?
    }

    private func runTurn(_ request: LLMRequest,
                         onText: @escaping @Sendable (String) -> Void) async throws -> TurnResult {
        guard let url = URL(string: profile.endpoint(path: "chat/completions")) else {
            throw LLMError.unsupported("bad base URL: \(profile.baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&req)
        req.httpBody = try makeBody(request)

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errData = Data()
            for try await chunk in bytes {
                errData.append(chunk)
                if errData.count > 8_000 { break }
            }
            let body = String(decoding: errData, as: UTF8.self)
            throw LLMError.http(http.statusCode, body)
        }

        var text = ""
        var usage: LLMUsage?
        var finish: String?
        var pending: [Int: (id: String, name: String, args: String)] = [:]

        // Assemble complete lines from raw bytes so UTF-8 sequences that
        // span chunk boundaries never break.
        var raw = Data()
        var lineBuffer = ""
        for try await byte in bytes {
            raw.append(byte)
            guard byte == 0x0A else { continue }
            let lineBytes = raw.dropLast() // strip the newline
            lineBuffer += String(decoding: lineBytes, as: UTF8.self)
            raw.removeAll(keepingCapacity: true)
            try parseLine(lineBuffer, text: &text, usage: &usage, finish: &finish,
                          pending: &pending, onText: onText)
            lineBuffer = ""
        }
        if !lineBuffer.isEmpty {
            try parseLine(lineBuffer, text: &text, usage: &usage, finish: &finish,
                          pending: &pending, onText: onText)
        }
        // A server may omit the final newline.
        if !raw.isEmpty {
            lineBuffer += String(decoding: raw, as: UTF8.self)
            if !lineBuffer.isEmpty {
                try parseLine(lineBuffer, text: &text, usage: &usage, finish: &finish,
                              pending: &pending, onText: onText)
            }
        }

        var calls = pending
            .sorted { $0.key < $1.key }
            .map { entry -> ToolCall in
                ToolCall(id: entry.value.id.isEmpty ? "call-\(entry.key)" : entry.value.id,
                         name: entry.value.name,
                         arguments: entry.value.args.isEmpty ? "{}" : entry.value.args)
            }

        // XML tool-call fallback: some backends (Qwen on Ollama without
        // function-calling, older vLLM) emit tool blocks in the text instead.
        if calls.isEmpty, XMLToolCalls.containsBlock(text) {
            let parsed = XMLToolCalls.parse(text)
            for (i, p) in parsed.enumerated() {
                calls.append(ToolCall(id: "xml-\(i)", name: p.name,
                                      arguments: p.argumentsJSON.raw))
            }
        }

        return TurnResult(text: text, calls: calls, finish: finish, usage: usage)
    }

    private func parseLine(_ rawLine: String,
                           text: inout String,
                           usage: inout LLMUsage?,
                           finish: inout String?,
                           pending: inout [Int: (id: String, name: String, args: String)],
                           onText: @escaping @Sendable (String) -> Void) throws {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        // SSE: only "data:" lines matter (ignore event:, id:, keepalives).
        guard line.hasPrefix("data:") else { return }
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if payload == "[DONE]" { return }

        guard let data = payload.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return // ignore undecodable lines (keepalive pings etc.)
        }

        if let u = obj["usage"] as? [String: Any],
           let p = u["prompt_tokens"] as? Int,
           let c = u["completion_tokens"] as? Int, p > 0 || c > 0 {
            usage = LLMUsage(promptTokens: p, completionTokens: c)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else { return }

        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                text += content
                onText(content)
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let index = (tc["index"] as? Int) ?? 0
                    var entry = pending[index] ?? (id: "", name: "", args: "")
                    if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { entry.name = name }
                        if let args = fn["arguments"] as? String { entry.args += args }
                    }
                    pending[index] = entry
                }
            }
        }
        if let fr = first["finish_reason"] as? String { finish = fr }
    }

    // MARK: Request body

    private func makeBody(_ request: LLMRequest) throws -> Data {
        var messages: [[String: Any]] = []
        if !request.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": request.systemPrompt])
        }
        for m in request.messages {
            switch m.role {
            case .system:
                messages.append(["role": "system", "content": m.content ?? ""])
            case .user:
                messages.append(["role": "user", "content": userContent(for: m)])
            case .assistant:
                var msg: [String: Any] = ["role": "assistant"]
                msg["content"] = m.content ?? ""
                if let calls = m.toolCalls, !calls.isEmpty {
                    msg["tool_calls"] = calls.map { c -> [String: Any] in
                        ["id": c.id, "type": "function",
                         "function": ["name": c.name, "arguments": c.arguments.raw]]
                    }
                }
                messages.append(msg)
            case .tool:
                messages.append(["role": "tool",
                                 "tool_call_id": m.toolCallID ?? "",
                                 "content": m.content ?? ""])
            }
        }

        var body: [String: Any] = [
            "model": request.model.isEmpty ? profile.model : request.model,
            "messages": messages,
            "stream": true,
        ]
        // `include_usage` is an OpenAI/OpenRouter/vLLM extension; Ollama and
        // some older servers 400 on unknown fields, so only send it for
        // OpenAI-family endpoints.
        if profile.kind == .openAI || profile.kind == .openRouter || profile.kind == .openAICompat {
            body["stream_options"] = ["include_usage": true]
        }
        if let t = request.temperature ?? profile.temperature { body["temperature"] = t }
        if let mt = request.maxTokens ?? profile.maxOutputTokens { body["max_tokens"] = mt }
        // Reasoning effort for thinking models (OpenAI/OpenRouter/compat).
        if let effort = profile.reasoningEffort, !effort.isEmpty,
           profile.kind == .openAI || profile.kind == .openRouter || profile.kind == .openAICompat {
            body["reasoning_effort"] = effort
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { spec -> [String: Any] in
                var params: Any = "{}"
                if let d = spec.parameters.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) {
                    params = o
                }
                return ["type": "function",
                        "function": ["name": spec.name,
                                     "description": spec.description,
                                     "parameters": params]]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return data
    }

    /// Build the OpenAI `content` value for a user message. Plain text when
    /// there are no attachments, otherwise a multi-part array mixing text
    /// with image / file entries (images inline as base64 data-URIs).
    private func userContent(for m: LLMMessage) -> Any {
        guard let attachments = m.attachments, !attachments.isEmpty else {
            return m.content ?? ""
        }
        var parts: [[String: Any]] = []
        if let text = m.content, !text.isEmpty {
            parts.append(["type": "text", "text": text])
        }
        for a in attachments {
            switch a.kind {
            case .image:
                let b64 = a.data.base64EncodedString()
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(a.mime);base64,\(b64)"],
                ])
            case .file:
                let b64 = a.data.base64EncodedString()
                parts.append([
                    "type": "file",
                    "file": ["filename": a.name, "file_data": "data:\(a.mime);base64,\(b64)"],
                ])
            }
        }
        return parts
    }

    /// Authorization + user-supplied custom headers on every request.
    private func applyHeaders(_ req: inout URLRequest) {
        if let key = profile.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let headers = profile.customHeaders {
            for (k, v) in headers where !k.isEmpty {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
    }
}

// MARK: - Fallback context windows
//
// Servers that don't expose their limits (most vLLM/llama.cpp builds, older
// Ollama) fall back to these tables. Keyed on the last path component of the
// model name, so "meta-llama/Llama-3.3-70B-Instruct" and "Llama-3.3-70B-Instruct"
// both match, and an Ollama "qwen3:8b" tag resolves through its base name.

public enum FallbackContextWindow {
    /// Default when nothing else matches: 32k keeps the gauge honest without
    /// promising more than the model actually has.
    public static let defaultLimit = 32_768

    /// Exact id (last path component, Ollama tag stripped).
    private static let exact: [String: Int] = [
        "gpt-4o": 128_000, "gpt-4o-mini": 128_000, "gpt-4.1": 1_048_576,
        "gpt-4.1-mini": 1_048_576, "gpt-4.1-nano": 1_048_576, "o1": 200_000,
        "o3": 200_000, "o4-mini": 200_000, "o3-mini": 200_000,
        "qwen3:8b": 32_768, "qwen3:14b": 32_768, "qwen3:32b": 32_768,
        "qwen2.5:7b": 32_768, "qwen2.5:14b": 32_768, "qwen2.5:32b": 32_768,
        "qwen2.5-coder:7b": 32_768, "qwen2.5-coder:32b": 32_768,
        "llama3.1:8b": 131_072, "llama3.1:70b": 131_072, "llama3.2:8b": 131_072,
        "deepseek-r1:14b": 65_536, "deepseek-r1:32b": 65_536,
        "deepseek-r1:70b": 131_072, "mistral:7b": 32_768, "mixtral:8x7b": 32_768,
    ]

    /// Prefix rules on the base name, checked after the exact table.
    private static let prefixes: [(String, Int)] = [
        ("llama-3.3-", 131_072), ("llama-3.1-", 131_072), ("llama-3.2-", 131_072),
        ("llama-4-", 1_048_576), ("llama4-", 1_048_576),
        ("qwen3", 32_768), ("qwen2.5", 32_768), ("qwen2-72b", 131_072),
        ("deepseek-r1", 65_536), ("deepseek-v3", 131_072), ("deepseek", 65_536),
        ("gpt-4o", 128_000), ("gpt-4.1", 1_048_576), ("gpt-4", 128_000),
        ("claude-3.5", 200_000), ("claude-3", 100_000), ("claude-", 200_000),
        ("mistral-large", 131_072), ("mistral-small", 131_072),
        ("mixtral", 32_768), ("llama", 131_072), ("smollm", 131_072),
    ]

    /// Look up a context window for a model name, or nil if unknown.
    public static func limit(for modelID: String) -> Int? {
        // "meta-llama/Llama-3.3-70B-Instruct" → "Llama-3.3-70B-Instruct" → "llama-3.3-70b-instruct"
        let base = (modelID.components(separatedBy: "/").last ?? modelID).lowercased()
        if let hit = exact[base] { return hit }
        // Ollama tags: "qwen3:8b" → try "qwen3" prefix rules, base name "qwen3".
        let noTag = (base.components(separatedBy: ":").first ?? base)
        for (prefix, limit) in prefixes where noTag.hasPrefix(prefix) { return limit }
        // Bare base without the family prefix, e.g. "8b" models already caught above;
        // last resort: the full id in the exact table.
        return exact[modelID.lowercased()]
    }
}
