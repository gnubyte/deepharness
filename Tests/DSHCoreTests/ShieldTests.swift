import XCTest
@testable import DSHCore

/// A model that records what it was sent and answers from a script.
private final class EchoModel: ProviderClient, @unchecked Sendable {
    let profile: ProviderProfile
    private let lock = NSLock()
    private var _requests: [LLMRequest] = []
    private let reply: @Sendable (LLMRequest) -> [LLMStreamEvent]

    init(name: String = "Kimi Code", reply: @escaping @Sendable (LLMRequest) -> [LLMStreamEvent]) {
        profile = ProviderProfile(kind: .openAICompat, name: name, baseURL: "https://api.kimi.ai/coding/v1", model: "kimi-for-coding")
        self.reply = reply
    }

    var requests: [LLMRequest] { lock.withLock { _requests } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.withLock { _requests.append(request) }
        let events = reply(request)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { [] }
    func modelInfo(_ model: String?) async -> ModelInfo? { nil }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ShieldReport] = []
    func add(_ report: ShieldReport) { lock.withLock { seen.append(report) } }
    var all: [ShieldReport] { lock.withLock { seen } }
}

final class ShieldTests: XCTestCase {
    private let everything: ShieldSettings = {
        var s = ShieldSettings()
        s.ips = true
        s.customTerms = ["Acme", "Project Bluebird", "re:CASE-\\d{4}"]
        return s
    }()

    private func masked(_ text: String, settings: ShieldSettings? = nil, vault: [String] = []) -> String {
        let detector = SensitiveDetector(settings: settings ?? everything, vaultValues: vault)
        let request = LLMRequest(systemPrompt: "", messages: [.user(text)], tools: [], model: "m")
        return Shield.mask(request, detector: detector).request.messages[0].content ?? ""
    }

    private func categories(_ text: String, settings: ShieldSettings? = nil) -> [SensitiveCategory] {
        SensitiveDetector(settings: settings ?? everything).matches(in: text).map(\.category)
    }

    // MARK: Detectors

    func testSecretsAndKeys() {
        let keys = [
            "AKIAIOSFODNN7ABCDEFG", "ASIAABCDEFGHIJKLMNOP",
            "ghp_" + String(repeating: "a1B2", count: 9), "github_pat_" + String(repeating: "A1b_", count: 16),
            "sk-" + String(repeating: "x9Y8", count: 6), "sk-proj-" + String(repeating: "Z7w-", count: 5) + "Z7wQ",
            "sk-ant-api03-" + String(repeating: "Qq11", count: 6), "xoxb-1234567890-abcdefghij",
            "AIza" + String(repeating: "B", count: 35), "sk_live_" + String(repeating: "4eC3", count: 5),
            "rk_test_" + String(repeating: "9Zz9", count: 5), "sst_1a2b3c4d_" + String(repeating: "Tok3n", count: 5),
            "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4fw",
        ]
        for key in keys {
            XCTAssertEqual(masked("use \(key) here"), "use ⟦SECRET_1⟧ here", key)
        }
    }

    func testAPrivateKeyBlockIsMaskedWhole() {
        let block = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA0Z3\nabc\n-----END RSA PRIVATE KEY-----"
        XCTAssertEqual(masked("key:\n\(block)\ndone"), "key:\n⟦SECRET_1⟧\ndone")
        XCTAssertEqual(masked("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk"), "⟦SECRET_1⟧", "cut off: to the end")
    }

