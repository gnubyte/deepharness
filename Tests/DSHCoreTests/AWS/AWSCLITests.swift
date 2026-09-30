import XCTest
@testable import DSHCore

/// The AWS CLI layer without a process: versions, where the CLI is looked for, the checks on what it
/// prints, how its failures read.
final class AWSCLITests: XCTestCase {

    // MARK: Versions

    func testReadsTheVersion() {
        let cases: [(printed: String, expected: String)] = [
            ("aws-cli/2.33.4 Python/3.13.9 Windows/11 exe/AMD64", "2.33.4"),
            ("aws-cli/2.37.5 Python/3.11.15 Linux/6.18.44-fc-v49 source/x86_64.ubuntu.24\n", "2.37.5"), // real output
            ("aws-cli/2.32.0 Python/3.13.7 Windows/10 exe/AMD64 prompt/off", "2.32.0"),
            ("aws-cli/1.29.62 Python/3.11.4 Windows/10 botocore/1.31.62", "1.29.62"),
            ("\n\naws-cli/2.31.39 Python/3.13.7 Windows/11 exe/AMD64\n", "2.31.39"),
            ("aws-cli/2.17.30 Python/3.11.9 Darwin/23.5.0 exe/arm64", "2.17.30"), // the macOS package
        ]
        for (printed, expected) in cases {
            XCTAssertEqual(AWSCLI.parseVersion(printed), SemanticVersion(expected), printed)
        }
    }

    func testNoVersionInGarbage() {
        for printed in ["", "zsh: command not found: aws", "aws-cli/two", "aws-cli/2.33"] {
            XCTAssertNil(AWSCLI.parseVersion(printed), printed)
        }
    }

    func testAwsLoginNeeds2_32() {
        XCTAssertEqual(AWSCLI.minimumVersion, SemanticVersion(2, 32, 0))
        XCTAssertEqual(AWSCLI.minimumVersion.description, "2.32.0")
    }

    func testVersionsCompareByNumberNotByText() {
        XCTAssertLessThan(SemanticVersion(2, 9, 0), SemanticVersion(2, 32, 0))
        XCTAssertLessThan(SemanticVersion(1, 99, 99), SemanticVersion(2, 0, 0))
        XCTAssertLessThan(SemanticVersion(2, 32, 0), SemanticVersion(2, 32, 1))
        XCTAssertEqual(SemanticVersion("2.33.4"), SemanticVersion(2, 33, 4))
        XCTAssertEqual(SemanticVersion("2.33"), SemanticVersion(2, 33, 0))
        XCTAssertEqual(SemanticVersion(" 2.33.4\n")?.description, "2.33.4")
        for bad in ["", "2", "2.x.1", "2.33.4.1", "-2.1.0", "2..1", "2.1.٣"] { XCTAssertNil(SemanticVersion(bad), bad) }
        XCTAssertEqual(Set([SemanticVersion(2, 1, 0), SemanticVersion("2.1.0")!]).count, 1)
    }

    // MARK: Locating

    private func search(_ existing: [String], explicit: String? = nil, ignoreCase: Bool = false) -> AWSCLISearch {
        let present = Set(existing)
        return AWSCLISearch(explicitPath: explicit,
                            pathDirectories: ["/usr/bin", "/Users/me/.local/bin", "/usr/bin/"],
                            knownLocations: ["/usr/local/aws-cli/aws", "/Users/me/aws-cli/aws"],
                            fileName: "aws", fileExists: { present.contains($0) }, ignoreCase: ignoreCase)
    }

    func testCandidatesComeExplicitThenPathThenInstallFolders() {
        let found = search(["/opt/custom/aws", "/Users/me/.local/bin/aws", "/usr/local/aws-cli/aws", "/usr/bin/aws"], explicit: "/opt/custom/aws")
        XCTAssertEqual(AWSCLI.candidates(found), ["/opt/custom/aws", "/usr/bin/aws", "/Users/me/.local/bin/aws", "/usr/local/aws-cli/aws"])
        XCTAssertEqual(AWSCLI.locate(found), "/opt/custom/aws")
    }

    func testMissingFilesAndDuplicatesAreSkipped() {
        XCTAssertEqual(AWSCLI.candidates(search(["/usr/local/aws-cli/aws"], explicit: "/nowhere/aws")), ["/usr/local/aws-cli/aws"])
        XCTAssertNil(AWSCLI.locate(search([])))
        // The same file reached twice (a trailing slash on a PATH entry, "." and ".." segments) counts once.
        let twice = search(["/usr/bin/aws"], explicit: "/usr/../usr/bin/./aws")
        XCTAssertEqual(AWSCLI.candidates(twice), ["/usr/bin/aws"])
    }

    func testPathsCompareWithoutCaseOnlyWhenAskedTo() {
        var found = search(["/usr/bin/aws", "/USR/BIN/aws"], ignoreCase: true)
        found.pathDirectories = ["/usr/bin", "/USR/BIN"]
        XCTAssertEqual(AWSCLI.candidates(found).count, 1)
        found.ignoreCase = false
        XCTAssertEqual(AWSCLI.candidates(found).count, 2, "macOS paths are compared exactly")
    }

    func testARelativePathIsResolvedAgainstTheWorkingDirectory() {
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertEqual(AWSCLI.absolutePath("bin/../aws"), cwd == "/" ? "/aws" : cwd + "/aws")
        XCTAssertEqual(AWSCLI.absolutePath("/a//b/./c/../d/"), "/a/b/d")
        XCTAssertEqual(AWSCLI.absolutePath("/.."), "/")
    }

    func testTheRealSearchLooksOnPathAndWhereTheInstallersPutIt() {
        let home = "/Users/someone"
        let found = AWSCLISearch.forThisMachine(explicitPath: "~/tools/aws",
                                                environment: ["PATH": "/usr/bin: /opt/x/bin ::\"/quoted/bin\":/usr/bin:~/bin"], home: home)
        XCTAssertEqual(found.explicitPath, "/Users/someone/tools/aws")
        XCTAssertEqual(found.pathDirectories, ["/usr/bin", "/opt/x/bin", "/quoted/bin", "/Users/someone/bin"])
        XCTAssertEqual(found.knownLocations, ["/usr/local/bin/aws", "/opt/homebrew/bin/aws", "/usr/local/aws-cli/aws",
                                              "/Users/someone/.local/bin/aws", "/Users/someone/aws-cli/aws"])
        XCTAssertEqual(found.fileName, "aws")
        XCTAssertFalse(found.ignoreCase)
        XCTAssertEqual(AWSCLISearch.forThisMachine(environment: [:], home: home).pathDirectories, [], "no PATH is no folders, not a crash")
    }

