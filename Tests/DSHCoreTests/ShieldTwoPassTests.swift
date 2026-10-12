import XCTest
@testable import DSHCore

/// The shield's second pass: a value found once — often only by what is around it — is masked wherever it appears
/// in the request, including where the app put it back after the model used its placeholder. And what counts as an
/// assigned secret, what can't be checked, and Claude's signed turns on Bedrock.
final class ShieldTwoPassTests: XCTestCase {
    private func plain() -> SensitiveDetector { SensitiveDetector(settings: ShieldSettings()) }

    private func masked(_ text: String) -> String {
        Shield.mask(LLMRequest(systemPrompt: "", messages: [.user(text)], tools: [], model: "m"), detector: plain())
            .request.messages[0].content ?? ""
    }

    private func arguments(_ call: ToolCall?) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(call).arguments.raw.utf8)) as? [String: String])
    }

    // MARK: Found once, masked everywhere

    func testAPasswordTheModelUsedIsStillMaskedOnTheNextTurn() throws {
        let password = "Tr0ub4dorX9"
        let turn1: [LLMMessage] = [.user("Use the staging DB, password: \(password)")]
        let one = Shield.mask(LLMRequest(systemPrompt: "s", messages: turn1, tools: [], model: "m"), detector: plain())
        XCTAssertEqual(one.request.messages[0].content, "Use the staging DB, password: ⟦SECRET_1⟧")

        // The model answered with the placeholder; the app put the value back, so the transcript has it bare.
        let reply = one.map.restore("I'll connect with ⟦SECRET_1⟧")
        XCTAssertEqual(reply, "I'll connect with \(password)")
        let call = ToolCall(id: "c1", name: "run_shell_command", arguments: #"{"command":"mysql -u admin -p\#(password)"}"#)
        let turn2 = turn1 + [.assistant(reply), .user("go on"), .assistant("", calls: [call]),
                             .toolResult(id: "c1", name: "run_shell_command", output: "connected")]
        let two = Shield.mask(LLMRequest(systemPrompt: "s", messages: turn2, tools: [], model: "m"), detector: plain())
        XCTAssertEqual(two.request.messages[0].content, "Use the staging DB, password: ⟦SECRET_1⟧", "the same placeholder")
        XCTAssertEqual(two.request.messages[1].content, "I'll connect with ⟦SECRET_1⟧")
        XCTAssertEqual(try arguments(two.request.messages[3].toolCalls?.first), ["command": "mysql -u admin -p⟦SECRET_1⟧"],
                       "inside a word too")
        XCTAssertEqual(two.map.counts, [.secret: 1])
    }

    func testABearerTokenAndAURLPasswordAreMaskedWhenMentionedLater() throws {
        let token = "abcdefghijklmnop1234ZZ", password = "s3cr3t-Pa55word"
        let call = ToolCall(id: "c1", name: "run_shell_command", arguments: #"{"command":"mysql -u admin -p\#(password) app"}"#)
        let out = Shield.mask(LLMRequest(systemPrompt: "", messages: [
            .user("curl -H 'Authorization: Bearer \(token)' https://x — the db is postgres://admin:\(password)@db:5432/app"),
            .assistant("The token \(token) looks expired.", calls: [call]),
        ], tools: [], model: "m"), detector: plain())
        XCTAssertEqual(out.request.messages[1].content, "The token ⟦SECRET_1⟧ looks expired.")
        XCTAssertEqual(try arguments(out.request.messages[1].toolCalls?.first), ["command": "mysql -u admin -p⟦SECRET_2⟧ app"])
    }

    func testAToolCallsRawJSONIsReadAsAssignmentsToo() throws {
        // Key and value are separate JSON strings: only the raw text shows them as an assignment.
        let call = ToolCall(id: "c1", name: "http_request", arguments: #"{"password":"hunter22x","api_key":"abcdef123456"}"#)
        let out = Shield.mask(LLMRequest(systemPrompt: "", messages: [.assistant("", calls: [call])], tools: [], model: "m"),
                              detector: plain())
        XCTAssertEqual(try arguments(out.request.messages[0].toolCalls?.first), ["password": "⟦SECRET_1⟧", "api_key": "⟦SECRET_2⟧"])
    }

    func testAShortValueIsMaskedOnlyWhereItWasFound() {
        var settings = ShieldSettings()
        settings.customTerms = ["Al"]
        let out = Shield.mask(LLMRequest(systemPrompt: "", messages: [.user("Al said: Also call Al.")], tools: [], model: "m"),
                              detector: SensitiveDetector(settings: settings))
        XCTAssertEqual(out.request.messages[0].content, "⟦TERM_1⟧ said: Also call ⟦TERM_1⟧.", "not inside \"Also\"")
    }

    // MARK: Assignments

    func testCodeIsNotTakenForASecret() {
        for code in ["let token: String; var password: String?; let apiKey: String", "const token = getToken();",
                     "password: string;", #"token = request.headers.get("x")"#, #"secret := os.Getenv("X")"#,
                     "token: accessToken", "password = user_password", "token: DEFAULT_TOKEN", "token: Uint8Array",
                     "password: undefined"] {
            XCTAssertEqual(masked(code), code, code)
        }
    }

    func testAnAssignedSecretIsMasked() {
        XCTAssertEqual(masked(#"password: "hunter2hunter2""#), #"password: "⟦SECRET_1⟧""#)
        XCTAssertEqual(masked(#"{"password": "hunter2"}"#), #"{"password": "⟦SECRET_1⟧"}"#)
        XCTAssertEqual(masked("PASSWORD=correcthorse"), "PASSWORD=⟦SECRET_1⟧")
        XCTAssertEqual(masked("DB_PASSWORD=supersecret"), "DB_PASSWORD=⟦SECRET_1⟧")
        XCTAssertEqual(masked("password: correcthorsebattery"), "password: ⟦SECRET_1⟧")
        XCTAssertEqual(masked("token: abc123def"), "token: ⟦SECRET_1⟧")
        XCTAssertEqual(masked("password: Tr0ub4dorX9"), "password: ⟦SECRET_1⟧", "digits make it no identifier")
        XCTAssertEqual(masked("The password: hunter2pass."), "The password: ⟦SECRET_1⟧.", "a full stop isn't part of it")
    }

    func testEnvFileLines() {
        let env = "export GITHUB_TOKEN=\"ghx_1234abcd\"\nAPI_KEY=${OTHER_KEY}\nDB_SECRET=$VAULT_SECRET\nSESSION_SECRET=Kx9-PLAIN"
        XCTAssertEqual(masked(env), "export GITHUB_TOKEN=\"⟦SECRET_1⟧\"\nAPI_KEY=${OTHER_KEY}\nDB_SECRET=$VAULT_SECRET\nSESSION_SECRET=⟦SECRET_2⟧")
    }

    // MARK: Attachments

    func testAUTF16TextFileIsMaskedAndAPDFIsFlagged() throws {
        let utf16 = try XCTUnwrap("contact ann@example.com".data(using: .utf16))   // with a byte-order mark
        var pdf = Data("%PDF-1.7\n".utf8)
        pdf.append(contentsOf: [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        pdf.append(Data("bob@example.com".utf8))
        let message = LLMMessage.user("see attached", attachments: [MessageAttachment(kind: .file, name: "notes.txt", data: utf16),
                                                                    MessageAttachment(kind: .file, name: "contract.pdf", data: pdf)])
        let out = Shield.mask(LLMRequest(systemPrompt: "", messages: [message], tools: [], model: "m"), detector: plain())
        let sent = try XCTUnwrap(out.request.messages[0].attachments)
        XCTAssertEqual(String(data: sent[0].data, encoding: .utf16), "contact ⟦EMAIL_1⟧")
        XCTAssertEqual(Array(sent[0].data.prefix(2)), Array(utf16.prefix(2)), "written back the same way, mark and all")
        XCTAssertEqual(sent[1].data, pdf, "a PDF goes as it is…")
        XCTAssertTrue(out.unchecked, "…and is flagged like a picture")

        let binary = MessageAttachment(kind: .file, name: "blob.bin", data: Data([0x01, 0x00, 0x02]) + Data("x@example.com".utf8))
        XCTAssertTrue(Shield.mask(LLMRequest(systemPrompt: "", messages: [.user("x", attachments: [binary])], tools: [], model: "m"),
                                  detector: plain()).unchecked)
        let text = MessageAttachment(kind: .file, name: "a.md", data: Data("hi".utf8))
        XCTAssertFalse(Shield.mask(LLMRequest(systemPrompt: "", messages: [.user("x", attachments: [text])], tools: [], model: "m"),
                                   detector: plain()).unchecked)
    }

    func testThousandsOfRowsAreMaskedQuickly() throws {
        var csv = "name,email,phone\n"
        for i in 0..<8_000 { csv += "Person \(i),person\(i)@example.com,+1415\(String(format: "%07d", i))\n" }
        let file = MessageAttachment(kind: .file, name: "contacts.csv", data: Data(csv.utf8))
        let request = LLMRequest(systemPrompt: "", messages: [.user("see", attachments: [file])], tools: [], model: "m")
        let start = Date()
        let out = Shield.mask(request, detector: plain())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out.map.counts, [.email: 8_000, .phone: 8_000])
        let sent = String(decoding: try XCTUnwrap(out.request.messages[0].attachments?.first).data, as: UTF8.self)
        XCTAssertFalse(sent.contains("@example.com") || sent.contains("+1415"))
        XCTAssertTrue(sent.hasPrefix("name,email,phone\nPerson 0,⟦EMAIL_1⟧,⟦PHONE_1⟧\n"))
        print("SHIELD: 8,000 rows masked in \(Int(elapsed * 1000)) ms")
        // Well under half a second in a release build; a debug build (as `swift test` runs) is several times slower.
        XCTAssertLessThan(elapsed, Self.isDebug ? 2.5 : 0.5)
    }

    private static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    // MARK: Claude's signed turns on Bedrock

    func testASignedTurnThatHoldsAMaskedValueStaysBehind() {
        let password = "Tr0ub4dorX9"
        let leaky = #"[{"reasoningContent":{"reasoningText":{"text":"They gave the password \#(password).","signature":"c2ln"}}},{"text":"Connecting."}]"#
        let safe = #"[{"reasoningContent":{"reasoningText":{"text":"They gave ⟦SECRET_1⟧.","signature":"c2ln"}}},{"text":"Connecting."}]"#
        var before = LLMMessage.assistant("Connecting.")
        before.providerState = leaky
        var through = LLMMessage.assistant("Connecting.")
        through.providerState = safe
        let out = Shield.mask(LLMRequest(systemPrompt: "", messages: [.user("password: \(password)"), before, .user("again"), through],
                                         tools: [], model: "m"), detector: plain())
        XCTAssertNil(out.request.messages[1].providerState, "written with the real value: it doesn't go back")
        XCTAssertEqual(out.request.messages[3].providerState, safe, "written through the shield: it does")

        // A value written with JSON escapes inside the record is found too.
        var settings = ShieldSettings()
        settings.customTerms = ["Zoë Café"]
        var escaped = LLMMessage.assistant("ok")
        escaped.providerState = #"[{"reasoningContent":{"reasoningText":{"text":"Zoë Café called","signature":"c2ln"}}}]"#
        let other = Shield.mask(LLMRequest(systemPrompt: "", messages: [.user("Zoë Café called"), escaped], tools: [], model: "m"),
                                detector: SensitiveDetector(settings: settings))
        XCTAssertNil(other.request.messages[1].providerState)
    }

    // MARK: The detector's overlaps

    func testOverlapsAreResolvedInOneSweep() {
        // A run of overlapping matches becomes one span named by the longest; neighbours stay apart.
        let detector = SensitiveDetector(settings: ShieldSettings())
        let text = "mysql://root:P@ssw0rd@db.example.com/x and ann@example.com"
        let found = detector.matches(in: text).map { (String(text[$0.range]), $0.category) }
        XCTAssertEqual(found.map(\.0), ["P@ssw0rd@db.example.com", "ann@example.com"])
        XCTAssertEqual(found.map(\.1), [.email, .email])
    }
}
