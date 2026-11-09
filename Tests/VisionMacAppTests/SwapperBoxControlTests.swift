import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// A Swapper that answers what a test tells it to, path by path.
final class FakeSwapper: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case json(Int, String)
        case unreachable
    }

    nonisolated(unsafe) static var handler: (@Sendable (String) -> Reply) = { _ in .json(404, #"{"error":"not found"}"#) }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _paths: [String] = []
    static var paths: [String] { lock.withLock { _paths } }

    static func reset(_ handler: @escaping @Sendable (String) -> Reply) {
        lock.withLock { _paths = [] }
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self._paths.append(path) }
        switch Self.handler(path) {
        case .unreachable:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .json(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A switch that can be flipped from the fake server's handler.
final class TestSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool = false) { self.value = value }
    var isOn: Bool { lock.withLock { value } }
    func set(_ on: Bool) { lock.withLock { value = on } }
}

/// The Swapper boxes as the app drives them with Swapper 2.2: a box that goes silent mid-switch, the context
/// window, pictures, adding a model, and the agent's `model_server` requests.
@MainActor
final class SwapperBoxControlTests: XCTestCase {
    private var dir: URL!
    private var suites: [String] = []
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-box-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SparkSwapperClient.protocolClassesForTesting = [FakeSwapper.self]
        FakeSwapper.reset { _ in .json(404, #"{"error":"not found"}"#) }
    }

    override func tearDown() async throws {
        transport?.stopAll()
        transport = nil
        SparkSwapperClient.protocolClassesForTesting = nil
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func defaults() -> UserDefaults {
        let suite = "vision.box.test.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func controller() -> (SparkController, SwapperBox) {
        let config = AppConfig(defaults: defaults(), secrets: MemorySecretStore())
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        let spark = SparkController(config: config, transport: transport, defaults: defaults(), secrets: MemorySecretStore())
        let box = spark.add(SwapperConnection(name: "DGX Spark (spark-3f2a)", url: "https://box.test:8999", auth: .token),
                            secret: "sst_x")
        return (spark, box)
    }

    /// GET /api/status from a 2.2 box serving Flash Next at 256K; `job` goes in as it is.
    nonisolated private static func status(job: String = "null", busy: Bool = false, pictures: Bool = true) -> String {
        """
        {"version":"2.2.0","platform":"nvidia-gb10","hostname":"spark-3f2a","active":"flash","busy":\(busy),"job":\(job),
         "memory":{"total":128.0,"available":97.4,"free":41.2},
         "pictures":{"installed":true,"enabled":\(pictures),"running":false,"ready":\(pictures),"summary":"\(pictures ? "On — starts when a picture is asked for" : "Off")","checks":[]},
         "models":{
          "flash":{"key":"flash","title":"Qwen3.8 Flash Next","context":262144,"served_context":262144,"served_id":"flash",
                   "running":true,"healthy":true,"installed":true,"order":1,"eta":"about 11 minutes",
                   "contexts":[{"tokens":262144,"label":"256K","detail":"native","pictures":true},
                               {"tokens":524288,"label":"512K","detail":"YaRN","pictures":false}]},
          "big":{"key":"big","title":"Qwen3.8 27B","context":262144,"served_id":"qwen3.8-27b","running":false,"healthy":false,
                 "installed":true,"order":2},
          "bolt":{"key":"bolt","title":"Nemotron 3.5 Bolt","context":262144,"served_id":"bolt","running":false,"healthy":false,
                  "installed":false,"order":3,"install":{"size_gb":23,"time":"10 minutes"}}}}
        """
    }

    nonisolated private static let runningJob = #"{"id":"j1","target":"big","state":"running","started":1.0,"steps":[{"key":"stop","label":"Stopping the current model","state":"running"}]}"#

    // MARK: A box that goes silent

    func testABoxThatGoesSilentMidSwitchStopsCountingAsSwitching() async {
        let (spark, box) = controller()
        let down = TestSwitch()
        FakeSwapper.reset { path in
            guard path == "/api/status", !down.isOn else { return .unreachable }
            return .json(200, Self.status(job: Self.runningJob, busy: true))
        }
        await spark.refresh(box)
        XCTAssertTrue(box.isSwitching)
        XCTAssertTrue(box.isOnline)
        XCTAssertNotNil(box.lastAnsweredText())

        // The box drops off the network: its last status still says "switching".
        down.set(true)
        await spark.refresh(box)
        XCTAssertTrue(box.isSwitching, "one missed check is not a lost box")
        XCTAssertEqual(box.progressLine, "Switching DGX Spark (spark-3f2a) to Qwen3.8 27B · the box isn't answering, trying again")
        await spark.refresh(box)
        await spark.refresh(box)
        XCTAssertFalse(box.isSwitching, "sending no longer waits on a box nobody can reach")
        XCTAssertTrue(spark.switchingBoxes.isEmpty)
        XCTAssertFalse(box.isOnline)
        XCTAssertEqual(box.progressLine, "Lost contact with DGX Spark (spark-3f2a) while it was switching to Qwen3.8 27B. Still trying to reach it.")

        // It comes back, still switching: followed again.
        down.set(false)
        await spark.refresh(box)
        XCTAssertTrue(box.isSwitching)
        XCTAssertTrue(box.isOnline)
        XCTAssertTrue(box.progressLine?.hasPrefix("Switching DGX Spark (spark-3f2a) to Qwen3.8 27B · Stopping the current model") ?? false,
                      box.progressLine ?? "")
    }

    // MARK: A "no" from the box is not the box being down

    func testARefusedSwitchLandsNextToTheControlsNotAsTheBoxBeingUnreachable() async {
        let (spark, box) = controller()
        FakeSwapper.reset { path in
            switch path {
            case "/api/status": return .json(200, Self.status())
            case "/api/swap": return .json(409, #"{"error":"A switch is already in progress."}"#)
            default: return .json(404, #"{"error":"not found"}"#)
            }
        }
        await spark.refresh(box)
        let failure = await spark.swap(box, to: "big")
        XCTAssertEqual(failure, "Spark Swapper replied 409: A switch is already in progress.")
        XCTAssertEqual(box.actionError, failure)
        XCTAssertNil(box.lastError)
        XCTAssertTrue(box.isOnline)
    }

    // MARK: Context window and pictures

    func testChoosingAWindowForTheServingModelFollowsTheRestart() async {
        let (spark, box) = controller()
        FakeSwapper.reset { path in
            switch path {
            case "/api/status": return .json(200, Self.status())
            case "/api/context":
                return .json(202, #"{"ok":true,"restarting":true,"job":{"id":"c7","target":"flash","state":"running","started":2.0,"steps":[]}}"#)
            default: return .json(404, #"{"error":"not found"}"#)
            }
        }
        await spark.refresh(box)
        XCTAssertTrue(box.hasContextAndPictures)
        XCTAssertEqual(box.status?.models["flash"]?.contextChoices.map(\.name), ["256K", "512K"])
        let failure = await spark.setContext(box, model: "flash", tokens: 524288)
        XCTAssertNil(failure)
        XCTAssertNil(box.actionError)
        XCTAssertNil(box.working, "the controls are free again")
        XCTAssertTrue(FakeSwapper.paths.contains("/api/context"))
    }

    func testAnOlderBoxSaysToUpdateAndStaysOnline() async {
        let (spark, box) = controller()
        FakeSwapper.reset { path in
            path == "/api/status" ? .json(200, #"{"version":"2.0.1","active":null,"busy":false,"models":{}}"#)
                                  : .json(404, #"{"error":"not found"}"#)
        }
        await spark.refresh(box)
        XCTAssertFalse(box.hasContextAndPictures)
        let failure = await spark.setPictures(box, enabled: true)
        XCTAssertTrue(failure?.contains("older than 2.2.0") ?? false, failure ?? "")
        XCTAssertEqual(box.actionError, failure)
        XCTAssertNil(box.lastError)
        await spark.loadActivity(box)
        XCTAssertTrue(box.activityError?.contains("older than 2.2.0") ?? false)
    }

    func testTurningPicturesOffShowsAtOnce() async {
        let (spark, box) = controller()
        FakeSwapper.reset { path in
            switch path {
            case "/api/status": return .json(200, Self.status())
            case "/api/pictures": return .json(200, #"{"ok":true,"installed":true,"enabled":false,"running":false,"ready":false,"summary":"Off","checks":[]}"#)
            case "/api/activity": return .json(200, #"{"lines":["2026-11-09 08:00:00  first","2026-11-09 09:00:00  Pictures turned off (pat's app connection)"]}"#)
            default: return .json(404, #"{"error":"not found"}"#)
            }
        }
        await spark.refresh(box)
        XCTAssertEqual(box.status?.pictures?.value?.isOn, true)
        let failure = await spark.setPictures(box, enabled: false)
        XCTAssertNil(failure)
        XCTAssertEqual(box.status?.pictures?.value?.isOn, false)
        XCTAssertEqual(box.status?.pictures?.value?.summary, "Off")
        await spark.loadActivity(box)
        XCTAssertEqual(box.activity.first, "2026-11-09 09:00:00  Pictures turned off (pat's app connection)", "newest first")
        XCTAssertNil(box.activityError)
    }

    // MARK: Adding a model

    func testCheckingAndAddingAHuggingFaceModel() async {
        let (spark, box) = controller()
        spark.installPollInterval = 60   // the install is only started here, not followed to its end
        FakeSwapper.reset { path in
            switch path {
            case "/api/status": return .json(200, Self.status())
            case "/api/hf/inspect":
                return .json(200, #"{"repo":"acme/coder-32b","title":"coder-32b","format":"safetensors","size_bytes":64000000000,"context_native":131072,"profile_label":"vLLM","catalog_key":null,"problems":[],"warnings":[],"supported":true}"#)
            case "/api/hf/add":
                return .json(202, #"{"ok":true,"key":"hf-acme-coder-32b","job":{"id":"i3","target":"install:model:hf-acme-coder-32b","state":"running","started":9.0,"steps":[]}}"#)
            default: return .json(404, #"{"error":"not found"}"#)
            }
        }
        let checked = await spark.inspectHuggingFace("acme/coder-32b", on: box)
        XCTAssertNil(checked.problem)
        XCTAssertEqual(checked.found?.canRun, true)
        let result = await spark.addHuggingFace("acme/coder-32b", on: box)
        XCTAssertEqual(result.added?.key, "hf-acme-coder-32b")
        XCTAssertEqual(box.installingKey, "hf-acme-coder-32b", "its install is followed like any other")
    }

    func testAModelTheBoxCannotAddSaysWhyInTheBoxsWords() async {
        let (spark, box) = controller()
        FakeSwapper.reset { _ in .json(403, #"{"error":"Not available to app connections."}"#) }
        let checked = await spark.inspectHuggingFace("acme/coder-32b", on: box)
        XCTAssertNil(checked.found)
        XCTAssertEqual(checked.problem, "Not available to app connections.")
    }

    // MARK: model_server

    func testTheAgentReadsEveryBoxAndIsToldWhatAChangeWouldDo() async {
        let (spark, box) = controller()
        FakeSwapper.reset { path in
            path == "/api/status" ? .json(200, Self.status()) : .json(404, #"{"error":"not found"}"#)
        }
        let report = await spark.perform(.status(box: nil))
        XCTAssertTrue(report.hasPrefix("DGX Spark (spark-3f2a) — DGX Spark · Swapper 2.2.0\nServing: Qwen3.8 Flash Next"), report)
        XCTAssertTrue(report.contains("- `bolt` — Nemotron 3.5 Bolt · 256K context · not installed (23 GB · 10 minutes)"), report)

        XCTAssertEqual(spark.describe(.switchModel(box: nil, model: "27b")),
                       "Switch DGX Spark (spark-3f2a) to Qwen3.8 27B (a few minutes). The model it serves now stops.")
        XCTAssertEqual(spark.describe(.setContext(box: "dgx", model: nil, tokens: 524288)),
                       "Serve Qwen3.8 Flash Next on DGX Spark (spark-3f2a) with a 512K context window. It restarts (about 11 minutes).")
        XCTAssertEqual(spark.describe(.setPictures(box: nil, enabled: false)), "Turn pictures off on DGX Spark (spark-3f2a).")
        XCTAssertEqual(box.status?.active, "flash")
    }

    func testRequestsThatCannotWorkAreAnsweredWithoutAskingTheBoxToTry() async {
        let (spark, _) = controller()
        FakeSwapper.reset { path in
            path == "/api/status" ? .json(200, Self.status()) : .json(404, #"{"error":"not found"}"#)
        }
        let unknown = await spark.perform(.switchModel(box: nil, model: "llama"))
        XCTAssertEqual(unknown, "Error: no model on DGX Spark (spark-3f2a) matches “llama”. Keys: flash, big, bolt.")
        let already = await spark.perform(.switchModel(box: nil, model: "flash"))
        XCTAssertEqual(already, "DGX Spark (spark-3f2a) is already serving Qwen3.8 Flash Next.")
        let missing = await spark.perform(.switchModel(box: nil, model: "bolt"))
        XCTAssertEqual(missing, "Error: Nemotron 3.5 Bolt isn't installed on DGX Spark (spark-3f2a). Use action install first.")
        let window = await spark.perform(.setContext(box: nil, model: nil, tokens: 1_048_576))
        XCTAssertEqual(window, "Error: Qwen3.8 Flash Next serves 256K or 512K, not 1M.")
        let same = await spark.perform(.setContext(box: nil, model: "flash", tokens: 262144))
        XCTAssertEqual(same, "Qwen3.8 Flash Next already serves a 256K window.")
        let fixed = await spark.perform(.setContext(box: nil, model: "big", tokens: 524288))
        XCTAssertEqual(fixed, "Error: Qwen3.8 27B's context window can't be changed on DGX Spark (spark-3f2a).")
        let nobody = await spark.perform(.status(box: "strix"))
        XCTAssertEqual(nobody, "Error: No box matches “strix”. The boxes: DGX Spark (spark-3f2a).")
        XCTAssertFalse(FakeSwapper.paths.contains("/api/swap"))
        XCTAssertFalse(FakeSwapper.paths.contains("/api/context"))
    }

    func testABoxThatCannotBeReachedIsSaidSo() async {
        let (spark, _) = controller()
        FakeSwapper.reset { _ in .unreachable }
        let answer = await spark.perform(.switchModel(box: nil, model: "big"))
        XCTAssertTrue(answer.hasPrefix("Error: DGX Spark (spark-3f2a) can't be reached:"), answer)
    }
}
