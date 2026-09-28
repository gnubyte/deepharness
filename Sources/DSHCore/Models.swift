import Foundation

// MARK: - Wire shapes (OpenAI-compatible chat completion, our internal currency)

/// A chat message in provider-neutral form.
public struct LLMMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String?
    /// Assistant tool calls, emitted after the message completes.
    public var toolCalls: [ToolCall]?
    /// For `role == .tool`: the call this result answers.
    public var toolCallID: String?
    /// For `role == .tool`: the tool that produced it.
    public var name: String?
    /// User-attached files/images sent alongside the text.
    public var attachments: [MessageAttachment]?
    /// Set on the synthetic user message that carries images a tool produced
    /// (names of the tools). Such messages are pruned to the newest few so a
    /// long debugging session doesn't fill the window with old screenshots.
    public var imageSource: String?

    public init(role: Role,
                content: String? = nil,
                toolCalls: [ToolCall]? = nil,
                toolCallID: String? = nil,
                name: String? = nil,
                attachments: [MessageAttachment]? = nil,
                imageSource: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.attachments = attachments
        self.imageSource = imageSource
    }

    public static func user(_ text: String, attachments: [MessageAttachment]? = nil) -> LLMMessage {
        .init(role: .user, content: text, attachments: attachments)
    }
    public static func system(_ text: String) -> LLMMessage {
        .init(role: .system, content: text)
    }
    public static func assistant(_ text: String, calls: [ToolCall] = []) -> LLMMessage {
        .init(role: .assistant, content: text, toolCalls: calls.isEmpty ? nil : calls)
    }
    public static func toolResult(id: String, name: String, output: String) -> LLMMessage {
        .init(role: .tool, content: output, toolCallID: id, name: name)
    }
}

/// A file or image the user attaches to a message.
public struct MessageAttachment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case image
        case file
    }
    public var kind: Kind
    public var name: String
    /// Raw content (base64-encoded on the wire for images).
    public var data: Data

    public init(kind: Kind, name: String, data: Data) {
        self.kind = kind
        self.name = name
        self.data = data
    }

    /// Best-effort MIME type from the filename extension.
    public var mime: String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}

/// One tool call requested by the model.
public struct ToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// JSON-encoded arguments, as sent by the model.
    public let arguments: JSONString

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = JSONString(arguments)
    }
}

/// A string we pass around as raw JSON.
public struct JSONString: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

// MARK: - Tool specifications (what we tell the model)

public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for arguments, as an object.
    public let parameters: String
}

// MARK: - Provider profiles

public struct ProviderProfile: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ollama        // 127.0.0.1:11434/v1
        case lmStudio      // 127.0.0.1:1234/v1
        case openAICompat  // any OpenAI-compatible server (vLLM, DGX Spark, ...)
        case openAI
        case openRouter
    }

    public var kind: Kind
    public var name: String
    public var baseURL: String
    public var apiKey: String?
    public var model: String
    public var temperature: Double?
    public var maxOutputTokens: Int?
    /// Explicit context-window override in tokens. When set, it wins over the
    /// server probe and the well-known fallback tables. Optional properties
    /// decode from saved profiles that predate this field (missing → nil).
    public var contextWindow: Int?
    /// Extra HTTP headers sent with every request (e.g. auth tokens, org IDs).
    public var customHeaders: [String: String]?
    /// Default thinking level for this route, stored as a `ThinkingLevel` raw
    /// value ("off", "low", "medium", "high", "max"); nil = the server's own
    /// default. (Older builds stored "low"/"medium"/"high" here, which decode
    /// unchanged.) Sessions can override it — see `ThinkingLevel`.
    public var reasoningEffort: String?

    public init(kind: Kind, name: String, baseURL: String, apiKey: String? = nil,
                model: String, temperature: Double? = nil, maxOutputTokens: Int? = nil,
                contextWindow: Int? = nil,
                customHeaders: [String: String]? = nil, reasoningEffort: String? = nil) {
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.contextWindow = contextWindow
        self.customHeaders = customHeaders
        self.reasoningEffort = reasoningEffort
    }

    public static let presets: [ProviderProfile] = [
        .init(kind: .ollama, name: "Ollama (local)", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b"),
        .init(kind: .lmStudio, name: "LM Studio (local)", baseURL: "http://127.0.0.1:1234/v1", model: "local-model"),
        .init(kind: .openAICompat, name: "DGX Spark / vLLM (LAN)", baseURL: "http://DGX-SPARK-ADDRESS:8002/v1", model: "my-ai"),
        .init(kind: .openAI, name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o"),
        .init(kind: .openRouter, name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "qwen/qwen3-32b"),
    ]

    public func endpoint(path: String) -> String {
        baseURL.hasSuffix("/") ? "\(baseURL)\(path)" : "\(baseURL)/\(path)"
    }

    /// The route's default thinking level (nil = leave it to the server).
    public var thinking: ThinkingLevel? {
        get { reasoningEffort.flatMap(ThinkingLevel.init(rawValue:)) }
        set { reasoningEffort = newValue?.rawValue }
    }

    /// True for a server you run yourself (vLLM, SGLang, llama.cpp, Ollama,
    /// LM Studio …) as opposed to a hosted API. Decided by host, not `kind`:
    /// a Spark behind nginx is often configured as kind "OpenAI" because it
    /// speaks the same protocol, and it still wants `chat_template_kwargs`.
    public var isSelfHosted: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return true }
        let hosted = ["openai.com", "openrouter.ai", "anthropic.com", "groq.com", "together.xyz",
                      "together.ai", "fireworks.ai", "mistral.ai", "deepseek.com", "x.ai",
                      "googleapis.com", "azure.com", "cerebras.ai", "perplexity.ai"]
        return !hosted.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

// MARK: - Thinking / reasoning effort

/// How hard a reasoning model should think before answering.
///
/// On the wire this becomes, for self-hosted OpenAI-compatible servers
/// (vLLM / SGLang serving Qwen3.x, GLM, DeepSeek, gpt-oss …):
///   - `chat_template_kwargs.enable_thinking` (false for `.off`), and
///   - `reasoning_effort` both top-level and inside `chat_template_kwargs`,
///     which is where Qwen3.8's template reads it.
/// For hosted APIs only the top-level `reasoning_effort` is sent.
///
/// Templates disagree on the vocabulary (Qwen3.8 accepts low/medium/xhigh,
/// gpt-oss low/medium/high). The client learns the accepted set from the
/// server's 400 and remaps automatically — see `ReasoningEffortCache`.
public enum ThinkingLevel: String, Codable, CaseIterable, Sendable, Hashable {
    case off, low, medium, high, max

    public var label: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        }
    }

    public var blurb: String {
        switch self {
        case .off: "No thinking — fastest replies"
        case .low: "Brief thinking"
        case .medium: "Balanced"
        case .high: "Careful"
        case .max: "Deepest (slowest)"
        }
    }

    public var symbol: String {
        switch self {
        case .off: "hare"
        case .low: "gauge.with.dots.needle.0percent"
        case .medium: "gauge.with.dots.needle.33percent"
        case .high: "gauge.with.dots.needle.67percent"
        case .max: "gauge.with.dots.needle.100percent"
        }
    }

    /// The effort word we try first; nil for `.off`.
    public var wireEffort: String? {
        switch self {
        case .off: nil
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .max: "xhigh"
        }
    }

    /// Parse user input like "/think high", "fast", "none", "xhigh".
    public init?(userInput raw: String) {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "off", "none", "no", "fast", "0", "false", "disable", "disabled": self = .off
        case "low", "light", "minimal", "1": self = .low
        case "medium", "med", "mid", "normal", "2": self = .medium
        case "high", "hard", "slow", "3": self = .high
        case "max", "xhigh", "maximum", "highest", "deep", "4": self = .max
        default: return nil
        }
    }
}

