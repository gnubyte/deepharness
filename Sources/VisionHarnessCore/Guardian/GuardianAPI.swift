import Foundation

// MARK: - Guardian beyond the model proxy
//
// A harness sign-in is a full session for everything the person's role allows,
// so these use Guardian's ordinary routes: local models, people, AI Coders,
// the boards and uploads. What each route needs is noted where it is called.

/// A model on one of Guardian's AI hosts (Orbital, and whatever is added next).
public struct GuardianLocalModel: Hashable, Sendable, Identifiable {
    /// `local:<nodeId>:<model>`; the model part may itself contain colons.
    public var modelId: String
    public var label: String
    public var nodeName: String
    public var contextWindow: Int?
    public var id: String { modelId }

    public init(modelId: String, label: String, nodeName: String, contextWindow: Int? = nil) {
        self.modelId = modelId
        self.label = label
        self.nodeName = nodeName
        self.contextWindow = contextWindow
    }

    /// "qwen3.6:35b" out of "local:n1:qwen3.6:35b".
    public static func modelName(from id: String) -> String {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "local" ? String(parts[2]) : id
    }
}

/// One of Guardian's virtual employees.
public struct GuardianPerson: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var title: String?
    public var avatarUrl: String?
    public var status: String?

    public init(id: String, displayName: String, title: String? = nil, avatarUrl: String? = nil, status: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.title = title
        self.avatarUrl = avatarUrl
        self.status = status
    }

    public var isRetired: Bool { status?.uppercased() == "RETIRED" }
}

public struct GuardianProject: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct GuardianBoardColumn: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct GuardianBoard: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// An AI Coders delivery board's columns are fixed keys.
public enum GuardianDeliveryColumn: String, CaseIterable, Sendable, Identifiable {
    case backlog, ready, doing, testing, staging, done
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// Something Guardian's chat stream says.
public enum GuardianChatEvent: Equatable, Sendable {
    case accepted(chatID: String?)
    case text(String)
    case toolCall(String)
    case done(tokensIn: Int?, tokensOut: Int?)
    case failed(String)
}

/// Guardian chat's SSE: `event: <name>` then `data: <json>` lines.
public struct GuardianSSEParser: Sendable {
    private var event: String?

    public init() {}

    /// Feed one line; returns an event when this line completes one.
    public mutating func feed(_ line: String) -> GuardianChatEvent? {
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else {
            if line.isEmpty { event = nil }
            return nil
        }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let name = event
        event = nil
        let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
        switch name {
        case "accepted": return .accepted(chatID: object["chatId"] as? String)
        case "delta": return (object["text"] as? String).map { .text($0) }
        case "tool_call":
            return .toolCall(object["name"] as? String ?? object["tool"] as? String ?? "a tool")
        case "done": return .done(tokensIn: object["tokensIn"] as? Int, tokensOut: object["tokensOut"] as? Int)
        case "error": return .failed(object["message"] as? String ?? "Guardian reported an error.")
        default: return nil
        }
    }
}

extension GuardianClient {
    /// The OpenAI-shaped base every Guardian route carries.
    public var harnessAPIBase: String { baseURL.absoluteString + "/api/harness/v1" }

    /// One route per proxy model. The token isn't in the route: `AppConfig` supplies it.
    public func routes(for models: [GuardianModel]) -> [ProviderProfile] {
        models.map { model in
            ProviderProfile(kind: .guardian, name: "Guardian", baseURL: harnessAPIBase,
                            model: model.id, contextWindow: model.contextWindow)
        }
    }

    /// One route per local model, named after its node, so a new AI host appears under its own name.
    /// `proxied` are the ids this deployment's proxy lists: those run this app's tools; the rest only chat.
    public func routes(forLocal models: [GuardianLocalModel], proxied: Set<String> = []) -> [ProviderProfile] {
        models.map { model in
            var route = ProviderProfile(kind: .guardian, name: model.nodeName, baseURL: harnessAPIBase,
                                        model: model.modelId, contextWindow: model.contextWindow)
            route.guardianProxied = proxied.contains(model.modelId) ? true : nil
            return route
        }
    }

    /// Plain uploads top out here; larger files use Guardian's multipart flow,
    /// which this client doesn't speak.
    public static let maxUploadBytes = 50 * 1024 * 1024

    private struct IDRow: Decodable {
        struct Nested: Decodable { var id: String? }
        var id: String?
        var chat: Nested?
        var card: Nested?
        var resolved: String? { id ?? chat?.id ?? card?.id }
    }

