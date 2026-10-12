import XCTest
@testable import DSHCore

/// Against a Spark Swapper 2.0 running in demo mode on plain HTTP. Skipped unless DSH_SWAPPER_DEMO_URL is set:
///   SWAPPER_DEMO=1 SWAPPER_DEMO_HTTP=1 SWAPPER_BIND=127.0.0.1 SWAPPER_PORT=18999 … python3 swapper/app.py
///   DSH_SWAPPER_DEMO_URL=http://127.0.0.1:18999 swift test --filter SwapperDemoLiveTests
/// (DSH_SWAPPER_DEMO_INSTALL=1 also starts an install, which the demo really runs.)
/// (The demo signs in as admin/admin. Its connection codes name https addresses that don't answer in demo
/// mode, so the code is only decoded here, not used to connect.)
final class SwapperDemoLiveTests: XCTestCase {
    func testTokensCodesStatusInstallAndSwap() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DSH_SWAPPER_DEMO_URL"], let url = URL(string: raw) else {
            throw XCTSkip("set DSH_SWAPPER_DEMO_URL to run")
        }
        // A login makes an app token, and the code it comes with decodes. (Over the demo's plain HTTP the session
        // cookie, being Secure, isn't sent back by URLSession, so the cookie is passed by hand here.)
        let grant = try await Self.createToken(url, label: SwapperConnect.tokenLabel(computerName: "the live test"))
        XCTAssertTrue(grant.token.hasPrefix("sst_"), grant.token)
        let code = try SwapperConnectionCode.decode(try XCTUnwrap(grant.code))
        XCTAssertEqual(code.token, grant.token)
        XCTAssertEqual(code.user, "admin")
        XCTAssertEqual(code.fingerprint.split(separator: ":").count, 32)
        XCTAssertTrue(code.apiBase.absoluteString.hasSuffix("/v1"))
        print("DEMO: code for \(code.name) — \(code.platform ?? "-") \(code.version ?? "-") api \(code.apiBase)")

        // The token signs in on its own.
        let client = SparkSwapperClient(baseURL: url, auth: .token(grant.token), pinnedFingerprint: nil)
        let session = try await client.sessionInfo()
        XCTAssertEqual(session.user, "admin")
        let info = try await client.connectInfo()
        XCTAssertEqual(info.fingerprint, code.fingerprint)
        let status = try await client.status()
        XCTAssertEqual(status.version, "2.0.0")
        XCTAssertFalse(status.models.isEmpty)
        for m in status.ordered {
            print("DEMO: \(m.isInstalled ? "✓" : "·") \(m.key) — \(m.title) · \(m.window) · \(m.speedText(roomForEstimate: true) ?? "-") · eta \(m.eta ?? "-") · install \(m.install?.summary ?? "-")")
        }

        // A model the box doesn't have: a switch is refused as not installed; an install starts and can be followed.
        // (The demo really runs an install's steps — a git clone into its own home — so that part is opt-in.)
        if let missing = status.ordered.first(where: { !$0.isInstalled && $0.install != nil }) {
            do {
                try await client.swap(to: missing.key)
                XCTFail("a switch to a model that isn't installed must be refused")
            } catch {
                XCTAssertEqual(error as? SwapperError, .notInstalled)
            }
        }
        if ProcessInfo.processInfo.environment["DSH_SWAPPER_DEMO_INSTALL"] == "1",
           let missing = status.ordered.first(where: { !$0.isInstalled && $0.install != nil }) {
            let job = try await client.installModel(missing.key)
            XCTAssertEqual(job?.installingModel, missing.key)
            var last = try await client.provisioningJob()
            for _ in 0..<40 where last?.isRunning == true {
                try await Task.sleep(nanoseconds: 250_000_000)
                last = try await client.provisioningJob()
            }
            print("DEMO: install of \(missing.key) — \(last?.state ?? "-") \(last?.error ?? "")")
            XCTAssertEqual(last?.installingModel, missing.key)
        }

        // A switch to another installed model starts a job.
        if let other = status.installedModels.first(where: { $0.key != status.active }), !status.isSwitching {
            try await client.swap(to: other.key)
            let after = try await client.status()
            XCTAssertEqual(after.job?.target, other.key)
            print("DEMO: switching to \(other.key) — \(after.job?.currentStep?.label ?? "-")")
        }

        // The login itself: a wrong password is a login error.
        let wrong = SparkSwapperClient(baseURL: url, auth: .login(username: "admin", password: "not-the-password"), pinnedFingerprint: nil)
        do {
            try await wrong.login()
            XCTFail("a wrong password must not sign in")
        } catch let SwapperError.badLogin(message) {
            XCTAssertFalse(message.isEmpty)
        }

        // A token the box doesn't know is refused in plain words.
        let stranger = SparkSwapperClient(baseURL: url, auth: .token("sst_00000000_notatokenthisboxhaseverseen00000000000"),
                                          pinnedFingerprint: nil)
        do {
            _ = try await stranger.status()
            XCTFail("an unknown token must be refused")
        } catch {
            XCTAssertEqual(error as? SwapperError, .revoked)
        }
    }

    /// POST /api/login, then POST /api/tokens/create with the session cookie set by hand.
    private static func createToken(_ url: URL, label: String) async throws -> SwapperTokenGrant {
        func post(_ path: String, _ body: [String: Any], cookie: String?) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("1", forHTTPHeaderField: "X-Swapper")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let (_, signedIn) = try await post("api/login", ["username": "admin", "password": "admin"], cookie: nil)
        let setCookie = try XCTUnwrap(signedIn.value(forHTTPHeaderField: "Set-Cookie"))
        let cookie = String(setCookie.split(separator: ";")[0])
        let (data, made) = try await post("api/tokens/create", ["label": label], cookie: cookie)
        XCTAssertEqual(made.statusCode, 201)
        return try JSONDecoder().decode(SwapperTokenGrant.self, from: data)
    }
}
