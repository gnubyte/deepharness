import XCTest
@testable import DSHCore

/// Records the arguments it was called with and echoes them back.
struct RecordingTool: ToolExecutor {
    static let name = "record"
    static let spec = ToolSpec(name: name, description: "records",
                               parameters: #"{"type":"object","properties":{"text":{"type":"string"}}}"#)
    let seen: SeenArgs
    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        seen.append(args.raw)
        return ToolResult(output: "ran with: \(Self.string(args, "text") ?? "")")
    }
}

final class SeenArgs: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ s: String) { lock.withLock { list.append(s) } }
    var all: [String] { lock.withLock { list } }
}

final class CredentialVaultTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func vault(_ store: MemoryBlobStore = MemoryBlobStore()) -> CredentialVault {
        CredentialVault(directory: dir, store: store)
    }

    // MARK: Store

    func testAddSearchUpdateDelete() throws {
        let v = vault()
        let openai = try v.add(name: "OPENAI_API_KEY", value: "sk-live-123456", description: "OpenAI production",
                               tags: ["AI", "openai", "ai"], url: "https://api.openai.com")
        _ = try v.add(name: "STRIPE_TEST", value: "sk_test_abcdef", kind: .token, description: "Stripe sandbox", tags: ["payments"])
        XCTAssertEqual(openai.tags, ["ai", "openai"])
        XCTAssertTrue(openai.fingerprint.hasPrefix("sha256:"))
        XCTAssertEqual(openai.fingerprint.count, "sha256:".count + 12)
        XCTAssertEqual(v.search("openai").map(\.name), ["OPENAI_API_KEY"])
        XCTAssertEqual(v.search("stripe sandbox").map(\.name), ["STRIPE_TEST"])
        XCTAssertEqual(v.search("").count, 2)
        XCTAssertEqual(v.search(openai.fingerprint).map(\.name), ["OPENAI_API_KEY"])
        XCTAssertEqual(try v.value(for: openai.id), "sk-live-123456")

        var edited = openai
        edited.description = "OpenAI (rotated)"
        try v.update(edited, value: "sk-live-999999")
        XCTAssertEqual(try v.value(for: openai.id), "sk-live-999999")
        XCTAssertNotEqual(v.entry(named: "openai_api_key")?.fingerprint, openai.fingerprint)
        try v.update(v.entry(named: "OPENAI_API_KEY")!)   // no value → unchanged
        XCTAssertEqual(try v.value(for: openai.id), "sk-live-999999")

        try v.delete(id: openai.id)
        XCTAssertNil(v.entry(named: "OPENAI_API_KEY"))
        XCTAssertNil(try v.value(for: openai.id))
    }

    func testNamesAreValidatedAndUnique() throws {
        let v = vault()
        XCTAssertThrowsError(try v.add(name: "has space", value: "x")) { XCTAssertEqual($0 as? VaultError, .invalidName("has space")) }
        XCTAssertThrowsError(try v.add(name: "OK", value: "")) { XCTAssertEqual($0 as? VaultError, .emptyValue) }
        _ = try v.add(name: "DB_PASSWORD", value: "hunter22")
        XCTAssertThrowsError(try v.add(name: "db_password", value: "other")) { XCTAssertEqual($0 as? VaultError, .duplicateName("db_password")) }
    }

    func testValuesNeverTouchTheMetadataFile() throws {
        let store = MemoryBlobStore()
        let v = vault(store)
        _ = try v.add(name: "GH_TOKEN", value: "ghp_supersecretvalue", description: "GitHub")
        let file = try String(contentsOf: dir.appendingPathComponent("vault.json"), encoding: .utf8)
        XCTAssertTrue(file.contains("GH_TOKEN"))
        XCTAssertFalse(file.contains("ghp_supersecretvalue"))
        // A new vault over the same folder + store sees both again.
        let reopened = vault(store)
        XCTAssertEqual(reopened.lookup("gh_token"), .value("ghp_supersecretvalue", access: .allowed))
    }

    // MARK: Placeholders

    func testPlaceholderSubstitutionKeepsJSONValid() throws {
        XCTAssertEqual(VaultPlaceholders.names(in: #"{"command":"curl -H 'k: {{vault:A}}' {{ vault:B }} {{vault:A}}"}"#), ["A", "B"])
        let tricky = "p\"a\\ss\nword/"
        let raw = #"{"text":"secret={{vault:PW}}"}"#
        let out = VaultPlaceholders.substitute(in: raw, values: ["PW": tricky])
        let decoded = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["text"], "secret=" + tricky)
        XCTAssertEqual(VaultPlaceholders.redact("key is sk-123456 and sk-123456", values: [("K", "sk-123456")]),
                       "key is [vault:K] and [vault:K]")
    }

    // MARK: Engine

    private func engine(_ vault: CredentialVault, seen: SeenArgs, calls: [ToolCall],
                        gate: @escaping @Sendable (String, String, String) async -> Bool = { _, _, _ in true },
                        grants: VaultGrants = VaultGrants()) -> (Engine, ScriptedClient) {
        let client = ScriptedClient(turns: calls.map { ScriptedClient.Turn(calls: [$0]) } + [.init(text: "done")])
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let e = Engine(client: client, registry: ToolRegistry(tools: [RecordingTool(seen: seen)]), systemPrompt: "s",
                       config: .init(maxIterations: 8, model: "m"), workspace: root,
                       policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root), permissionGate: gate,
                       vault: vault, vaultGrants: grants)
        return (e, client)
    }

    func testToolGetsTheValueAndTheModelNeverSeesIt() async throws {
        let v = vault()
        _ = try v.add(name: "API_KEY", value: "sk-live-abcdef123")
        let seen = SeenArgs()
        let (e, client) = engine(v, seen: seen, calls: [ToolCall(id: "1", name: "record", arguments: #"{"text":"{{vault:API_KEY}}"}"#)])
        let outputs = SeenArgs()
        let result = try await e.run(messages: [], userText: "go") { event in
            if case .toolFinished(_, _, _, _, let output) = event { outputs.append(output) }
        }
        XCTAssertEqual(seen.all.count, 1)
        XCTAssertTrue(seen.all[0].contains("sk-live-abcdef123"), "the tool got the real value")
        XCTAssertEqual(outputs.all, ["ran with: [vault:API_KEY]"], "the UI and log see the placeholder")
        let everything = result.messages.compactMap(\.content).joined() + client.requests.flatMap(\.messages).compactMap(\.content).joined()
        XCTAssertFalse(everything.contains("sk-live-abcdef123"), "the model never sees the value")
        XCTAssertEqual(v.entry(named: "API_KEY")?.useCount, 1)
    }

    func testSecretsInToolOutputAreScrubbedEvenWithoutAPlaceholder() async throws {
        // e.g. the agent cats a .env file that holds a vault value.
        let v = vault()
        _ = try v.add(name: "DB_PASSWORD", value: "correct-horse-battery")
        let seen = SeenArgs()
        let (e, _) = engine(v, seen: seen, calls: [ToolCall(id: "1", name: "record", arguments: #"{"text":"DB=correct-horse-battery"}"#)])
        let result = try await e.run(messages: [], userText: "go", sink: { _ in })
        XCTAssertTrue(result.messages.contains { $0.content == "ran with: DB=[vault:DB_PASSWORD]" })
    }

    func testAccessRules() async throws {
        let v = vault()
        _ = try v.add(name: "NEVER", value: "never-value", access: .never)
        _ = try v.add(name: "ASK", value: "ask-value", access: .ask)
        let seen = SeenArgs()

        // Unknown and withheld credentials refuse the call; the tool never runs.
        let (e1, _) = engine(v, seen: seen, calls: [
            ToolCall(id: "1", name: "record", arguments: #"{"text":"{{vault:MISSING}}"}"#),
            ToolCall(id: "2", name: "record", arguments: #"{"text":"{{vault:NEVER}}"}"#),
        ])
        let r1 = try await e1.run(messages: [], userText: "go", sink: { _ in })
        XCTAssertTrue(seen.all.isEmpty)
        XCTAssertTrue(r1.messages.contains { $0.content?.contains("no credential named MISSING") == true })
        XCTAssertTrue(r1.messages.contains { $0.content?.contains("unavailable to the agent") == true })

        // "Ask first" asks once per chat.
        let asked = Counter()
        let grants = VaultGrants()
        let call = ToolCall(id: "3", name: "record", arguments: #"{"text":"{{vault:ASK}}"}"#)
        let (e2, _) = engine(v, seen: seen, calls: [call, call], gate: { _, _, detail in
            XCTAssertTrue(detail.contains("ASK"))
            _ = asked.next()
            return true
        }, grants: grants)
        _ = try await e2.run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(asked.value, 1)
        XCTAssertEqual(seen.all.count, 2)

        // Declined: refused, not run.
        let (e3, _) = engine(v, seen: seen, calls: [call], gate: { _, _, _ in false })
        let r3 = try await e3.run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(seen.all.count, 2)
        XCTAssertTrue(r3.messages.contains { $0.content?.hasPrefix("Permission denied") == true })
    }

    func testSearchToolListsPlaceholdersNotValues() async throws {
        let v = vault()
        _ = try v.add(name: "OPENAI_API_KEY", value: "sk-verysecret", description: "OpenAI", tags: ["ai"])
        _ = try v.add(name: "ROOT_PW", value: "pw-verysecret", kind: .password, access: .never)
        let ctx = ToolContext(workspace: dir, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: dir),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let all = await VaultSearchTool(vault: v).execute(args: "{}", in: ctx).output
        XCTAssertTrue(all.contains("{{vault:OPENAI_API_KEY}}"))
        XCTAssertTrue(all.contains("NOT available to the agent"))
        XCTAssertFalse(all.contains("verysecret"))
        let none = await VaultSearchTool(vault: v).execute(args: #"{"query":"stripe"}"#, in: ctx).output
        XCTAssertTrue(none.contains("No credential matches"))
        let blank = CredentialVault(directory: dir.appendingPathComponent("other"), store: MemoryBlobStore())
        let empty = await VaultSearchTool(vault: blank).execute(args: "{}", in: ctx).output
        XCTAssertTrue(empty.contains("vault is empty"))
    }
}
