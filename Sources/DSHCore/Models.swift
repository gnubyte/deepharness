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

    public init(role: Role,
                content: String? = nil,
                toolCalls: [ToolCall]? = nil,
                toolCallID: String? = nil,
                name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    public static func user(_ text: String) -> LLMMessage { .init(role: .user, content: text) }
    public static func assistant(_ text: String, calls: [ToolCall] = []) -> LLMMessage {
        .init(role: .assistant, content: text, toolCalls: calls.isEmpty ? nil : calls)
    }
    public static func toolResult(id: String, name: String, output: String) -> LLMMessage {
        .init(role: .tool, content: output, toolCallID: id, name: name)
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

    public init(kind: Kind, name: String, baseURL: String, apiKey: String? = nil,
                model: String, temperature: Double? = nil, maxOutputTokens: Int? = nil) {
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
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
}

// MARK: - Requests / responses

public struct LLMRequest: Sendable {
    public let systemPrompt: String
    public let messages: [LLMMessage]
    public let tools: [ToolSpec]
    public let model: String
    public let temperature: Double?
    public let maxTokens: Int?

    public init(systemPrompt: String, messages: [LLMMessage], tools: [ToolSpec],
                model: String, temperature: Double? = nil, maxTokens: Int? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
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
    /// The stream finished: complete tool calls (may be empty) + metadata.
    case done(calls: [ToolCall], finish: String?, usage: LLMUsage?)
}

/// Transport errors with user-actionable guidance (wizard smoke test uses this).
public enum LLMError: LocalizedError, Sendable {
    case noModel
    case connection(String)
    case http(Int, String)
    case sse(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .noModel: "No model is configured. Run the setup wizard or pick a model in Settings."
        case .connection(let why):
            "Could not reach the model server (\(why)). Is it running and is the address right?"
        case .http(let code, let body): "The model server replied \(code): \(String(body.prefix(300)))"
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