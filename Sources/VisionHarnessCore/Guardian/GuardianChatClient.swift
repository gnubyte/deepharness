import Foundation

// MARK: - Local models and people, through Guardian's own chat
//
// Guardian's OpenAI-shaped proxy speaks to Bedrock only: it refuses `local:`
// model ids, and has no idea what a person is. Both are reachable through
// Guardian's chat instead, so this client adapts that to `LLMClient`.
//
// The difference that matters: Guardian keeps the conversation and runs the
// model and its tools on its side. So this client sends only the newest user
// message, never asks for tool calls, and this app's tools (files, the shell)
// don't run. These routes are for conversation, not for editing a project.

extension ProviderProfile {
    /// The `model` of a route that talks to one of Guardian's people.
    public static func guardianPersonModel(_ personID: String) -> String { "person:\(personID)" }

    public var guardianPersonID: String? {
        guard kind == .guardian, model.hasPrefix("person:") else { return nil }
        return String(model.dropFirst("person:".count))
    }

    /// True for routes served by `GuardianChatClient` (no harness tools).
    public var isGuardianChatOnly: Bool {
        kind == .guardian && (model.hasPrefix("person:") || (model.hasPrefix("local:") && guardianProxied != true))
    }

    /// The model's name without Guardian's `local:<node>:` plumbing.
    public var friendlyModel: String {
        kind == .guardian ? GuardianLocalModel.modelName(from: model) : model
    }
}

public final class GuardianChatClient: ProviderClient, @unchecked Sendable {
    public let profile: ProviderProfile
    private let lock = NSLock()
    private var chatID: String?
    private var onChatCreated: (@Sendable (String) -> Void)?

    public init(profile: ProviderProfile) {
        self.profile = profile
    }

    /// Continue an existing Guardian chat, and hear about a new one, so the
    /// conversation survives this client being rebuilt or the app restarting.
    public func bind(chatID: String?, onChatCreated: @escaping @Sendable (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.chatID = chatID
        self.onChatCreated = onChatCreated
    }

    private func guardianClient() throws -> GuardianClient {
        let suffix = "/api/harness/v1"
        var base = profile.baseURL
        if base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)) }
        let token = profile.apiKey ?? ""
        guard !token.isEmpty else { throw GuardianError.unauthorized }
        return try GuardianClient(baseURL: base, session: GuardianSession(userID: "", email: "", name: nil, token: token))
    }

    private func currentBinding() -> (chatID: String?, created: (@Sendable (String) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        return (chatID, onChatCreated)
    }

    private func remember(chatID: String) {
        lock.lock(); defer { lock.unlock() }
        self.chatID = chatID
    }

    /// What goes in a new Guardian chat that isn't the conversation's start:
    /// the words so far, so switching route doesn't lose the thread.
    static func recap(of messages: [LLMMessage], limit: Int = 20_000) -> String? {
        let lines: [String] = messages.compactMap { message in
            guard let text = message.content, !text.isEmpty else { return nil }
            switch message.role {
            case .user: return "User: \(text)"
            case .assistant: return "Assistant: \(text)"
            default: return nil
            }
        }
        guard !lines.isEmpty else { return nil }
        return String(lines.joined(separator: "\n\n").suffix(limit))
    }

    /// The text of a first message: the conversation so far, then what the user said.
    static func firstMessage(earlier: [LLMMessage], text: String) -> String {
        var parts: [String] = []
        if let recap = recap(of: earlier) { parts.append("The conversation so far:\n\n\(recap)") }
        parts.append(text)
        return parts.joined(separator: "\n\n---\n\n")
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var openChat: String?
                var guardian: GuardianClient?
                do {
                    let client = try self.guardianClient()
                    guardian = client
                    guard let last = request.messages.last(where: { $0.role == .user }) else {
                        throw LLMError.unsupported("There is no message to send to Guardian.")
                    }
                    let binding = self.currentBinding()
                    var text = last.content ?? ""
                    let chat: String
                    if let existing = binding.chatID {
                        chat = existing
                    } else {
                        chat = try await client.createChat(personID: self.profile.guardianPersonID,
                                                           modelID: self.profile.guardianPersonID == nil ? self.profile.model : nil)
                        self.remember(chatID: chat)
                        binding.created?(chat)
                        text = Self.firstMessage(earlier: Array(request.messages.dropLast()), text: text)
                    }
                    openChat = chat
                    var attachmentIDs: [String] = []
                    for attachment in last.attachments ?? [] {
                        attachmentIDs.append(try await client.upload(name: attachment.name, contentType: attachment.mime,
                                                                     data: attachment.data))
                    }
                    var usage: LLMUsage?
                    for try await event in client.sendChatMessage(chatID: chat, content: text, attachmentIDs: attachmentIDs) {
                        switch event {
                        case .accepted: break
                        case .text(let delta): continuation.yield(.text(delta))
                        case .toolCall(let name): continuation.yield(.reasoning("Guardian is using \(name)…\n"))
                        case .done(let tokensIn, let tokensOut):
                            if let tokensIn, let tokensOut {
                                usage = LLMUsage(promptTokens: tokensIn, completionTokens: tokensOut)
                            }
                        case .failed(let message): throw LLMError.sse(message)
                        }
                    }
                    openChat = nil
                    continuation.yield(.done(calls: [], finish: "stop", usage: usage))
                    continuation.finish()
                } catch {
                    if Task.isCancelled, let openChat, let guardian { await guardian.stopChat(openChat) }
                    if let guardianError = error as? GuardianError {
                        continuation.finish(throwing: LLMError.connection(guardianError.errorDescription ?? "Guardian refused the request."))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] { [profile.model] }

    public func modelInfo(_ model: String?) async -> ModelInfo? {
        ModelInfo(id: profile.model, contextWindow: profile.contextWindow, servedModels: [profile.model])
    }
}