    func testTheRealSearchFindsExecutablesAndIgnoresLookAlikes() {
        let dir = makeScratch()
        dir.write("first/aws", "#!/bin/sh\n", executable: true)
        dir.write("notexec/aws", "#!/bin/sh\n", executable: false)
        try? FileManager.default.createDirectory(atPath: dir["adir/aws"], withIntermediateDirectories: true) // a folder called aws
        dir.write("home/aws-cli/aws", "#!/bin/sh\n", executable: true)
        dir.write("home/.local/bin/aws", "#!/bin/sh\n", executable: true)
        let found = AWSCLISearch.forThisMachine(environment: ["PATH": [dir["notexec"], dir["adir"], dir["first"], dir["nothing"]].joined(separator: ":")],
                                                home: dir["home"])
        let candidates = AWSCLI.candidates(found).filter { $0.hasPrefix(dir.path) }
        XCTAssertEqual(candidates, [dir["first/aws"], dir["home/.local/bin/aws"], dir["home/aws-cli/aws"]])
    }

    // MARK: Checking what was found

    private func versions(_ printedByPath: [String: String]) -> @Sendable (String) -> any AWSCLIRunner {
        { path in FakeAWSCLIRunner().on(["--version"], stdout: printedByPath[path] ?? "") }
    }

    func testMissingWhenNothingIsInstalled() async {
        let status = await AWSCLI.check(search: search([])) { _ in
            XCTFail("there is nothing to run")
            return FakeAWSCLIRunner()
        }
        XCTAssertEqual(status, .missing)
        XCTAssertTrue(status.summary.contains("isn't installed"))
        XCTAssertNil(status.path)
        XCTAssertNil(status.version)
    }

    func testReadyWhenNewEnough() async {
        let status = await AWSCLI.check(search: search(["/usr/local/aws-cli/aws"]),
                                        runnerFor: versions(["/usr/local/aws-cli/aws": "aws-cli/2.33.4 Python/3.13.9 Darwin/25.2.0 exe/arm64"]))
        XCTAssertEqual(status, .ready(version: SemanticVersion(2, 33, 4), path: "/usr/local/aws-cli/aws"))
        XCTAssertEqual(status.summary, "AWS CLI 2.33.4 is ready.")
        XCTAssertTrue(status.isReady)
        XCTAssertEqual(status.path, "/usr/local/aws-cli/aws")
        XCTAssertEqual(status.version, SemanticVersion(2, 33, 4))
    }

    func testAnOldCliOnPathDoesntHideANewOneInTheInstallFolder() async {
        let status = await AWSCLI.check(search: search(["/usr/bin/aws", "/usr/local/aws-cli/aws"]), runnerFor: versions([
            "/usr/bin/aws": "aws-cli/1.29.62 Python/3.11.4 Darwin/23 botocore/1.31.62",
            "/usr/local/aws-cli/aws": "aws-cli/2.37.5 Python/3.13.9 Darwin/25.2.0 exe/arm64",
        ]))
        XCTAssertEqual(status.path, "/usr/local/aws-cli/aws")
        XCTAssertTrue(status.isReady)
    }

    func testTheFirstReadyCandidateWinsEvenIfALaterOneIsNewer() async {
        let status = await AWSCLI.check(search: search(["/usr/bin/aws", "/usr/local/aws-cli/aws"]), runnerFor: versions([
            "/usr/bin/aws": "aws-cli/2.33.0 Python/3.13.9 Darwin/25.2.0 exe/arm64",
            "/usr/local/aws-cli/aws": "aws-cli/2.37.5 Python/3.13.9 Darwin/25.2.0 exe/arm64",
        ]))
        XCTAssertEqual(status.path, "/usr/bin/aws", "what the user's own terminal runs comes first")
    }

    func testTooOldReportsTheNewestOldOne() async {
        let status = await AWSCLI.check(search: search(["/usr/bin/aws", "/Users/me/.local/bin/aws", "/usr/local/aws-cli/aws"]), runnerFor: versions([
            "/usr/bin/aws": "aws-cli/1.29.62 Python/3.11.4 Darwin/23 botocore/1.31.62",
            "/Users/me/.local/bin/aws": "",
            "/usr/local/aws-cli/aws": "aws-cli/2.31.39 Python/3.13.7 Darwin/25.2.0 exe/arm64",
        ]))
        XCTAssertEqual(status, .tooOld(version: SemanticVersion(2, 31, 39), path: "/usr/local/aws-cli/aws"))
        XCTAssertTrue(status.summary.contains("2.32.0 or newer"))
        XCTAssertTrue(AWSCLIStatus.tooOld(version: SemanticVersion(1, 29, 62), path: "/usr/bin/aws").summary.contains("needs version 2"))
    }

    func testABrokenOneIsReportedOnlyWhenNothingBetterExists() async {
        let onlyBroken = await AWSCLI.check(search: search(["/usr/bin/aws", "/Users/me/.local/bin/aws"]), runnerFor: { path in
            FakeAWSCLIRunner().on(["--version"], stdout: "", stderr: "broken \(path)", exitCode: 1)
        })
        XCTAssertEqual(onlyBroken.path, "/usr/bin/aws", "the first broken one is the one reported")
        let mixed = await AWSCLI.check(search: search(["/usr/bin/aws", "/Users/me/.local/bin/aws"]), runnerFor: versions([
            "/usr/bin/aws": "",
            "/Users/me/.local/bin/aws": "aws-cli/1.29.62 Python/3.11.4 Darwin/23 botocore/1.31.62",
        ]))
        guard case .tooOld = mixed else { return XCTFail("\(mixed)") }
    }

    func testBrokenWhenItDoesntSayItsVersion() async {
        let status = await AWSCLI.check(search: search(["/usr/bin/aws"]), runnerFor: { _ in
            FakeAWSCLIRunner().on(["--version"], stdout: "", stderr: "Fatal Python error: init_fs_encoding", exitCode: 1)
        })
        guard case .broken(let path, let problem) = status else { return XCTFail("\(status)") }
        XCTAssertEqual(path, "/usr/bin/aws")
        XCTAssertTrue(problem.contains("Fatal Python error"))
        XCTAssertTrue(status.summary.contains("didn't start properly"))
    }

