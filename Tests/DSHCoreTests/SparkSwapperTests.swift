import XCTest
@testable import DSHCore

/// Swapper 2.0 from the app's side: connection codes, app tokens, the new status fields — and a 1.x Swapper
/// still working.
final class SparkSwapperTests: XCTestCase {
    private let fingerprint = (1...32).map { String(format: "%02X", $0 * 7 % 256) }.joined(separator: ":")

    override func tearDown() {
        SparkSwapperClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        super.tearDown()
    }

    private func fields(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var out: [String: Any] = [
            "v": 1, "name": "DGX Spark (spark-3f2a)", "hostname": "spark-3f2a", "platform": "nvidia-gb10",
            "version": "2.0.0", "swapper_url": "https://192.168.1.42:8999",
            "api_base": "https://192.168.1.42:11443/v1", "api_key": "vllm-local",
            "model": "Qwen3.8-27B", "context": 262144, "fingerprint": fingerprint,
            "token": "sst_1a2b3c4d_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ", "user": "pat",
        ]
        for (key, value) in changes { out[key] = value }
        return out
    }

    // MARK: Connection codes

    func testAConnectionCodeDecodes() throws {
        let code = try SwapperConnectionCode.decode(SwapperConnectionCode.encode(fields()))
        XCTAssertEqual(code.name, "DGX Spark (spark-3f2a)")
        XCTAssertEqual(code.hostname, "spark-3f2a")
        XCTAssertEqual(code.platform, "nvidia-gb10")
        XCTAssertEqual(code.version, "2.0.0")
        XCTAssertEqual(code.swapperURL.absoluteString, "https://192.168.1.42:8999")
        XCTAssertEqual(code.apiBase.absoluteString, "https://192.168.1.42:11443/v1")
        XCTAssertEqual(code.apiKey, "vllm-local")
        XCTAssertEqual(code.model, "Qwen3.8-27B")
        XCTAssertEqual(code.context, 262144)
        XCTAssertEqual(code.fingerprint, fingerprint)
        XCTAssertEqual(code.token, "sst_1a2b3c4d_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ")
        XCTAssertEqual(code.user, "pat")
        XCTAssertEqual(code.connectInfo.displayName, "DGX Spark (spark-3f2a)")
    }

