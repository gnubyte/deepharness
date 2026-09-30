import XCTest
@testable import DSHCore

/// SigV4 signatures checked against botocore 1.43.104 (SigV4Auth / SigV4QueryAuth with the clock
/// frozen at 2026-09-29T12:34:56Z and the credentials below). The expected values were printed by a
/// reference script run once; nothing here needs Python.
final class SigV4Tests: XCTestCase {
    static let now = ISO8601DateFormatter().date(from: "2026-09-29T12:34:56Z")!
    static let key = "AKIDEXAMPLE"
    static let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    static let token = "FwoGZXIvYXdzEXAMPLE//+TOKEN=="
    static let withToken = AWSCredentials(accessKeyID: key, secretAccessKey: secret, sessionToken: token)
    static let noToken = AWSCredentials(accessKeyID: key, secretAccessKey: secret)

    static let modelID = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
    static let profileARN = "arn:aws:bedrock:us-west-2:123456789012:inference-profile/us.anthropic.claude-opus-4-1-20250805-v1:0"
    private static let body = Data(#"{"messages":[{"role":"user","content":[{"text":"hi"}]}]}"#.utf8)

    private func post(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = Self.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func testModelIDsAreEncodedLikeBotocoreEncodesThePathParameter() {
        XCTAssertEqual(SigV4.encode(Self.modelID), "us.anthropic.claude-sonnet-4-5-20250929-v1%3A0")
        XCTAssertEqual(SigV4.encode(Self.profileARN),
                       "arn%3Aaws%3Abedrock%3Aus-west-2%3A123456789012%3Ainference-profile%2Fus.anthropic.claude-opus-4-1-20250805-v1%3A0")
        XCTAssertEqual(SigV4.encode("abc+def/ghi= xé~"), "abc%2Bdef%2Fghi%3D%20x%C3%A9~")
    }

    func testConverseStreamWithSessionTokenMatchesBotocore() throws {
        var request = post("https://bedrock-runtime.us-east-1.amazonaws.com/model/\(SigV4.encode(Self.modelID))/converse-stream")
        try SigV4.sign(&request, body: Self.body, credentials: Self.withToken, region: "us-east-1", service: "bedrock", now: Self.now)

        // The URL keeps the encoded ':' on the wire.
        XCTAssertEqual(request.url!.absoluteString,
                       "https://bedrock-runtime.us-east-1.amazonaws.com/model/us.anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Date"), "20260929T123456Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Security-Token"), Self.token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260929/us-east-1/bedrock/aws4_request, "
                       + "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, "
                       + "Signature=2e93ac76b3d7dcfcd749068ad7e6548106763d0842edfed57350e2a2e0fe5b60")
    }

    func testCanonicalRequestDoublyEncodesThePath() {
        let url = URL(string: "https://bedrock-runtime.us-east-1.amazonaws.com/model/\(SigV4.encode(Self.modelID))/converse-stream")!
        let headers = [
            "content-type": "application/json",
            "host": "bedrock-runtime.us-east-1.amazonaws.com",
            "x-amz-date": "20260929T123456Z",
            "x-amz-security-token": Self.token,
        ]
        let canonical = SigV4.canonicalRequest(
            method: "POST", url: url, canonicalQuery: "", headers: headers,
            payloadHash: "c3335e07d6e89650bf94cb98664be69f8774dbc3198df221f113db0a59ea14f0")
        XCTAssertEqual(canonical,
                       "POST\n"
                       + "/model/us.anthropic.claude-sonnet-4-5-20250929-v1%253A0/converse-stream\n"
                       + "\n"
                       + "content-type:application/json\n"
                       + "host:bedrock-runtime.us-east-1.amazonaws.com\n"
                       + "x-amz-date:20260929T123456Z\n"
                       + "x-amz-security-token:FwoGZXIvYXdzEXAMPLE//+TOKEN==\n"
                       + "\n"
                       + "content-type;host;x-amz-date;x-amz-security-token\n"
                       + "c3335e07d6e89650bf94cb98664be69f8774dbc3198df221f113db0a59ea14f0")
    }

    func testInferenceProfileARNWithoutTokenMatchesBotocore() throws {
        var request = post("https://bedrock-runtime.us-west-2.amazonaws.com/model/\(SigV4.encode(Self.profileARN))/converse-stream")
        try SigV4.sign(&request, body: Self.body, credentials: Self.noToken, region: "us-west-2", service: "bedrock", now: Self.now)

        XCTAssertTrue(request.url!.absoluteString.contains("arn%3Aaws%3Abedrock%3Aus-west-2%3A123456789012%3Ainference-profile%2Fus.anthropic"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Amz-Security-Token"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260929/us-west-2/bedrock/aws4_request, "
                       + "SignedHeaders=content-type;host;x-amz-date, "
                       + "Signature=e6b4fe45fead2b5035469cf75d461f65bbc8faff141304b54cf936bd8794875e")
    }

    func testGetWithQueryMatchesBotocore() throws {
        var request = URLRequest(url: URL(string: "https://bedrock.us-east-1.amazonaws.com/foundation-models?byOutputModality=TEXT")!)
        try SigV4.sign(&request, body: Data(), credentials: Self.withToken, region: "us-east-1", service: "bedrock", now: Self.now)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260929/us-east-1/bedrock/aws4_request, "
                       + "SignedHeaders=host;x-amz-date;x-amz-security-token, "
                       + "Signature=59f7d182d2a9b1997881516e65ef9d1677434f925edd898cc3884acffaa467f8")
    }