    func testOnlyTheSecretPartOfABearerHeaderAURLOrAnAssignmentIsMasked() {
        XCTAssertEqual(masked("Authorization: Bearer abcdefghijklmnop1234"), "Authorization: Bearer ⟦SECRET_1⟧")
        XCTAssertEqual(masked("Bearer short"), "Bearer short", "16 characters or more")
        XCTAssertEqual(masked("postgres://admin:s3cr3t-Pa55@db:5432/app"), "postgres://admin:⟦SECRET_1⟧@db:5432/app")
        XCTAssertEqual(masked("mysql://root:P@ssw0rd@localhost/x"), "mysql://root:⟦SECRET_1⟧@localhost/x", "an @ in the password")
        // A password whose "@host" also reads as an email address: the longer match covers both — nothing shows.
        let both = masked("mysql://root:P@ssw0rd@db.example.com/x")
        XCTAssertEqual(both, "mysql://root:⟦EMAIL_1⟧/x")
        XCTAssertFalse(both.contains("P@") || both.contains("ssw0rd"))
        XCTAssertEqual(masked("password = hunter2pass"), "password = ⟦SECRET_1⟧")
        XCTAssertEqual(masked("API_KEY=\"q8Fz2LmN0p\""), "API_KEY=\"⟦SECRET_1⟧\"")
        XCTAssertEqual(masked(#"{"token": "abc123xyz789"}"#), #"{"token": "⟦SECRET_1⟧"}"#, "a quoted key")
        XCTAssertEqual(masked("access-key: Zz99Yy88Xx"), "access-key: ⟦SECRET_1⟧")
    }

    func testObviousStandInsAreNotSecrets() {
        for text in ["password = ********", "password: <your password>", "token=${GITHUB_TOKEN}", "api_key = xxxxxxxx",
                     "password=changeme", "api-key: your-api-key-here", "token={{vault:GITHUB_TOKEN}}",
                     "token = os.environ.get('X')", "secret=⟦SECRET_1⟧"] {
            XCTAssertEqual(masked(text), text, text)
        }
    }

    func testEmailsAndPhones() {
        XCTAssertEqual(masked("mail jane.doe+work@example.co.uk now"), "mail ⟦EMAIL_1⟧ now")
        XCTAssertEqual(masked("call +14155552671 or (415) 555-2671 or 415.555.2671"), "call ⟦PHONE_1⟧ or ⟦PHONE_2⟧ or ⟦PHONE_3⟧")
        XCTAssertEqual(masked("id 4155552671 and port 8080"), "id 4155552671 and port 8080", "plain digits aren't a phone number")
    }

    func testIDsCardsAndIBANs() {
        XCTAssertEqual(masked("SSN 123-45-6789."), "SSN ⟦ID_1⟧.")
        XCTAssertEqual(masked("card 4111 1111 1111 1111"), "card ⟦CARD_1⟧", "Luhn-valid")
        // Luhn-valid by chance, but no card network starts like that: a millisecond timestamp and an order number.
        XCTAssertTrue(SensitiveDetector.isCardNumber("4111111111111111"))
        XCTAssertFalse(SensitiveDetector.isCardNumber("1791827673618"), "13 digits, and a timestamp")
        XCTAssertFalse(SensitiveDetector.isCardNumber("17918276736181"), "starts like no card")
        XCTAssertTrue(SensitiveDetector.isCardNumber("378282246310005"), "Amex")
        XCTAssertTrue(SensitiveDetector.isCardNumber("5555555555554444"), "Mastercard")
        XCTAssertEqual(masked("at 17918276736181 ms"), "at 17918276736181 ms")
        XCTAssertEqual(masked("card 4111-1111-1111-1111"), "card ⟦CARD_1⟧")
        XCTAssertEqual(masked("4111111111111111"), "⟦CARD_1⟧")
        XCTAssertEqual(masked("order 4111 1111 1111 1112"), "order 4111 1111 1111 1112", "fails Luhn")
        XCTAssertEqual(masked("ts 1700000000000"), "ts 1700000000000", "a timestamp that fails Luhn")
        XCTAssertEqual(masked("IBAN GB82WEST12345698765432"), "IBAN ⟦ID_1⟧", "a valid IBAN")
        XCTAssertEqual(masked("IBAN GB82WEST12345698765433"), "IBAN GB82WEST12345698765433", "a bad check")
    }

    func testIPAddressesOnlyWhenAskedFor() {
        var settings = ShieldSettings()
        XCTAssertFalse(settings.ips, "off by default")
        XCTAssertEqual(masked("host 192.168.1.42", settings: settings), "host 192.168.1.42")
        settings.ips = true
        XCTAssertEqual(masked("host 192.168.1.42, loopback 127.0.0.1, any 0.0.0.0, v1.2.3.4, 300.1.1.1", settings: settings),
                       "host ⟦IP_1⟧, loopback 127.0.0.1, any 0.0.0.0, v1.2.3.4, 300.1.1.1")
    }

    func testCustomTerms() {
        XCTAssertEqual(masked("ACME and acme and Acmeville"), "⟦TERM_1⟧ and ⟦TERM_2⟧ and Acmeville",
                       "any case, whole words (each spelling is its own value)")
        XCTAssertEqual(masked("the project bluebird launch"), "the ⟦TERM_1⟧ launch")
        XCTAssertEqual(masked("see CASE-0042 and case-0042"), "see ⟦TERM_1⟧ and case-0042", "a re: line is the regex as written")
        var off = everything
        off.terms = false
        XCTAssertEqual(masked("Acme", settings: off), "Acme")
    }

    func testVaultSecretsAreAlwaysMaskedExactly() {
        var off = ShieldSettings()
        off.enabled = false
        XCTAssertEqual(masked("my pw is Tr0ub4dor&3 ok", settings: off, vault: ["Tr0ub4dor&3"]), "my pw is ⟦SECRET_1⟧ ok",
                       "whatever the switches say")
        XCTAssertEqual(masked("tr0ub4dor&3", settings: off, vault: ["Tr0ub4dor&3"]), "tr0ub4dor&3", "exact values only")
        XCTAssertNil(ShieldPolicy(settings: off).detector(), "nothing to mask: no wrapper at all")
        XCTAssertNotNil(ShieldPolicy(settings: off, vaultValues: { ["Tr0ub4dor&3"] }).detector())
    }

    func testTheLongestMatchWinsAndPlaceholdersAreLeftAlone() {
        XCTAssertEqual(categories("write to bob@acme.com"), [.email], "the email, not the term inside it")
        XCTAssertEqual(masked("⟦EMAIL_1⟧ says acme"), "⟦EMAIL_1⟧ says ⟦TERM_1⟧")
        var withTag = everything
        withTag.customTerms = ["EMAIL"]
        XCTAssertEqual(masked("⟦EMAIL_1⟧", settings: withTag), "⟦EMAIL_1⟧", "never inside a placeholder")
    }

    // MARK: The wrapper

    private func run(_ client: ShieldClient, _ request: LLMRequest) async throws -> (text: String, reasoning: String, calls: [ToolCall]) {
        var text = "", reasoning = "", calls: [ToolCall] = []
        for try await event in client.stream(request) {
            switch event {
            case .text(let t): text += t
            case .reasoning(let r): reasoning += r
            case .done(let c, _, _, _): calls = c
            }
        }
        return (text, reasoning, calls)
    }

    private func detector() -> SensitiveDetector { SensitiveDetector(settings: everything) }

    func testTheAppSeesRealValuesAndTheModelOnlyPlaceholders() async throws {
        let model = EchoModel { request in
            // The model uses the placeholders it was given, in pieces.
            let sent = request.messages.last?.content ?? ""
            return [.text("Writing to "), .text(String(sent.dropFirst("email ".count).prefix(3))),
                    .text(String(sent.dropFirst("email ".count + 3))), .done(calls: [], finish: "stop", usage: nil)]
        }
        let reports = Reports()
        let client = ShieldClient(inner: model, detector: detector(), onReport: reports.add)
        let result = try await run(client, LLMRequest(systemPrompt: "sys", messages: [.user("email ann@example.com")], tools: [], model: "m"))
        XCTAssertEqual(model.requests[0].messages[0].content, "email ⟦EMAIL_1⟧")
        XCTAssertEqual(result.text, "Writing to ann@example.com", "mask, then restore: the app side is unchanged")
        XCTAssertEqual(reports.all, [ShieldReport(route: "Kimi Code", counts: [.email: 1])])
        XCTAssertEqual(reports.all.first?.summary, "Masked 1 email before sending to Kimi Code")
    }

    func testNumberingIsStableAsTheConversationGrows() {
        let first = [LLMMessage.user("mail bob@x.io, then ann@y.io"), .assistant("ok")]
        let second = first + [.user("also ann@y.io and carl@z.io, key sk-" + String(repeating: "k1", count: 12))]
        let one = Shield.mask(LLMRequest(systemPrompt: "s", messages: first, tools: [], model: "m"), detector: detector())
        let two = Shield.mask(LLMRequest(systemPrompt: "s", messages: second, tools: [], model: "m"), detector: detector())
        XCTAssertEqual(one.request.messages[0].content, "mail ⟦EMAIL_1⟧, then ⟦EMAIL_2⟧")
        XCTAssertEqual(two.request.messages[0].content, "mail ⟦EMAIL_1⟧, then ⟦EMAIL_2⟧", "the earlier turn is unchanged")
        XCTAssertEqual(two.request.messages[2].content, "also ⟦EMAIL_2⟧ and ⟦EMAIL_3⟧, key ⟦SECRET_1⟧")
        XCTAssertEqual(two.map.counts, [.email: 3, .secret: 1])
    }

    func testTheNoteIsAddedOnceToTheFirstSystemMessage() {
        let withPrompt = Shield.mask(LLMRequest(systemPrompt: "You are DSH.", messages: [.user("hi")], tools: [], model: "m"),
                                     detector: detector()).request
        XCTAssertEqual(withPrompt.systemPrompt, "You are DSH.\n\n" + Shield.note)
        let again = Shield.mask(withPrompt, detector: detector()).request
        XCTAssertEqual(again.systemPrompt, withPrompt.systemPrompt, "not twice")
        let inMessages = Shield.mask(LLMRequest(systemPrompt: "", messages: [.system("Earlier: x"), .user("hi"), .system("later")],
                                                tools: [], model: "m"), detector: detector()).request
        XCTAssertEqual(inMessages.messages[0].content, "Earlier: x\n\n" + Shield.note)
        XCTAssertEqual(inMessages.messages[2].content, "later")
        let none = Shield.mask(LLMRequest(systemPrompt: "", messages: [.user("hi")], tools: [], model: "m"), detector: detector()).request
        XCTAssertEqual(none.systemPrompt, Shield.note)
    }

    func testAPlaceholderSplitOverSeveralDeltasIsPutBack() async throws {
        let model = EchoModel { _ in
            [.text("Mail ⟦EM"), .text("AIL_"), .text("1⟧ and ⟦"), .text("SECRET_1⟧ done ⟦"), .text("nope⟧ ⟦EMAIL_9⟧"),
             .done(calls: [], finish: "stop", usage: nil)]
        }
        let client = ShieldClient(inner: model, detector: detector())
        let key = "sk-" + String(repeating: "Ab3", count: 8)
        let result = try await run(client, LLMRequest(systemPrompt: "", messages: [.user("to ann@example.com with \(key)")], tools: [], model: "m"))
        XCTAssertEqual(result.text, "Mail ann@example.com and \(key) done ⟦nope⟧ ⟦EMAIL_9⟧", "an unknown placeholder stays as it is")
    }

    func testReasoningIsPutBackToo() async throws {
        let model = EchoModel { _ in
            [.reasoning("The user ⟦TER"), .reasoning("M_1⟧ wants…"), .text("ok"), .done(calls: [], finish: "stop", usage: nil)]
        }
        let client = ShieldClient(inner: model, detector: detector())
        let result = try await run(client, LLMRequest(systemPrompt: "", messages: [.user("I'm from Acme")], tools: [], model: "m"))
        XCTAssertEqual(result.reasoning, "The user Acme wants…")
    }

    func testToolCallArgumentsAreMaskedAndRestoredInsideTheirJSONStrings() async throws {
        let awkward = "ann \"the\" O'Neil\\path\nline 2 🚀 ünïcödé"
        let terms: ShieldSettings = { var s = ShieldSettings(); s.customTerms = [awkward]; return s }()
        let model = EchoModel { _ in
            [.done(calls: [ToolCall(id: "c1", name: "write_file",
                                    arguments: #"{"file_path":"notes.txt","content":"Dear ⟦TERM_1⟧,\nsee ⟦EMAIL_1⟧"}"#)],
                   finish: "tool_calls", usage: nil)]
        }
        let client = ShieldClient(inner: model, detector: SensitiveDetector(settings: terms))
        // An earlier call with the values in its arguments goes out masked, its keys untouched.
        let earlier = ToolCall(id: "c0", name: "run_shell_command",
                               arguments: try String(decoding: JSONSerialization.data(withJSONObject: ["command": "mail ann@example.com # \(awkward)"]), as: UTF8.self))
        let result = try await run(client, LLMRequest(systemPrompt: "", messages: [
            .user("Write to \(awkward) at ann@example.com"), .assistant("", calls: [earlier]),
            .toolResult(id: "c0", name: "run_shell_command", output: "sent to ann@example.com")], tools: [], model: "m"))
        let sent = model.requests[0]
        XCTAssertEqual(sent.messages[0].content, "Write to ⟦TERM_1⟧ at ⟦EMAIL_1⟧")
        let sentArgs = try JSONSerialization.jsonObject(with: Data(sent.messages[1].toolCalls![0].arguments.raw.utf8)) as! [String: String]
        XCTAssertEqual(sentArgs, ["command": "mail ⟦EMAIL_1⟧ # ⟦TERM_1⟧"])
        XCTAssertEqual(sent.messages[2].content, "sent to ⟦EMAIL_1⟧", "tool results too")
        // The new call comes back with the real values, correctly escaped.
        let raw = try XCTUnwrap(result.calls.first?.arguments.raw)
        let args = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: String]
        XCTAssertEqual(args["content"], "Dear \(awkward),\nsee ann@example.com")
        XCTAssertEqual(args["file_path"], "notes.txt")
    }

    func testArgumentsThatArentJSONAreMaskedAsText() {
        let call = ToolCall(id: "c1", name: "run_shell_command", arguments: "not json: ann@example.com")
        let out = Shield.mask(LLMRequest(systemPrompt: "", messages: [.assistant("", calls: [call])], tools: [], model: "m"),
                              detector: detector())
        XCTAssertEqual(out.request.messages[0].toolCalls?[0].arguments.raw, "not json: ⟦EMAIL_1⟧")
        XCTAssertEqual(Shield.restoreArguments("{\"a\":\"\\u27e6EMAIL_1\\u27e7\"}", out.map), "{\"a\":\"ann@example.com\"}",
                       "a placeholder written with JSON escapes is found too")
    }

    func testAttachedTextFilesAreMaskedAndImagesAreReported() async throws {
        let model = EchoModel { _ in [.text("ok"), .done(calls: [], finish: "stop", usage: nil)] }
        let reports = Reports()
        let client = ShieldClient(inner: model, detector: detector(), onReport: reports.add)
        let file = MessageAttachment(kind: .file, name: "notes.md", data: Data("call 415-555-2671".utf8))
        let image = MessageAttachment(kind: .image, name: "shot.png", data: Data([0x89, 0x50]))
        _ = try await run(client, LLMRequest(systemPrompt: "", messages: [.user("see", attachments: [file, image])], tools: [], model: "m"))
        let sent = try XCTUnwrap(model.requests.first?.messages.first?.attachments)
        XCTAssertEqual(String(decoding: sent[0].data, as: UTF8.self), "call ⟦PHONE_1⟧")
        XCTAssertEqual(sent[1].data, image.data, "pictures go as they are")
        XCTAssertEqual(reports.all.first?.unchecked, true)
        XCTAssertEqual(reports.all.first?.summary, "Masked 1 phone number before sending to Kimi Code")
    }

    func testTheSummaryCountsEachKind() {
        let report = ShieldReport(route: "Kimi Code", counts: [.email: 2, .secret: 1, .phone: 0])
        XCTAssertEqual(report.summary, "Masked 1 key and 2 emails before sending to Kimi Code")
        XCTAssertEqual(report.categories, "Secrets and keys, Email addresses")
        XCTAssertNil(ShieldReport(route: "x", counts: [:]).summary)
    }

    func testOnlyRoutesThatArentPrivateAreWrapped() {
        defer { ProviderClients.shield = nil }
        ProviderClients.shield = ShieldPolicy()
        let spark = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "https://192.168.1.42:11443/v1", model: "q")
        let kimi = ProviderProfile(kind: .openAICompat, name: "Kimi Code", baseURL: "https://api.kimi.ai/coding/v1", model: "k")
        XCTAssertTrue(ProviderClients.make(spark) is OpenAIClient, "a private route: no wrapping")
        XCTAssertTrue(ProviderClients.make(kimi) is ShieldClient)
        var trusted = kimi
        trusted.isPrivate = true
        XCTAssertTrue(ProviderClients.make(trusted) is OpenAIClient, "the user's choice wins")
        // Each backup gets its own shield.
        let failover = ProviderClients.make(spark, backups: [kimi]) as? FailoverClient
        XCTAssertTrue(failover?.primary is OpenAIClient)
        XCTAssertTrue(failover?.backups.first is ShieldClient)
        // The switch off and an empty vault: nothing to do.
        var off = ShieldSettings()
        off.enabled = false
        ProviderClients.shield = ShieldPolicy(settings: off)
        XCTAssertTrue(ProviderClients.make(kimi) is OpenAIClient)
    }

    func testSettingsFromAnotherBuildLoad() throws {
        let partial = try JSONDecoder().decode(ShieldSettings.self, from: Data(#"{"ips":true,"unknown":1}"#.utf8))
        XCTAssertTrue(partial.enabled)
        XCTAssertTrue(partial.ips)
        XCTAssertTrue(partial.customTerms.isEmpty)
    }
}