    func testBrokenExplainsAnEmptyAnswerAndATimeout() async {
        let silent = await AWSCLI.check(search: search(["/usr/bin/aws"]), runnerFor: { _ in FakeAWSCLIRunner().on(["--version"], exitCode: 3) })
        XCTAssertEqual(silent, .broken(path: "/usr/bin/aws", problem: "exit code 3"))
        let hung = await AWSCLI.check(search: search(["/usr/bin/aws"]), runnerFor: { _ in
            FakeAWSCLIRunner().on(["--version"]) { _ in AWSCLIResult(exitCode: -1, timedOut: true) }
        })
        XCTAssertEqual(hung, .broken(path: "/usr/bin/aws", problem: "it didn't answer"))
    }

    func testAProgramThatCantStartIsBroken() async {
        let status = await AWSCLI.check(search: search(["/usr/bin/aws"]), runnerFor: { path in
            FakeAWSCLIRunner().on(["--version"]) { _ in throw AWSCLIStartError(executable: path, reason: "the file doesn't exist.") }
        })
        guard case .broken(_, let problem) = status else { return XCTFail("\(status)") }
        XCTAssertEqual(problem, "Couldn't start the AWS CLI (/usr/bin/aws): the file doesn't exist.")
    }

    func testCancellingTheCheckStopsLookingAndReportsWhatItFound() async {
        let found = search(["/usr/bin/aws"])
        let task = Task { () -> AWSCLIStatus in
            withUnsafeCurrentTask { $0?.cancel() }
            return await AWSCLI.check(search: found, runnerFor: { _ in
                XCTFail("a cancelled check doesn't run anything")
                return FakeAWSCLIRunner()
            })
        }
        let status = await task.value
        XCTAssertEqual(status, .missing)
    }

    // MARK: Arguments and JSON

    func testProfileRegionAndJsonAreAppended() {
        XCTAssertEqual(AWSCLI.arguments(["bedrock", "list-foundation-models"], profile: "dsh-bedrock", region: "eu-central-1"),
                       ["bedrock", "list-foundation-models", "--profile", "dsh-bedrock", "--region", "eu-central-1", "--output", "json"])
        XCTAssertEqual(AWSCLI.arguments(["sts", "get-caller-identity"], profile: nil, region: "", json: false), ["sts", "get-caller-identity"])
    }