    func testEncodedPaginationTokenMatchesBotocore() throws {
        var request = URLRequest(url: URL(string:
            "https://bedrock.eu-central-1.amazonaws.com/inference-profiles?maxResults=1000&nextToken=" + SigV4.encode("abc+def/ghi= x"))!)
        try SigV4.sign(&request, body: Data(), credentials: Self.noToken, region: "eu-central-1", service: "bedrock", now: Self.now)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260929/eu-central-1/bedrock/aws4_request, "
                       + "SignedHeaders=host;x-amz-date, "
                       + "Signature=fdad7d3772854acef01ccb3e517a3e88afc5768e8e5d44330151cd16eba26f32")
    }

    func testSigningAgainReplacesTheEarlierSignature() throws {
        var request = post("https://bedrock-runtime.us-east-1.amazonaws.com/model/\(SigV4.encode(Self.modelID))/converse-stream")
        try SigV4.sign(&request, body: Self.body,
                       credentials: AWSCredentials(accessKeyID: "OLDKEY", secretAccessKey: "old", sessionToken: "old-token"),
                       region: "us-east-1", service: "bedrock", now: Self.now.addingTimeInterval(-180))
        try SigV4.sign(&request, body: Self.body, credentials: Self.withToken, region: "us-east-1", service: "bedrock", now: Self.now)
        let names = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        XCTAssertEqual(names.filter { $0 == "x-amz-date" }.count, 1)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Security-Token"), Self.token)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!
            .hasSuffix("Signature=2e93ac76b3d7dcfcd749068ad7e6548106763d0842edfed57350e2a2e0fe5b60"))
    }

    func testContentSHA256HeaderIsSentAndSigned() throws {
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        try SigV4.sign(&request, body: Data(), credentials: Self.noToken, region: "us-east-1", service: "s3",
                       now: Self.now, contentSHA256: true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Content-SHA256"), SigV4.emptyPayloadHash)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!
            .contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date,"))
    }

    func testCanonicalPathDropsDotAndEmptySegments() {
        XCTAssertEqual(SigV4.canonicalPath(""), "/")
        XCTAssertEqual(SigV4.canonicalPath("/"), "/")
        XCTAssertEqual(SigV4.canonicalPath("/a/./b/../c//d/"), "/a/c/d/")
        XCTAssertEqual(SigV4.canonicalPath("/model/x%3A0"), "/model/x%253A0")
    }

    func testQueryIsSortedByEncodedKeyThenValue() {
        XCTAssertEqual(SigV4.canonicalQuery(SigV4.parameters(of: URL(string: "https://h/?c=&b=x%20y&a=2&a=1")!)),
                       "a=1&a=2&b=x%20y&c=")
    }

    func testAPortInTheURLIsSignedUnlessItIsTheDefault() throws {
        var custom = URLRequest(url: URL(string: "https://vpce.example.com:8443/x")!)
        try SigV4.sign(&custom, body: Data(), credentials: Self.noToken, region: "us-east-1", service: "bedrock", now: Self.now)
        XCTAssertEqual(SigV4.host(of: custom.url!), "vpce.example.com:8443")
        XCTAssertEqual(SigV4.host(of: URL(string: "https://Example.COM:443/x")!), "example.com")
        XCTAssertEqual(SigV4.host(of: URL(string: "http://example.com:80/")!), "example.com")
    }

    func testPresignMatchesBotocoreQueryAuth() throws {
        let url = try SigV4.presign(method: "POST", url: URL(string: "https://bedrock.amazonaws.com/?Action=CallWithBearerToken")!,
                                    credentials: Self.withToken, region: "us-east-1", service: "bedrock",
                                    now: Self.now, expires: 3600)
        XCTAssertEqual(url,
                       "https://bedrock.amazonaws.com/?Action=CallWithBearerToken&X-Amz-Algorithm=AWS4-HMAC-SHA256"
                       + "&X-Amz-Credential=AKIDEXAMPLE%2F20260929%2Fus-east-1%2Fbedrock%2Faws4_request&X-Amz-Date=20260929T123456Z"
                       + "&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Security-Token=FwoGZXIvYXdzEXAMPLE%2F%2F%2BTOKEN%3D%3D"
                       + "&X-Amz-Signature=ddd1bdf5b4306eac24b3f78c7fc8ba4f36ecb181f8ea31d4f0b44a6076dfab0c")
    }

    func testPresignRefusesImpossibleLifetimes() {
        let url = URL(string: "https://bedrock.amazonaws.com/")!
        XCTAssertThrowsError(try SigV4.presign(method: "GET", url: url, credentials: Self.noToken, region: "us-east-1",
                                               service: "bedrock", now: Self.now, expires: 0))
        XCTAssertThrowsError(try SigV4.presign(method: "GET", url: url, credentials: Self.noToken, region: "us-east-1",
                                               service: "bedrock", now: Self.now, expires: 8 * 24 * 3600))
    }
}
