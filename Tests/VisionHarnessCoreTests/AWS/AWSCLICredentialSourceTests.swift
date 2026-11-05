import XCTest
@testable import VisionHarnessCore

/// `aws configure export-credentials --format process` output (the shape AWS CLI 2.37.5 prints).
private func awsProcessOutput(_ keyID: String, expires: Date?, token: String? = "IQoJb3JpZ2luX2VjEXAMPLE") -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    var text = "{\n  \"Version\": 1,\n  \"AccessKeyId\": \"\(keyID)\",\n  \"SecretAccessKey\": \"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\""
    if let token { text += ",\n  \"SessionToken\": \"\(token)\"" }
    if let expires { text += ",\n  \"Expiration\": \"\(formatter.string(from: expires)).000000+00:00\"" }
    return text + "\n}\n"
}

private func awsUTC(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

final class AWSCLICredentialSourceTests: XCTestCase {
    private let now = AWSTestClock.epoch

    func testParsesWhatTheCliPrints() throws {
        // Verbatim from a real CLI (credential_process profile).
        let real = try AWSCLICredentialSource.parseProcessOutput("""
            {
              "Version": 1,
              "AccessKeyId": "ASIAPROC",
              "SecretAccessKey": "sec",
              "SessionToken": "tok",
              "Expiration": "2026-09-29T19:55:23.728587+00:00"
            }
            """)
        XCTAssertEqual(real.accessKeyID, "ASIAPROC")
        XCTAssertEqual(real.secretAccessKey, "sec")
        XCTAssertEqual(real.sessionToken, "tok")
        XCTAssertEqual(try XCTUnwrap(real.expiration).timeIntervalSince1970, awsUTC("2026-09-29T19:55:23Z").timeIntervalSince1970 + 0.728587, accuracy: 0.000_01)

        let keys = try AWSCLICredentialSource.parseProcessOutput(#"{"Version": 1, "AccessKeyId": "AKIAEXAMPLE", "SecretAccessKey": "secretexample"}"#)
        XCTAssertNil(keys.sessionToken)
        XCTAssertNil(keys.expiration)

        let zulu = try AWSCLICredentialSource.parseProcessOutput(#"{"AccessKeyId":"A","SecretAccessKey":"S","Expiration":"2026-09-29T20:00:00Z"}"#)
        XCTAssertEqual(zulu.expiration, awsUTC("2026-09-29T20:00:00Z"))
    }

    func testReadsTheOtherWaysADateCanBeWritten() throws {
        let cases: [(text: String, seconds: TimeInterval)] = [
            ("2026-09-29T20:00:00+00:00", 0),
            ("2026-09-29T22:00:00+02:00", 0),
            ("2026-09-29T22:00:00+0200", 0),
            ("2026-09-29T22:00:00+02", 0),
            ("2026-09-29T15:30:00-04:30", 0),
            ("2026-09-29T20:00:00", 0),
            ("2026-09-29 20:00:00Z", 0),
            ("2026-09-29T20:00:00z", 0),
            ("2026-09-29T20:00:00.5Z", 0.5),
            ("2026-09-29T20:00:00.123456789Z", 0.123456789),
            ("  2026-09-29T20:00:00Z\n", 0),
        ]
        for (text, seconds) in cases {
            let parsed = try XCTUnwrap(AWSCLICredentialSource.parseTimestamp(text), text)
            XCTAssertEqual(parsed.timeIntervalSince1970, awsUTC("2026-09-29T20:00:00Z").timeIntervalSince1970 + seconds, accuracy: 0.000_001, text)
        }
        for bad in ["", "soon", "2026-09-29", "2026-13-40T00:00:00Z", "2026-02-30T00:00:00Z", "2026-09-29T25:00:00Z",
                    "2026-09-29T20:00:00+25:00", "2026-09-29T20:00:00+02:99", "1790711723", "2026-09-29T20:00:00 UTC"] {
            XCTAssertNil(AWSCLICredentialSource.parseTimestamp(bad), bad)
        }
    }

    func testUnusableOutputIsReported() {
        for bad in ["{}", "not json", "[]", "", "null", #"{"AccessKeyId":"A"}"#, #"{"AccessKeyId":"","SecretAccessKey":"S"}"#,
                    #"{"AccessKeyId":1,"SecretAccessKey":2}"#] {
            XCTAssertThrowsError(try AWSCLICredentialSource.parseProcessOutput(bad, profile: "vision-bedrock"), bad) { error in
                guard let signIn = error as? AWSSignInRequiredError else { return XCTFail("\(error)") }
                XCTAssertEqual(signIn.profile, "vision-bedrock")
            }
        }
        XCTAssertThrowsError(try AWSCLICredentialSource.parseProcessOutput("{}")) { XCTAssertEqual(($0 as? AWSSignInRequiredError)?.profile, "default") }
        XCTAssertThrowsError(try AWSCLICredentialSource.parseProcessOutput(#"{"AccessKeyId":"A","SecretAccessKey":"S","Expiration":"soon"}"#)) { error in
            guard let failure = error as? AWSCLIException else { return XCTFail("\(error)") }
            XCTAssertEqual(failure.kind, .other)
            XCTAssertTrue(failure.localizedDescription.contains("(soon)"))
        }
        // An empty token is no token.
        XCTAssertNil(try AWSCLICredentialSource.parseProcessOutput(#"{"AccessKeyId":"A","SecretAccessKey":"S","SessionToken":""}"#).sessionToken)
    }

    func testRunsExportCredentialsForTheProfile() async throws {
        let runner = FakeAWSCLIRunner().on(["configure", "export-credentials"], stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(3600)))
        let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock", now: AWSTestClock().reader)
        let credentials = try await source.credentials(forceRefresh: false)
        XCTAssertEqual(credentials.accessKeyID, "ASIA1")
        XCTAssertEqual(runner.calls[0].args, ["configure", "export-credentials", "--format", "process", "--profile", "vision-bedrock"])
        XCTAssertEqual(runner.calls[0].options.timeout, 120)
        XCTAssertEqual(AWSCLICredentialSource(runner: runner, profile: "p", region: "eu-central-1").exportArguments,
                       ["configure", "export-credentials", "--format", "process", "--profile", "p", "--region", "eu-central-1"])
    }

    func testCachesUntilFiveMinutesBeforeExpiry() async throws {
        let clock = AWSTestClock()
        let runner = FakeAWSCLIRunner().onSequence(["configure", "export-credentials"], [
            AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(60 * 60))),
            AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA2", expires: now.addingTimeInterval(120 * 60))),
        ])
        let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock", now: clock.reader)

        var first = try await source.credentials()
        XCTAssertEqual(first.accessKeyID, "ASIA1")
        clock.advance(by: 54 * 60)
        first = try await source.credentials()
        XCTAssertEqual(first.accessKeyID, "ASIA1", "6 minutes left: still cached")
        XCTAssertEqual(runner.calls.count, 1)
        clock.advance(by: 90)
        let second = try await source.credentials()
        XCTAssertEqual(second.accessKeyID, "ASIA2", "4.5 minutes left: fetched again")
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testTheMarginAndTheTimeoutCanBeChosen() async throws {
        let clock = AWSTestClock()
        let runner = FakeAWSCLIRunner().onSequence(["configure", "export-credentials"], [
            AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(120))),
            AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA2", expires: now.addingTimeInterval(7200))),
        ])
        let source = AWSCLICredentialSource(runner: runner, profile: "p", refreshMargin: 60, timeout: 30, now: clock.reader)
        let first = try await source.credentials()
        XCTAssertEqual(first.accessKeyID, "ASIA1")
        XCTAssertEqual(runner.calls[0].options.timeout, 30)
        clock.advance(by: 50) // 70 seconds left, margin 60
        let stillFirst = try await source.credentials()
        XCTAssertEqual(stillFirst.accessKeyID, "ASIA1")
        clock.advance(by: 20) // 50 seconds left
        let next = try await source.credentials()
        XCTAssertEqual(next.accessKeyID, "ASIA2")
        XCTAssertEqual(source.refreshMargin, 60)
        XCTAssertEqual(source.timeout, 30)
    }

    func testForceRefreshAndInvalidateFetchAgain() async throws {
        let runner = FakeAWSCLIRunner().onSequence(["configure", "export-credentials"], [
            AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(3600))),
            AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA2", expires: now.addingTimeInterval(3600))),
            AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA3", expires: now.addingTimeInterval(3600))),
        ])
        let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock", now: AWSTestClock().reader)
        let first = try await source.credentials()
        XCTAssertEqual(first.accessKeyID, "ASIA1")
        let forced = try await source.credentials(forceRefresh: true)
        XCTAssertEqual(forced.accessKeyID, "ASIA2")
        let cached = try await source.credentials()
        XCTAssertEqual(cached.accessKeyID, "ASIA2")
        source.invalidate()
        let afterInvalidate = try await source.credentials()
        XCTAssertEqual(afterInvalidate.accessKeyID, "ASIA3")
    }

    func testLongTermKeysStayCached() async throws {
        let clock = AWSTestClock()
        let runner = FakeAWSCLIRunner().on(["configure", "export-credentials"], stdout: awsProcessOutput("AKIA", expires: nil, token: nil))
        let source = AWSCLICredentialSource(runner: runner, profile: "keys", now: clock.reader)
        _ = try await source.credentials()
        clock.advance(by: 30 * 24 * 3600)
        _ = try await source.credentials()
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testExpiredSignInsAskToSignInAgain() async {
        // Real CLI messages for an `aws login` session that is gone, an SSO token that expired, and a missing profile.
        let cases: [(stderr: String, exitCode: Int)] = [
            ("aws: [ERROR]: Unable to retrieve credentials: Error loading login session token: Unable to load a existing login session for session arn:aws:iam::111122223333:user/alice, Please reauthenticate with 'aws login'.", 253),
            ("aws: [ERROR]: Unable to retrieve credentials: Your session has expired. Please reauthenticate using 'aws login'.", 253),
            ("aws: [ERROR]: Error loading SSO Token: Token for corp does not exist", 255),
            ("aws: [ERROR]: The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile.", 255),
            ("aws: [ERROR]: Unable to retrieve credentials: The config profile (vision-bedrock) could not be found", 253),
        ]
        for (stderr, exitCode) in cases {
            let runner = FakeAWSCLIRunner().fail(["configure", "export-credentials"], stderr: stderr, exitCode: exitCode)
            let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock")
            let signIn = await awsAssertThrows(AWSSignInRequiredError.self) { _ = try await source.credentials(forceRefresh: false) }
            XCTAssertEqual(signIn?.profile, "vision-bedrock", stderr)
            XCTAssertFalse(signIn?.message.contains("aws: [ERROR]") ?? true, stderr)
        }
    }

    func testOtherFailuresAreNotSignInProblemsAndArentCached() async throws {
        let runner = FakeAWSCLIRunner().onSequence(["configure", "export-credentials"], [
            AWSCLIResult(exitCode: 255, stdout: "", stderr: "\naws: [ERROR]: Could not connect to the endpoint URL: \"https://us-east-1.signin.aws.amazon.com/v1/token\"\n"),
            AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(3600))),
        ])
        let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock", now: AWSTestClock().reader)
        let failure = await awsAssertThrows(AWSCLIException.self) { _ = try await source.credentials() }
        XCTAssertEqual(failure?.kind, .network)
        let recovered = try await source.credentials()
        XCTAssertEqual(recovered.accessKeyID, "ASIA1")
    }

    func testAnExportThatPrintsNothingUsableIsASignInProblem() async {
        let runner = FakeAWSCLIRunner().on(["configure", "export-credentials"], stdout: "no credentials here")
        let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock")
        let signIn = await awsAssertThrows(AWSSignInRequiredError.self) { _ = try await source.credentials() }
        XCTAssertEqual(signIn?.profile, "vision-bedrock")
    }

    func testAProgramThatCantStartFailsTheCallAndThenTriesAgain() async throws {
        let tries = AWSLockedBox(0)
        let runner = FakeAWSCLIRunner().on(["configure", "export-credentials"]) { [now] _ in
            let attempt = tries.mutate { value -> Int in value += 1; return value }
            if attempt == 1 { throw AWSCLIStartError(executable: "/x/aws", reason: "the file doesn't exist.") }
            return AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(3600)))
        }
        let source = AWSCLICredentialSource(runner: runner, profile: "p", now: AWSTestClock().reader)
        let failure = await awsAssertThrows(AWSCLIStartError.self) { _ = try await source.credentials() }
        XCTAssertEqual(failure?.executable, "/x/aws")
        let credentials = try await source.credentials()
        XCTAssertEqual(credentials.accessKeyID, "ASIA1")
    }

    func testConcurrentCallersShareOneExport() async throws {
        let release = AWSCLIGate()
        let runner = FakeAWSCLIRunner().on(["configure", "export-credentials"]) { [now] _ in
            await release.wait()
            return AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(3600)))
        }
        let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock", now: AWSTestClock().reader)
        let callers = (0..<8).map { index in Task { try await source.credentials(forceRefresh: index % 2 == 0) } }
        // One who gives up before it has even started waiting, and one who gives up while waiting.
        let early = Task { try await source.credentials() }
        early.cancel()
        await awsExpectCancelled(early)
        await awsWaitUntil(5, "the export to start") { runner.calls.count == 1 }
        let impatient = Task { try await source.credentials() }
        try await Task.sleep(nanoseconds: 100_000_000)
        impatient.cancel()
        await awsExpectCancelled(impatient)

        release.open()
        var keys: [String] = []
        for caller in callers {
            guard let outcome = await awsOutcome(of: caller) else { continue }
            keys.append(try outcome.get().accessKeyID)
        }
        XCTAssertEqual(keys, Array(repeating: "ASIA1", count: 8))
        XCTAssertEqual(runner.calls.count, 1)
        let afterwards = try await source.credentials()
        XCTAssertEqual(afterwards.accessKeyID, "ASIA1")
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testAWaiterWhoLeavesMidExportDoesntStopItForTheOthers() async throws {
        let release = AWSCLIGate()
        let runner = FakeAWSCLIRunner().on(["configure", "export-credentials"]) { [now] _ in
            await release.wait()
            return AWSCLIResult(exitCode: 0, stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(3600)))
        }
        let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock", now: AWSTestClock().reader)
        let starter = Task { try await source.credentials() }
        await awsWaitUntil(5, "the export to start") { runner.calls.count == 1 }
        let staying = Task { try await source.credentials() }
        try await Task.sleep(nanoseconds: 100_000_000)
        starter.cancel() // the caller that started the export walks away
        await awsExpectCancelled(starter)
        release.open()
        guard let outcome = await awsOutcome(of: staying) else { return }
        XCTAssertEqual(try outcome.get().accessKeyID, "ASIA1")
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testEveryWaiterOfAFailedExportGetsTheFailure() async throws {
        let release = AWSCLIGate()
        let runner = FakeAWSCLIRunner().on(["configure", "export-credentials"]) { _ in
            await release.wait()
            return AWSCLIResult(exitCode: 253, stdout: "", stderr: "aws: [ERROR]: Your session has expired. Please reauthenticate using 'aws login'.")
        }
        let source = AWSCLICredentialSource(runner: runner, profile: "vision-bedrock")
        let callers = (0..<3).map { _ in Task { try await source.credentials() } }
        await awsWaitUntil(5, "the export to start") { runner.calls.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        release.open()
        for caller in callers {
            guard let outcome = await awsOutcome(of: caller) else { continue }
            guard case .failure(let error) = outcome, let signIn = error as? AWSSignInRequiredError else {
                XCTFail("expected a sign-in request, got \(outcome)")
                continue
            }
            XCTAssertEqual(signIn.profile, "vision-bedrock")
        }
        XCTAssertEqual(runner.calls.count, 1)
    }

    func testABlankProfileMeansTheDefaultProfile() {
        let source = AWSCLICredentialSource(runner: FakeAWSCLIRunner(), profile: "  ")
        XCTAssertEqual(source.profile, "default")
        XCTAssertEqual(source.exportArguments, ["configure", "export-credentials", "--format", "process", "--profile", "default"])
    }

    func testItIsTheBedrockClientsCredentialSource() async throws {
        let source: any AWSCredentialSource = AWSCLICredentialSource(
            runner: FakeAWSCLIRunner().on(["configure", "export-credentials"], stdout: awsProcessOutput("ASIA1", expires: now.addingTimeInterval(3600))),
            profile: "vision-bedrock", now: AWSTestClock().reader)
        let credentials = try await source.credentials(forceRefresh: false)
        XCTAssertFalse(credentials.description.contains("wJalr"), "the secret must never be printed")
        XCTAssertEqual(credentials.expiration, now.addingTimeInterval(3600))
    }

    func testAnExportThroughARealProcess() async throws {
        let dir = awsScratch()
        let aws = dir.write("aws", """
            #!/bin/sh
            case "$*" in
              "configure export-credentials --format process --profile vision-bedrock --region eu-central-1")
                echo '{"Version": 1, "AccessKeyId": "ASIAREAL", "SecretAccessKey": "real-secret", "SessionToken": "real-token", "Expiration": "2099-01-01T00:00:00+00:00"}' ;;
              *) echo "unexpected: $*" >&2; exit 254 ;;
            esac
            """, executable: true)
        let source = AWSCLICredentialSource(cli: AWSCLI.forPath(aws), profile: "vision-bedrock", region: "eu-central-1")
        let credentials = try await source.credentials()
        XCTAssertEqual(credentials.accessKeyID, "ASIAREAL")
        XCTAssertEqual(credentials.sessionToken, "real-token")
        XCTAssertEqual(credentials.expiration, awsUTC("2099-01-01T00:00:00Z"))
    }
}
