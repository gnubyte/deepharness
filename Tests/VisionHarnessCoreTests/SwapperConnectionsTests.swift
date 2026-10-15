import XCTest
@testable import VisionHarnessCore

/// The list of Swapper boxes: moving an earlier build's single Spark into it, which routes a box serves, and what
/// `/swap` means with several boxes.
final class SwapperConnectionsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        SparkSwapperClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "dsh.swapper.test.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private let service = SwapperConnectionStore.keychainService

    // MARK: Moving the old setting over

    func testTheSingleSparkOfEarlierBuildsBecomesTheFirstConnection() throws {
        let store = defaults()
        let secrets = MemorySecretStore()
        let pin = String(repeating: "AB:", count: 31) + "AB"
        store.set("https://192.168.68.69:8999", forKey: "spark.swapper.url")
        store.set("pat", forKey: "spark.swapper.user")
        store.set(pin, forKey: "spark.swapper.pin")
        secrets.write("hunter2-pass", service: service, account: "login")

        let list = SwapperConnectionStore.load(defaults: store, secrets: secrets)
        let box = try XCTUnwrap(list.first)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(box.url, "https://192.168.68.69:8999")
        XCTAssertEqual(box.auth, .login(username: "pat"))
        XCTAssertEqual(box.pinnedFingerprint, pin)
        XCTAssertEqual(box.name, "DGX Spark (192.168.68.69)")
        XCTAssertNil(box.platform, "a Swapper before 2.0 doesn't say")
        XCTAssertEqual(SwapperConnectionStore.secret(for: box, secrets: secrets), "hunter2-pass", "the password moved with it")
        XCTAssertEqual(secrets.read(service: service, account: "login"), "hunter2-pass", "and the old one is still there")
        XCTAssertEqual(store.string(forKey: "spark.swapper.url"), "https://192.168.68.69:8999", "the old setting is left alone")

        // Saved: the next launch reads the list and doesn't migrate again.
        let again = SwapperConnectionStore.load(defaults: store, secrets: secrets)
        XCTAssertEqual(again, list)
    }

    func testAMovedOverPasswordIsFoundUnderTheOldAccountWhenCopyingItFailed() throws {
        let store = defaults()
        store.set("https://spark.local:8999", forKey: "spark.swapper.url")
        store.set("pat", forKey: "spark.swapper.user")
        // A Keychain that turns every write down (locked at first launch, say).
        let secrets = UnwritableSecrets(["\(service)/login": "hunter2-pass"])
        let box = try XCTUnwrap(SwapperConnectionStore.load(defaults: store, secrets: secrets).first)
        XCTAssertEqual(box.migrated, true)
        XCTAssertEqual(SwapperConnectionStore.secret(for: box, secrets: secrets), "hunter2-pass")
        // A box added later has no old account to fall back to.
        let other = SwapperConnection(name: "Strix Halo (evo-x2)", url: "https://evo.local:8999", auth: .token)
        XCTAssertEqual(SwapperConnectionStore.secret(for: other, secrets: secrets), "")
    }

    func testTheRoutesOnTheOldSwappersHostStayWithIt() throws {
        let store = defaults()
        store.set("https://Spark.local:8999", forKey: "spark.swapper.url")
        let direct = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local:8002/v1", model: "qwen")
        let elsewhere = ProviderProfile(kind: .openAICompat, name: "Ollama", baseURL: "http://127.0.0.1:11434/v1", model: "llama")
        let box = try XCTUnwrap(SwapperConnectionStore.load(defaults: store, secrets: MemorySecretStore(),
                                                            routes: [direct, elsewhere]).first)
        XCTAssertEqual(box.linkedRoutes, [direct.routeID])
        // Once the box reports its model API (an upgrade to 2.0), the old route is still its own.
        var upgraded = box
        upgraded.apiBase = "https://spark.local:11443/v1"
        XCTAssertTrue(upgraded.serves(direct))
        XCTAssertFalse(upgraded.serves(elsewhere))
    }

    func testOneUnreadableEntryCostsNothingElse() throws {
        let store = defaults()
        let good = SwapperConnection(name: "DGX Spark (a)", url: "https://a.local:8999", auth: .token)
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let damaged: [String: Any] = ["id": "x", "name": "half a box"]
        store.set(try JSONSerialization.data(withJSONObject: [goodJSON, damaged]), forKey: SwapperConnectionStore.listKey)

        let list = SwapperConnectionStore.load(defaults: store, secrets: MemorySecretStore())
        XCTAssertEqual(list, [good], "the readable box loads")
        let added = SwapperConnection(name: "Strix Halo (evo-x2)", url: "https://evo.local:8999", auth: .token)
        SwapperConnectionStore.save(list + [added], defaults: store)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.data(forKey: SwapperConnectionStore.listKey))) as? [[String: Any]])
        XCTAssertEqual(stored.count, 3, "the entry this build can't read is kept as it was")
        XCTAssertTrue(stored.contains { $0["name"] as? String == "half a box" })
        XCTAssertEqual(SwapperConnectionStore.load(defaults: store, secrets: MemorySecretStore()), [good, added])
    }

    func testAListThatIsntReadableIsCopiedAsideNotOverwritten() {
        let store = defaults()
        let garbage = Data("not json".utf8)
        store.set(garbage, forKey: SwapperConnectionStore.listKey)
        XCTAssertEqual(SwapperConnectionStore.load(defaults: store, secrets: MemorySecretStore()), [])
        let added = SwapperConnection(name: "DGX Spark (a)", url: "https://a.local:8999", auth: .token)
        SwapperConnectionStore.save([added], defaults: store)
        XCTAssertEqual(store.data(forKey: SwapperConnectionStore.listKey + ".unreadable"), garbage)
        XCTAssertEqual(SwapperConnectionStore.load(defaults: store, secrets: MemorySecretStore()), [added])
    }

    func testAnAddressWithoutALoginStillMovesOver() {
        let store = defaults()
        store.set("https://spark.local:8999", forKey: "spark.swapper.url")
        let list = SwapperConnectionStore.load(defaults: store, secrets: MemorySecretStore())
        XCTAssertEqual(list.map(\.url), ["https://spark.local:8999"])
        XCTAssertEqual(list.first?.auth, .login(username: ""))
    }

    func testNothingToMoveMeansAnEmptyListAndNothingSaved() {
        let store = defaults()
        XCTAssertTrue(SwapperConnectionStore.load(defaults: store, secrets: MemorySecretStore()).isEmpty)
        XCTAssertNil(store.data(forKey: SwapperConnectionStore.listKey))
    }

    func testTheListRoundTripsAndSecretsStayOutOfIt() throws {
        let store = defaults()
        let secrets = MemorySecretStore()
        let a = SwapperConnection(name: "DGX Spark (spark-3f2a)", url: "https://192.168.1.42:8999", platform: "nvidia-gb10",
                                  auth: .token, pinnedFingerprint: "AA", apiBase: "https://192.168.1.42:11443/v1",
                                  linkedRoutes: ["DGX Spark (spark-3f2a)|Qwen3.8-27B"])
        let b = SwapperConnection(name: "Strix Halo (evo-x2)", url: "https://10.0.0.9:8999", platform: "amd-strix-halo",
                                  auth: .login(username: "pat"))
        SwapperConnectionStore.save([a, b], defaults: store)
        SwapperConnectionStore.setSecret("sst_1a2b3c4d_secret", for: a, secrets: secrets)
        XCTAssertEqual(SwapperConnectionStore.load(defaults: store, secrets: secrets), [a, b])
        let saved = String(decoding: try XCTUnwrap(store.data(forKey: SwapperConnectionStore.listKey)), as: UTF8.self)
        XCTAssertFalse(saved.contains("sst_1a2b3c4d_secret"), "the token lives in the Keychain, not the settings")
        XCTAssertEqual(SwapperConnectionStore.secret(for: a, secrets: secrets), "sst_1a2b3c4d_secret")
    }

    // MARK: Which routes a box serves

    func testABoxServesTheRoutesAtItsModelAPI() {
        let box = SwapperConnection(name: "Spark", url: "https://192.168.1.42:8999", auth: .token,
                                    apiBase: "https://192.168.1.42:11443/v1")
        let route = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "https://192.168.1.42:11443/v1/", model: "x")
        let other = ProviderProfile(kind: .openAICompat, name: "Other", baseURL: "http://192.168.1.42:8002/v1", model: "x")
        XCTAssertTrue(box.serves(route), "the same address, whatever the trailing slash")
        XCTAssertFalse(box.serves(other), "another port on the same host is another server")
        var linked = box
        linked.linkedRoutes = [other.routeID]
        XCTAssertTrue(linked.serves(other), "a route made for the box")
    }

    func testABoxFromBeforeSwapper2ServesTheRoutesOnItsHost() {
        let box = SwapperConnection(name: "DGX Spark (spark.local)", url: "https://spark.local:8999", auth: .login(username: "pat"))
        XCTAssertTrue(box.serves(ProviderProfile(kind: .openAICompat, name: "S", baseURL: "http://SPARK.local:8002/v1", model: "m")))
        XCTAssertFalse(box.serves(ProviderProfile(kind: .openAICompat, name: "T", baseURL: "http://other.local:8002/v1", model: "m")))
        XCTAssertFalse(box.serves(ProviderProfile(kind: .bedrock, name: "B", baseURL: "https://spark.local", model: "m")))
    }

    // MARK: /swap

    private let spark = SwapperConnection(id: "spark", name: "DGX Spark (spark-3f2a)", url: "https://192.168.1.42:8999",
                                          hostname: "spark-3f2a", auth: .token)
    private let strix = SwapperConnection(id: "strix", name: "Strix Halo (evo-x2)", url: "https://10.0.0.9:8999",
                                          hostname: "evo-x2", auth: .token)

    func testSwapWithoutAModelListsEveryBox() {
        XCTAssertEqual(SwapCommand.parse(nil, boxes: [spark, strix], primaryBox: nil), .list)
        XCTAssertEqual(SwapCommand.parse("  ", boxes: [spark], primaryBox: nil), .list)
        XCTAssertEqual(SwapCommand.parse("flash", boxes: [], primaryBox: nil), .noBoxes)
    }

    func testAModelAloneGoesToTheBoxBehindTheMainModelElseTheOnlyBox() {
        XCTAssertEqual(SwapCommand.parse("flash", boxes: [spark, strix], primaryBox: "strix"),
                       .switchModel(box: "strix", model: "flash"))
        XCTAssertEqual(SwapCommand.parse("flash", boxes: [spark], primaryBox: nil), .switchModel(box: "spark", model: "flash"))
        XCTAssertEqual(SwapCommand.parse("flash", boxes: [spark, strix], primaryBox: nil), .whichBox(model: "flash"))
        XCTAssertEqual(SwapCommand.parse("qwen 27b", boxes: [spark, strix], primaryBox: "spark"),
                       .switchModel(box: "spark", model: "qwen 27b"), "a model name with a space is still a model")
    }

    func testABoxIsNamedByTheStartOfItsName() {
        XCTAssertEqual(SwapCommand.parse("strix qwen3.8", boxes: [spark, strix], primaryBox: "spark"),
                       .switchModel(box: "strix", model: "qwen3.8"))
        XCTAssertEqual(SwapCommand.parse("DGX flash", boxes: [spark, strix], primaryBox: "strix"),
                       .switchModel(box: "spark", model: "flash"))
        XCTAssertEqual(SwapCommand.parse("evo flash", boxes: [spark, strix], primaryBox: "spark"),
                       .switchModel(box: "strix", model: "flash"), "or of its host name")
        // Two boxes both called "DGX Spark …": the longer start picks one out.
        let second = SwapperConnection(id: "spark2", name: "DGX Spark (spark-9c1d)", url: "https://192.168.1.43:8999", auth: .token)
        XCTAssertEqual(SwapCommand.parse("dgx spark (spark-9c1d) flash", boxes: [spark, second], primaryBox: nil),
                       .switchModel(box: "spark2", model: "flash"))
        XCTAssertEqual(SwapCommand.parse("dgx flash", boxes: [spark, second], primaryBox: nil), .whichBox(model: "dgx flash"))
    }

    // MARK: Signing in with an address and login

    private func stub(_ handler: @escaping @Sendable (URLRequest) -> StubServer.Reply) {
        SparkSwapperClient.protocolClassesForTesting = [StubServer.self]
        StubServer.reset(handler)
    }

    func testSigningInOnSwapper2ReadsTheBoxAndKeepingItMakesAnAppToken() async throws {
        let paths = PathLog()
        stub { request in
            paths.add(request.url?.path ?? "")
            switch request.url?.path ?? "" {
            case "/api/login": return .init(body: #"{"ok":true}"#, contentType: "application/json")
            case "/api/connect":
                return .init(body: #"{"name":"DGX Spark (spark-3f2a)","hostname":"spark-3f2a","platform":"nvidia-gb10","version":"2.0.0","swapper_url":"https://192.168.1.42:8999","api_base":"https://192.168.1.42:11443/v1","api_key":"vllm-local","model":"Qwen3.8-27B","context":262144,"fingerprint":"aa:bb"}"#,
                             contentType: "application/json")
            case "/api/tokens/create":
                return .init(status: 201, body: #"{"id":"1a2b3c4d","token":"sst_1a2b3c4d_tok","code":"SSC1:x"}"#, contentType: "application/json")
            default: return .init(status: 404, body: "{}", contentType: "application/json")
            }
        }
        let outcome = try await SwapperConnect.login(address: "192.168.1.42", username: "pat", password: "pw", pinned: nil)
        guard case .connected(let connection, let secret, let info, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(secret, "pw", "signed in, nothing kept yet")
        XCTAssertEqual(connection.auth, .login(username: "pat"))
        XCTAssertEqual(connection.url, "https://192.168.1.42:8999")
        XCTAssertEqual(connection.name, "DGX Spark (spark-3f2a)")
        XCTAssertEqual(connection.apiBase, "https://192.168.1.42:11443/v1")
        XCTAssertEqual(info?.apiKey, "vllm-local")
        XCTAssertFalse(paths.all.contains("/api/tokens/create"), "no token on the box until the connection is kept")

        let kept = try await SwapperConnect.keep(connection, password: secret,
                                                 label: SwapperConnect.tokenLabel(computerName: "Pat's MacBook"))
        XCTAssertEqual(kept.secret, "sst_1a2b3c4d_tok")
        XCTAssertEqual(kept.connection.auth, .token)
        XCTAssertEqual(kept.connection.id, connection.id)
        XCTAssertEqual(paths.all.filter { $0 == "/api/tokens/create" }.count, 1)
    }

    func testAnOlderSwapperKeepsThePasswordAndAsksForTheModelAPI() async throws {
        stub { request in
            switch request.url?.path ?? "" {
            case "/api/login": return .init(body: #"{"ok":true}"#, contentType: "application/json")
            case "/api/credentials":
                return .init(body: #"{"api":{"key":"vllm-local","base_url":"https://spark.local:11443/v1","model":"qwen"}}"#,
                             contentType: "application/json")
            case "/api/session": return .init(body: #"{"setup_needed":false,"user":"pat"}"#, contentType: "application/json")
            default: return .init(status: 404, body: #"{"error":"not found"}"#, contentType: "application/json")
            }
        }
        let outcome = try await SwapperConnect.login(address: "spark.local", username: "pat", password: "pw", pinned: nil)
        guard case .connected(let connection, let secret, let info, let credentials) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(secret, "pw")
        XCTAssertEqual(connection.auth, .login(username: "pat"))
        XCTAssertEqual(connection.apiBase, "https://spark.local:11443/v1")
        XCTAssertNil(info)
        XCTAssertEqual(credentials?.apiKey, "vllm-local")
        XCTAssertEqual(connection.name, "DGX Spark (spark.local)")
        let kept = try await SwapperConnect.keep(connection, password: secret, label: "DSH on Test")
        XCTAssertEqual(kept.secret, "pw", "no tokens before 2.0: the password, as before")
        XCTAssertEqual(kept.connection.auth, .login(username: "pat"))
    }

    func testTheTokensLabelNamesThisMac() {
        XCTAssertEqual(SwapperConnect.tokenLabel(computerName: "Pat's MacBook"), "DSH on Pat's MacBook")
        XCTAssertEqual(SwapperConnect.tokenLabel(computerName: nil), "DSH on this Mac")
    }
}

/// The paths a stub was asked for.
private final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.withLock { paths.append(path) } }
    var all: [String] { lock.withLock { paths } }
}

/// A secret store that refuses every write.
private final class UnwritableSecrets: SecretStore, @unchecked Sendable {
    private let values: [String: String]
    init(_ values: [String: String]) { self.values = values }
    func read(service: String, account: String) -> String? { values["\(service)/\(account)"] }
    func write(_ value: String?, service: String, account: String) {}
}

