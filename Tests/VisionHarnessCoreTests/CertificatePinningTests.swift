import XCTest
@testable import VisionHarnessCore

/// A route to a self-signed box (a Spark Swapper's model front on :11443) is trusted by its certificate's
/// fingerprint; everything else still needs the system's trust.
final class CertificatePinningTests: XCTestCase {
    private let pin = (1...32).map { String(format: "%02X", $0) }.joined(separator: ":")
    private let other = (1...32).map { String(format: "%02X", 200 - $0) }.joined(separator: ":")

    override func tearDown() {
        OpenAIClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        super.tearDown()
    }

    // MARK: Fingerprints

    func testFingerprintsAreComparedWhateverTheirCaseOrColons() {
        XCTAssertEqual(CertificatePin.normalized(pin.lowercased()), pin)
        XCTAssertEqual(CertificatePin.normalized(pin.replacingOccurrences(of: ":", with: "")), pin)
        XCTAssertEqual(CertificatePin.normalized("  \(pin)\n"), pin)
        XCTAssertTrue(CertificatePin.matches(pin.lowercased(), pin))
        XCTAssertFalse(CertificatePin.matches(pin, other))
        XCTAssertFalse(CertificatePin.matches(pin, nil))
    }

    func testSomethingThatIsNotThirtyTwoHexPairsIsNotAFingerprint() {
        XCTAssertNil(CertificatePin.normalized("3A:9F"))
        XCTAssertNil(CertificatePin.normalized(String(pin.dropLast(3))))
        XCTAssertNil(CertificatePin.normalized(pin.replacingOccurrences(of: "0", with: "G")))
        XCTAssertNil(CertificatePin.normalized(""))
    }

    func testTheFingerprintIsTheSHA256OfTheCertificateInOpensslsSpelling() {
        let fp = CertificatePin.fingerprint(der: Data("certificate".utf8))
        XCTAssertEqual(fp.count, 95)
        XCTAssertEqual(fp, fp.uppercased())
        XCTAssertEqual(fp.split(separator: ":").count, 32)
        XCTAssertTrue(CertificatePin.short(fp).contains(":…:"))
    }

    // MARK: The decision

    func testSystemTrustIsEnoughWithOrWithoutAPin() {
        XCTAssertEqual(PinningDelegate.decide(fingerprint: other, pinned: pin, mode: .systemThenPin) { true }, .accept)
        XCTAssertEqual(PinningDelegate.decide(fingerprint: other, pinned: nil, mode: .systemThenPin) { true }, .accept)
    }

    func testAnUntrustedCertificateIsAcceptedOnlyWhenItIsThePin() {
        XCTAssertEqual(PinningDelegate.decide(fingerprint: pin, pinned: pin.lowercased(), mode: .systemThenPin) { false }, .accept)
        XCTAssertEqual(PinningDelegate.decide(fingerprint: other, pinned: pin, mode: .systemThenPin) { false }, .systemDecides,
                       "the system's own refusal: a certificate error, not a cancelled request that would be retried")
        XCTAssertEqual(PinningDelegate.decide(fingerprint: other, pinned: nil, mode: .systemThenPin) { false }, .systemDecides)
    }

    func testCheckingAConnectionCodeTrustsOnlyTheCodesCertificate() {
        var asked = false
        XCTAssertEqual(PinningDelegate.decide(fingerprint: pin, pinned: pin, mode: .pinOnly) { asked = true; return false }, .accept)
        XCTAssertEqual(PinningDelegate.decide(fingerprint: other, pinned: pin, mode: .pinOnly) { asked = true; return true }, .refuse,
                       "a certificate the system trusts is still refused when it isn't the one the code names")
        XCTAssertFalse(asked, "system trust isn't consulted for the check")
    }

    // MARK: The client

