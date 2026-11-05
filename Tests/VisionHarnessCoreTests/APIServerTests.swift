import XCTest
@testable import VisionHarnessCore

final class APIServerTests: XCTestCase {
    private func request(_ method: String, _ path: String, body: Data = Data()) -> LocalAPIServer.HTTPRequest {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\r\n"
        _ = head
        let headData = Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        return LocalAPIServer.HTTPRequest(head: headData, body: body)
    }

    static let profile = ProviderProfile(kind: .openAICompat, name: "Test", baseURL: "http://127.0.0.1:1/v1", model: "test-model")

    func testHealth() async {
        let data = await LocalAPIServer.route(request: request("GET", "/health")) { Self.profile }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("200 OK"))
        XCTAssertTrue(text.contains("\"test-model\""))
    }

    func testHealthUnconfigured() async {
        let data = await LocalAPIServer.route(request: request("GET", "/health")) { nil }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("200 OK"))
    }

    func testModelsList() async {
        let data = await LocalAPIServer.route(request: request("GET", "/v1/models")) { Self.profile }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("chat.completion") == false)
        XCTAssertTrue(text.contains("\"object\":\"list\""))
        XCTAssertTrue(text.contains("test-model"))
    }

    func testModelsUnconfiguredIs503() async {
        let data = await LocalAPIServer.route(request: request("GET", "/v1/models")) { nil }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("503"))
    }

    func testUnknownPathAndWrongMethod() async {
        let notFound = await LocalAPIServer.route(request: request("GET", "/nope")) { Self.profile }
        XCTAssertTrue(String(decoding: notFound, as: UTF8.self).contains("404"))
        let wrongMethod = await LocalAPIServer.route(request: request("DELETE", "/v1/models")) { Self.profile }
        XCTAssertTrue(String(decoding: wrongMethod, as: UTF8.self).contains("405"))
    }

    func testCompletionUnconfiguredIs503() async {
        let body = Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let data = await LocalAPIServer.route(request: request("POST", "/v1/chat/completions", body: body)) { nil }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("503"))
    }

    func testBadBodyIs400() async {
        let data = await LocalAPIServer.route(request: request("POST", "/v1/chat/completions", body: Data("not json".utf8))) { Self.profile }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("400"))
    }

    /// A completion against an unreachable server must fail cleanly (502),
    /// not hang or crash — the profile points at port 1 on loopback.
    func testCompletionErrorIs502() async {
        let body = Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        let data = await LocalAPIServer.route(request: request("POST", "/v1/chat/completions", body: body)) { Self.profile }
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("502"))
    }

    func testSplitHTTPBuffersUntilComplete() {
        let full = Data("POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi".utf8)
        XCTAssertNil(LocalAPIServer.splitHTTP(full.prefix(20)))   // headers incomplete
        let split = LocalAPIServer.splitHTTP(full)
        XCTAssertNotNil(split)
    }

    // MARK: Live socket

    func testServerBindsLoopbackAndAnswers() async throws {
        let profile = Self.profile
        let server = LocalAPIServer(port: 0) { profile }
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.boundPort)
        // /health over a real socket.
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["status"] as? String, "ok")
        XCTAssertEqual(body["model"] as? String, "test-model")
    }
}