    /// A code made by Spark Swapper 2.0's own encoder (swapper/tokens.py `connection_code`), so the two sides can't
    /// drift apart unnoticed.
    func testACodeFromSparkSwapperItselfDecodes() throws {
        let code = try SwapperConnectionCode.decode("SSC1:eyJ2IjoxLCJuYW1lIjoiREdYIFNwYXJrIChzcGFyay0zZjJhKSIsImhvc3RuYW1lIjoic3BhcmstM2YyYSIsInBsYXRmb3JtIjoibnZpZGlhLWdiMTAiLCJ2ZXJzaW9uIjoiMi4wLjAiLCJzd2FwcGVyX3VybCI6Imh0dHBzOi8vMTkyLjE2OC4xLjQyOjg5OTkiLCJhcGlfYmFzZSI6Imh0dHBzOi8vMTkyLjE2OC4xLjQyOjExNDQzL3YxIiwiYXBpX2tleSI6InNrLXNwYXJrLTAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1NjciLCJtb2RlbCI6IlF3ZW4zLjgtMjdCIiwiY29udGV4dCI6MjYyMTQ0LCJmaW5nZXJwcmludCI6IjNBOjlGOkMyOjAwOjExOjIyOjMzOjQ0OjU1OjY2Ojc3Ojg4Ojk5OkFBOkJCOkNDOkREOkVFOkZGOjAxOjIzOjQ1OjY3Ojg5OkFCOkNEOkVGOjEwOjMyOjU0Ojc2Ojk4IiwidG9rZW4iOiJzc3RfMWEyYjNjNGRfWm05dlltRnlMV0poZWkxeGRYVjRMVEF4TWpNME5UWTNPRGt0WVdKalpHVm0tX3giLCJ1c2VyIjoicGF0In0")
        XCTAssertEqual(code.name, "DGX Spark (spark-3f2a)")
        XCTAssertEqual(code.platform, "nvidia-gb10")
        XCTAssertEqual(code.swapperURL.absoluteString, "https://192.168.1.42:8999")
        XCTAssertEqual(code.apiBase.absoluteString, "https://192.168.1.42:11443/v1")
        XCTAssertEqual(code.apiKey, "sk-spark-0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(code.model, "Qwen3.8-27B")
        XCTAssertEqual(code.context, 262144)
        XCTAssertEqual(code.fingerprint, "3A:9F:C2:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:01:23:45:67:89:AB:CD:EF:10:32:54:76:98")
        XCTAssertEqual(code.token, "sst_1a2b3c4d_Zm9vYmFyLWJhei1xdXV4LTAxMjM0NTY3ODktYWJjZGVm-_x")
        XCTAssertEqual(code.user, "pat")
    }

    func testTheWayItWasPastedDoesNotMatter() throws {
        let encoded = SwapperConnectionCode.encode(fields())
        let body = String(encoded.dropFirst(SwapperConnectionCode.prefix.count))
        // Broken over lines and indented, as a chat or a terminal leaves it.
        var wrapped = "  \n"
        for (i, ch) in encoded.enumerated() {
            wrapped.append(ch)
            if i % 37 == 36 { wrapped += "\n   " }
        }
        // Standard base64 with padding.
        let json = try JSONSerialization.data(withJSONObject: fields(), options: [.sortedKeys])
        let standard = json.base64EncodedString()
        let variants = [encoded, "ssc1:" + body, "Ssc1:" + body, body, wrapped + "\n\n", "SSC1:" + standard, standard,
                        String(decoding: json, as: UTF8.self), "  \(String(decoding: json, as: UTF8.self))\n"]
        for variant in variants {
            XCTAssertEqual(try SwapperConnectionCode.decode(variant).token, fields()["token"] as? String, variant)
        }
    }

    func testUnknownKeysAreIgnoredAndOptionalOnesMayBeMissing() throws {
        var bare = fields(["future_field": ["x": 1], "model": nil, "context": nil, "api_key": nil, "user": nil,
                           "name": nil, "v": nil])
        bare["model"] = NSNull()
        let code = try SwapperConnectionCode.decode(SwapperConnectionCode.encode(bare))
        XCTAssertNil(code.model)
        XCTAssertNil(code.context)
        XCTAssertNil(code.apiKey)
        XCTAssertEqual(code.name, "DGX Spark (spark-3f2a)", "a name made from the platform and host")
        let strix = try SwapperConnectionCode.decode(SwapperConnectionCode.encode(
            fields(["name": nil, "platform": "amd-strix-halo", "hostname": "evo-x2"])))
        XCTAssertEqual(strix.name, "Strix Halo (evo-x2)")
    }

    func testWhatIsNotACodeSaysSoInPlainWords() {
        let bad: [String] = [
            "", "   ", "hello there", "SSC1:", "SSC1:!!!!", "{}", "[1,2,3]",
            SwapperConnectionCode.encode(fields(["swapper_url": nil])),
            SwapperConnectionCode.encode(fields(["api_base": nil])),
            SwapperConnectionCode.encode(fields(["fingerprint": nil])),
            SwapperConnectionCode.encode(fields(["token": nil])),
            SwapperConnectionCode.encode(fields(["token": "  "])),
            SwapperConnectionCode.encode(fields(["v": 2])),
            SwapperConnectionCode.encode(fields(["v": true])),
            SwapperConnectionCode.encode(fields(["v": "1"])),
            SwapperConnectionCode.encode(fields(["swapper_url": "http://192.168.1.42:8999"])),
            SwapperConnectionCode.encode(fields(["api_base": "http://192.168.1.42:11443/v1"])),
            SwapperConnectionCode.encode(fields(["fingerprint": "3A:9F:C2"])),
            SwapperConnectionCode.encode(fields(["fingerprint": String(repeating: "ZZ:", count: 31) + "ZZ"])),
        ]
        for text in bad {
            XCTAssertThrowsError(try SwapperConnectionCode.decode(text), text) { error in
                XCTAssertEqual(error.localizedDescription,
                               "That doesn't look like a Spark Swapper connection code. Copy it again from the Swapper's Connect tab.")
            }
        }
    }

    func testAFingerprintInLowerCaseOrWithoutColonsIsAccepted() throws {
        let plain = fingerprint.replacingOccurrences(of: ":", with: "").lowercased()
        XCTAssertEqual(try SwapperConnectionCode.decode(SwapperConnectionCode.encode(fields(["fingerprint": plain]))).fingerprint,
                       fingerprint)
    }

    // MARK: Status

    func testAnOlderSwappersStatusStillDecodes() throws {
        let json = #"""
        {"active":"standard","loading":null,"busy":false,"openclaw_primary":"vllm/qwen",
         "models":{"standard":{"key":"standard","title":"Qwen3.8 27B","context":1000000,"served_id":"qwen3.8-27b",
                               "running":true,"healthy":true,"order":1},
                   "flash":{"key":"flash","title":"Qwen3.8 Flash","context":524288,"served_id":"flash",
                            "running":false,"healthy":false,"order":2}}}
        """#
        let status = try JSONDecoder().decode(SwapperStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.version)
        XCTAssertNil(status.platform)
        XCTAssertEqual(status.installedModels.map(\.key), ["standard", "flash"], "a missing `installed` means installed")
        XCTAssertNil(status.models["standard"]?.speedText(roomForEstimate: true))
        XCTAssertEqual(SwapperPlatform.displayName(status.platform), "DGX Spark")
    }

    func testTheNewStatusFieldsDecode() throws {
        let json = #"""
        {"version":"2.0.0","platform":"amd-strix-halo","hostname":"evo-x2","active":"a","busy":false,
         "models":{
          "a":{"key":"a","title":"A","context":262144,"served_id":"a","running":true,"healthy":true,"installed":true,
               "platform":"amd-strix-halo","family":"qwen3.8-27b","vision":true,
               "perf":{"decode":58.3,"decode_concurrent":220.6,"concurrency":8,"prefill":1793.0,"source":"sparkDash (MiaAI-Lab)","estimate":false},
               "measured":{"decode":27.1,"at":1791234567.0}},
          "b":{"key":"b","title":"B","context":131072,"served_id":"b","running":false,"healthy":false,"installed":false,
               "perf":{"decode":58.4,"estimate":false},"measured":null},
          "c":{"key":"c","title":"C","context":131072,"served_id":"c","running":false,"healthy":false,
               "perf":{"decode":42.0,"estimate":true}}}}
        """#
        let status = try JSONDecoder().decode(SwapperStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.version, "2.0.0")
        XCTAssertEqual(status.hostname, "evo-x2")
        XCTAssertEqual(SwapperPlatform.displayName(status.platform), "Strix Halo")
        XCTAssertEqual(status.installedModels.map(\.key), ["a", "c"])
        XCTAssertEqual(status.models["a"]?.family, "qwen3.8-27b")
        XCTAssertEqual(status.models["a"]?.perf?.concurrency, 8)
        XCTAssertEqual(status.models["a"]?.speedText(), "27 tok/s measured here", "measured here beats published")
        XCTAssertEqual(status.models["b"]?.speedText(), "~58 tok/s")
        XCTAssertNil(status.models["c"]?.speedText(), "an estimate only where there is room")
        XCTAssertEqual(status.models["c"]?.speedText(roomForEstimate: true), "≈42 tok/s (estimate)")
    }

    // MARK: The client

    private func stub(_ handler: @escaping @Sendable (URLRequest) -> StubServer.Reply) {
        SparkSwapperClient.protocolClassesForTesting = [StubServer.self]
        StubServer.reset(handler)
    }

    private static func json(_ text: String, status: Int = 200) -> StubServer.Reply {
        .init(status: status, body: text, contentType: "application/json")
    }

    func testATokenIsSentOnEveryRequestAndThereIsNoLogin() async throws {
        let headers = SeenHeaders()
        stub { request in
            headers.add(request)
            switch request.url?.path ?? "" {
            case "/api/status": return Self.json(#"{"busy":false,"models":{}}"#)
            case "/api/connect":
                return Self.json(#"{"name":"DGX Spark (spark-3f2a)","swapper_url":"https://192.168.1.42:8999","api_base":"https://192.168.1.42:11443/v1","api_key":"vllm-local","model":null,"context":null,"fingerprint":"AA"}"#)
            default: return Self.json(#"{"ok":true}"#)
            }
        }
        let client = SparkSwapperClient(baseURL: URL(string: "https://192.168.1.42:8999")!, auth: .token("sst_x"),
                                        pinnedFingerprint: fingerprint)
        _ = try await client.status()
        let info = try await client.connectInfo()
        try await client.swap(to: "flash")
        XCTAssertNil(info.model)
        XCTAssertEqual(info.apiBase, "https://192.168.1.42:11443/v1")
        XCTAssertFalse(StubServer.paths.contains("/api/login"), "a token never logs in")
        for seen in headers.all {
            XCTAssertEqual(seen["Authorization"], "Bearer sst_x")
            XCTAssertEqual(seen["X-Swapper"], "1")
        }
        let post = try XCTUnwrap(headers.all.first { $0["path"] == "/api/swap" })
        XCTAssertEqual(post["Origin"], "https://192.168.1.42:8999")
    }

    func testARevokedTokenSaysToPasteANewCode() async {
        stub { _ in Self.json(#"{"error":"bad token"}"#, status: 401) }
        let client = SparkSwapperClient(baseURL: URL(string: "https://spark:8999")!, auth: .token("sst_gone"), pinnedFingerprint: nil)
        do {
            _ = try await client.status()
            XCTFail("a revoked token must not pass")
        } catch {
            XCTAssertEqual(error as? SwapperError, .revoked)
            XCTAssertEqual(error.localizedDescription,
                           "The Swapper no longer accepts this app's connection (it was revoked or the Swapper was reset). Paste a new connection code.")
        }
    }

    func testAUsernameAndPasswordStillWork() async throws {
        stub { request in
            switch request.url?.path ?? "" {
            case "/api/login": return Self.json(#"{"ok":true}"#)
            case "/api/status": return Self.json(#"{"busy":false,"active":"a","models":{}}"#)
            case "/api/credentials": return Self.json(#"{"api":{"key":"vllm-local","base_url":"https://spark:11443/v1","model":"qwen"},"openclaw":{}}"#)
            default: return Self.json(#"{"error":"not found"}"#, status: 404)
            }
        }
        let client = SparkSwapperClient(baseURL: URL(string: "https://spark:8999")!, username: "pat", password: "pw",
                                        pinnedFingerprint: nil)
        let status = try await client.status()
        XCTAssertEqual(status.active, "a")
        XCTAssertEqual(StubServer.paths.first, "/api/login")
        let credentials = try await client.credentials()
        XCTAssertEqual(credentials.apiKey, "vllm-local")
        XCTAssertEqual(credentials.apiBase, "https://spark:11443/v1")
        // A Swapper older than 2.0 has no app tokens.
        do {
            _ = try await client.createToken(label: "DSH on Test Mac")
            XCTFail("an older Swapper has no tokens")
        } catch {
            XCTAssertEqual(error as? SwapperError, .unsupported("version 2.0"))
        }
    }

    func testCreatingATokenReturnsItsCodeAndConnectDetails() async throws {
        stub { request in
            switch request.url?.path ?? "" {
            case "/api/login": return Self.json(#"{"ok":true}"#)
            case "/api/tokens/create":
                return Self.json(#"{"id":"1a2b3c4d","token":"sst_1a2b3c4d_xyz","code":"SSC1:abc","connect":{"name":"Strix Halo (evo-x2)","platform":"amd-strix-halo","swapper_url":"https://10.0.0.9:8999","api_base":"https://10.0.0.9:11443/v1","api_key":"k","model":"m","context":131072,"fingerprint":"AA"}}"#)
            default: return Self.json("{}", status: 404)
            }
        }
        let client = SparkSwapperClient(baseURL: URL(string: "https://10.0.0.9:8999")!, username: "pat", password: "pw",
                                        pinnedFingerprint: nil)
        let grant = try await client.createToken(label: "DSH on Test Mac")
        XCTAssertEqual(grant.token, "sst_1a2b3c4d_xyz")
        XCTAssertEqual(grant.connect?.displayName, "Strix Halo (evo-x2)")
        XCTAssertEqual(grant.connect?.context, 131072)
    }

    func testInstallingAModelAndFollowingIt() async throws {
        stub { request in
            switch request.url?.path ?? "" {
            case "/api/models/install":
                return Self.json(#"{"ok":true,"job":{"id":"i1","target":"install:model:flash","source":null,"state":"running","error":null,"note":null,"started":1.0,"finished":null,"steps":[{"key":"requires","label":"Checking what it needs","state":"running","started":1.0,"finished":null,"detail":""}],"log_total":1,"log":[{"t":1.0,"m":"checking docker"}]}}"#,
                                 status: 202)
            case "/api/provisioning/job":
                return Self.json(#"{"job":{"id":"i1","target":"install:model:flash","state":"done","started":1.0,"finished":9.0,"steps":[],"log":[]}}"#)
            default: return Self.json("{}", status: 404)
            }
        }
        let client = SparkSwapperClient(baseURL: URL(string: "https://spark:8999")!, auth: .token("sst_x"), pinnedFingerprint: nil)
        let started = try await client.installModel("flash")
        let job = try XCTUnwrap(started)
        XCTAssertTrue(job.isRunning)
        XCTAssertEqual(job.installingModel, "flash")
        XCTAssertEqual(job.currentStep?.label, "Checking what it needs")
        XCTAssertEqual(job.lastLogLine, "checking docker")
        let polled = try await client.provisioningJob()
        let later = try XCTUnwrap(polled)
        XCTAssertEqual(later.state, "done")
    }

    func testABusyInstallerAndAModelThatIsNotInstalledAreTheirOwnErrors() async {
        stub { request in
            switch request.url?.path ?? "" {
            case "/api/models/install": return Self.json(#"{"error":"An install is already in progress."}"#, status: 409)
            case "/api/swap": return Self.json(#"{"error":"Qwen3.8 Flash isn't installed yet.","not_installed":true}"#, status: 400)
            default: return Self.json("{}", status: 404)
            }
        }
        let client = SparkSwapperClient(baseURL: URL(string: "https://spark:8999")!, auth: .token("sst_x"), pinnedFingerprint: nil)
        do { try await client.installModel("flash"); XCTFail("busy") } catch {
            XCTAssertEqual(error as? SwapperError, .installBusy("An install is already in progress."))
        }
        do { try await client.swap(to: "flash"); XCTFail("not installed") } catch {
            XCTAssertEqual(error as? SwapperError, .notInstalled)
        }
    }

    func testAnotherFourHundredFromSwapIsAnOrdinaryError() async {
        stub { _ in Self.json(#"{"error":"Unknown model."}"#, status: 400) }
        let client = SparkSwapperClient(baseURL: URL(string: "https://spark:8999")!, auth: .token("sst_x"), pinnedFingerprint: nil)
        do { try await client.swap(to: "nope"); XCTFail("unknown") } catch {
            XCTAssertEqual(error as? SwapperError, .server(400, "Unknown model."))
        }
    }

    func testInstallDetailsAndTheSwitchTimeComeFromTheCatalog() throws {
        let json = #"""
        {"busy":false,"models":{"x":{"key":"x","title":"X Flash","context":8192,"served_id":"x","running":false,"healthy":false,
          "installed":false,"install":{"size_gb":16.8,"time":"5–15 minutes: downloads 16.8 GB","requires":["docker"]},"eta":"about 20 seconds"},
          "y":{"key":"y","title":"Y Flash","context":8192,"served_id":"y","running":false,"healthy":false,"install":null}},
         "install_job":{"id":"i9","target":"install:model:x","state":"running","started":5.0,"steps":[]}}
        """#
        let status = try JSONDecoder().decode(SwapperStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.models["x"]?.install?.summary, "16.8 GB · 5–15 minutes: downloads 16.8 GB")
        XCTAssertEqual(status.models["x"]?.switchDuration, "about 20 seconds")
        XCTAssertNil(status.models["y"]?.install)
        XCTAssertEqual(status.models["y"]?.switchDuration, "about 11 minutes", "no figure: the rough one")
        XCTAssertEqual(status.install_job?.installingModel, "x")
        XCTAssertEqual(SwapperStatus.Model.Install(size_gb: 60).summary, "60 GB")
    }

    func testATypedAddressBecomesTheSwappersAddress() {
        XCTAssertEqual(SparkSwapperClient.normalizedURL("192.168.1.42")?.absoluteString, "https://192.168.1.42:8999")
        XCTAssertEqual(SparkSwapperClient.normalizedURL(" spark.local ")?.absoluteString, "https://spark.local:8999")
        XCTAssertEqual(SparkSwapperClient.normalizedURL("spark.local:9000")?.absoluteString, "https://spark.local:9000")
        XCTAssertEqual(SparkSwapperClient.normalizedURL("https://spark:8999/")?.absoluteString, "https://spark:8999")
        XCTAssertEqual(SparkSwapperClient.normalizedURL("http://spark")?.absoluteString, "https://spark:8999")
        XCTAssertNil(SparkSwapperClient.normalizedURL("   "))
    }
}

/// Request headers seen by the stub, by request.
private final class SeenHeaders: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String: String]] = []
    func add(_ request: URLRequest) {
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["path"] = request.url?.path ?? ""
        lock.withLock { seen.append(headers) }
    }
    var all: [[String: String]] { lock.withLock { seen } }
}
