import XCTest
@testable import VisionHarnessCore

final class GuardianAPITests: XCTestCase {
    private final class Script: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var answers: [String: (Int, String)]
        init(_ answers: [String: (Int, String)]) { self.answers = answers }
        func handle(_ request: URLRequest) -> GuardianHTTPResponse {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            let key = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"
            let answer = answers[key] ?? (404, #"{"message":"no route: \#(key)"}"#)
            return GuardianHTTPResponse(data: Data(answer.1.utf8), status: answer.0, headers: [:])
        }
    }

    private let base = "https://g.example.com"

    private func client(_ script: Script) throws -> GuardianClient {
        try GuardianClient(baseURL: base, session: GuardianSession(userID: "u", email: "e", name: nil, token: "tok"),
                           transport: { request in script.handle(request) })
    }

    func testLocalModelsKeepsOnlyAllowedLocalRowsAndKeepsTheQueryString() async throws {
        let script = Script(["GET \(base)/api/models?includeLocal=1": (200, """
        [{"modelId":"us.anthropic.x","label":"Claude","provider":"bedrock"},
         {"modelId":"local:n1:qwen3.6:35b","label":"qwen · Orbital (local)","provider":"local","nodeName":"Orbital","contextWindow":1000000,"allowedAsMain":true},
         {"modelId":"local:n2:blocked","provider":"local","nodeName":"Other","allowedAsMain":false}]
        """)])
        let models = try await client(script).localModels()
        XCTAssertEqual(models.map(\.modelId), ["local:n1:qwen3.6:35b"])
        XCTAssertEqual(models[0].nodeName, "Orbital")
        XCTAssertEqual(script.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testANewAIHostBecomesItsOwnRoute() throws {
        let guardian = try client(Script([:]))
        let routes = guardian.routes(forLocal: [
            GuardianLocalModel(modelId: "local:n1:qwen", label: "", nodeName: "Orbital"),
            GuardianLocalModel(modelId: "local:n9:kimi", label: "", nodeName: "Nebula"),
        ])
        XCTAssertEqual(routes.map(\.name), ["Orbital", "Nebula"])
        XCTAssertTrue(routes.allSatisfy(\.isGuardianChatOnly))
        XCTAssertEqual(routes[0].friendlyModel, "qwen")
        XCTAssertNotNil(ProviderClients.guardianChat(in: ProviderClients.make(routes[0])))
    }

    func testALocalModelTheProxyListsRunsToolsThroughTheProxy() throws {
        let guardian = try client(Script([:]))
        let routes = guardian.routes(forLocal: [GuardianLocalModel(modelId: "local:n1:qwen", label: "", nodeName: "Orbital"),
                                                GuardianLocalModel(modelId: "local:n2:old", label: "", nodeName: "Orbital")],
                                     proxied: ["local:n1:qwen"])
        XCTAssertFalse(routes[0].isGuardianChatOnly)
        XCTAssertTrue(routes[1].isGuardianChatOnly)
    }

    func testAProxyModelStaysOnTheOpenAIClient() {
        let route = ProviderProfile(kind: .guardian, name: "Guardian", baseURL: "\(base)/api/harness/v1", model: "guardian/default")
        XCTAssertFalse(route.isGuardianChatOnly)
        XCTAssertNil(ProviderClients.guardianChat(in: ProviderClients.make(route)))
    }

    func testAModelNameCanContainColons() {
        XCTAssertEqual(GuardianLocalModel.modelName(from: "local:n1:qwen3.6:35b"), "qwen3.6:35b")
        XCTAssertEqual(GuardianLocalModel.modelName(from: "us.anthropic.claude"), "us.anthropic.claude")
    }

    func testPeople() async throws {
        let script = Script(["GET \(base)/api/people": (200, """
        [{"id":"p1","displayName":"Dana Reyes","avatarUrl":null,"status":"ACTIVE","job":{"id":"j","title":"Assistant"},"team":{"id":"t"}},
         {"id":"p2","displayName":"Old Timer","status":"RETIRED"}]
        """)])
        let people = try await client(script).people()
        XCTAssertEqual(people.map(\.displayName), ["Dana Reyes", "Old Timer"])
        XCTAssertEqual(people[0].title, "Assistant")
        XCTAssertTrue(people[1].isRetired)
    }

    func testUploadInitsPutsWithoutTheBearerAndFinalizes() async throws {
        let script = Script([
            "POST \(base)/api/uploads/init": (200, #"{"attachmentId":"a1","uploadMode":"single","uploadUrl":"https://s3.example.com/put?sig=1","method":"PUT","headers":{"Content-Type":"text/markdown"}}"#),
            "PUT https://s3.example.com/put?sig=1": (200, ""),
            "POST \(base)/api/uploads/a1/finalize": (200, "{}"),
        ])
        let id = try await client(script).upload(name: "t.md", contentType: "text/markdown", data: Data("hi".utf8))
        XCTAssertEqual(id, "a1")
        let put = script.requests[1]
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"), "the token must not go to storage")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "text/markdown")
        XCTAssertEqual(script.requests.count, 3)
    }

    func testUploadRefusesWhatItCantSend() async throws {
        do {
            _ = try await client(Script([:])).upload(name: "big", contentType: "x", data: Data(count: GuardianClient.maxUploadBytes + 1))
            XCTFail("should refuse")
        } catch GuardianError.server(let detail) {
            XCTAssertTrue(detail.contains("50 MB"))
        }
    }

    func testKanbanCardIsCreatedThenEachFileAttachedAndAFailureIsCounted() async throws {
        let script = Script([
            "POST \(base)/api/kanban/b1/cards": (200, #"{"id":"c1"}"#),
            "POST \(base)/api/kanban/b1/cards/c1/attachments": (200, "{}"),
        ])
        var result = try await client(script).addKanbanCard(boardID: "b1", columnID: "col", title: "T", description: "D", attachmentIDs: ["a", "b"])
        XCTAssertEqual(result.cardID, "c1")
        XCTAssertEqual(result.failedAttachments, 0)
        XCTAssertEqual(script.requests.count, 3)
        let body = try JSONSerialization.jsonObject(with: script.requests[0].httpBody!) as! [String: String]
        XCTAssertEqual(body, ["columnId": "col", "title": "T", "description": "D"])

        script.answers["POST \(base)/api/kanban/b1/cards/c1/attachments"] = (403, #"{"message":"no access"}"#)
        result = try await client(script).addKanbanCard(boardID: "b1", columnID: "col", title: "T", description: "D", attachmentIDs: ["a"])
        XCTAssertEqual(result.failedAttachments, 1)
    }

    func testKanbanBoardsMergesOwnedAndShared() async throws {
        let script = Script(["GET \(base)/api/kanban": (200, #"{"owned":[{"id":"1","title":"Mine"}],"shared":[{"id":"2","title":"Ours","sharedWithMe":true}]}"#)])
        let boards = try await client(script).kanbanBoards()
        XCTAssertEqual(boards.map(\.title), ["Mine", "Ours"])
    }

    func testDeliveryCardSendsTheChosenColumn() async throws {
        let script = Script(["POST \(base)/api/ai-coders/projects/p/board/cards": (200, #"{"id":"c"}"#)])
        try await client(script).addDeliveryCard(projectID: "p", title: "T", body: "B", column: .ready)
        let body = try JSONSerialization.jsonObject(with: script.requests[0].httpBody!) as! [String: String]
        XCTAssertEqual(body["column"], "ready")
    }

    func testA403SaysItsAPermissionProblemNotAnExpiredSignIn() async throws {
        let script = Script(["GET \(base)/api/kanban": (403, #"{"statusCode":403,"message":"Missing kanban.manage","error":"Forbidden"}"#)])
        do {
            _ = try await client(script).kanbanBoards()
            XCTFail("should throw")
        } catch GuardianError.forbidden(let detail) {
            XCTAssertEqual(detail, "Missing kanban.manage")
        }
    }

    func testA401IsAnExpiredSignIn() async throws {
        let script = Script(["GET \(base)/api/people": (401, "{}")])
        do {
            _ = try await client(script).people()
            XCTFail("should throw")
        } catch GuardianError.unauthorized {}
    }

    func testLoginIdentifiesAsAClientGuardianRecognises() async throws {
        let script = Script(["POST \(base)/api/auth/login": (200, #"{"ok":true,"token":"t","profile":{"id":"u"}}"#)])
        let guardian = try GuardianClient(baseURL: base, transport: { request in script.handle(request) })
        _ = try await guardian.signIn(email: "e", password: "p")
        let body = try JSONSerialization.jsonObject(with: script.requests[0].httpBody!) as! [String: String]
        XCTAssertEqual(body["client"], "vision-harness")
    }

    // MARK: Chat stream

    private func parse(_ lines: [String]) -> [GuardianChatEvent] {
        var parser = GuardianSSEParser()
        return lines.compactMap { parser.feed($0) }
    }

    func testChatStream() {
        XCTAssertEqual(parse([
            "event: accepted", #"data: {"userMessageId":"m","chatId":"c1"}"#, "",
            "event: delta", #"data: {"text":"Hel"}"#, "",
            "event: plan", #"data: {"steps":[]}"#, "",
            "event: delta", #"data: {"text":"lo"}"#, "",
            "event: tool_call", #"data: {"name":"search"}"#, "",
            "event: done", #"data: {"tokensIn":5,"tokensOut":2}"#, "",
        ]), [.accepted(chatID: "c1"), .text("Hel"), .text("lo"), .toolCall("search"), .done(tokensIn: 5, tokensOut: 2)])
    }

    func testChatStreamError() {
        XCTAssertEqual(parse(["event: error", #"data: {"message":"budget"}"#]), [.failed("budget")])
    }

    func testADataLineWithoutAnEventIsIgnored() {
        XCTAssertEqual(parse([#"data: {"text":"x"}"#]), [])
    }

    func testAFirstMessageCarriesContextAndTheConversationSoFar() {
        let text = GuardianChatClient.firstMessage(
            earlier: [LLMMessage(role: .user, content: "before"), LLMMessage(role: .assistant, content: "reply"),
                                       LLMMessage(role: .tool, content: "tool noise")],
            text: "now")
        XCTAssertTrue(text.contains("User: before"))
        XCTAssertTrue(text.contains("Assistant: reply"))
        XCTAssertFalse(text.contains("tool noise"))
        XCTAssertTrue(text.hasSuffix("now"))
    }

    func testAFirstMessageWithNothingBeforeIsJustTheMessage() {
        XCTAssertEqual(GuardianChatClient.firstMessage(earlier: [], text: "hi"), "hi")
    }
}