    private func json<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw GuardianError.server("Guardian's answer wasn't in the expected shape.")
        }
    }

    // MARK: Local models

    /// Every local model the org may run as a main model. Guardian leaves
    /// offline nodes out, so this list is live. Any signed-in user may ask.
    public func localModels() async throws -> [GuardianLocalModel] {
        struct Row: Decodable {
            var modelId: String
            var label: String?
            var provider: String?
            var nodeName: String?
            var contextWindow: Int?
            var allowedAsMain: Bool?
        }
        let rows = try json([Row].self, from: try await get(path: "/api/models?includeLocal=1"))
        return rows.compactMap { row in
            guard row.provider == "local", row.allowedAsMain != false else { return nil }
            return GuardianLocalModel(modelId: row.modelId, label: row.label ?? row.modelId,
                                      nodeName: row.nodeName ?? "Local", contextWindow: row.contextWindow)
        }
    }

    // MARK: People

    /// The people this account may see: `people.manage` sees everyone, others
    /// only the people they've been granted (possibly none).
    public func people() async throws -> [GuardianPerson] {
        struct Row: Decodable {
            struct Job: Decodable { var title: String? }
            var id: String
            var displayName: String
            var avatarUrl: String?
            var status: String?
            var job: Job?
        }
        let rows = try json([Row].self, from: try await get(path: "/api/people"))
        return rows.map {
            GuardianPerson(id: $0.id, displayName: $0.displayName, title: $0.job?.title,
                           avatarUrl: $0.avatarUrl, status: $0.status)
        }
    }

    // MARK: Chat

    /// Open a Guardian chat, locked to a person or on a specific model.
    public func createChat(personID: String? = nil, modelID: String? = nil) async throws -> String {
        struct Body: Encodable { var personId: String?; var modelId: String? }
        let data = try await post(path: "/api/chats", body: Body(personId: personID, modelId: modelID), token: session?.token)
        guard let id = try json(IDRow.self, from: data).resolved else {
            throw GuardianError.server("Guardian didn't return the new chat's id.")
        }
        return id
    }

    public func stopChat(_ chatID: String) async {
        struct Empty: Encodable {}
        _ = try? await post(path: "/api/chats/\(chatID)/stop", body: Empty(), token: session?.token)
    }

    /// Send one message and stream what Guardian says back.
    public func sendChatMessage(chatID: String, content: String, attachmentIDs: [String] = [],
                                intent: String? = nil) -> AsyncThrowingStream<GuardianChatEvent, Error> {
        struct Body: Encodable { var content: String; var attachmentIds: [String]?; var intent: String? }
        return streamEvents(path: "/api/chats/\(chatID)/messages",
                            body: Body(content: content, attachmentIds: attachmentIDs.isEmpty ? nil : attachmentIDs, intent: intent))
    }

    /// POST and read the response as Guardian's SSE. Not through `transport`:
    /// that returns a whole body, and this has to arrive as it's written.
    private func streamEvents<B: Encodable & Sendable>(path: String, body: B) -> AsyncThrowingStream<GuardianChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: baseURL.absoluteString + path) else { throw GuardianError.badURL }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 900
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let token = session?.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    request.httpBody = try JSONEncoder().encode(body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(status) else {
                        var collected = Data()
                        for try await byte in bytes { collected.append(byte) }
                        try Self.check(status, data: collected)
                        return
                    }
                    var parser = GuardianSSEParser()
                    for try await line in bytes.lines {
                        if let event = parser.feed(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Uploads

    /// Upload a file and return its attachment id: init, PUT to the presigned
    /// URL, finalize. Needs `chat.create`.
    public func upload(name: String, contentType: String, data: Data) async throws -> String {
        guard data.count <= Self.maxUploadBytes else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            throw GuardianError.server("“\(name)” is \(size); uploads from here are limited to 50 MB.")
        }
        struct Init: Encodable { var name: String; var contentType: String; var size: Int }
        struct Slot: Decodable { var attachmentId: String; var uploadUrl: String; var headers: [String: String]? }
        let slot = try json(Slot.self, from: try await post(
            path: "/api/uploads/init", body: Init(name: name, contentType: contentType, size: data.count), token: session?.token))
        guard let url = URL(string: slot.uploadUrl) else { throw GuardianError.server("Guardian returned a bad upload address.") }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.httpBody = data
        // A presigned URL carries its own authority: no bearer token goes to storage.
        for (field, value) in slot.headers ?? [:] { put.setValue(value, forHTTPHeaderField: field) }
        let stored = try await transport(put)
        guard (200...299).contains(stored.status) else {
            throw GuardianError.server("Uploading “\(name)” failed (HTTP \(stored.status)).")
        }
        struct Empty: Encodable {}
        _ = try await post(path: "/api/uploads/\(slot.attachmentId)/finalize", body: Empty(), token: session?.token)
        return slot.attachmentId
    }

    // MARK: AI Coders

    /// Projects the account owns or was granted (module `ai-coders`).
    public func coderProjects() async throws -> [GuardianProject] {
        struct Row: Decodable { var id: String; var name: String?; var repo: String?; var fullName: String? }
        let rows = try json([Row].self, from: try await get(path: "/api/ai-coders/projects"))
        return rows.map { GuardianProject(id: $0.id, name: $0.name ?? $0.fullName ?? $0.repo ?? $0.id) }
    }

    /// Start an AI Coders chat on a project and send it the task. Needs project
    /// WRITE. The turn outlives the connection on Guardian's side, so this
    /// returns as soon as Guardian has taken the message.
    @discardableResult
    public func sendToCoderProject(projectID: String, title: String, content: String,
                                   attachmentIDs: [String]) async throws -> String {
        struct NewChat: Encodable { var title: String; var mode: String }
        let data = try await post(path: "/api/ai-coders/projects/\(projectID)/chats",
                                  body: NewChat(title: String(title.prefix(120)), mode: "agent"), token: session?.token)
        guard let chatID = try json(IDRow.self, from: data).resolved else {
            throw GuardianError.server("Guardian didn't return the new coder chat's id.")
        }
        struct Message: Encodable { var content: String; var attachmentIds: [String]? }
        let events = streamEvents(path: "/api/ai-coders/chats/\(chatID)/messages",
                                  body: Message(content: content, attachmentIds: attachmentIDs.isEmpty ? nil : attachmentIDs))
        for try await event in events {
            if case .failed(let message) = event { throw GuardianError.server(message) }
            break   // Guardian answered with an event: it has the message.
        }
        return chatID
    }

    /// A card on a project's delivery board, in the chosen column. This route
    /// takes no attachments, so files arrive as links in the body.
    @discardableResult
    public func addDeliveryCard(projectID: String, title: String, body: String,
                                column: GuardianDeliveryColumn) async throws -> String? {
        struct Body: Encodable { var title: String; var body: String; var column: String }
        let data = try await post(path: "/api/ai-coders/projects/\(projectID)/board/cards",
                                  body: Body(title: String(title.prefix(500)), body: body, column: column.rawValue),
                                  token: session?.token)
        return (try? json(IDRow.self, from: data))?.resolved
    }

    // MARK: Kanban

    /// Boards the account owns or has been shared (`kanban.manage`).
    public func kanbanBoards() async throws -> [GuardianBoard] {
        struct Row: Decodable { var id: String; var title: String }
        struct Response: Decodable { var owned: [Row]?; var shared: [Row]? }
        let response = try json(Response.self, from: try await get(path: "/api/kanban"))
        return ((response.owned ?? []) + (response.shared ?? [])).map { GuardianBoard(id: $0.id, title: $0.title) }
    }

    public func kanbanColumns(boardID: String) async throws -> [GuardianBoardColumn] {
        struct Column: Decodable { var id: String; var title: String?; var name: String? }
        struct Response: Decodable { var columns: [Column]? }
        let response = try json(Response.self, from: try await get(path: "/api/kanban/\(boardID)"))
        return (response.columns ?? []).map { GuardianBoardColumn(id: $0.id, title: $0.title ?? $0.name ?? "Untitled") }
    }

    /// Create the card, then attach each file. Attaching isn't atomic: a file
    /// that fails is reported by name, and the card stays.
    public func addKanbanCard(boardID: String, columnID: String, title: String, description: String,
                              attachmentIDs: [String]) async throws -> (cardID: String, failedAttachments: Int) {
        struct Body: Encodable { var columnId: String; var title: String; var description: String }
        let data = try await post(path: "/api/kanban/\(boardID)/cards",
                                  body: Body(columnId: columnID, title: title, description: description), token: session?.token)
        guard let cardID = try json(IDRow.self, from: data).resolved else {
            throw GuardianError.server("Guardian didn't return the new card's id.")
        }
        struct Attach: Encodable { var attachmentId: String }
        var failed = 0
        for id in attachmentIDs {
            do {
                _ = try await post(path: "/api/kanban/\(boardID)/cards/\(cardID)/attachments",
                                   body: Attach(attachmentId: id), token: session?.token)
            } catch {
                failed += 1
            }
        }
        return (cardID, failed)
    }
}