    func testRunJSONParsesOutputAndMapsFailures() async throws {
        let runner = FakeAWSCLIRunner()
            .on(["sts"], stdout: #"{"UserId":"AIDAEXAMPLE","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/alice"}"#)
            .on(["bedrock", "put-use-case-for-model-access"], stdout: "")
            .on(["bedrock", "weird"], stdout: "not json")
            .fail(["bedrock", "list-foundation-models"], stderr: "aws: [ERROR]: Unable to retrieve credentials: Your session has expired. Please reauthenticate using 'aws login'.", exitCode: 253)
        let cli = AWSCLI(runner: runner)

        let identity = try await cli.runJSON(["sts", "get-caller-identity"], profile: "p", region: "us-east-1")
        XCTAssertEqual(identity["Account"]?.string, "123456789012")
        let empty = try await cli.runJSON(["bedrock", "put-use-case-for-model-access"], profile: "p", region: "us-east-1")
        XCTAssertEqual(empty, .object([:]))
        let bad = await assertThrows(AWSCLIException.self) { _ = try await cli.runJSON(["bedrock", "weird"], profile: "p", region: "us-east-1") }
        XCTAssertTrue(bad?.localizedDescription.contains("couldn't read") == true)
        XCTAssertEqual(bad?.error.details, "not json")
        let signIn = await assertThrows(AWSSignInRequiredError.self) {
            _ = try await cli.runJSON(["bedrock", "list-foundation-models"], profile: "dsh-bedrock", region: "us-east-1")
        }
        XCTAssertEqual(signIn?.profile, "dsh-bedrock")
        XCTAssertTrue(signIn?.message.contains("expired") == true)
        XCTAssertEqual(runner.calls[0].options.timeout, 120)
        XCTAssertEqual(runner.calls[0].args, ["sts", "get-caller-identity", "--profile", "p", "--region", "us-east-1", "--output", "json"])
    }

    func testAJSONNullBodyCountsAsNothingAndATimeoutIsHonoured() async throws {
        let runner = FakeAWSCLIRunner().on(["a"], stdout: "null\n").on(["b"], stdout: "[1,2]")
        let cli = AWSCLI(runner: runner)
        let none = try await cli.runJSON(["a"], profile: nil, region: nil)
        XCTAssertEqual(none, .object([:]))
        let list = try await cli.runJSON(["b"], profile: nil, region: nil, timeout: 30)
        XCTAssertEqual(list.array?.count, 2)
        XCTAssertEqual(runner.calls[1].options.timeout, 30)
    }

    func testRunCheckedReturnsTheResultOrThrows() async throws {
        let runner = FakeAWSCLIRunner().on(["ok"], stdout: "fine").fail(["nope"], stderr: "aws: [ERROR]: Something nobody expected happened.", exitCode: 255)
        let cli = AWSCLI(runner: runner)
        let ok = try await cli.runChecked(["ok"], profile: "p", region: nil)
        XCTAssertEqual(ok.stdout, "fine")
        let failed = await assertThrows(AWSCLIException.self) { _ = try await cli.runChecked(["nope"], profile: nil, region: nil) }
        XCTAssertEqual(failed?.kind, .other)
        XCTAssertEqual(failed?.localizedDescription, "Something nobody expected happened.")
    }

    func testItIsTheCommandRunnerTheSetupCodeUses() async throws {
        // What BedrockSetup and friends are written against: only the protocol.
        let commands: any AWSCLICommands = AWSCLI(runner: FakeAWSCLIRunner().on(["sts"], stdout: #"{"a":1}"#))
        let json = try await commands.runJSON(["sts", "x"], profile: "p", region: "r")
        XCTAssertEqual(json["a"]?.int, 1)
        let result = try await commands.runChecked(["sts", "x"], profile: nil, region: nil)
        XCTAssertTrue(result.succeeded)
    }

    func testAReadyStatusMakesACliAndNothingElseDoes() {
        XCTAssertNotNil(AWSCLI.from(ready: .ready(version: SemanticVersion(2, 33, 4), path: "/usr/bin/aws")))
        XCTAssertNil(AWSCLI.from(ready: .missing))
        XCTAssertNil(AWSCLI.from(ready: .tooOld(version: SemanticVersion(2, 1, 0), path: "/x")))
        XCTAssertNil(AWSCLI.from(ready: .broken(path: "/x", problem: "y")))
    }

    // MARK: Errors

    func testSignInProblemsAskToSignInAgain() {
        // Texts as the CLI prints them (awscli errorhandler + botocore exceptions); several captured from a real CLI.
        let cases: [(error: String, mentions: String)] = [
            ("Unable to retrieve credentials: Error loading login session token: Unable to load a existing login session for session arn:aws:iam::111122223333:user/alice, Please reauthenticate with 'aws login'.", "expired"),
            ("Unable to retrieve credentials: Your session has expired. Please reauthenticate using 'aws login'.", "expired"),
            ("Unable to refresh login credentials because of a change in your password. Please reauthenticate with your new password using 'aws login'.", "password"),
            ("Error loading SSO Token: Token for corp does not exist", "SSO"),
            ("The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile.", "SSO"),
            ("Error when retrieving token from sso: Token has expired and refresh failed", "SSO"),
            ("Unable to retrieve credentials: The config profile (nope) could not be found", "isn't signed in"),
            ("Unable to locate credentials. You can configure credentials by running \"aws login\".", "isn't signed in"),
            ("An error occurred (ExpiredTokenException) when calling the ListFoundationModels operation: The security token included in the request is expired", "expired"),
            ("An error occurred (UnrecognizedClientException) when calling the ListFoundationModels operation: The security token included in the request is invalid.", "didn't accept"),
        ]
        for (error, mentions) in cases {
            let classified = AWSCLIErrors.classify(AWSCLIResult(exitCode: 255, stdout: "", stderr: "\naws: [ERROR]: " + error + "\n"), service: "bedrock")
            XCTAssertEqual(classified.kind, .signInRequired, error)
            XCTAssertTrue(classified.message.contains(mentions), "\(classified.message) should mention \(mentions)")
            guard let signIn = AWSCLIErrors.toError(classified, profile: "dsh-bedrock") as? AWSSignInRequiredError else {
                XCTFail("a sign-in problem must become AWSSignInRequiredError: \(error)")
                continue
            }
            XCTAssertEqual(signIn.profile, "dsh-bedrock")
            XCTAssertEqual(signIn.message, classified.message)
        }
        // No profile named means the CLI's default one.
        let anyProfile = AWSCLIErrors.classify(AWSCLIResult(exitCode: 255, stderr: "Unable to locate credentials."))
        XCTAssertEqual((AWSCLIErrors.toError(anyProfile, profile: nil) as? AWSSignInRequiredError)?.profile, "default")
        XCTAssertEqual((AWSCLIErrors.toError(anyProfile, profile: "") as? AWSSignInRequiredError)?.profile, "default")
    }

    func testAccessDeniedNamesThePermission() {
        // Captured from a real CLI talking to a stub endpoint that denied the call.
        let stderr = "\naws: [ERROR]: An error occurred (AccessDeniedException) when calling the GetFoundationModelAvailability operation: User: arn:aws:sts::111122223333:assumed-role/Dev/alice is not authorized to perform: bedrock:GetFoundationModelAvailability because no identity-based policy allows the bedrock:GetFoundationModelAvailability action\n"
        let error = AWSCLIErrors.classify(AWSCLIResult(exitCode: 254, stdout: "", stderr: stderr), service: "bedrock")
        XCTAssertEqual(error.kind, .accessDenied)
        XCTAssertEqual(error.code, "AccessDeniedException")
        XCTAssertEqual(error.operation, "GetFoundationModelAvailability")
        XCTAssertEqual(error.permission, "bedrock:GetFoundationModelAvailability")
        XCTAssertTrue(error.message.contains("don't allow bedrock:GetFoundationModelAvailability"))
        XCTAssertEqual(error.details, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(AWSCLIErrors.toError(error, profile: "p") is AWSCLIException)
    }

    func testAccessDeniedWithoutAPermissionInTheMessageUsesTheOperation() {
        let error = AWSCLIErrors.classify(AWSCLIResult(exitCode: 254, stderr:
            "An error occurred (AccessDeniedException) when calling the ListInferenceProfiles operation (reached max retries: 2): Access denied."), service: "bedrock")
        XCTAssertEqual(error.permission, "bedrock:ListInferenceProfiles")
        let explicitDeny = AWSCLIErrors.classify(AWSCLIResult(exitCode: 254, stderr:
            "An error occurred (AccessDeniedException) when calling the InvokeModel operation: User: arn:aws:iam::1:user/a is not authorized to perform: bedrock:InvokeModel on resource: x with an explicit deny in a service control policy"), service: "bedrock")
        XCTAssertTrue(explicitDeny.message.contains("explicitly blocks bedrock:InvokeModel"))
        let unnamed = AWSCLIErrors.classify(AWSCLIResult(exitCode: 254, stderr: "An error occurred (AccessDenied): nope"))
        XCTAssertNil(unnamed.permission)
        XCTAssertTrue(unnamed.message.contains("don't allow this"))
    }

    func testSignInWithoutTheCliPermissionIsAccessDenied() {
        let error = AWSCLIErrors.classify(AWSCLIResult(exitCode: 255, stderr:
            "aws: [ERROR]: Unable to create or refresh login credentials due to insufficient permissions. You may be missing permission for the 'signin:CreateOAuth2Token' action."))
        XCTAssertEqual(error.kind, .accessDenied)
        XCTAssertEqual(error.permission, "signin:CreateOAuth2Token")
        XCTAssertTrue(error.message.contains("SignInLocalDevelopmentAccess"))
    }

    func testOtherFailures() {
        let cases: [(stderr: String, kind: AWSCLIFailure)] = [
            ("aws: [ERROR]: An error occurred (ParamValidation): argument command: Found invalid choice 'login'\n\nusage: aws [options] <command> <subcommand> [<subcommand> ...] [parameters]", .notSupported),
            ("aws: error: argument command: Invalid choice, valid choices are:", .notSupported),
            ("Could not connect to the endpoint URL: \"https://bedrock.us-east-1.amazonaws.com/foundation-models\"", .network),
            ("SSL validation failed for https://bedrock.us-east-1.amazonaws.com/ [SSL: CERTIFICATE_VERIFY_FAILED]", .network),
            ("An error occurred (ThrottlingException) when calling the ListFoundationModels operation (reached max retries: 2): Rate exceeded", .throttled),
            ("An error occurred (ResourceNotFoundException) when calling the GetUseCaseForModelAccess operation: Use case form not found.", .notFound),
            ("An error occurred (ConflictException) when calling the CreateFoundationModelAgreement operation: Agreement is being processed.", .conflict),
            ("An error occurred (ValidationException) when calling the GetFoundationModelAvailability operation: Model id is invalid.", .invalid),
            ("You must specify a region. You can also configure your region by running \"aws configure\".", .invalid),
            ("Something nobody expected happened.", .other),
        ]
        for (stderr, kind) in cases {
            XCTAssertEqual(AWSCLIErrors.classify(AWSCLIResult(exitCode: 254, stdout: "", stderr: stderr), service: "bedrock").kind, kind, stderr)
        }
    }

    func testTimeoutsAndMessagesAreReadable() {
        XCTAssertEqual(AWSCLIErrors.classify(AWSCLIResult(exitCode: -1, timedOut: true)).kind, .timedOut)
        let other = AWSCLIErrors.classify(AWSCLIResult(exitCode: 255, stderr: "\naws: [ERROR]: Something nobody expected happened.\n"))
        XCTAssertEqual(other.message, "Something nobody expected happened.")
        XCTAssertEqual(AWSCLIErrors.classify(AWSCLIResult(exitCode: 254, stderr:
            "An error occurred (ResourceNotFoundException) when calling the GetUseCaseForModelAccess operation: Use case form not found.")).message,
                       "Use case form not found.")
        XCTAssertEqual(AWSCLIErrors.cleanMessage("\naws: [ERROR]: An error occurred (ParamValidation): argument command: Found invalid choice 'logn'\n\nusage: aws [options] <command>\nTo see help text, you can run:\n"),
                       "argument command: Found invalid choice 'logn'")
        XCTAssertEqual(AWSCLIErrors.cleanMessage(""), "The AWS CLI stopped with an error.")
    }

    func testErrorsAreReadFromStdoutWhenStderrIsEmptyAndWindowsLineEndingsDontMatter() {
        let fromStdout = AWSCLIErrors.classify(AWSCLIResult(exitCode: 254, stdout: "An error occurred (ConflictException) when calling the X operation: busy\r\n", stderr: "  \n"))
        XCTAssertEqual(fromStdout.kind, .conflict)
        XCTAssertEqual(fromStdout.message, "busy")
        XCTAssertEqual(AWSCLIErrors.cleanMessage("aws: [ERROR]: first\r\nAdditional error details:\r\nsecond\r\n"), "first second")
        XCTAssertEqual(AWSCLIErrors.cleanMessage(String(repeating: "x", count: 900)).count, 500)
    }

    func testAnErrorTextIsMatchedWithoutRegardToCase() {
        XCTAssertEqual(AWSCLIErrors.classify(AWSCLIResult(exitCode: 255, stderr: "UNABLE TO LOCATE CREDENTIALS")).kind, .signInRequired)
        XCTAssertEqual(AWSCLIErrors.classify(AWSCLIResult(exitCode: 255, stderr: "An error occurred (expiredtokenexception): x")).kind, .signInRequired)
    }

    // MARK: Helpers

    func testTheGateWaitsForOpenAndCanGiveUp() async {
        let gate = AWSCLIGate()
        let start = Date()
        let opened = await gate.wait(upTo: 0.15)
        XCTAssertFalse(opened)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.14)
        async let waiting = gate.wait()
        try? await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        let sawIt = await waiting
        XCTAssertTrue(sawIt)
        let again = await gate.wait(upTo: 5)
        XCTAssertTrue(again, "an open gate stays open")
        XCTAssertTrue(gate.opened)
    }

    func testAnsiSequencesAreStrippedAndLineEndingsNormalised() {
        XCTAssertEqual(AWSCLIText.stripANSI("\u{1B}[1;31mred\u{1B}[0m plain \u{1B}]0;title\u{07}text \u{1B}[2K"), "red plain text ")
        XCTAssertEqual(AWSCLIText.stripANSI("no escapes"), "no escapes")
        XCTAssertEqual(AWSCLIText.normalizeNewlines("a\r\nb\rc\n"), "a\nb\nc\n")
        XCTAssertEqual(AWSCLIText.firstLine("\n\nsecond\nthird"), "second")
        XCTAssertEqual(AWSCLIText.firstLine(""), "")
        XCTAssertEqual(AWSCLIText.prefix("abcdef", 3), "abc")
        XCTAssertEqual(AWSCLIText.prefix("abc", 0), "")
    }
}

// MARK: - The real runner, against stand-in "aws" scripts

/// `ProcessAWSCLIRunner` end to end: tiny /bin/sh scripts play the CLI.
final class ProcessAWSCLIRunnerTests: XCTestCase {

    /// A script that runs inside `dir` (so its marker and pid files land there).
    private func script(_ dir: AWSScratchDirectory, _ body: String, name: String = "aws") -> String {
        dir.write(name, "#!/bin/sh\ncd '\(dir.path)' || exit 99\n" + body + "\n", executable: true)
    }

    /// A pid written by a script into a file.
    private func pid(in dir: AWSScratchDirectory, _ name: String) -> pid_t? {
        (try? String(contentsOfFile: dir[name], encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    func testPassesArgumentsVerbatimAndSetsTheEnvironment() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"""
            for a in "$@"; do echo "arg=[$a]"; done
            echo "pager=[${AWS_PAGER-unset}] hint=[$AWS_CLI_AGENT_TOOLKIT_HINT_DISABLED] prompt=[$AWS_CLI_AUTO_PROMPT] enc=[$AWS_CLI_OUTPUT_ENCODING] fmt=[$AWS_CLI_ERROR_FORMAT] py=[$PYTHONUTF8]"
            echo "extra=[$DSH_EXTRA] gone=[${HOME-unset}]"
            echo "café ✓" >&2
            exit 3
            """#)
        let lines = AWSLockedBox<[AWSCLILine]>([])
        let result = try await ProcessAWSCLIRunner(executable: aws).run(
            ["--form-data", #"a b "c" 'd' $HOME;x"#],
            options: AWSCLIRunOptions(environment: ["DSH_EXTRA": "yes", "HOME": nil], onLine: { lines.append($0) }))
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stdout.contains("arg=[--form-data]\narg=[a b \"c\" 'd' $HOME;x]\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("pager=[] hint=[true] prompt=[off] enc=[UTF-8] fmt=[legacy] py=[1]"), result.stdout)
        XCTAssertTrue(result.stdout.contains("extra=[yes] gone=[unset]"), result.stdout)
        XCTAssertEqual(result.stderr, "café ✓\n")
        XCTAssertTrue(lines.value.contains(AWSCLILine("café ✓", isError: true)))
        XCTAssertTrue(lines.value.contains(AWSCLILine("arg=[--form-data]")))
    }

    func testTheEnvironmentIsBuiltInTheRightOrder() {
        let base = ["PATH": "/usr/bin:/bin", "KEEP": "1", "AWS_PAGER": "less", "HOME": "/Users/me"]
        let env = ProcessAWSCLIRunner.environment(base: base, overrides: ["AWS_PAGER": "cat", "KEEP": nil, "NEW": "x"], home: "/Users/other")
        XCTAssertEqual(env["AWS_PAGER"], "cat", "the caller's value wins over the standard one")
        XCTAssertNil(env["KEEP"], "a nil override removes the variable")
        XCTAssertEqual(env["NEW"], "x")
        XCTAssertEqual(env["AWS_CLI_AUTO_PROMPT"], "off")
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/Users/me/.local/bin",
                       "a GUI app's minimal PATH gets the folders Homebrew and the AWS package use")
        // HOME is filled in when missing, but a caller can still remove it.
        let noHome = ProcessAWSCLIRunner.environment(base: ["PATH": "/usr/bin"], overrides: [:], home: "/Users/other")
        XCTAssertEqual(noHome["HOME"], "/Users/other")
        XCTAssertNil(ProcessAWSCLIRunner.environment(base: [:], overrides: ["HOME": nil], home: "/Users/other")["HOME"])
        // Folders already on PATH aren't repeated; a missing PATH gets the system default.
        XCTAssertEqual(ProcessAWSCLIRunner.environment(base: ["PATH": "/opt/homebrew/bin:/usr/bin"], overrides: [:], home: "/h")["PATH"],
                       "/opt/homebrew/bin:/usr/bin:/usr/local/bin:/opt/homebrew/sbin:/h/.local/bin")
        XCTAssertTrue(ProcessAWSCLIRunner.environment(base: [:], overrides: [:], home: "/h")["PATH"]!.hasPrefix("/usr/bin:/bin:/usr/sbin:/sbin:"))
    }

    func testTheRunnerUsesThisProcessesEnvironmentAndAGoodPath() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"echo "path=[$PATH]"; echo "marker=[$DSH_TEST_MARKER]""#)
        let runner = ProcessAWSCLIRunner(executable: aws, baseEnvironment: ["PATH": "/usr/bin:/bin", "DSH_TEST_MARKER": "inherited"], killGrace: 1, outputGrace: 1)
        let result = try await runner.run(["x"], options: AWSCLIRunOptions())
        XCTAssertTrue(result.stdout.contains("marker=[inherited]"), result.stdout)
        XCTAssertTrue(result.stdout.contains("path=[/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:"), result.stdout)
    }

    func testAnswersPromptsThatHaveNoNewline() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"""
            echo "Attempting to open your default browser."
            printf 'Do you want to overwrite it to use B instead? (y/n): '
            read answer
            echo "got [$answer]"
            """#)
        let prompts = AWSLockedBox<[String]>([])
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(
            answerPrompt: { text in
                prompts.append(text)
                return text.hasSuffix("(y/n): ") ? "y" : nil
            }, timeout: 30))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("got [y]"), result.stdout)
        XCTAssertTrue(prompts.value.contains("Do you want to overwrite it to use B instead? (y/n): "), "\(prompts.value)")
    }

    func testAPromptIsAnsweredOnceButOfferedAgainWhileItIsNotUnderstood() async throws {
        let dir = makeScratch()
        // The question arrives in pieces; only the whole of it is one the answerer knows.
        let aws = script(dir, #"""
            printf 'Enter the authorization'
            sleep 0.3
            printf ' code displayed in your browser: '
            read code
            echo
            printf 'Are you sure? (y/n): '
            read sure
            echo "code=[$code] sure=[$sure]"
            """#)
        let offered = AWSLockedBox<[String]>([])
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(
            answerPrompt: { text in
                offered.append(text)
                if text.hasPrefix("Enter the authorization code") && text.hasSuffix(": ") { return "abc123" }
                if text.hasSuffix("(y/n): ") { return "n" }
                return nil
            }, timeout: 30))
        XCTAssertTrue(result.stdout.contains("code=[abc123]"), result.stdout)
        XCTAssertTrue(result.stdout.hasSuffix("sure=[n]\n"), result.stdout)
        XCTAssertTrue(offered.value.contains("Enter the authorization"), "the first piece was offered and declined: \(offered.value)")
        XCTAssertEqual(offered.value.filter { $0.hasSuffix("browser: ") }.count, 1, "an answered line is not offered again")
    }

    func testStandardInputIsClosedUnlessSomethingAnswers() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"if read line; then echo "in [$line]"; else echo eof; fi"#)
        let closed = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions())
        XCTAssertEqual(closed.stdout, "eof\n")
        let typed = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(standardInput: "hello\n"))
        XCTAssertEqual(typed.stdout, "in [hello]\n")
    }

    func testTimesOutKeepingTheOutputSoFar() async throws {
        let dir = makeScratch()
        let aws = script(dir, "echo started; sleep 30")
        let start = Date()
        let timedOut = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(timeout: 0.5))
        XCTAssertTrue(timedOut.timedOut)
        XCTAssertFalse(timedOut.succeeded)
        XCTAssertEqual(timedOut.exitCode, -1)
        XCTAssertEqual(timedOut.stdout, "started\n")
        XCTAssertEqual(AWSCLIErrors.classify(timedOut).kind, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    func testCancellingStopsTheCliAndEverythingItStarted() async throws {
        let dir = makeScratch()
        let aws = script(dir, "sleep 30 & echo $! > child.pid; echo started; wait")
        let task = Task { try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions()) }
        await waitUntil(10, "the script to start its child") { pid(in: dir, "child.pid") != nil }
        let child = try XCTUnwrap(pid(in: dir, "child.pid"))
        XCTAssertTrue(isAlive(child))
        let start = Date()
        task.cancel()
        _ = await assertThrows(CancellationError.self) { _ = try await task.value }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        await waitUntil(5, "the child to be gone") { !isAlive(child) }
    }

    func testATimeoutStopsTheChildrenToo() async throws {
        let dir = makeScratch()
        let aws = script(dir, "sleep 30 & echo $! > child.pid; wait")
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(timeout: 0.6))
        XCTAssertTrue(result.timedOut)
        let child = try XCTUnwrap(pid(in: dir, "child.pid"))
        await waitUntil(5, "the child to be gone") { !isAlive(child) }
    }

    func testAChildThatIgnoresSigtermIsKilled() async throws {
        let dir = makeScratch()
        // "trap '' TERM" is inherited by the sleeps it starts: only SIGKILL stops any of this.
        let aws = script(dir, "trap '' TERM; sleep 30 & echo $! > child.pid; echo started; while true; do sleep 1; done")
        let runner = ProcessAWSCLIRunner(executable: aws, baseEnvironment: nil, killGrace: 0.4, outputGrace: 1)
        let start = Date()
        let result = try await runner.run([], options: AWSCLIRunOptions(timeout: 0.6))
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        let child = try XCTUnwrap(pid(in: dir, "child.pid"))
        await waitUntil(5, "the stubborn child to be gone") { !isAlive(child) }
    }

    func testACancelledTaskNeverStartsTheProgram() async {
        let dir = makeScratch()
        let aws = script(dir, "touch ran.marker")
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions())
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let threwCancellation = await task.value
        XCTAssertTrue(threwCancellation)
        XCTAssertFalse(dir.exists("ran.marker"))
    }

    func testAFailingAnswererStopsTheCliAndItsErrorSurfaces() async throws {
        struct Closed: Error, Equatable {}
        let dir = makeScratch()
        let aws = script(dir, #"printf 'Enter the authorization code displayed in your browser: '; sleep 30 & echo $! > child.pid; read code; echo done"#)
        let thrown = await assertThrows(Closed.self) {
            _ = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(
                answerPrompt: { _ in throw Closed() }, timeout: 30))
        }
        XCTAssertNotNil(thrown)
        if let child = pid(in: dir, "child.pid") { await waitUntil(5, "the child to be gone") { !isAlive(child) } }
    }

    func testAnAnswererSeesTheCancellationOfTheRun() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"printf 'Enter the authorization code displayed in your browser: '; read code; echo done"#)
        let sawCancellation = AWSLockedBox(false)
        let asked = AWSLockedBox(false)
        let task = Task {
            try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(
                answerPrompt: { _ in
                    asked.mutate { $0 = true }
                    // Like the sign-in window: waits for the user, and ends the wait when the run is cancelled.
                    await withTaskCancellationHandler {
                        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                    } onCancel: {
                        sawCancellation.mutate { $0 = true }
                    }
                    return nil
                }, timeout: 60))
        }
        await waitUntil(10, "the prompt") { asked.value }
        task.cancel()
        _ = await assertThrows(CancellationError.self) { _ = try await task.value }
        XCTAssertTrue(sawCancellation.value)
    }

    func testAnAnswerToACliThatAlreadyLeftDoesNotKillTheApp() async throws {
        let dir = makeScratch()
        // The CLI asks and exits without reading; by the time the code is typed there is nobody to hear it
        // (writing to a closed pipe would otherwise raise SIGPIPE and end the app).
        let aws = script(dir, "printf 'Enter the authorization code displayed in your browser: '; sleep 0.1")
        let answered = AWSLockedBox(false)
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(
            answerPrompt: { _ in
                await AWSCLIGate.sleep(0.8) // not cut short by the run ending
                answered.mutate { $0 = true }
                return "too late"
            }, timeout: 30))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
        await waitUntil(5, "the late answer") { answered.value }
    }

    func testALargeStandardInputIsDeliveredWhileTheOutputIsDrained() async throws {
        let dir = makeScratch()
        let aws = script(dir, "cat")
        let input = (0..<20_000).map { "line \($0) of the input\n" }.joined()
        XCTAssertGreaterThan(input.utf8.count, 300_000)
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(standardInput: input, timeout: 60))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, input, "a child that echoes as it reads must not deadlock with the pipes")
    }

    func testATimeoutEndsAWaitingAnswerer() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"printf 'Enter the authorization code displayed in your browser: '; read code; echo done"#)
        let cancelled = AWSLockedBox(false)
        let start = Date()
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(
            answerPrompt: { _ in
                // Like a sign-in window that never gets an answer.
                await withTaskCancellationHandler {
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                } onCancel: {
                    cancelled.mutate { $0 = true }
                }
                return nil
            }, timeout: 0.8))
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertTrue(cancelled.value, "the waiting answerer is told to stop")
    }

    func testOnlyStandardOutputIsOfferedToTheAnswerer() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"printf 'Are you sure? (y/n): ' >&2; read x; echo "[$x]""#)
        let offered = AWSLockedBox<[String]>([])
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(
            answerPrompt: { text in offered.append(text); return "y" }, timeout: 1.0))
        XCTAssertTrue(result.timedOut, "nobody answered a question printed on standard error")
        XCTAssertTrue(offered.value.isEmpty)
        XCTAssertEqual(result.stderr, "Are you sure? (y/n): ")
    }

    func testBigOutputOnBothStreamsDoesNotDeadlock() async throws {
        let dir = makeScratch()
        let aws = script(dir, "yes abcdefghijklmnopqrstuvwxyz | head -n 60000; yes 0123456789 | head -n 60000 >&2")
        let lines = AWSLockedBox(0)
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(
            onLine: { _ in lines.mutate { $0 += 1 } }, timeout: 60))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 60_000 * 27)
        XCTAssertEqual(result.stderr.utf8.count, 60_000 * 11)
        XCTAssertEqual(lines.value, 120_000)
    }

    func testLinesArriveInOrder() async throws {
        let dir = makeScratch()
        let aws = script(dir, "i=0; while [ $i -lt 500 ]; do echo \"line $i\"; i=$((i+1)); done")
        let lines = AWSLockedBox<[String]>([])
        _ = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(onLine: { lines.append($0.text) }))
        XCTAssertEqual(lines.value, (0..<500).map { "line \($0)" })
    }

    func testMultibyteCharactersSplitAcrossReadsSurvive() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"printf '\360\237'; sleep 0.3; printf '\230\200 done\n'"#)
        let lines = AWSLockedBox<[AWSCLILine]>([])
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(onLine: { lines.append($0) }))
        XCTAssertEqual(result.stdout, "😀 done\n")
        XCTAssertEqual(lines.value, [AWSCLILine("😀 done")])
    }

    func testAGrandchildHoldingThePipeDoesntHangTheRun() async throws {
        let dir = makeScratch()
        // The CLI opens a browser (here: a sleeping child holding stdout) and exits at once.
        let aws = script(dir, "sleep 10 & echo $! > child.pid; echo bye")
        let runner = ProcessAWSCLIRunner(executable: aws, baseEnvironment: nil, killGrace: 0.4, outputGrace: 0.5)
        let start = Date()
        let result = try await runner.run([], options: AWSCLIRunOptions())
        XCTAssertEqual(result.stdout, "bye\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the run must not wait for the grandchild")
        if let child = pid(in: dir, "child.pid") {
            XCTAssertTrue(isAlive(child), "a normal exit leaves what the CLI started alone")
            kill(child, SIGKILL)
        }
    }

    func testLinesAreCleanedAndTheLastOneWithoutANewlineIsDelivered() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"printf 'one\r\n\033[31mtwo\033[0m\n\nlast'; printf 'err1\nerr2' >&2"#)
        let lines = AWSLockedBox<[AWSCLILine]>([])
        let result = try await ProcessAWSCLIRunner(executable: aws).run([], options: AWSCLIRunOptions(onLine: { lines.append($0) }))
        XCTAssertEqual(lines.value.filter { !$0.isError }, [AWSCLILine("one"), AWSCLILine("two"), AWSCLILine(""), AWSCLILine("last")])
        XCTAssertEqual(lines.value.filter(\.isError), [AWSCLILine("err1", isError: true), AWSCLILine("err2", isError: true)])
        XCTAssertEqual(result.stdout, "one\r\n\u{1B}[31mtwo\u{1B}[0m\n\nlast", "the result keeps the raw text")
    }

    func testAProgramKilledBySignalLooksLikeItDoesInAShell() async throws {
        let dir = makeScratch()
        let result = try await ProcessAWSCLIRunner(executable: script(dir, "kill -9 $$")).run([], options: AWSCLIRunOptions())
        XCTAssertEqual(result.exitCode, 137)
        XCTAssertFalse(result.succeeded)
    }

    func testConcurrentRunsDontShareOutputOrHoldEachOthersPipesOpen() async throws {
        let dir = makeScratch()
        let slow = script(dir, "echo slow-start; sleep 3; echo slow-end", name: "slow")
        let fast = script(dir, #"echo "fast [$1]""#, name: "fast")
        // Slow and fast runs starting at the same moments: a pipe end leaking into a sibling child would
        // keep a fast run's output open until the slow one exits.
        let outcomes = try await withThrowingTaskGroup(of: (String, String, TimeInterval).self) { group in
            for index in 0..<4 {
                group.addTask {
                    let result = try await ProcessAWSCLIRunner(executable: slow).run([], options: AWSCLIRunOptions())
                    return ("slow", result.stdout, 0)
                }
                group.addTask {
                    let start = Date()
                    let result = try await ProcessAWSCLIRunner(executable: fast).run(["\(index)"], options: AWSCLIRunOptions())
                    return ("fast", result.stdout, Date().timeIntervalSince(start))
                }
            }
            var all: [(String, String, TimeInterval)] = []
            for try await outcome in group { all.append(outcome) }
            return all
        }
        XCTAssertEqual(outcomes.filter { $0.0 == "slow" }.map(\.1), Array(repeating: "slow-start\nslow-end\n", count: 4))
        XCTAssertEqual(outcomes.filter { $0.0 == "fast" }.map(\.1).sorted(), (0..<4).map { "fast [\($0)]\n" })
        for fastRun in outcomes where fastRun.0 == "fast" {
            XCTAssertLessThan(fastRun.2, 2.5, "a run that is still going must not keep another run's pipes open")
        }
    }

    func testAMissingOrUnrunnableProgramIsAStartError() async {
        let missing = await assertThrows(AWSCLIStartError.self) {
            _ = try await ProcessAWSCLIRunner(executable: "/nonexistent/dsh/aws").run(["--version"], options: AWSCLIRunOptions())
        }
        XCTAssertEqual(missing?.executable, "/nonexistent/dsh/aws")
        XCTAssertEqual(missing?.localizedDescription, "Couldn't start the AWS CLI (/nonexistent/dsh/aws): the file doesn't exist.")
        let dir = makeScratch()
        let plain = dir.write("plain", "not a program")
        let notExecutable = await assertThrows(AWSCLIStartError.self) { _ = try await ProcessAWSCLIRunner(executable: plain).run([], options: AWSCLIRunOptions()) }
        XCTAssertEqual(notExecutable?.reason, "it isn't an executable file.")
        let brokenScript = dir.write("broken", "#!/nonexistent/interpreter\n", executable: true)
        _ = await assertThrows(AWSCLIStartError.self) { _ = try await ProcessAWSCLIRunner(executable: brokenScript).run([], options: AWSCLIRunOptions()) }
    }

    func testChecksARealExecutable() async throws {
        let dir = makeScratch()
        let aws = script(dir, "echo 'aws-cli/2.37.5 Python/3.13.9 Darwin/25.2.0 exe/arm64'")
        let status = await AWSCLI.check(search: AWSCLISearch(explicitPath: aws, fileName: "aws"))
        XCTAssertEqual(status, .ready(version: SemanticVersion(2, 37, 5), path: aws))
        let version = try await AWSCLI.forPath(aws).version()
        XCTAssertEqual(version, SemanticVersion(2, 37, 5))
        let from = try XCTUnwrap(AWSCLI.from(ready: status))
        let again = try await from.version()
        XCTAssertEqual(again, SemanticVersion(2, 37, 5))
    }

    func testARealBrokenCliIsReportedWithWhatItSaid() async {
        let dir = makeScratch()
        let aws = script(dir, "echo 'Fatal Python error: init_fs_encoding' >&2; exit 1")
        let status = await AWSCLI.check(search: AWSCLISearch(explicitPath: aws, fileName: "aws"))
        XCTAssertEqual(status, .broken(path: aws, problem: "Fatal Python error: init_fs_encoding"))
    }

    func testRunJSONThroughARealProcess() async throws {
        let dir = makeScratch()
        let aws = script(dir, #"""
            case "$*" in
              *"sts get-caller-identity --profile dsh --region us-east-1 --output json"*) echo '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/alice"}' ;;
              *) echo "An error occurred (ValidationException) when calling the Nope operation: unexpected: $*" >&2; exit 254 ;;
            esac
            """#)
        let cli = AWSCLI.forPath(aws)
        let identity = try await cli.runJSON(["sts", "get-caller-identity"], profile: "dsh", region: "us-east-1")
        XCTAssertEqual(identity["Account"]?.string, "123456789012")
        let failure = await assertThrows(AWSCLIException.self) { _ = try await cli.runJSON(["sts", "other"], profile: "dsh", region: "us-east-1") }
        XCTAssertEqual(failure?.kind, .invalid)
    }
}
