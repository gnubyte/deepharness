import XCTest
@testable import DSHCore

/// Short-term Bedrock API keys, checked against aws-bedrock-token-generator 1.1.0 (its
/// `_generate_token` with botocore's clock frozen at 2026-09-29T12:34:56Z and the SigV4Tests credentials).
final class BedrockAPIKeysTests: XCTestCase {
    /// provide_token(region="us-west-2", expiry=12 h) without a session token.
    private static let twelveHoursUsWest2 =
        "bedrock-api-key-YmVkcm9jay5hbWF6b25hd3MuY29tLz9BY3Rpb249Q2FsbFdpdGhCZWFyZXJUb2tlbiZYLUFtei1BbGdvcml0aG09QVdTNC1ITUFD"
        + "LVNIQTI1NiZYLUFtei1DcmVkZW50aWFsPUFLSURFWEFNUExFJTJGMjAyNjA5MjklMkZ1cy13ZXN0LTIlMkZiZWRyb2NrJTJGYXdzNF9yZXF1ZXN0JlgtQW16"
        + "LURhdGU9MjAyNjA5MjlUMTIzNDU2WiZYLUFtei1FeHBpcmVzPTQzMjAwJlgtQW16LVNpZ25lZEhlYWRlcnM9aG9zdCZYLUFtei1TaWduYXR1cmU9ZTE3YWFk"
        + "ZjI2ZjUyMjk0NTJkZmI4MjdkZWU5NWUxYjllNmM0ZGNhNDFiZTYxNzEzZThkODFjZDlkMmMzZmVjNiZWZXJzaW9uPTE="

    /// region="us-east-1", expiry=1 h, with a session token.
    private static let oneHourUsEast1WithToken =
        "bedrock-api-key-YmVkcm9jay5hbWF6b25hd3MuY29tLz9BY3Rpb249Q2FsbFdpdGhCZWFyZXJUb2tlbiZYLUFtei1BbGdvcml0aG09QVdTNC1ITUFD"
        + "LVNIQTI1NiZYLUFtei1DcmVkZW50aWFsPUFLSURFWEFNUExFJTJGMjAyNjA5MjklMkZ1cy1lYXN0LTElMkZiZWRyb2NrJTJGYXdzNF9yZXF1ZXN0JlgtQW16"
        + "LURhdGU9MjAyNjA5MjlUMTIzNDU2WiZYLUFtei1FeHBpcmVzPTM2MDAmWC1BbXotU2lnbmVkSGVhZGVycz1ob3N0JlgtQW16LVNlY3VyaXR5LVRva2VuPUZ3"
        + "b0daWEl2WVhkekVYQU1QTEUlMkYlMkYlMkJUT0tFTiUzRCUzRCZYLUFtei1TaWduYXR1cmU9ZGRkMWJkZjViNDMwNmVhYzI0YjNmNzhjN2ZjOGJhNGYzNmVj"
        + "YjE4MWY4ZWEzMWQ0ZjBiNDRhNjA3NmRmYWIwYyZWZXJzaW9uPTE="

    func testMatchesTheTokenGeneratorLibrary() throws {
        XCTAssertEqual(try BedrockAPIKeys.create(credentials: SigV4Tests.noToken, region: "us-west-2", now: SigV4Tests.now),
                       Self.twelveHoursUsWest2)
        XCTAssertEqual(try BedrockAPIKeys.create(credentials: SigV4Tests.withToken, region: "us-east-1",
                                                 now: SigV4Tests.now, lifetime: 3600),
                       Self.oneHourUsEast1WithToken)
    }

    func testDescribeReadsRegionAndExpiryBack() throws {
        let info = try XCTUnwrap(BedrockAPIKeys.describe(Self.twelveHoursUsWest2))
        XCTAssertEqual(info.region, "us-west-2")
        XCTAssertEqual(info.issued, SigV4Tests.now)
        XCTAssertEqual(info.expires, SigV4Tests.now.addingTimeInterval(12 * 3600))
        XCTAssertEqual(info.accessKeyID, SigV4Tests.key)
        XCTAssertEqual(BedrockAPIKeys.describe(Self.oneHourUsEast1WithToken)?.expires, SigV4Tests.now.addingTimeInterval(3600))
    }

    func testLifetimeIsCappedAtTwelveHoursAndTheCredentialsExpiry() throws {
        let longer = try BedrockAPIKeys.create(credentials: SigV4Tests.noToken, region: "us-west-2",
                                               now: SigV4Tests.now, lifetime: 24 * 3600)
        XCTAssertEqual(BedrockAPIKeys.describe(longer)?.expires, SigV4Tests.now.addingTimeInterval(12 * 3600))

        var shortLived = SigV4Tests.withToken
        shortLived.expiration = SigV4Tests.now.addingTimeInterval(30 * 60 + 0.5)
        let key = try BedrockAPIKeys.create(credentials: shortLived, region: "eu-central-1", now: SigV4Tests.now)
        XCTAssertEqual(BedrockAPIKeys.describe(key)?.expires, SigV4Tests.now.addingTimeInterval(30 * 60))
        XCTAssertEqual(BedrockAPIKeys.describe(key)?.region, "eu-central-1")
    }

    func testExpiredCredentialsCannotMintAKey() {
        var expired = SigV4Tests.withToken
        expired.expiration = SigV4Tests.now.addingTimeInterval(-1)
        XCTAssertThrowsError(try BedrockAPIKeys.create(credentials: expired, region: "us-east-1", now: SigV4Tests.now)) {
            XCTAssertTrue($0 is BedrockAPIKeys.Expired)
        }
    }

    func testOtherStringsAreNotDescribed() {
        XCTAssertNil(BedrockAPIKeys.describe("ABSKQmVkcm9ja0FQSUtleS1leGFtcGxl")) // a long-term key
        XCTAssertNil(BedrockAPIKeys.describe("bedrock-api-key-!!!"))
        XCTAssertNil(BedrockAPIKeys.describe("bedrock-api-key-aGVsbG8=")) // base64 of "hello"
    }
}
