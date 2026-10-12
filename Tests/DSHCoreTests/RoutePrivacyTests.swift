import XCTest
@testable import DSHCore

/// Which routes may see sensitive data by default: only addresses that can't be anything but your own network.
final class RoutePrivacyTests: XCTestCase {
    private func route(_ baseURL: String, kind: ProviderProfile.Kind = .openAICompat) -> ProviderProfile {
        ProviderProfile(kind: kind, name: "r", baseURL: baseURL, model: "m")
    }

    func testYourOwnNetworkIsPrivate() {
        let own = [
            "http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://127.8.9.1/v1",
            "http://10.0.0.5:8002/v1", "http://172.16.0.1/v1", "http://172.31.255.254/v1", "http://192.168.1.42:8002/v1",
            "https://192.168.68.69:11443/v1", "http://169.254.10.20/v1",
            "http://100.64.0.1/v1", "http://100.101.102.103:8002/v1", "http://100.127.255.255/v1",   // Tailscale (CGNAT)
            "http://[::1]:8000/v1", "http://[fd7a:115c:a1e0::1]:8002/v1", "http://[fc00::5]/v1", "http://[fe80::1]/v1",
            "http://spark:8002/v1", "http://nas/v1",                                                  // single-label names
            "http://spark.local:8002/v1", "http://evo-x2.lan/v1", "http://box.home/v1", "http://box.home.arpa/v1",
            "http://models.internal/v1", "https://spark.tail1234.ts.net/v1", "http://spark.local./v1",
        ]
        for url in own {
            XCTAssertTrue(RoutePrivacy.isPrivateAddress(url), url)
            XCTAssertTrue(route(url).isPrivateRoute, url)
        }
    }

    func testEverythingElseIsNot() {
        let online = [
            "https://api.openai.com/v1", "https://openrouter.ai/api/v1", "https://api.z.ai/api/coding/paas/v4",
            "https://open.bigmodel.cn/api/coding/paas/v4", "https://api.kimi.ai/coding/v1", "https://api.moonshot.ai/v1",
            "https://coding-intl.dashscope.aliyuncs.com/v1", "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "http://172.32.0.1/v1", "http://172.15.0.1/v1", "http://100.63.255.255/v1", "http://100.128.0.1/v1",
            "http://8.8.8.8/v1", "http://192.169.1.1/v1", "http://[2001:db8::1]/v1",
            "https://my-gpu-box.example.com/v1", "https://models.mycompany.io/v1",   // unknown hosts: not private (the safe way)
            "", "not a url",
        ]
        for url in online {
            XCTAssertFalse(RoutePrivacy.isPrivateAddress(url), url)
        }
    }

    func testBedrockIsNeverPrivateByDefault() {
        XCTAssertFalse(route("https://bedrock-runtime.us-east-1.amazonaws.com", kind: .bedrock).isPrivateRoute)
        // (Even with an address that would otherwise count.)
        XCTAssertFalse(route("http://127.0.0.1", kind: .bedrock).isPrivateRoute)
    }

    func testTheUsersChoiceWinsEitherWay() {
        var spark = route("http://192.168.1.42:8002/v1")
        spark.isPrivate = false
        XCTAssertFalse(spark.isPrivateRoute)
        var hosted = route("https://api.openai.com/v1")
        hosted.isPrivate = true
        XCTAssertTrue(hosted.isPrivateRoute)
    }

    func testSelfHostedIsAnotherQuestion() {
        // An unknown host counts as self-hosted for the thinking parameters, but not as private.
        let unknown = route("https://my-gpu-box.example.com/v1")
        XCTAssertTrue(unknown.isSelfHosted)
        XCTAssertFalse(unknown.isPrivateRoute)
        // The plans' hosts are hosted services.
        for url in ["https://api.z.ai/api/paas/v4", "https://open.bigmodel.cn/api/paas/v4", "https://api.kimi.com/coding/v1",
                    "https://api.moonshot.cn/v1", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                    "https://modelstudio.console.alibabacloud.com/x"] {
            XCTAssertFalse(route(url).isSelfHosted, url)
        }
    }

    func testRolesDecodeFromOlderSettingsAsBefore() throws {
        let json = #"{"kind":"openAICompat","name":"Spark","baseURL":"http://spark.local:8002/v1","model":"qwen","subagentWorker":true}"#
        let old = try JSONDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
        XCTAssertTrue(old.isEnabled)
        XCTAssertFalse(old.isBackup)
        XCTAssertFalse(old.isInteractiveOnly)
        XCTAssertNil(old.isPrivate)
        XCTAssertTrue(old.isPrivateRoute)
        XCTAssertTrue(old.isSubagentWorker)
        // New fields round-trip, and nil ones are left out of the file.
        var changed = old
        changed.enabled = false
        changed.backup = true
        changed.isPrivate = false
        changed.interactiveOnly = true
        let data = try JSONEncoder().encode(changed)
        let back = try JSONDecoder().decode(ProviderProfile.self, from: data)
        XCTAssertEqual(back, changed)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("backup"))
    }
}
