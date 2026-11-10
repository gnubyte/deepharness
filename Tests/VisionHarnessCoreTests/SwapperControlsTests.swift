import XCTest
@testable import VisionHarnessCore

/// Spark Swapper 2.1 and 2.2 from the app's side: the context window, pictures, the activity log, adding a model
/// from Hugging Face — and the agent's `model_server` tool over them. The JSON here is shaped like the Swapper's
/// own replies (swapper/app.py and engine.py at 2.2.0).
final class SwapperControlsTests: XCTestCase {
    override func tearDown() {
        SparkSwapperClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        super.tearDown()
    }

    private func stub(_ handler: @escaping @Sendable (URLRequest) -> StubServer.Reply) {
        SparkSwapperClient.protocolClassesForTesting = [StubServer.self]
        StubServer.reset(handler)
    }

    private static func json(_ text: String, status: Int = 200) -> StubServer.Reply {
        .init(status: status, body: text, contentType: "application/json")
    }

    private func client() -> SparkSwapperClient {
        SparkSwapperClient(baseURL: URL(string: "https://spark:8999")!, auth: .token("sst_x"), pinnedFingerprint: nil)
    }

    private static let status22 = #"""
    {"version":"2.2.0","platform":"nvidia-gb10","hostname":"spark-3f2a","active":"flash","busy":false,
     "memory":{"total":128.0,"available":97.4,"free":41.2},
     "vision":{"port":8443,"up":true},
     "pictures":{"installed":true,"enabled":true,"running":false,"ready":false,"room":true,"available_gib":12.0,
                 "need_gib":22,"last_used":null,"unit":"qwen-image.service","summary":"12.0 GiB free; a picture needs 22 GiB free to start",
                 "checks":[{"key":"installed","ok":true,"text":"qwen-image and its service are installed"},
                           {"key":"memory","ok":false,"text":"12.0 GiB free; a picture needs 22 GiB free to start"}]},
     "models":{
      "flash":{"key":"flash","title":"Qwen3.8 Flash Next","context":262144,"served_context":262144,"served_id":"flash",
               "running":true,"healthy":true,"installed":true,"order":1,"kind":"flash-vllm","experimental":false,
               "custom":false,"recommended":true,"disk_bytes":160000000000,"eta":"about 11 minutes",
               "contexts":[{"tokens":262144,"label":"256K","detail":"the model's native window — leaves room for pictures","pictures":true},
                           {"tokens":524288,"label":"512K","detail":"the longest chats (YaRN) — no room for pictures","pictures":false}]},
      "bolt":{"key":"bolt","title":"Nemotron 3.5 Bolt","context":262144,"served_id":"bolt","running":false,"healthy":false,
              "installed":false,"order":2,"contexts":null,"install":{"size_gb":23,"time":"10 minutes"}},
      "hf":{"key":"hf","title":"Some HF Model","context":65536,"served_id":"some-hf","running":false,"healthy":false,
            "installed":true,"order":101,"experimental":true,"custom":true,"contexts":null}}}
    """#

    // MARK: Status

    func testTheTwoPointTwoStatusFieldsDecode() throws {
        let status = try JSONDecoder().decode(SwapperStatus.self, from: Data(Self.status22.utf8))
        XCTAssertEqual(status.memory?.value?.summary, "97 of 128 GiB free")
        XCTAssertEqual(status.memory?.value?.usedFraction ?? 0, (128.0 - 97.4) / 128.0, accuracy: 0.0001)
        XCTAssertEqual(status.vision?.value?.up, true)
        let pictures = try XCTUnwrap(status.pictures?.value)
        XCTAssertTrue(pictures.isInstalled)
        XCTAssertTrue(pictures.isOn)
        XCTAssertEqual(pictures.problems, ["12.0 GiB free; a picture needs 22 GiB free to start"])
        let flash = try XCTUnwrap(status.models["flash"])
        XCTAssertEqual(flash.contextChoices.map(\.name), ["256K", "512K"])
        XCTAssertEqual(flash.contextChoices.last?.pictures, false)
        XCTAssertEqual(flash.disk_bytes?.value, 160_000_000_000)
        XCTAssertFalse(flash.isExperimental)
        XCTAssertTrue(status.models["hf"]?.isExperimental ?? false)
        XCTAssertEqual(status.models["bolt"]?.contextChoices.count, 0, "no choice to make")
    }

    /// A later Swapper may reshape a newer section. That must cost the section, never the whole status — a status
    /// that doesn't decode makes the box look offline.
    func testAReshapedNewSectionCostsOnlyThatSection() throws {
        let json = #"""
        {"active":"a","busy":false,"memory":"lots","pictures":["yes"],"vision":7,
         "models":{"a":{"key":"a","title":"A","context":8192,"served_id":"a","running":true,"healthy":true,
                        "contexts":{"256K":true},"experimental":"maybe","disk_bytes":"big","custom":1.5}}}
        """#
        let status = try JSONDecoder().decode(SwapperStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.activeModel?.title, "A")
        XCTAssertNil(status.memory?.value)
        XCTAssertNil(status.pictures?.value)
        XCTAssertNil(status.vision?.value)
        XCTAssertEqual(status.models["a"]?.contextChoices.count, 0)
        XCTAssertFalse(status.models["a"]?.isExperimental ?? true)
        XCTAssertNil(status.models["a"]?.disk_bytes?.value)
    }

    func testASingleWindowIsNotAChoice() {
        var model = SwapperStatus.Model(key: "a", title: "A", context: 8192, served_id: "a")
        model.contexts = Lenient([.init(tokens: 8192)])
        XCTAssertTrue(model.contextChoices.isEmpty)
        model.contexts = Lenient([.init(tokens: 262144), .init(tokens: 1_048_576, label: " ")])
        XCTAssertEqual(model.contextChoices.map(\.name), ["256K", "1M"], "a name made from the number when there is no label")
    }

    func testVersionsCompareByNumber() {
        XCTAssertTrue(SwapperVersion.isAtLeast("2.2.0", "2.2.0"))
        XCTAssertTrue(SwapperVersion.isAtLeast("2.10.1", "2.2.0"), "ten is more than two")
        XCTAssertTrue(SwapperVersion.isAtLeast("3", "2.2.0"))
        XCTAssertTrue(SwapperVersion.isAtLeast("2.2.0-rc1", "2.2.0"))
        XCTAssertFalse(SwapperVersion.isAtLeast("2.1.2", "2.2.0"))
        XCTAssertFalse(SwapperVersion.isAtLeast("2.2", "2.2.1"))
        XCTAssertFalse(SwapperVersion.isAtLeast(nil, "2.0.0"), "a Swapper before 2.0 doesn't say")
    }

    // MARK: The client

    func testChoosingAWindowOnTheServingModelRestartsItAsAJob() async throws {
        stub { request in
            guard request.url?.path == "/api/context" else { return Self.json("{}", status: 404) }
            return Self.json(#"{"ok":true,"restarting":true,"job":{"id":"c1","target":"flash","state":"running","started":5.0,"steps":[{"key":"context","label":"Setting the context window","state":"running"}],"log":[]}}"#,
                             status: 202)
        }
        let change = try await client().setContext(model: "flash", tokens: 524288)
        XCTAssertTrue(change.isRestarting)
        XCTAssertEqual(change.job?.id, "c1")
        XCTAssertEqual(change.job?.currentStep?.label, "Setting the context window")
        XCTAssertEqual(StubServer.paths, ["/api/context"])
    }

    func testAWindowForAModelThatIsNotServingIsOnlySaved() async throws {
        stub { _ in Self.json(#"{"ok":true,"restarting":false,"context":524288}"#) }
        let change = try await client().setContext(model: "flash", tokens: 524288)
        XCTAssertFalse(change.isRestarting)
        XCTAssertEqual(change.context, 524288)
        XCTAssertNil(change.job)
    }

    func testTheBoxSayingNoIsToldInItsOwnWords() async {
        stub { request in
            switch request.url?.path ?? "" {
            case "/api/context": return Self.json(#"{"error":"A switch is already in progress."}"#, status: 409)
            case "/api/pictures": return Self.json(#"{"error":"Qwen3.8 Flash Next serves 512K, which leaves no room for pictures. Switch it to 256K first."}"#, status: 409)
            default: return Self.json(#"{"error":"Not available to app connections."}"#, status: 403)
            }
        }
        do { try await client().setContext(model: "flash", tokens: 262144); XCTFail("busy") } catch {
            XCTAssertEqual(error as? SwapperError, .refused("A switch is already in progress."))
            XCTAssertEqual(error.localizedDescription, "A switch is already in progress.")
        }
        do { try await client().setPictures(true); XCTFail("no room") } catch {
            XCTAssertEqual(error.localizedDescription,
                           "Qwen3.8 Flash Next serves 512K, which leaves no room for pictures. Switch it to 256K first.")
        }
        do { _ = try await client().inspectHuggingFace("a/b"); XCTFail("not an admin") } catch {
            XCTAssertEqual(error as? SwapperError, .refused("Not available to app connections."))
        }
    }

    func testAnOlderSwapperIsToldToUpdateNotThatItFailed() async {
        stub { _ in Self.json(#"{"error":"not found"}"#, status: 404) }
        do { _ = try await client().pictures(); XCTFail("2.0 has no pictures") } catch {
            XCTAssertEqual(error as? SwapperError, .needsUpdate(version: "2.2.0", feature: "pictures"))
            XCTAssertTrue(error.localizedDescription.contains("older than 2.2.0"), error.localizedDescription)
        }
        do { try await client().setContext(model: "flash", tokens: 262144); XCTFail("2.0 has no windows") } catch {
            XCTAssertEqual(error as? SwapperError, .needsUpdate(version: "2.2.0", feature: "choosing the context window"))
        }
        do { _ = try await client().activity(); XCTFail("2.0 has no activity log") } catch {
            XCTAssertEqual(error as? SwapperError, .needsUpdate(version: "2.2.0", feature: "the activity log"))
        }
        do { _ = try await client().addHuggingFace("a/b"); XCTFail("2.0 can't add models") } catch {
            XCTAssertEqual(error as? SwapperError,
                           .needsUpdate(version: "2.1.2", feature: "adding models from Hugging Face"))
        }
    }

    func testARevokedTokenIsStillItsOwnErrorOnTheNewEndpoints() async {
        stub { _ in Self.json(#"{"error":"bad token"}"#, status: 401) }
        do { _ = try await client().pictures(); XCTFail("revoked") } catch {
            XCTAssertEqual(error as? SwapperError, .revoked)
        }
    }

    func testPicturesAndActivity() async throws {
        stub { request in
            switch request.url?.path ?? "" {
            case "/api/pictures":
                return Self.json(#"{"ok":true,"installed":true,"enabled":false,"running":false,"ready":false,"summary":"Off","checks":[{"key":"switch","ok":false,"text":"Turned off here — qwen-image says so instead of drawing"}],"log":["a","b"],"activity":["x"]}"#)
            case "/api/activity":
                return Self.json(#"{"lines":["2026-11-09 08:12:44  Switched to Qwen3.8 27B","2026-11-09 09:00:01  Pictures turned off (pat's app connection)",7]}"#)
            default: return Self.json("{}", status: 404)
            }
        }
        let pictures = try await client().setPictures(false)
        XCTAssertFalse(pictures.isOn)
        XCTAssertEqual(pictures.summary, "Off")
        XCTAssertEqual(pictures.log, ["a", "b"])
        let lines = try await client().activity()
        XCTAssertEqual(lines.count, 2, "anything that isn't a line is skipped")
        XCTAssertEqual(lines.last, "2026-11-09 09:00:01  Pictures turned off (pat's app connection)")
    }

    func testLookingAHuggingFaceModelUpAndAddingIt() async throws {
        stub { request in
            switch request.url?.path ?? "" {
            case "/api/hf/inspect":
                return Self.json(#"{"repo":"acme/coder-32b","commit":"abc","title":"coder-32b","license":"apache-2.0","gated":false,"private":false,"format":"safetensors","quantization":null,"architecture":"Qwen3ForCausalLM","pipeline":"text-generation","tags":["code"],"size_bytes":64000000000,"files":12,"context_native":131072,"context_default":65536,"profile":"vllm-spark","profile_label":"vLLM (community Spark image)","catalog_key":null,"memory_gib":79,"memory_total_gib":128.0,"disk_free":900000000000,"problems":[],"warnings":["Runs on vLLM from a community image built for the Spark."],"supported":true}"#)
            case "/api/hf/add":
                return Self.json(#"{"ok":true,"key":"hf-acme-coder-32b","job":{"id":"i3","target":"install:model:hf-acme-coder-32b","state":"running","started":9.0,"steps":[],"log":[]}}"#,
                                 status: 202)
            default: return Self.json("{}", status: 404)
            }
        }
        let found = try await client().inspectHuggingFace("https://huggingface.co/acme/coder-32b")
        XCTAssertTrue(found.canRun)
        XCTAssertEqual(found.sizeText, "64.0 GB")
        XCTAssertNil(found.catalog_key?.value)
        let report = found.report()
        XCTAssertTrue(report.contains("acme/coder-32b"), report)
        XCTAssertTrue(report.contains("Runs with: vLLM (community Spark image)"), report)
        XCTAssertTrue(report.contains("128K native context"), report)
        XCTAssertTrue(report.hasSuffix("This box can run it."), report)
        let added = try await client().addHuggingFace("acme/coder-32b", context: 65536)
        XCTAssertEqual(added.key, "hf-acme-coder-32b")
        XCTAssertEqual(added.job?.installingModel, "hf-acme-coder-32b")
        XCTAssertNil(added.note)
    }

    func testAModelAddedWhileAnotherInstallRunsIsStillAdded() async throws {
        stub { _ in
            Self.json(#"{"error":"Added coder-32b, but it can't install right now: an install is already running. Press Install on its card when the other job has finished.","key":"hf-acme-coder-32b","added":true}"#,
                      status: 409)
        }
        let added = try await client().addHuggingFace("acme/coder-32b")
        XCTAssertEqual(added.key, "hf-acme-coder-32b")
        XCTAssertNil(added.job)
        XCTAssertTrue(added.note?.hasPrefix("Added coder-32b") ?? false)
    }

    func testAModelTheBoxCannotRunIsRefusedWithTheReason() async {
        stub { _ in Self.json(#"{"error":"It needs about 190 GiB of memory and this box has 128 GiB."}"#, status: 400) }
        do { _ = try await client().addHuggingFace("acme/huge"); XCTFail("too big") } catch {
            XCTAssertEqual(error.localizedDescription, "It needs about 190 GiB of memory and this box has 128 GiB.")
        }
    }

    // MARK: model_server: reading the request

    private func parse(_ json: String) throws -> ModelServerRequest {
        try ModelServerRequest.parse(JSONString(json))
    }

    func testRequestsAreReadFromTheArguments() throws {
        XCTAssertEqual(try parse("{}"), .status(box: nil))
        XCTAssertEqual(try parse(#"{"action":"status","box":" evo "}"#), .status(box: "evo"))
        XCTAssertEqual(try parse(#"{"action":"switch","model":"flash"}"#), .switchModel(box: nil, model: "flash"))
        XCTAssertEqual(try parse(#"{"action":"SWAP","model":"flash","box":"dgx"}"#), .switchModel(box: "dgx", model: "flash"))
        XCTAssertEqual(try parse(#"{"action":"set_context","context":"512K"}"#), .setContext(box: nil, model: nil, tokens: 524288))
        XCTAssertEqual(try parse(#"{"action":"set-context","context":262144,"model":"flash"}"#),
                       .setContext(box: nil, model: "flash", tokens: 262144))
        XCTAssertEqual(try parse(#"{"action":"pictures","enabled":false}"#), .setPictures(box: nil, enabled: false))
        XCTAssertEqual(try parse(#"{"action":"pictures","enabled":"on"}"#), .setPictures(box: nil, enabled: true))
        XCTAssertEqual(try parse(#"{"action":"install","model":"bolt"}"#), .install(box: nil, model: "bolt"))
        XCTAssertEqual(try parse(#"{"action":"inspect_model","link":"acme/coder"}"#),
                       .addModel(box: nil, link: "acme/coder", context: nil, install: false))
        XCTAssertEqual(try parse(#"{"action":"add_model","link":"acme/coder","context":"64k"}"#),
                       .addModel(box: nil, link: "acme/coder", context: 65536, install: true))
        XCTAssertEqual(try parse(#"{"action":"activity"}"#), .activity(box: nil))
    }

    func testWhatIsMissingIsSaidPlainly() {
        let bad = [#"{"action":"switch"}"#, #"{"action":"switch","model":"  "}"#, #"{"action":"set_context"}"#,
                   #"{"action":"set_context","context":"big"}"#, #"{"action":"pictures"}"#,
                   #"{"action":"pictures","enabled":"maybe"}"#, #"{"action":"install"}"#,
                   #"{"action":"add_model"}"#, #"{"action":"reboot"}"#]
        for json in bad {
            XCTAssertThrowsError(try parse(json), json) { error in
                XCTAssertTrue(error is ModelServerRequestError, json)
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testAWindowAsAModelWritesIt() {
        XCTAssertEqual(ModelServerRequest.tokens(262144), 262144)
        XCTAssertEqual(ModelServerRequest.tokens(262144.0), 262144)
        XCTAssertEqual(ModelServerRequest.tokens("262144"), 262144)
        XCTAssertEqual(ModelServerRequest.tokens("262,144"), 262144)
        XCTAssertEqual(ModelServerRequest.tokens("256K"), 262144)
        XCTAssertEqual(ModelServerRequest.tokens(" 512 k "), 524288)
        XCTAssertEqual(ModelServerRequest.tokens("1M"), 1_048_576)
        XCTAssertNil(ModelServerRequest.tokens(true), "a boolean is not a window")
        XCTAssertNil(ModelServerRequest.tokens("K"))
        XCTAssertNil(ModelServerRequest.tokens(0))
        XCTAssertNil(ModelServerRequest.tokens(-4096))
        XCTAssertNil(ModelServerRequest.tokens(nil))
    }

    func testOnlyReadingNeedsNoSaySo() {
        XCTAssertFalse(ModelServerRequest.status(box: nil).changesTheBox)
        XCTAssertFalse(ModelServerRequest.activity(box: nil).changesTheBox)
        XCTAssertFalse(ModelServerRequest.addModel(box: nil, link: "a/b", context: nil, install: false).changesTheBox)
        XCTAssertTrue(ModelServerRequest.addModel(box: nil, link: "a/b", context: nil, install: true).changesTheBox)
        XCTAssertTrue(ModelServerRequest.switchModel(box: nil, model: "x").changesTheBox)
        XCTAssertTrue(ModelServerRequest.setContext(box: nil, model: nil, tokens: 1).changesTheBox)
        XCTAssertTrue(ModelServerRequest.setPictures(box: nil, enabled: false).changesTheBox)
        XCTAssertTrue(ModelServerRequest.install(box: nil, model: "x").changesTheBox)
    }

    // MARK: model_server: the tool

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _performed: [ModelServerRequest] = []
        private var _asked: [String] = []
        var performed: [ModelServerRequest] { lock.withLock { _performed } }
        var asked: [String] { lock.withLock { _asked } }
        func perform(_ request: ModelServerRequest) { lock.withLock { _performed.append(request) } }
        func ask(_ detail: String) { lock.withLock { _asked.append(detail) } }
    }

    private final class NoClient: LLMClient, @unchecked Sendable {
        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func listModels() async throws -> [String] { [] }
    }

    private func tool(_ seen: Seen) -> ModelServerTool {
        ModelServerTool(describe: { request in "Would do \(request)" },
                        perform: { request in
                            seen.perform(request)
                            return "done"
                        })
    }

    private func context(_ preset: PermissionPreset, depth: Int = 0, approve: Bool = true, seen: Seen) -> ToolContext {
        let dir = FileManager.default.temporaryDirectory
        return ToolContext(workspace: dir, policy: PermissionPolicy(preset: preset, workspaceRoot: dir),
                           client: NoClient(), registry: ToolRegistry(tools: []), depth: depth,
                           requestPermission: { _, name, detail in
                               seen.ask("\(name): \(detail)")
                               return approve
                           })
    }

    func testReadingTheStatusNeverAsks() async {
        let seen = Seen()
        let result = await tool(seen).execute(args: JSONString("{}"), in: context(.workspaceWrite, seen: seen))
        XCTAssertEqual(result.output, "done")
        XCTAssertEqual(seen.performed, [.status(box: nil)])
        XCTAssertTrue(seen.asked.isEmpty)
        // Plan mode may look too.
        let planned = await tool(seen).execute(args: JSONString(#"{"action":"activity"}"#), in: context(.plan, seen: seen))
        XCTAssertEqual(planned.output, "done")
    }

    func testChangingABoxAsksFirstAndADeclineChangesNothing() async {
        let seen = Seen()
        let args = JSONString(#"{"action":"switch","model":"flash"}"#)
        let declined = await tool(seen).execute(args: args, in: context(.workspaceWrite, approve: false, seen: seen))
        XCTAssertTrue(declined.output.hasPrefix("Error: the user declined"), declined.output)
        XCTAssertTrue(seen.performed.isEmpty)
        XCTAssertEqual(seen.asked.count, 1)
        XCTAssertTrue(seen.asked[0].hasPrefix("model_server: Would do"), seen.asked[0])
        let approved = await tool(seen).execute(args: args, in: context(.workspaceWrite, approve: true, seen: seen))
        XCTAssertEqual(approved.output, "done")
        XCTAssertEqual(seen.performed, [.switchModel(box: nil, model: "flash")])
    }

    func testFullAccessDoesNotAskAndPlanModeAndSubagentsChangeNothing() async {
        let seen = Seen()
        let args = JSONString(#"{"action":"pictures","enabled":false}"#)
        let full = await tool(seen).execute(args: args, in: context(.fullAccess, seen: seen))
        XCTAssertEqual(full.output, "done")
        XCTAssertTrue(seen.asked.isEmpty)
        let plan = await tool(seen).execute(args: args, in: context(.plan, seen: seen))
        XCTAssertTrue(plan.output.hasPrefix("Error: plan mode"), plan.output)
        let sub = await tool(seen).execute(args: args, in: context(.fullAccess, depth: 1, seen: seen))
        XCTAssertTrue(sub.output.hasPrefix("Error: only the main agent"), sub.output)
        XCTAssertEqual(seen.performed.count, 1, "only the full-access call at the top level went through")
    }

    func testArgumentsThatCannotBeReadAreAnErrorNotAGuess() async {
        let seen = Seen()
        let result = await tool(seen).execute(args: JSONString(#"{"action":"switch"}"#), in: context(.fullAccess, seen: seen))
        XCTAssertTrue(result.output.hasPrefix("Error: switch needs `model`"), result.output)
        XCTAssertTrue(seen.performed.isEmpty)
    }

    // MARK: The status, in words

    func testTheReportNamesKeysSoAFollowUpCanSwitch() throws {
        let status = try JSONDecoder().decode(SwapperStatus.self, from: Data(Self.status22.utf8))
        let report = status.report(name: "DGX Spark (spark-3f2a)", summary: "DGX Spark · Swapper 2.2.0")
        let lines = report.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "DGX Spark (spark-3f2a) — DGX Spark · Swapper 2.2.0")
        XCTAssertEqual(lines[1], "Serving: Qwen3.8 Flash Next (key `flash`, model id `flash`, 256K context)")
        XCTAssertTrue(lines.contains("Memory: 97 of 128 GiB free"), report)
        XCTAssertTrue(lines.contains("Pictures: 12.0 GiB free; a picture needs 22 GiB free to start"), report)
        XCTAssertTrue(lines.contains("- `flash` — Qwen3.8 Flash Next · 256K context · serving · windows: 256K or 512K"), report)
        XCTAssertTrue(lines.contains("- `bolt` — Nemotron 3.5 Bolt · 256K context · not installed (23 GB · 10 minutes)"), report)
        XCTAssertTrue(lines.contains("- `hf` — Some HF Model · 64K context · installed, switching takes a few minutes · experimental"), report)
    }

    func testAnIdleBoxSaysNothingIsServing() {
        let status = SwapperStatus(models: ["a": .init(key: "a", title: "A", context: 8192, served_id: "a")])
        let report = status.report(name: "Box", summary: "DGX Spark")
        XCTAssertTrue(report.contains("Serving: nothing right now"), report)
    }
}
