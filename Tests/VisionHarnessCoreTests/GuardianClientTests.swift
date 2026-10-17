import XCTest
@testable import VisionHarnessCore

/// A sendable capture box for observing requests from inside a transport.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class GuardianClientTests: XCTestCase {
    /// A scripted transport: path → responder. The login endpoint is
    /// auto-answered unless the test overrides it (most tests just need a
    /// session to exist before the call under test).
    private func client(_ routes: [String: @Sendable (URLRequest) -> GuardianHTTPResponse],
                        base: String = "https://guardian.503cm.com") throws -> GuardianClient {
        let scripted: [String: @Sendable (URLRequest) -> GuardianHTTPResponse]
        if routes["POST /api/auth/login"] == nil {
            var withLogin = routes
            withLogin["POST /api/auth/login"] = reply(#"{"token":"t"}"#)
            scripted = withLogin
        } else {
            scripted = routes
        }
        return try GuardianClient(baseURL: base) { request in
            let path = request.url?.path ?? ""
            let key = request.httpMethod == "POST" ? "POST \(path)" : path
            guard let responder = scripted[key] ?? scripted[path] else {
                return GuardianHTTPResponse(data: Data("{}".utf8), status: 404, headers: [:])
            }
            return responder(request)
        }
    }

    /// A route that always answers the same way.
    private func reply(_ json: String, status: Int = 200) -> @Sendable (URLRequest) -> GuardianHTTPResponse {
        { _ in GuardianHTTPResponse(data: Data(json.utf8), status: status, headers: [:]) }
    }

    // MARK: URL validation

    // MARK: 2FA (TOTP) sign-in

    func testSignInWith2FAAccountThrowsTwoFactorRequired() async throws {
        // Guardian answers a TOTP account with {ok, twoFactorRequired, challenge}.
        let c = try client([
            "POST /api/auth/login": reply(#"{"ok":true,"twoFactorRequired":true,"challenge":"jwt-challenge-1"}"#),
        ])
        do {
            _ = try await c.signIn(email: "me@503cm.com", password: "pw")
            XCTFail("signIn should surface the 2FA step, not misreport bad credentials")
        } catch let GuardianError.twoFactorRequired(challenge) {
            XCTAssertEqual(challenge, "jwt-challenge-1")
        }
        // No session until the code lands.
        XCTAssertNil(c.session)
    }

    func testVerifyTwoFactorExchangesChallengeAndCodeForSession() async throws {
        let seen = Box<URLRequest?>(nil)
        let c = try client([
            "POST /api/auth/login": reply(#"{"ok":true,"twoFactorRequired":true,"challenge":"jwt-challenge-1"}"#),
            "POST /api/auth/login/2fa": { request in
                seen.value = request
                return GuardianHTTPResponse(
                    data: Data(#"{"ok":true,"token":"sess-tok","session":{"userId":"u1","email":"me@503cm.com","name":"Pat"}}"#.utf8),
                    status: 200, headers: [:])
            },
        ])
        do {
            _ = try await c.signIn(email: "me@503cm.com", password: "pw")
            XCTFail("expected the 2FA step")
        } catch GuardianError.twoFactorRequired { }
        let session = try await c.verifyTwoFactor(challenge: "jwt-challenge-1", code: "123456")
        XCTAssertEqual(session.token, "sess-tok")
        XCTAssertEqual(session.email, "me@503cm.com")
        XCTAssertEqual(c.session?.token, "sess-tok")
        let body = String(decoding: seen.value?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains(#""challenge":"jwt-challenge-1""#))
        XCTAssertTrue(body.contains(#""code":"123456""#))
        XCTAssertEqual(seen.value?.url?.path, "/api/auth/login/2fa")
    }

    func testVerifyTwoFactorRejectsMalformedCodesBeforeCalling() async throws {
        let c = try client([
            "POST /api/auth/login": reply(#"{"ok":true,"twoFactorRequired":true,"challenge":"jwt-c"}"#),
            "POST /api/auth/login/2fa": reply(#"{"ok":true,"token":"should-not-happen"}"#),
        ])
        do {
            _ = try await c.signIn(email: "me@503cm.com", password: "pw")
            XCTFail("expected the 2FA step")
        } catch GuardianError.twoFactorRequired { }
        for bad in ["12 456", "abc123", "12345", "1234567", ""] {
            do {
                _ = try await c.verifyTwoFactor(challenge: "c", code: bad)
                XCTFail("'\(bad)' should be refused client-side")
            } catch let GuardianError.invalidCredentials(detail) {
                XCTAssertTrue(detail.contains("6-digit"), "message should explain the format: \(detail)")
            }
        }
    }

    func testVerifyTwoFactorBadCodeSurfacesGuardianError() async throws {
        let c = try client([
            "POST /api/auth/login": reply(#"{"ok":true,"twoFactorRequired":true,"challenge":"jwt-1"}"#),
            "POST /api/auth/login/2fa": reply(#"{"statusCode":401,"message":"invalid 2fa code"}"#, status: 401),
        ])
        _ = try? await c.signIn(email: "me@503cm.com", password: "pw")
        do {
            _ = try await c.verifyTwoFactor(challenge: "jwt-1", code: "000000")
            XCTFail("a rejected code must throw")
        } catch let GuardianError.invalidCredentials(detail) {
            // A wrong/rotated code is remapped to retry guidance (the wire
            // 401 doesn't carry a decode-able body through `check`).
            XCTAssertTrue(detail.contains("rotated") || detail.contains("invalid 2fa code"),
                          "detail should explain the retry: \(detail)")
        }
    }

    func testBadURLIsRefused() {        XCTAssertThrowsError(try GuardianClient(baseURL: "not a url"))
        XCTAssertThrowsError(try GuardianClient(baseURL: "ftp://guardian.503cm.com"))
        XCTAssertNoThrow(try GuardianClient(baseURL: "https://guardian.503cm.com"))
        XCTAssertNoThrow(try GuardianClient(baseURL: "http://localhost:3000"))
    }

    func testTrailingSlashIsTrimmed() throws {
        let c = try client(["/api/harness/v1/models": reply(#"{"models":[]}"#)],
                           base: "https://guardian.503cm.com/")
        XCTAssertEqual(c.baseURL.absoluteString, "https://guardian.503cm.com")
    }

    // MARK: Sign-in

    func testSignInStoresSession() async throws {
        let c = try client(["POST /api/auth/login": reply(#"{"token":"tok-1","user":{"id":"u1","email":"me@503cm.com","name":"Pat"}}"#)])
        XCTAssertFalse(c.isSignedIn)
        let session = try await c.signIn(email: "me@503cm.com", password: "secret")
        XCTAssertEqual(session.token, "tok-1")
        XCTAssertEqual(session.userID, "u1")
        XCTAssertEqual(session.name, "Pat")
        XCTAssertTrue(c.isSignedIn)
    }

    func testSignInAcceptsAlternateTokenShapes() async throws {
        for shape in [#"{"accessToken":"alt-1"}"#, #"{"sessionToken":"alt-2"}"#] {
            let c = try client(["POST /api/auth/login": reply(shape)])
            let session = try await c.signIn(email: "e", password: "p")
            XCTAssertTrue(session.token.hasPrefix("alt-"))
        }
    }

    func testSignInFailureExplains() async throws {
        let c = try client(["POST /api/auth/login": reply(#"{"error":"No account matches that email"}"#)])
        do {
            _ = try await c.signIn(email: "e", password: "p")
            XCTFail("should have thrown")
        } catch let error as GuardianError {
            XCTAssertEqual(error.errorDescription, "Guardian didn't accept that sign-in. No account matches that email")
        }
    }

    func testSignInSendsCredentialsAndClientName() async throws {
        let seen = Box<URLRequest?>(nil)
        let c = try GuardianClient(baseURL: "https://guardian.503cm.com") { request in
            seen.value = request
            return GuardianHTTPResponse(data: Data(#"{"token":"t"}"#.utf8), status: 200, headers: [:])
        }
        _ = try await c.signIn(email: "me@503cm.com", password: "pw")
        let body = String(decoding: seen.value?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("me@503cm.com"))
        XCTAssertTrue(body.contains("vision-harness"))
        XCTAssertEqual(seen.value?.url?.path, "/api/auth/login")
    }

    // MARK: Models

    func testModelsBearerAndDecode() async throws {
        let seenAuth = Box<String?>(nil)
        let c = try client(["/api/harness/v1/models": { request in
            seenAuth.value = request.value(forHTTPHeaderField: "Authorization")
            return GuardianHTTPResponse(data: Data(
                #"{"models":[{"id":"glm-5.3","label":"GLM-5.3","contextWindow":1000000},{"id":"kimi-for-coding","interactiveOnly":false}]}"#.utf8),
                status: 200, headers: [:])
        }])
        _ = try await c.signIn(email: "e", password: "p")
        let models = try await c.models()
        XCTAssertEqual(seenAuth.value, "Bearer t")
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "glm-5.3")
        XCTAssertEqual(models[0].contextWindow, 1_000_000)
        XCTAssertEqual(models[1].interactiveOnly, false)
    }

    func testModelsOpenAIShape() async throws {
        let c = try client(["/api/harness/v1/models": reply(#"{"data":[{"id":"gpt-x"},{"id":"qwen3.7-plus"}]}"#)])
        let models = try await c.models()
        XCTAssertEqual(models.map(\.id), ["gpt-x", "qwen3.7-plus"])
    }

    // MARK: Error mapping

    func testUnauthorized() async throws {
        let c = try client(["/api/harness/v1/models": reply("{}", status: 401)])
        do {
            _ = try await c.models()
            XCTFail()
        } catch let error as GuardianError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testServerErrorMessageSurfaces() async throws {
        let c = try client(["/api/harness/v1/models": reply(#"{"error":"quota spent"}"#, status: 503)])
        do {
            _ = try await c.models()
            XCTFail()
        } catch let error as GuardianError {
            XCTAssertEqual(error.errorDescription, "Guardian had a problem: quota spent")
        }
    }

    // MARK: Prompt sync (item 4)

    func testPushPrompts() async throws {
        let seenBody = Box<Data?>(nil)
        let seenAuth = Box<String?>(nil)
        let c = try client(["POST /api/harness/prompts": { request in
            seenBody.value = request.httpBody
            seenAuth.value = request.value(forHTTPHeaderField: "Authorization")
            return GuardianHTTPResponse(data: Data(#"{"accepted":2}"#.utf8), status: 200, headers: [:])
        }])
        _ = try await c.signIn(email: "e", password: "p")
        let accepted = try await c.pushPrompts([
            .init(text: "Fix the flaky test", at: Date(timeIntervalSince1970: 1_700_000_000), outcome: "completed", source: "chat-1"),
            .init(text: "Draft release notes", at: Date(timeIntervalSince1970: 1_700_000_100)),
        ])
        XCTAssertEqual(accepted, 2)
        let body = String(decoding: seenBody.value ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("Fix the flaky test"))
        XCTAssertTrue(body.contains("completed"))
        XCTAssertEqual(seenAuth.value, "Bearer t")
    }

    func testPullPromptsAcceptsISOAndEpochDates() async throws {
        let c = try client(["/api/harness/prompts": reply(
            #"{"prompts":[{"text":"a","at":"2026-10-16T09:30:00Z"},{"text":"b","at":"1700000000"}]}"#)])
        let prompts = try await c.prompts()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts[0].text, "a")
        XCTAssertEqual(prompts[1].at.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    // MARK: Skills

    func testPutAndTakeSkills() async throws {
        let putPath = Box<String?>(nil)
        let putBody = Box<Data?>(nil)
        let c = try client([
            "POST /api/harness/skills": { request in
                putPath.value = request.url?.path
                putBody.value = request.httpBody
                return GuardianHTTPResponse(data: Data("{}".utf8), status: 200, headers: [:])
            },
            "/api/harness/skills": reply(
                ##"{"skills":[{"name":"godot-debugging","description":"Debug a Godot game","files":{"SKILL.md":"# debug"}}]}"##),
        ])
        _ = try await c.signIn(email: "e", password: "p")
        try await c.putSkill(name: "godot-debugging", description: "Debug a Godot game",
                             files: ["SKILL.md": "# debug"])
        XCTAssertEqual(putPath.value, "/api/harness/skills")
        XCTAssertTrue(String(decoding: putBody.value ?? Data(), as: UTF8.self).contains("godot-debugging"))
        let skills = try await c.skills()
        XCTAssertEqual(skills.first?.name, "godot-debugging")
        XCTAssertEqual(skills.first?.files["SKILL.md"], "# debug")
    }

    // MARK: Chats

    func testExportImportChatRoundTrip() async throws {
        let payload = #"{"entries":[{"role":"user","text":"hello"}]}"#
        let stored = Box<Data?>(nil)
        let escaped = #"{"payload":"{\"entries\":[{\"role\":\"user\",\"text\":\"hello\"}]}"}"#
        let c = try client([
            "POST /api/harness/chats/chat-9": { request in
                stored.value = request.httpBody
                return GuardianHTTPResponse(data: Data("{}".utf8), status: 200, headers: [:])
            },
            "/api/harness/chats/chat-9": reply(escaped),
        ])
        _ = try await c.signIn(email: "e", password: "p")
        try await c.putChat(id: "chat-9", title: "Test chat", updatedAt: .now, payload: Data(payload.utf8))
        XCTAssertTrue(String(decoding: stored.value ?? Data(), as: UTF8.self).contains("hello"))
        let back = try await c.chat(id: "chat-9")
        XCTAssertEqual(String(decoding: back, as: UTF8.self), payload)
    }

    func testListChats() async throws {
        let c = try client(["/api/harness/chats": reply(
            #"{"chats":[{"id":"c1","title":"Fix the bug","updatedAt":"2026-10-16T10:00:00Z"}]}"#)])
        let chats = try await c.chats()
        XCTAssertEqual(chats.first?.title, "Fix the bug")
    }

    // MARK: Projects

    func testPutProject() async throws {
        let seenPath = Box<String?>(nil)
        let seenBody = Box<Data?>(nil)
        let c = try client(["POST /api/harness/projects": { request in
            seenPath.value = request.url?.path
            seenBody.value = request.httpBody
            return GuardianHTTPResponse(data: Data("{}".utf8), status: 200, headers: [:])
        }])
        _ = try await c.signIn(email: "e", password: "p")
        try await c.putProject(name: "ledger", files: ["README.md": "# ledger", "main.py": "print(1)"])
        XCTAssertEqual(seenPath.value, "/api/harness/projects")
        let body = String(decoding: seenBody.value ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("ledger"))
        XCTAssertTrue(body.contains("main.py"))
    }

    // MARK: The shared ETA cache

    func testEtaSummaryDecodesByKind() async throws {
        let c = try client(["/api/harness/eta": reply(
            #"{"byKind":{"codeEdit":{"count":12,"meanSeconds":180,"meanScope":1.4},"research":{"count":3,"meanSeconds":45,"meanScope":0.9}}}"#)])
        let summary = try await c.etaSummary()
        XCTAssertEqual(summary[.codeEdit]?.count, 12)
        XCTAssertEqual(summary[.codeEdit]?.meanSeconds ?? 0, 180, accuracy: 0.01)
        XCTAssertEqual(summary[.research]?.meanScope ?? 0, 0.9, accuracy: 0.001)
    }

    func testPushEtaSamples() async throws {
        let seenBody = Box<Data?>(nil)
        let c = try client(["POST /api/harness/eta": { request in
            seenBody.value = request.httpBody
            return GuardianHTTPResponse(data: Data(#"{"accepted":1}"#.utf8), status: 200, headers: [:])
        }])
        _ = try await c.signIn(email: "e", password: "p")
        try await c.pushEtaSamples([(.codeEdit, 1.5, 240)])
        let body = String(decoding: seenBody.value ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("codeEdit"))
        XCTAssertTrue(body.contains("240"))
    }

    func testSyncEtasBlendsSharedIntoRunner() async throws {
        let c = try client(["/api/harness/eta": reply(
            #"{"byKind":{"codeEdit":{"count":40,"meanSeconds":100,"meanScope":1.0}}}"#)])
        _ = try await c.signIn(email: "e", password: "p")
        let runner = TurnPhaseRunner()
        // Local: 4 samples at 200s.
        runner.mergeSample(kind: .codeEdit, .init(count: 4, meanSeconds: 200, meanScope: 1.0))
        try await c.syncEtas(into: runner)
        let blended = runner.sample(for: .codeEdit)
        // (200×4 + 100×40) / 44 ≈ 109
        XCTAssertEqual(blended.meanSeconds, 109.09, accuracy: 0.5)
        XCTAssertEqual(blended.count, 44)
        // A kind Guardian knows and the Mac doesn't is adopted whole.
        let c2 = try client(["/api/harness/eta": reply(
            #"{"byKind":{"writing":{"count":7,"meanSeconds":80,"meanScope":1.1}}}"#)])
        _ = try await c2.signIn(email: "e", password: "p")
        try await c2.syncEtas(into: runner)
        XCTAssertEqual(runner.sample(for: .writing).meanSeconds, 80, accuracy: 0.01)
    }
}
