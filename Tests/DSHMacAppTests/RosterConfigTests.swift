import XCTest
import DSHCore
@testable import DSHMacApp

/// The AI roster: routes switched on or off, the primary, subagent servers, backups, and who may see sensitive data.
@MainActor
final class RosterConfigTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        try await super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "dsh.roster.test.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func route(_ name: String, host: String, worker: Bool = false, backup: Bool = false,
                       enabled: Bool? = nil) -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: name, baseURL: "http://\(host):8002/v1", model: "m",
                        subagentWorker: worker ? true : nil, enabled: enabled, backup: backup ? true : nil)
    }

    private func config(_ routes: [ProviderProfile], defaults: UserDefaults? = nil) -> AppConfig {
        let config = AppConfig(defaults: defaults ?? self.defaults())
        config.providers = routes
        config.activeRoute = routes.first?.routeID
        return config
    }

    func testARouteThatIsSwitchedOffServesNothing() {
        let c = config([route("Main", host: "a.local"), route("Off", host: "b.local", worker: true, backup: true, enabled: false),
                        route("On", host: "c.local", worker: true, backup: true)])
        XCTAssertEqual(c.workerRoutes.map(\.name), ["On"])
        XCTAssertEqual(c.backupRoutes.map(\.name), ["On"])
    }

    func testBackupsAreTheMarkedRoutesInOrderExceptTheMainOne() {
        let c = config([route("Main", host: "a.local", backup: true), route("B1", host: "b.local", backup: true),
                        route("Spare", host: "c.local"), route("B2", host: "d.local", backup: true)])
        XCTAssertEqual(c.backupRoutes.map(\.name), ["B1", "B2"])
        c.setBackup(c.providers[2].routeID, true)
        XCTAssertEqual(c.backupRoutes.map(\.name), ["B1", "Spare", "B2"])
        c.setBackup(c.providers[1].routeID, false)
        XCTAssertEqual(c.backupRoutes.map(\.name), ["Spare", "B2"])
        XCTAssertNil(c.providers[1].backup, "an untick leaves nothing behind in the settings file")
    }

    func testTheMainModelCannotBeSwitchedOff() {
        let c = config([route("Main", host: "a.local"), route("Other", host: "b.local")])
        XCTAssertFalse(c.setEnabled(c.providers[0].routeID, false))
        XCTAssertTrue(c.providers[0].isEnabled)
        XCTAssertTrue(c.setEnabled(c.providers[1].routeID, false))
        XCTAssertFalse(c.providers[1].isEnabled)
    }

    func testMakingASwitchedOffRouteTheMainOneSwitchesItOn() {
        let c = config([route("Main", host: "a.local"), route("Off", host: "b.local", enabled: false)])
        c.makeMain(c.providers[1].routeID)
        XCTAssertEqual(c.mainRoute?.name, "Off")
        XCTAssertTrue(c.mainRoute?.isEnabled == true)
    }

    func testRemovingTheMainModelHandsTheLeadToARouteThatIsOn() {
        let c = config([route("Main", host: "a.local"), route("Off", host: "b.local", enabled: false), route("On", host: "c.local")])
        c.removeProvider(c.providers[0])
        XCTAssertEqual(c.mainRoute?.name, "On")
    }

    func testAPrivacyChoiceIsStoredAndSurvivesARelaunch() {
        let store = defaults()
        let c = config([route("Spark", host: "192.168.1.5"), ProviderProfile(kind: .openAI, name: "OpenAI",
                        baseURL: "https://api.openai.com/v1", model: "gpt")], defaults: store)
        XCTAssertTrue(c.providers[0].isPrivateRoute)
        XCTAssertFalse(c.providers[1].isPrivateRoute)
        c.setPrivate(c.providers[0].routeID, false)
        c.setPrivate(c.providers[1].routeID, true)
        let reloaded = AppConfig(defaults: store)
        XCTAssertEqual(reloaded.providers.map(\.isPrivateRoute), [false, true])
        XCTAssertEqual(reloaded.providers.map(\.isPrivate), [false, true])
    }

    func testASettingsFileWithTheMainModelOffLoadsWithItOn() throws {
        let store = defaults()
        let routes = [route("Main", host: "a.local", enabled: false), route("Other", host: "b.local")]
        store.set(try JSONEncoder().encode(routes), forKey: "providers.v2")
        store.set(routes[0].routeID, forKey: "activeModel.v2")
        let c = AppConfig(defaults: store)
        XCTAssertEqual(c.mainRoute?.name, "Main")
        XCTAssertTrue(c.mainRoute?.isEnabled == true)
    }
}