/// Metadata about a model, used to size the context gauge in the UI.
///
/// `contextWindow` is the model's total input+output token budget. Servers that
/// expose it (Ollama, LM Studio, OpenRouter, some vLLM builds) report it on
/// `GET /v1/models`; for the rest we fall back to the well-known tables below
/// or a conservative default.
public struct ModelInfo: Codable, Hashable, Sendable {
    /// The id the server actually serves for this route. Usually the
    /// configured model; when that isn't served but the server serves exactly
    /// one model (a box that swaps models, e.g. the Spark swapper), it is that
    /// one — the app follows it instead of failing with "model not found".
    public var id: String
    public var contextWindow: Int?
    public var maxTokens: Int?
    /// Every model id the server listed (empty when `/models` didn't answer).
    public var servedModels: [String]

    public init(id: String, contextWindow: Int? = nil, maxTokens: Int? = nil,
                servedModels: [String] = []) {
        self.id = id
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.servedModels = servedModels
    }
}

// MARK: - Requests / responses

public struct LLMRequest: Sendable {
    public let systemPrompt: String
    public let messages: [LLMMessage]
    public let tools: [ToolSpec]
    public let model: String
    public let temperature: Double?
    public let maxTokens: Int?
    /// Thinking level for this request; nil = the provider profile's default.
    public let thinking: ThinkingLevel?

    public init(systemPrompt: String, messages: [LLMMessage], tools: [ToolSpec],
                model: String, temperature: Double? = nil, maxTokens: Int? = nil,
                thinking: ThinkingLevel? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.thinking = thinking
    }
}

public struct LLMUsage: Codable, Hashable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// What the engine consumes from a streaming client.
///
/// The client accumulates partial `tool_calls` internally and hands the engine
/// complete calls at the end, so the engine never deals in fragments.
public enum LLMStreamEvent: Sendable {
    /// A text delta to append to the assistant message.
    case text(String)
    /// A reasoning ("thinking") delta — `reasoning_content` from a vLLM/SGLang
    /// reasoning parser, or OpenRouter's `reasoning`. Shown live, never sent back.
    case reasoning(String)
    /// The stream finished: complete tool calls (may be empty) + metadata.
    case done(calls: [ToolCall], finish: String?, usage: LLMUsage?)
}

/// Transport errors with user-actionable guidance (wizard smoke test uses this).
public enum LLMError: LocalizedError, Sendable {
    case noModel
    case connection(String)
    case http(Int, String)
    /// The server refused the request because it would exceed the model's
    /// context window, and told us the limit in the error body (SGLang/vLLM do:
    /// "maximum context length is 262144 tokens"). The caller should compact
    /// the transcript and retry once.
    case overflow(limit: Int, detail: String)
    case sse(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .noModel: "No model is configured. Run the setup wizard or pick a model in Settings."
        case .connection(let why):
            "Could not reach the model server (\(why)). Is it running and is the address right?"
        case .http(let code, let body): "The model server replied \(code): \(String(body.prefix(300)))"
        case .overflow(let limit, let detail):
            "Conversation is too long for the \(limit.formatted())-token window (\(detail.prefix(120)))."
        case .sse(let why): "The model stream ended unexpectedly (\(why))."
        case .unsupported(let what): "\(what) is not supported yet."
        }
    }
}

/// A streaming chat client — the seam the engine tests against mocks.
/// Must be `@Sendable`-friendly: implementations may outlive the engine turn.
public protocol LLMClient: Sendable {
    /// Stream one model turn. Emits `.text` deltas then exactly one `.done`.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
    /// Liveness + capability probe: returns the server's model list.
    func listModels() async throws -> [String]
}