    func testAPinnedRouteGetsItsOwnSessionAndEqualPinsShareOne() {
        OpenAIClient.protocolClassesForTesting = [StubServer.self]
        let before = OpenAIClient.sessionCount
        let route = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "https://spark.local:11443/v1", model: "m")
        _ = OpenAIClient(profile: route)
        var pinned = route
        pinned.pinnedCertificate = pin
        _ = OpenAIClient(profile: pinned)
        pinned.pinnedCertificate = pin.lowercased()
        _ = OpenAIClient(profile: pinned)
        _ = OpenAIClient(profile: pinned)
        XCTAssertLessThanOrEqual(OpenAIClient.sessionCount - before, 2, "one session per pin, not per client")
    }

    func testEveryRequestNamesThisApp() async throws {
        OpenAIClient.protocolClassesForTesting = [StubServer.self]
        let agents = HeaderLog()
        StubServer.reset { request in
            agents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "")
            if request.url?.path.hasSuffix("/models") == true {
                return .init(body: #"{"data":[{"id":"m"}]}"#, contentType: "application/json")
            }
            return .init(body: StubServer.sse("hi"))
        }
        let client = OpenAIClient(profile: .init(kind: .openAI, name: "Kimi", baseURL: "https://api.kimi.ai/coding/v1",
                                                 apiKey: "k", model: "kimi-for-coding"))
        _ = try await client.listModels()
        for try await _ in client.stream(LLMRequest(systemPrompt: "", messages: [.user("hi")], tools: [], model: "m")) {}
        XCTAssertEqual(agents.items.count, 2)
        for agent in agents.items {
            XCTAssertTrue(agent.hasPrefix("Vision/"), agent)
            XCTAssertTrue(agent.hasSuffix("(macOS)"), agent)
        }
    }

    func testAnUntrustedCertificateIsAPlainWordsErrorThatIsNotRetried() {
        let error = LLMError.rejected(status: OpenAIClient.untrustedCertificateStatus,
                                      message: "The server's certificate isn't trusted (SHA-256 \(pin)).",
                                      body: "certificate not trusted", permanent: true)
        XCTAssertEqual(RequestRetry.disposition(for: error), .fail)
        XCTAssertTrue(AgentFleet.isServerFault(error), "another server may well be trusted")
        XCTAssertTrue(error.errorDescription?.hasPrefix("The server's certificate isn't trusted (SHA-256 ") == true)
    }

    func testOnlyACertificateThatWasTurnedDownMakesAFailedConnectionACertificateError() throws {
        let dropped = URLError(.secureConnectionFailed)
        let trust = PinningDelegate(pinned: nil)
        // The system trusted the host's certificate: a failed TLS connection later is just a failed connection.
        trust.note(host: "api.example.com", fingerprint: pin, systemTrusted: true, decision: .accept)
        XCTAssertTrue(OpenAIClient.certificateError(dropped, host: "api.example.com", trust: trust) is URLError,
                      "left as it is, so it is retried")
        // It didn't, and no pin vouched for it: a certificate error that isn't retried.
        trust.note(host: "spark.local", fingerprint: other, systemTrusted: false, decision: .systemDecides)
        let refused = try XCTUnwrap(OpenAIClient.certificateError(dropped, host: "spark.local", trust: trust) as? LLMError)
        XCTAssertEqual(refused.errorDescription, "The server's certificate isn't trusted (SHA-256 \(other)).")
        XCTAssertEqual(RequestRetry.disposition(for: refused), .fail)
        XCTAssertTrue(OpenAIClient.certificateError(URLError(.timedOut), host: "spark.local", trust: trust) is URLError)
        // The pin vouched for it: a failure afterwards is a connection problem again.
        let pinned = PinningDelegate(pinned: pin)
        pinned.note(host: "spark.local", fingerprint: pin, systemTrusted: false, decision: .accept)
        XCTAssertTrue(OpenAIClient.certificateError(dropped, host: "spark.local", trust: pinned) is URLError)
    }

    func testOlderSavedRoutesDecodeWithoutAPin() throws {
        let json = #"{"kind":"openAICompat","name":"Spark","baseURL":"http://spark.local:8002/v1","model":"qwen"}"#
        let route = try JSONDecoder().decode(ProviderProfile.self, from: Data(json.utf8))
        XCTAssertNil(route.pinnedCertificate)
        var pinned = route
        pinned.pinnedCertificate = pin
        let round = try JSONDecoder().decode(ProviderProfile.self, from: JSONEncoder().encode(pinned))
        XCTAssertEqual(round.pinnedCertificate, pin)
    }
}

/// Headers several requests report from different threads.
private final class HeaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var items: [String] { lock.withLock { values } }
}
