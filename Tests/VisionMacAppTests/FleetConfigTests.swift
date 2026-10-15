import XCTest
import VisionHarnessCore
@testable import VisionMacApp

/// How routes are arranged into a fleet: which one is the main model (the conductor), which serve
/// subagents, and what happens to that arrangement when another route takes the lead.
@MainActor
final class FleetConfigTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "dsh.fleet.test.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func config(_ routes: [ProviderProfile], main: String? = nil, defaults: UserDefaults? = nil) -> AppConfig {
        let config = AppConfig(defaults: defaults ?? self.defaults(), secrets: MemorySecretStore())
        config.providers = routes
        config.activeRoute = main ?? routes.first?.routeID
        return config
    }

    private func spark(_ name: String, host: String, model: String = "qwen3.8", worker: Bool = false) -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: name, baseURL: "http://\(host):8002/v1", model: model,
                        subagentWorker: worker ? true : nil)
    }

    private func bedrock(model: String = "us.anthropic.claude-sonnet-4-5-20250929-v1:0", worker: Bool = false) -> ProviderProfile {
        ProviderProfile(kind: .bedrock, name: "Amazon Bedrock", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                        model: model, awsProfile: "dsh-bedrock", awsRegion: "us-east-1", subagentWorker: worker ? true : nil)
    }

    private func names(_ routes: [ProviderProfile]) -> [String] { routes.map(\.name) }

    // MARK: Who the workers are

    func testWorkersAreTheFlaggedRoutesExceptTheMainOne() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true),
                        bedrock(worker: true), spark("Spare", host: "old.local")])
        XCTAssertEqual(names(c.workerRoutes), ["Spark 2", "Amazon Bedrock"])
        XCTAssertEqual(names(c.flaggedWorkers), ["Spark 2", "Amazon Bedrock"])
    }

    func testTheMainRouteIsNeverItsOwnWorker() {
        let c = config([spark("Spark 1", host: "spark1.local", worker: true), spark("Spark 2", host: "spark2.local", worker: true)])
        XCTAssertEqual(names(c.workerRoutes), ["Spark 2"])
    }

    func testOneMachineIsOneWorkerHoweverManyModelsItIsListedWith() {
        // A Spark serves one model at a time, so a second route on it would only queue behind the first.
        let c = config([spark("Spark 1", host: "spark1.local"),
                        spark("Spark 1 (coder)", host: "spark1.local", model: "coder", worker: true),   // the main's own machine
                        spark("Spark 2", host: "spark2.local", worker: true),
                        ProviderProfile(kind: .openAICompat, name: "Spark 2 (big)", baseURL: "http://SPARK2.local:8002/v1/",
                                        model: "big", subagentWorker: true)])                            // same machine, spelled differently
        XCTAssertEqual(names(c.workerRoutes), ["Spark 2"])
    }

    func testAHostedServiceIsToldApartByRoute() {
        // Bedrock serves every model at once: a cheaper model can be a worker while a stronger one leads.
        let c = config([bedrock(model: "us.anthropic.claude-opus-4-1-20250805-v1:0"),
                        bedrock(model: "us.anthropic.claude-haiku-4-5-20251001-v1:0", worker: true),
                        bedrock(model: "amazon.nova-pro-v1:0", worker: true)])
        XCTAssertEqual(c.workerRoutes.map(\.model), ["us.anthropic.claude-haiku-4-5-20251001-v1:0", "amazon.nova-pro-v1:0"])
    }

    func testTheRouteLabelFallsBackToTheModel() {
        XCTAssertEqual(AppConfig.routeLabel(spark("Spark 2", host: "h")), "Spark 2")
        XCTAssertEqual(AppConfig.routeLabel(ProviderProfile(kind: .ollama, name: "", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b")), "qwen3:8b")
    }

    // MARK: Swapping the conductor

    func testMakingAnotherRouteMainKeepsTheOldMainWorkingInTheFleet() {
        // The user's setup: two Sparks and Bedrock, one leads, the other two take subagent tasks.
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true), bedrock(worker: true)])
        c.makeMain(bedrock().routeID)
        XCTAssertEqual(c.mainRoute?.name, "Amazon Bedrock")
        XCTAssertEqual(names(c.workerRoutes), ["Spark 1", "Spark 2"], "the old main becomes a subagent server; nothing is dropped")

        c.makeMain(spark("Spark 2", host: "x").routeID)
        XCTAssertEqual(c.mainRoute?.name, "Spark 2")
        XCTAssertEqual(names(c.workerRoutes), ["Spark 1", "Amazon Bedrock"])

        c.makeMain(spark("Spark 1", host: "x").routeID)
        XCTAssertEqual(names(c.workerRoutes), ["Spark 2", "Amazon Bedrock"], "and back again: still all three in use")
    }

    func testATwoServerFleetStaysTwoServersAfterASwap() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true)])
        c.makeMain(spark("Spark 2", host: "x").routeID)
        XCTAssertEqual(c.mainRoute?.name, "Spark 2")
        XCTAssertEqual(names(c.workerRoutes), ["Spark 1"])
    }

    func testSwappingWithoutAFleetDoesNotInventOne() {
        // Two unrelated routes, no subagent servers: switching from one to the other is just a switch.
        let c = config([spark("Spark 1", host: "spark1.local"), bedrock()])
        c.makeMain(bedrock().routeID)
        XCTAssertEqual(c.mainRoute?.name, "Amazon Bedrock")
        XCTAssertTrue(c.workerRoutes.isEmpty)
        XCTAssertFalse(c.providers[0].isSubagentWorker)
    }

    func testAWorkerFlagIsKeptWhileARouteLeadsSoItCanComeBack() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true), bedrock(worker: true)])
        c.makeMain(spark("Spark 2", host: "x").routeID)
        XCTAssertTrue(c.providers.first { $0.name == "Spark 2" }!.isSubagentWorker)
        XCTAssertFalse(names(c.workerRoutes).contains("Spark 2"), "but a route that leads does not serve itself")
    }

    func testMakingTheCurrentOrAnUnknownRouteMainChangesNothing() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true)])
        let before = c.providers
        c.makeMain(c.activeRoute!)
        c.makeMain("nobody|nothing")
        XCTAssertEqual(c.providers, before)
        XCTAssertEqual(c.mainRoute?.name, "Spark 1")
    }

    // MARK: Editing the arrangement

    func testTheWorkerSwitchAndTheParallelCountAreSetPerRoute() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local")])
        let two = spark("Spark 2", host: "x").routeID
        c.setSubagentWorker(two, true)
        c.setSubagentParallel(two, 4)
        XCTAssertEqual(names(c.workerRoutes), ["Spark 2"])
        XCTAssertEqual(c.workerRoutes.first?.subagentParallel, 4)
        c.setSubagentWorker(two, false)
        XCTAssertTrue(c.workerRoutes.isEmpty)
        XCTAssertNil(c.providers[1].subagentWorker, "off is stored as absent, so old files stay identical")
    }

    func testStoringARouteNeverChangesTheMainModel() {
        let c = config([spark("Spark 1", host: "spark1.local")])
        c.store(spark("Spark 2", host: "spark2.local", worker: true))
        XCTAssertEqual(c.mainRoute?.name, "Spark 1")
        XCTAssertEqual(c.providers.count, 2)
        var edited = spark("Spark 2", host: "spark2.local", worker: true)
        edited.temperature = 0.1
        c.store(edited)
        XCTAssertEqual(c.providers.count, 2, "same name and model = the same route, replaced")
        XCTAssertEqual(c.providers[1].temperature, 0.1)
    }

    func testAChangeToTheFleetIsAnnouncedSoItCanBeRebuilt() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local")])
        var calls = 0
        c.onRoutesChanged = { calls += 1 }
        c.setSubagentWorker(spark("Spark 2", host: "x").routeID, true)
        XCTAssertEqual(calls, 1)
        c.makeMain(spark("Spark 2", host: "x").routeID)
        XCTAssertGreaterThanOrEqual(calls, 2)
        let before = calls
        c.subagentsUsePrimary = false
        XCTAssertEqual(calls, before + 1)
    }

    // MARK: Replacing a route in place

    func testReplacingARouteKeepsItsPlaceAndItsRole() {
        // Change… on a Bedrock route that serves subagents: a different model, the same seat.
        let c = config([spark("Spark 1", host: "spark1.local"), bedrock(worker: true), spark("Spark 2", host: "spark2.local", worker: true)])
        var changed = bedrock(model: "us.anthropic.claude-haiku-4-5-20251001-v1:0", worker: true)
        changed.subagentParallel = 4
        c.replace(bedrock(), with: changed)
        XCTAssertEqual(c.providers.map(\.name), ["Spark 1", "Amazon Bedrock", "Spark 2"], "same position")
        XCTAssertEqual(c.providers[1].model, "us.anthropic.claude-haiku-4-5-20251001-v1:0")
        XCTAssertEqual(c.workerRoutes.map(\.name), ["Amazon Bedrock", "Spark 2"])
        XCTAssertEqual(c.mainRoute?.name, "Spark 1")
    }

    func testReplacingTheMainRouteKeepsItTheMainModel() {
        let c = config([bedrock(), spark("Spark 2", host: "spark2.local", worker: true)])
        XCTAssertEqual(c.mainRoute?.name, "Amazon Bedrock")
        c.replace(bedrock(), with: bedrock(model: "amazon.nova-pro-v1:0"))
        XCTAssertEqual(c.mainRoute?.model, "amazon.nova-pro-v1:0")
        XCTAssertEqual(c.activeRoute, "Amazon Bedrock|amazon.nova-pro-v1:0")
        XCTAssertEqual(c.providers.count, 2)
    }

    func testReplacingWithAModelThatIsAlreadyARouteLeavesOneOfThem() {
        let sonnet = bedrock(model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        let haiku = bedrock(model: "us.anthropic.claude-haiku-4-5-20251001-v1:0", worker: true)
        let c = config([sonnet, haiku], main: sonnet.routeID)
        // The user re-picks Haiku for the main route, which already exists as a subagent server.
        var picked = haiku
        picked.subagentWorker = nil
        c.replace(sonnet, with: picked)
        XCTAssertEqual(c.providers.count, 1, "two routes for one model would collapse into one identity anyway")
        XCTAssertEqual(c.mainRoute?.model, haiku.model)
    }

    func testReplacingAnUnknownRouteJustStoresTheNewOne() {
        let c = config([spark("Spark 1", host: "spark1.local")])
        c.replace(bedrock(), with: bedrock(model: "amazon.nova-pro-v1:0"))
        XCTAssertEqual(c.providers.count, 2)
        XCTAssertEqual(c.mainRoute?.name, "Spark 1")
    }

    // MARK: Persistence

    func testTheArrangementSurvivesARestart() {
        let store = defaults()
        let first = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true), bedrock(worker: true)],
                           defaults: store)
        first.setSubagentParallel(bedrock().routeID, 3)
        first.subagentsUsePrimary = false

        let second = AppConfig(defaults: store, secrets: MemorySecretStore())
        XCTAssertEqual(second.mainRoute?.name, "Spark 1")
        XCTAssertEqual(names(second.workerRoutes), ["Spark 2", "Amazon Bedrock"])
        XCTAssertEqual(second.workerRoutes.last?.subagentParallel, 3)
        XCTAssertFalse(second.subagentsUsePrimary)
        XCTAssertEqual(second.workerRoutes.last?.awsProfile, "dsh-bedrock")
    }

    func testRoutesSavedByAnOlderBuildStillLoad() throws {
        let store = defaults()
        let old = #"[{"kind":"openAICompat","name":"Spark","baseURL":"http://spark:8002/v1","model":"qwen"}]"#
        store.set(Data(old.utf8), forKey: "providers.v2")
        store.set("Spark|qwen", forKey: "activeModel.v2")
        let c = AppConfig(defaults: store, secrets: MemorySecretStore())
        XCTAssertEqual(c.mainRoute?.name, "Spark")
        XCTAssertTrue(c.subagentsUsePrimary, "on by default")
        XCTAssertTrue(c.workerRoutes.isEmpty)
    }

    // MARK: AWS sign-in expiry

    func testAnExpiredAWSSignInOnTheMainBedrockRouteOffersASignIn() {
        let route = bedrock()
        let expired = LLMError.rejected(status: 401, message: "The AWS sign-in for profile \"dsh-bedrock\" has expired.",
                                        body: "sign-in expired", permanent: true)
        XCTAssertEqual(AppTransport.expiredAWSProfile(for: expired, route: route), "dsh-bedrock")
        let refused = LLMError.rejected(status: 403, message: "AWS did not accept the credentials", body: "", permanent: true)
        XCTAssertEqual(AppTransport.expiredAWSProfile(for: refused, route: route), "dsh-bedrock")
    }

    func testOtherFailuresDoNotOfferASignIn() {
        let route = bedrock()
        // Access to one model being denied, throttling and a missing model are not about the sign-in.
        for error in [LLMError.rejected(status: 403, message: "no access to this model", body: "", permanent: false),
                      LLMError.rejected(status: 429, message: "throttled", body: "", permanent: false),
                      LLMError.rejected(status: 404, message: "no such model", body: "", permanent: true),
                      LLMError.http(401, "nope"), LLMError.connection("down")] as [Error] {
            XCTAssertNil(AppTransport.expiredAWSProfile(for: error, route: route), "\(error)")
        }
    }

    func testNoSignInIsOfferedForARouteWithoutAnAWSProfile() {
        let expired = LLMError.rejected(status: 401, message: "x", body: "", permanent: true)
        XCTAssertNil(AppTransport.expiredAWSProfile(for: expired, route: spark("Spark 1", host: "h")), "not a Bedrock route")
        var apiKeyRoute = bedrock()
        apiKeyRoute.awsProfile = nil   // authenticates with a Bedrock API key: signing in again would not help
        XCTAssertNil(AppTransport.expiredAWSProfile(for: expired, route: apiKeyRoute))
        XCTAssertNil(AppTransport.expiredAWSProfile(for: expired, route: nil))
    }

    func testTheAgentsCommandIsRecognisedWithItsAliases() {
        XCTAssertEqual(SlashCommand.parse("/agents"), .agents)
        XCTAssertEqual(SlashCommand.parse("/fleet"), .agents)
        XCTAssertTrue(SlashCommand.catalog.contains { $0.usage == "/agents" })
    }
}
