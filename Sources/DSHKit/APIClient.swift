import Foundation

/// Unary client for the harness `/api` gateway.
///
/// Mirrors `AbstractApiClient` on the TypeScript side: this type owns every
/// protocol invariant (rpcId minting, envelope wrap/unwrap, error surfacing) so
/// callers pass payloads directly and never mint ids themselves.
public actor APIClient {
    public let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Invoke one unary method and return its success value.
    /// - Throws: `RpcError` for business failures, `TransportError` for carrier failures.
    @discardableResult
    public func call(_ method: String, _ payload: JSONValue = .object([:])) async throws -> JSONValue {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent(method)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(
            ClientRequest(rpcId: .mint(), method: method, payload: payload)
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw TransportError.cancelled
        }

        guard let http = response as? HTTPURLResponse else {
            throw TransportError.malformedResponse("non-HTTP response")
        }
        // Status expresses only the carrier; business errors ride a 200 body.
        guard http.statusCode == 200 else {
            throw TransportError.badStatus(http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let envelope: ServerResponse
        do {
            envelope = try decoder.decode(ServerResponse.self, from: data)
        } catch {
            throw TransportError.malformedResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try envelope.result.unwrap()
    }

    /// Answer one answerable server-request (an approval or a question).
    ///
    /// This is not a unary method and has no row in the method map: it posts a
    /// client-response to the fixed `/api/respond` path, echoing the frame's
    /// rpcId. The reply is a carrier receipt, not a business result.
    @discardableResult
    public func respond(to rpcId: RpcId, value: JSONValue) async throws -> RpcReceipt {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("respond")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(ClientResponse(rpcId: rpcId, result: .init(value: value)))

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransportError.badStatus(code, body: String(decoding: data, as: UTF8.self))
        }
        do {
            return try decoder.decode(RpcReceipt.self, from: data)
        } catch {
            throw TransportError.malformedResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// Convenience: call and decode the value into a concrete type.
    public func call<T: Decodable>(_ method: String, _ payload: JSONValue = .object([:]), as: T.Type) async throws -> T {
        let value = try await call(method, payload)
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Domain conveniences
//
// Thin, intention-revealing wrappers over the verified method names. They stay
// payload-direct: no envelope details leak past this file.

extension APIClient {
    public func hostDescribe() async throws -> JSONValue {
        try await call("host.describe")
    }

    public func sessionList() async throws -> [JSONValue] {
        try await call("session.list")["items"]?.arrayValue ?? []
    }

    /// Create a session, optionally inside a project.
    ///
    /// The contract accepts at most one of `workspaceId` / `cwd`; a workspace
    /// resolves to its own canonical directory, and passing neither uses the
    /// host cwd. `workspaceId` wins when both are supplied, since attaching to
    /// the project is the stronger intent.
    public func sessionCreate(workspaceId: String? = nil, cwd: String? = nil) async throws -> String {
        var payload: [String: JSONValue] = [:]
        if let workspaceId {
            payload["workspaceId"] = .string(workspaceId)
        } else if let cwd {
            payload["cwd"] = .string(cwd)
        }
        let value = try await call("session.create", .object(payload))
        guard let id = value["sessionId"]?.stringValue else {
            throw TransportError.malformedResponse("session.create returned no sessionId")
        }
        return id
    }

    public func sessionHistory(_ sessionId: String, maxMessages: Int? = nil) async throws -> JSONValue {
        var payload: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let maxMessages { payload["maxMessages"] = .number(Double(maxMessages)) }
        return try await call("session.history", .object(payload))
    }

    public func sessionModels(_ sessionId: String) async throws -> JSONValue {
        try await call("session.models", ["sessionId": .string(sessionId)])
    }

    public func selectModel(_ sessionId: String, provider: String, model: String) async throws {
        try await call("session.selectModel", [
            "sessionId": .string(sessionId),
            "provider": .string(provider),
            "model": .string(model),
        ])
    }

    /// Send a prompt. `mode` is `queue` (normal) or `steer` (interrupt the active turn).
    public func prompt(_ sessionId: String, content: [JSONValue], mode: String = "queue") async throws {
        try await call("session.prompt", [
            "sessionId": .string(sessionId),
            "mode": .string(mode),
            "content": .array(content),
        ])
    }

    /// Send text plus inline image attachments.
    ///
    /// Attachments enter durable storage through the prompt itself: the wire
    /// carries base64, the harness commits each image before the user event,
    /// and the log then holds only verified references.
    public func prompt(
        _ sessionId: String,
        text: String,
        attachments: [Attachment] = [],
        mode: String = "queue"
    ) async throws {
        var content: [JSONValue] = []
        if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
        for a in attachments {
            content.append([
                "type": "image",
                "mediaType": .string(a.mediaType),
                "data": .string(a.data.base64EncodedString()),
                "name": .string(a.name),
            ])
        }
        guard !content.isEmpty else { return }
        try await prompt(sessionId, content: content, mode: mode)
    }

    public func cancel(_ sessionId: String) async throws {
        try await call("session.cancel", ["sessionId": .string(sessionId)])
    }

    public func rename(_ sessionId: String, title: String) async throws {
        try await call("session.rename", ["sessionId": .string(sessionId), "title": .string(title)])
    }

    public func fork(_ sessionId: String, atSeq: Int? = nil) async throws -> JSONValue {
        var payload: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let atSeq { payload["atSeq"] = .number(Double(atSeq)) }
        return try await call("session.fork", .object(payload))
    }

    /// Read one durable image attachment the session log references.
    public func attachment(_ sessionId: String, attachmentId: String) async throws -> JSONValue {
        try await call("session.attachment", [
            "sessionId": .string(sessionId),
            "attachmentId": .string(attachmentId),
        ])
    }

    public func providers() async throws -> [JSONValue] {
        try await call("llm.providers")["providers"]?.arrayValue ?? []
    }

    public func models() async throws -> JSONValue {
        try await call("llm.models")
    }

    /// Interrogate a draft endpoint for the models it advertises (the
    /// Cline-style "point at a vLLM/Ollama URL and discover" flow).
    public func discoverModels(settingsNs: String, baseURL: String? = nil, api: String? = nil, apiKey: String? = nil, provider: String? = nil) async throws -> [JSONValue] {
        var payload: [String: JSONValue] = ["settingsNs": .string(settingsNs)]
        if let provider { payload["provider"] = .string(provider) }
        if let baseURL { payload["baseURL"] = .string(baseURL) }
        if let api { payload["api"] = .string(api) }
        if let apiKey { payload["apiKey"] = .string(apiKey) }
        return try await call("llm.discoverModels", .object(payload))["models"]?.arrayValue ?? []
    }

    public func settingsUpdate(ns: String, patch: JSONValue) async throws -> JSONValue {
        try await call("settings.update", ["ns": .string(ns), "patch": patch])
    }

    public func credentialsSet(ref: String, value: String) async throws {
        try await call("credentials.set", ["ref": .string(ref), "value": .string(value)])
    }

    public func credentialsDescribe(refs: [String]) async throws -> JSONValue {
        try await call("credentials.describe", ["refs": .array(refs.map { .string($0) })])
    }

    // MARK: - Answering server-requests

    /// Answer one approval request. Only the two user-giveable outcomes exist;
    /// `cancelled` and `unavailable` are host-side and never sent from here.
    public func answerApproval(
        rpcId: RpcId,
        sessionId: String,
        approvalId: String,
        allow: Bool
    ) async throws {
        try await respond(to: rpcId, value: [
            "sessionId": .string(sessionId),
            "approvalId": .string(approvalId),
            "outcome": .string(allow ? "allowed-once" : "rejected"),
        ])
    }

    /// Answer one `ask()` as a whole batch — core never splits an answer per
    /// question, so every question in the frame is answered together.
    public func answerQuestions(
        rpcId: RpcId,
        sessionId: String,
        answers: [(id: String, selected: [String], custom: String?)]
    ) async throws {
        let items: [JSONValue] = answers.map { a in
            var obj: [String: JSONValue] = [
                "id": .string(a.id),
                "selected": .array(a.selected.map { .string($0) }),
            ]
            if let custom = a.custom, !custom.isEmpty { obj["custom"] = .string(custom) }
            return .object(obj)
        }
        try await respond(to: rpcId, value: [
            "sessionId": .string(sessionId),
            "answer": ["answers": .array(items)],
        ])
    }

    // MARK: - Queue

    public func updateQueue(_ sessionId: String, itemId: String, action: JSONValue) async throws {
        try await call("session.updateQueue", [
            "sessionId": .string(sessionId),
            "itemId": .string(itemId),
            "action": action,
        ])
    }

    public func removeQueued(_ sessionId: String, itemId: String) async throws {
        try await updateQueue(sessionId, itemId: itemId, action: ["kind": "remove"])
    }

    public func steerQueued(_ sessionId: String, itemId: String) async throws {
        try await updateQueue(sessionId, itemId: itemId, action: ["kind": "steer"])
    }

    public func editQueued(_ sessionId: String, itemId: String, text: String) async throws {
        try await updateQueue(sessionId, itemId: itemId, action: [
            "kind": "edit",
            "content": [["type": "text", "text": .string(text)]],
        ])
    }

    // MARK: - Search

    /// At most 20 sessions, no cursor; `hasMore` asks the user to refine.
    public func search(_ query: String) async throws -> (items: [JSONValue], hasMore: Bool) {
        let value = try await call("session.search", ["query": .string(query)])
        return (value["items"]?.arrayValue ?? [], value["hasMore"]?.boolValue ?? false)
    }

    // MARK: - Workspaces

    /// Open a path with the OS default application, host-side.
    ///
    /// Routed through the harness rather than opened locally because the host
    /// is the process that can actually see the path — it may be a container
    /// or another machine. `host.describe().canOpenPath` says whether it will.
    public func openPath(_ path: String) async throws {
        try await call("host.openPath", ["path": .string(path)])
    }

    public func workspaceList() async throws -> (items: [JSONValue], archived: [String]) {
        let value = try await call("workspace.list")
        return (
            value["items"]?.arrayValue ?? [],
            (value["archivedSessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
        )
    }

    /// Adopts an EXISTING directory — the harness never creates one here.
    public func workspaceCreate(path: String) async throws -> JSONValue {
        try await call("workspace.create", ["path": .string(path)])
    }

    public func workspaceRename(_ workspaceId: String, title: String) async throws {
        try await call("workspace.rename", ["workspaceId": .string(workspaceId), "title": .string(title)])
    }

    /// Removes the registration only — directory, files, and session logs stay.
    public func workspaceDelete(_ workspaceId: String) async throws {
        try await call("workspace.delete", ["workspaceId": .string(workspaceId)])
    }

    public func archiveSession(_ workspaceId: String, sessionId: String, archived: Bool) async throws {
        try await call("workspace.archiveSession", [
            "workspaceId": .string(workspaceId),
            "sessionId": .string(sessionId),
            "archived": .bool(archived),
        ])
    }

    // MARK: - Skills

    /// The skill catalog visible to one session.
    ///
    /// Session-scoped rather than global because discovery depends on the
    /// session's cwd: project roots are found by walking up from it, so two
    /// chats in different folders legitimately see different skills.
    public func skillList(_ sessionId: String) async throws -> [JSONValue] {
        try await call("skill.list", ["sessionId": .string(sessionId)])["skills"]?.arrayValue ?? []
    }

    // MARK: - Subagents

    public func subagentList(parent: String) async throws -> JSONValue {
        try await call("subagent.list", ["parentSessionId": .string(parent)])
    }

    public func subagentHistory(parent: String, child: String, mode: String) async throws -> JSONValue {
        try await call("subagent.history", [
            "parentSessionId": .string(parent),
            "childSessionId": .string(child),
            "mode": .string(mode),
        ])
    }

    public func subagentPrompt(parent: String, child: String, text: String) async throws -> JSONValue {
        try await call("subagent.prompt", [
            "parentSessionId": .string(parent),
            "childSessionId": .string(child),
            "mode": "continuable",
            "content": [["type": "text", "text": .string(text)]],
        ])
    }

    public func subagentInterrupt(parent: String, child: String, mode: String) async throws {
        try await call("subagent.interrupt", [
            "parentSessionId": .string(parent),
            "childSessionId": .string(child),
            "mode": .string(mode),
        ])
    }
}
