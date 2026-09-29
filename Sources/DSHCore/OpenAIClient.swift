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
                    let result = try await client.runTurn(request, onText: { delta in
                        continuation.yield(.text(delta))
                    }, onReasoning: { delta in
                        continuation.yield(.reasoning(delta))
                    })
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

    /// Probe the server for the active model's metadata (context window, the
    /// id it really serves, etc.).
    ///
    /// `contextWindow` is `nil` when no live source answered — deliberately:
    /// the caller applies the static fallback tables fresh each time, so a
    /// transient miss never locks a guessed window in as "learned".
    ///
    /// Sources, in order:
    ///  1. `GET /v1/models` — vLLM and SGLang both report `max_model_len` here
    ///     (1000000 for the Spark's YaRN 1M serve, 524288 for Flash at 512K).
    ///     If the configured id isn't listed but the server serves exactly one
    ///     model, that one is used (and reported as `id`): a box whose model
    ///     was swapped keeps working instead of 404ing.
    ///  2. SGLang's `/get_model_info` / `/get_server_info` (`context_len` /
    ///     `context_length`), at `/v1/…` and at the server root.
    public func modelInfo(_ model: String? = nil) async -> ModelInfo? {
        let id = model?.isEmpty == false ? model! : profile.model
        var limit: Int? = nil
        var maxOut: Int? = nil
        var resolved = id
        var served: [String] = []

        if let url = URL(string: profile.endpoint(path: "models")) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            applyHeaders(&req)
            if let (data, response) = try? await session.data(for: req),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["data"] as? [[String: Any]] {
                served = arr.compactMap { $0["id"] as? String }
                var hit = arr.first { ($0["id"] as? String) == id }
                    ?? arr.first { Self.matchesModel(($0["id"] as? String) ?? "", id) }
                if hit == nil, arr.count == 1 { hit = arr[0] }
                if let hit {
                    resolved = (hit["id"] as? String) ?? id
                    limit = Self.contextWindow(from: hit)
                    maxOut = hit["max_tokens"] as? Int
                }
            }
        }
        if limit == nil { limit = await sglangContextLength() }
        return ModelInfo(id: resolved, contextWindow: limit, maxTokens: maxOut, servedModels: served)
    }

    /// SGLang-specific metadata routes. They live at the server root, but the
    /// base URL usually ends in `/v1` (and behind a proxy the root may belong
    /// to something else entirely, which answers HTML — ignored), so try both.
    private func sglangContextLength() async -> Int? {
        let root = Self.strippingV1(profile.baseURL)
        let candidates: [String] = [
            profile.endpoint(path: "get_model_info"), root + "/get_model_info",
            profile.endpoint(path: "get_server_info"), root + "/get_server_info",
        ]
        for url in candidates.compactMap(URL.init) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            applyHeaders(&req)
            guard let (data, response) = try? await session.data(for: req),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let v = obj["context_len"] as? Int, v > 0 { return v }
            if let v = obj["context_length"] as? Int, v > 0 { return v }
        }
        return nil
    }

    /// A base URL with a trailing "/v1" removed, so we can hit root-level SGLang
    /// routes even when the provider was configured with the OpenAI path.
    static func strippingV1(_ baseURL: String) -> String {
        var s = baseURL
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s = String(s.dropLast(3)) }
        return s
    }

    /// Match the active model name against a `/models` entry id, tolerating the
    /// common shapes: exact, "vendor/model" vs "model", and Ollama tags.
    static func matchesModel(_ entryID: String, _ requested: String) -> Bool {
        if entryID == requested { return true }
        let base = requested.components(separatedBy: "/").last ?? requested
        let entryBase = entryID.components(separatedBy: "/").last ?? entryID
        return entryID == base || entryBase == base
    }

    /// Parse the real context limit out of an overflow error body, e.g. SGLang's
    /// "This model's maximum context length is 262144 tokens; however, you
    /// requested 270000 tokens". Returns nil when the body carries no limit.
    static func overflowLimit(in body: String) -> Int? {
        let patterns = [
            "maximum context length is (\\d+)",
            "context length is (\\d+)",
            "exceed the maximum context length of (\\d+)",
            "max context length of (\\d+)",
            "maximum context tokens: (\\d+)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(body.startIndex..., in: body)
            if let m = regex.firstMatch(in: body, options: [], range: range),
               let r = Range(m.range(at: 1), in: body),
               let n = Int(body[r]), n > 0 {
                return n
            }
        }
        return nil
    }

    /// Pull a context-window figure out of the assorted field names servers use.
    static func contextWindow(from entry: [String: Any]) -> Int? {
        if let v = entry["context"] as? Int, v > 0 { return v }                 // Ollama
        if let v = entry["context_length"] as? Int, v > 0 { return v }          // some vLLM
        if let v = entry["max_context_length"] as? Int, v > 0 { return v }      // LM Studio
        if let v = entry["context_window"] as? Int, v > 0 { return v }          // OpenRouter
        if let v = entry["context_len"] as? Int, v > 0 { return v }             // SGLang (echoed on /models)
        if let v = entry["max_context_len"] as? Int, v > 0 { return v }         // SGLang
        if let v = entry["max_model_len"] as? Int, v > 0 { return v }           // vLLM / SGLang / llama.cpp
        // Not `max_total_tokens`: that is SGLang's KV-pool size, not a window.
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
                         onText: @escaping @Sendable (String) -> Void,
                         onReasoning: @escaping @Sendable (String) -> Void = { _ in },
                         isRetry: Bool = false) async throws -> TurnResult {
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
            // A chat template that rejects our effort word ("Unexpected
            // reasoning effort high. Supported types are xhigh (default),
            // medium, and low.") — learn the nearest accepted word and retry.
            if !isRetry, http.statusCode == 400,
               let requested = effortWord(for: request),
               let fix = Self.effortCorrection(requested: requested, errorBody: body) {
                ReasoningEffortCache.shared.learn(route: effortRoute(request), requested: requested, accepted: fix)
                return try await runTurn(request, onText: onText, onReasoning: onReasoning, isRetry: true)
            }
            // SGLang / vLLM report a context-overflow 400 as
            // "This model's maximum context length is N tokens; however, you requested M ...".
            if let limit = Self.overflowLimit(in: body) {
                throw LLMError.overflow(limit: limit, detail: body)
            }
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
                          pending: &pending, onText: onText, onReasoning: onReasoning)
            lineBuffer = ""
        }
        if !lineBuffer.isEmpty {
            try parseLine(lineBuffer, text: &text, usage: &usage, finish: &finish,
                          pending: &pending, onText: onText, onReasoning: onReasoning)
        }
        // A server may omit the final newline.
        if !raw.isEmpty {
            lineBuffer += String(decoding: raw, as: UTF8.self)
            if !lineBuffer.isEmpty {
                try parseLine(lineBuffer, text: &text, usage: &usage, finish: &finish,
                              pending: &pending, onText: onText, onReasoning: onReasoning)
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
                           onText: @escaping @Sendable (String) -> Void,
                           onReasoning: @escaping @Sendable (String) -> Void) throws {
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
            if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !r.isEmpty {
                onReasoning(r)
            }
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

    func makeBody(_ request: LLMRequest) throws -> Data {
        var messages: [[String: Any]] = []
        // Some OpenAI-compatible servers (SGLang on the DGX Spark, notably)
        // reject any request with more than one system message, or with one
        // anywhere but index 0 — e.g. after compaction inserts a "[Earlier
        // conversation, compacted]" note into the transcript as `.system`.
        // Collect every system-role message (the engine's own prompt plus
        // any the transcript carries) and merge them into a single leading
        // message so the wire request always has at most one, always first.
        var systemParts: [String] = []
        if !request.systemPrompt.isEmpty { systemParts.append(request.systemPrompt) }
        for m in request.messages {
            switch m.role {
            case .system:
                if let c = m.content, !c.isEmpty { systemParts.append(c) }
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
        if !systemParts.isEmpty {
            messages.insert(["role": "system", "content": systemParts.joined(separator: "\n\n")], at: 0)
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
        applyThinking(request, to: &body)
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { spec -> [String: Any] in
                // SGLang (Pydantic) rejects a bare "{}" string here — it must be
                // a real schema object, even for parameterless tools.
                var params: Any = ["type": "object", "properties": [String: Any]()]
                if let d = spec.parameters.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d),
                   let schema = o as? [String: Any] {
                    params = schema
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

    // MARK: Thinking

    /// The level in force for a request: the request's own, else the route's.
    func thinkingLevel(for request: LLMRequest) -> ThinkingLevel? {
        request.thinking ?? profile.thinking
    }

    private func effortRoute(_ request: LLMRequest) -> String {
        "\(profile.baseURL)|\(request.model.isEmpty ? profile.model : request.model)"
    }

    /// The effort word that will go on the wire (after any learned remap), or
    /// nil when none is sent.
    func effortWord(for request: LLMRequest) -> String? {
        guard let level = thinkingLevel(for: request), let word = level.wireEffort else { return nil }
        if let learned = ReasoningEffortCache.shared.accepted(route: effortRoute(request), requested: word) {
            return learned.isEmpty ? nil : learned
        }
        return word
    }

    /// Put the thinking controls on the request body.
    ///
    /// Self-hosted servers get `chat_template_kwargs` — that is how Qwen3.x,
    /// GLM and DeepSeek templates switch thinking on/off and read the effort —
    /// plus the top-level `reasoning_effort` (SGLang forwards it to the
    /// template too; vLLM's gpt-oss path reads it there). Hosted APIs only
    /// understand the top-level field, and only when thinking is on.
    func applyThinking(_ request: LLMRequest, to body: inout [String: Any]) {
        guard let level = thinkingLevel(for: request) else { return }
        let effort = effortWord(for: request)
        if profile.isSelfHosted && (profile.kind == .openAICompat || profile.kind == .openAI || profile.kind == .openRouter) {
            var kwargs: [String: Any] = ["enable_thinking": level != .off]
            if let effort {
                kwargs["reasoning_effort"] = effort
                body["reasoning_effort"] = effort
            }
            body["chat_template_kwargs"] = kwargs
        } else if profile.kind == .ollama || profile.kind == .lmStudio {
            if level == .off { body["chat_template_kwargs"] = ["enable_thinking": false] }
            if let effort { body["reasoning_effort"] = effort }
        } else if let effort {
            body["reasoning_effort"] = effort
        }
    }

    /// Effort vocabulary, weakest → strongest, for picking the nearest word a
    /// template accepts.
    static let effortRank: [String: Int] = [
        "none": 0, "minimal": 1, "low": 2, "medium": 3, "high": 4, "xhigh": 5, "max": 6,
    ]

    /// If `errorBody` is a template rejecting `requested`, the nearest effort
    /// it accepts ("" = send none). Nil when the error is about something else.
    static func effortCorrection(requested: String, errorBody: String) -> String? {
        let lower = errorBody.lowercased()
        guard lower.contains("reasoning effort") || lower.contains("reasoning_effort") else { return nil }
        guard lower.contains(requested.lowercased()) || lower.contains("supported") || lower.contains("invalid") else { return nil }
        // Pull the accepted words from the tail ("Supported types are xhigh (default), medium, and low").
        var tail = lower
        for marker in ["supported types are", "supported values are", "supported:", "must be one of", "expected one of", "supported"] {
            if let r = lower.range(of: marker) { tail = String(lower[r.upperBound...]); break }
        }
        let words = tail.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let accepted = Set(words.filter { effortRank[$0] != nil && $0 != requested.lowercased() })
        guard !accepted.isEmpty, let want = effortRank[requested.lowercased()] else { return "" }
        return accepted.min { a, b in
            let da = abs(effortRank[a]! - want), db = abs(effortRank[b]! - want)
            return da != db ? da < db : effortRank[a]! > effortRank[b]!   // tie → the stronger one
        }
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
        // SGLang on a DGX Spark typically serves these (native windows; the
        // live /get_model_info probe corrects them when YaRN or an extended
        // context_len is configured).
        "qwen3-30b-a3b": 32_768, "qwen3-32b": 32_768, "qwen3-235b-a22b": 32_768,
        "llama3.3-70b-instruct": 131_072, "llama3.1-8b-instruct": 131_072,
        "glm-4.5": 131_072, "glm-4.5-air": 131_072, "glm-4.6": 131_072,
    ]

    /// Prefix rules on the base name, checked after the exact table.
    private static let prefixes: [(String, Int)] = [
        ("llama-3.3-", 131_072), ("llama-3.1-", 131_072), ("llama-3.2-", 131_072),
        ("llama-4-", 1_048_576), ("llama4-", 1_048_576),
        // Qwen3.5 and later ship a 256K native window (262144); the probe
        // replaces this with the served figure (e.g. 1M under YaRN).
        ("qwen3.5", 262_144), ("qwen3.6", 262_144), ("qwen3.7", 262_144), ("qwen3.8", 262_144),
        ("qwen3.9", 262_144), ("qwen3-next", 262_144), ("qwen3-coder", 262_144),
        ("qwen3", 32_768), ("qwen2.5", 32_768), ("qwen2-72b", 131_072),
        ("deepseek-r1", 65_536), ("deepseek-v3", 131_072), ("deepseek", 65_536),
        ("gpt-4o", 128_000), ("gpt-4.1", 1_048_576), ("gpt-4", 128_000),
        ("claude-3.5", 200_000), ("claude-3", 100_000), ("claude-", 200_000),
        ("mistral-large", 131_072), ("mistral-small", 131_072),
        ("mixtral", 32_768), ("llama", 131_072), ("smollm", 131_072),
        ("glm-4.5", 131_072), ("glm-4.6", 131_072), ("glm-4", 131_072),
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

// MARK: - Learned reasoning-effort vocabulary

/// Per route (base URL + model), which effort word the server's template
/// actually accepts for each word we asked for — learned from its 400s so
/// the retry happens once, not on every request.
public final class ReasoningEffortCache: @unchecked Sendable {
    public static let shared = ReasoningEffortCache()
    private var map: [String: String] = [:]
    private let lock = NSLock()

    public func accepted(route: String, requested: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map["\(route)|\(requested)"]
    }

    public func learn(route: String, requested: String, accepted: String) {
        lock.lock(); defer { lock.unlock() }
        map["\(route)|\(requested)"] = accepted
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
    }
}
