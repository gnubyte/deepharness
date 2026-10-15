import XCTest
@testable import VisionHarnessCore

final class AWSSignInTests: XCTestCase {
    // What `aws login` prints, captured from AWS CLI 2.37.5 (state and challenge shortened).
    private static let sameDeviceURL = "https://eu-central-1.signin.aws.amazon.com/v1/authorize?response_type=code&client_id=arn%3Aaws%3Asignin%3A%3A%3Adevtools%2Fsame-device&state=89734afa-92db-48ad-81a0-af765322efcd&code_challenge_method=SHA-256&scope=openid&redirect_uri=http%3A%2F%2F127.0.0.1%3A53123%2Foauth%2Fcallback&code_challenge=abc"
    private static let remoteURL = "https://us-east-1.signin.aws.amazon.com/v1/authorize?response_type=code&client_id=arn%3Aaws%3Asignin%3A%3A%3Adevtools%2Fcross-device&state=4c6c7daf-2f1b-42c9-9d36-a99147ed34c8&code_challenge_method=SHA-256&scope=openid&redirect_uri=https%3A%2F%2Fus-east-1.signin.aws.amazon.com%2Fv1%2Fsessions%2Fconfirmation&code_challenge=abc"

    private func sameDeviceOutput(_ then: FakeAWSCLIStep...) -> [FakeAWSCLIStep] {
        [
            .line("Attempting to open your default browser. If the browser does not open, open the following URL."),
            .line("If you are unable to open the URL on this device, run this command again with the '--remote' option."),
            .line(""),
            .line(Self.sameDeviceURL),
            .line(""),
        ] + then
    }

    private let loggedIn = AWSCLIResult(
        exitCode: 0,
        stdout: "\nUpdated profile dsh-bedrock to use arn:aws:iam::111122223333:user/alice credentials.\n"
            + "Use \"--profile dsh-bedrock\" to use the new credentials, such as \"aws sts get-caller-identity --profile dsh-bedrock\"\n",
        stderr: "")

    private func profiles(_ config: String?, _ credentials: String? = nil) -> @Sendable () -> AWSProfiles {
        { AWSProfiles.parse(config: config, credentials: credentials) }
    }

    private func makeSignIn(_ runner: FakeAWSCLIRunner, _ profiles: @escaping @Sendable () -> AWSProfiles) -> AWSSignIn {
        AWSSignIn(cli: AWSCLI(runner: runner), loadProfiles: profiles)
    }

    func testBuildsTheLoginCommand() {
        XCTAssertEqual(AWSSignIn.loginArguments(profile: "dsh-bedrock", region: "eu-central-1"), ["login", "--profile", "dsh-bedrock", "--region", "eu-central-1"])
        XCTAssertEqual(AWSSignIn.loginArguments(profile: "p", region: "us-east-1", remote: true, redirectPort: 8400),
                       ["login", "--profile", "p", "--region", "us-east-1", "--remote", "--redirect-port", "8400"])
        XCTAssertEqual(AWSSignIn.ssoLoginArguments(profile: "corp-dev"), ["sso", "login", "--profile", "corp-dev"])
        XCTAssertEqual(AWSSignIn.ssoLoginArguments(profile: "corp-dev", remote: true), ["sso", "login", "--profile", "corp-dev", "--use-device-code", "--no-browser"])
        XCTAssertEqual(AWSSignIn.defaultProfile, "dsh-bedrock")
        XCTAssertEqual(AWSSignIn.defaultRegion, "us-east-1")
    }

    func testSignsInReportsTheLinkAndSavesTheRegion() async throws {
        let runner = FakeAWSCLIRunner()
            .onInteractive(["login"], sameDeviceOutput(), final: loggedIn)
            .on(["configure", "set"], stdout: "")
        let loads = AWSLockedBox(0)
        // Before: no such profile. After: aws login wrote login_session but no region (it only saves one it asked for).
        let signIn = makeSignIn(runner) {
            let count = loads.mutate { value -> Int in defer { value += 1 }; return value }
            return count == 0
                ? AWSProfiles.parse(config: "[default]\nregion = us-west-2\n", credentials: nil)
                : AWSProfiles.parse(config: "[profile dsh-bedrock]\nlogin_session = arn:aws:iam::111122223333:user/alice\n", credentials: nil)
        }
        let output = AWSLockedBox<[String]>([])
        let links = AWSLockedBox<[AWSSignInLink]>([])

        let result = try await signIn.login(profile: "dsh-bedrock", region: "eu-central-1", options: AWSSignInOptions(
            onOutput: { output.append($0) }, onSignInLink: { links.append($0) }))

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.message, "Signed in to AWS.")
        XCTAssertEqual(result.link?.url, URL(string: Self.sameDeviceURL))
        XCTAssertEqual(links.value.map(\.url), [URL(string: Self.sameDeviceURL)!])
        XCTAssertTrue(output.value.contains("Attempting to open your default browser. If the browser does not open, open the following URL."))
        let login = try XCTUnwrap(runner.calls(to: ["login"]).first)
        XCTAssertEqual(runner.calls(to: ["login"]).count, 1)
        XCTAssertEqual(login.args, ["login", "--profile", "dsh-bedrock", "--region", "eu-central-1"])
        XCTAssertEqual(login.options.timeout, 15 * 60)
        XCTAssertEqual(runner.calls(to: ["configure"]).map(\.args), [["configure", "set", "region", "eu-central-1", "--profile", "dsh-bedrock"]])
    }

    func testARegionAlreadyInTheProfileIsLeftAlone() async throws {
        let runner = FakeAWSCLIRunner().onInteractive(["login"], sameDeviceOutput(), final: loggedIn)
        let signIn = makeSignIn(runner, profiles("[profile dsh-bedrock]\nlogin_session = old\nregion = eu-central-1\n"))
        let result = try await signIn.login(profile: "dsh-bedrock", region: "eu-central-1")
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(runner.calls(to: ["configure"]).isEmpty)
    }

    func testAFailureToSaveTheRegionIsReportedButTheSignInStands() async throws {
        let runner = FakeAWSCLIRunner()
            .onInteractive(["login"], sameDeviceOutput(), final: loggedIn)
            .fail(["configure", "set"], stderr: "aws: [ERROR]: [Errno 13] Permission denied: '/Users/me/.aws/config'", exitCode: 255)
        let result = try await makeSignIn(runner, profiles(nil)).login(profile: "dsh-bedrock", region: "us-east-1")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.message, "Signed in, but DSH couldn't save the Region in the profile: [Errno 13] Permission denied: '/Users/me/.aws/config'")
    }

    func testAnswersTheOverwriteQuestion() async throws {
        let question = "\nProfile dsh-bedrock is already configured to use session arn:aws:iam::111122223333:user/bob. Do you want to overwrite it to use arn:aws:iam::111122223333:user/alice instead? (y/n): "
        for (replace, expected, outcome) in [(true, "y", AWSSignInOutcome.signedIn), (false, "n", AWSSignInOutcome.cancelled)] {
            // Declining, the real CLI returns without printing "Updated profile …" and exits 0.
            let final = replace ? loggedIn : AWSCLIResult(exitCode: 0, stdout: "", stderr: "")
            let runner = FakeAWSCLIRunner().onInteractive(["login"], sameDeviceOutput(.prompt(question)), final: final)
            let signIn = makeSignIn(runner, profiles("[profile dsh-bedrock]\nlogin_session = x\nregion = us-east-1\n"))
            let result = try await signIn.login(profile: "dsh-bedrock", region: "us-east-1", options: AWSSignInOptions(replaceExistingSession: replace))
            XCTAssertEqual(runner.answers.count, 1)
            XCTAssertEqual(runner.answers.first?.prompt, question)
            XCTAssertEqual(runner.answers.first?.answer, expected)
            XCTAssertEqual(result.outcome, outcome)
            if !replace { XCTAssertEqual(result.message, "Kept the existing AWS sign-in; the profile wasn't changed.") }
        }
    }

    func testDeclinesTheAgentToolkitQuestionIfItEverComes() async throws {
        let runner = FakeAWSCLIRunner()
            .onInteractive(["login"], sameDeviceOutput(.prompt("\nConfigure AWS skills and the AWS MCP server for your AI coding agent(s)? [y/n/never]: ")), final: loggedIn)
            .on(["configure", "set"], stdout: "")
        let result = try await makeSignIn(runner, profiles(nil)).login(profile: "dsh-bedrock", region: "us-east-1")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runner.answers.map(\.answer), ["n"])
    }

    func testAnUnknownQuestionIsLeftUnanswered() async throws {
        let runner = FakeAWSCLIRunner().onInteractive(["login"], sameDeviceOutput(.prompt("Proceed with the unexpected? ")), final: loggedIn)
        let signIn = makeSignIn(runner, profiles(nil))
        let task = Task { try await signIn.login(profile: "dsh-bedrock", region: "us-east-1") }
        await awsWaitUntil(10, "the question") { !runner.answers.isEmpty }
        XCTAssertNil(runner.answers.first?.answer, "no guessing at questions the app doesn't know")
        task.cancel()
        await awsExpectCancelled(task)
    }

    func testRemoteSignInAsksForTheCode() async throws {
        let runner = FakeAWSCLIRunner()
            .onInteractive(["login"], [
                .line("Browser will not be automatically opened."),
                .line("Please visit the following URL:"),
                .line(""),
                .line(Self.remoteURL),
                .line(""),
                .prompt("\nEnter the authorization code displayed in your browser: "),
            ], final: loggedIn)
            .on(["configure", "set"], stdout: "")
        let asked = AWSLockedBox<AWSSignInLink?>(nil)
        let result = try await makeSignIn(runner, profiles(nil)).login(profile: "dsh-bedrock", region: "us-east-1", options: AWSSignInOptions(
            remote: true,
            requestAuthorizationCode: { link in
                asked.mutate { $0 = link }
                return "  c3RhdGU9eHgmY29kZT15eQ==  \n"
            }))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(asked.value?.url, URL(string: Self.remoteURL))
        XCTAssertEqual(runner.answers.first?.answer, "c3RhdGU9eHgmY29kZT15eQ==")
        XCTAssertEqual(runner.answers.count, 1)
        XCTAssertTrue(try XCTUnwrap(runner.calls(to: ["login"]).first).args.contains("--remote"))
    }

    func testNoCodeMeansCancelled() async throws {
        for answer in [nil, "", "   \n"] as [String?] {
            let runner = FakeAWSCLIRunner().onInteractive(["login"],
                [.line(Self.remoteURL), .prompt("\nEnter the authorization code displayed in your browser: ")], final: loggedIn)
            let result = try await makeSignIn(runner, profiles(nil)).login(profile: "dsh-bedrock", region: "us-east-1", options: AWSSignInOptions(
                remote: true, requestAuthorizationCode: { _ in answer }))
            XCTAssertEqual(result.outcome, .cancelled, "answer: \(String(describing: answer))")
            XCTAssertEqual(result.message, "Sign-in stopped: no authorization code was entered.")
            XCTAssertEqual(result.link?.url, URL(string: Self.remoteURL))
            XCTAssertTrue(runner.calls(to: ["configure"]).isEmpty)
        }
    }

    func testWithoutAnAnswererACodeQuestionEndsTheSignIn() async throws {
        let runner = FakeAWSCLIRunner().onInteractive(["login"],
            [.line(Self.remoteURL), .prompt("\nEnter the authorization code displayed in your browser: ")], final: loggedIn)
        let result = try await makeSignIn(runner, profiles(nil)).login(profile: "dsh-bedrock", region: "us-east-1", options: AWSSignInOptions(remote: true))
        XCTAssertEqual(result.outcome, .cancelled)
    }

    func testCancellingStopsTheCli() async throws {
        let runner = FakeAWSCLIRunner().onInteractive(["login"], sameDeviceOutput(.hang), final: loggedIn)
        let stop = AWSCancelSwitch()
        let signIn = makeSignIn(runner, profiles(nil))
        let login = Task { try await signIn.login(profile: "dsh-bedrock", region: "us-east-1", options: AWSSignInOptions(onSignInLink: { _ in stop.fire() })) }
        stop.arm { login.cancel() }
        await awsExpectCancelled(login)
        XCTAssertTrue(runner.calls(to: ["configure"]).isEmpty)
    }

    func testAnAnswererThatFailsSurfacesItsError() async {
        struct WindowClosed: Error {}
        let runner = FakeAWSCLIRunner().onInteractive(["login"],
            [.line(Self.remoteURL), .prompt("\nEnter the authorization code displayed in your browser: ")], final: loggedIn)
        let thrown = await awsAssertThrows(WindowClosed.self) {
            _ = try await makeSignIn(runner, profiles(nil)).login(profile: "dsh-bedrock", region: "us-east-1", options: AWSSignInOptions(
                remote: true, requestAuthorizationCode: { _ in throw WindowClosed() }))
        }
        XCTAssertNotNil(thrown)
    }

    func testProfilesWithOtherCredentialsAreLeftAlone() async throws {
        let cases: [(config: String, outcome: AWSSignInOutcome)] = [
            ("[profile dsh-bedrock]\nsso_session = corp\nsso_account_id = 1\nsso_role_name = Dev\n", .useSSOLogin),
            ("[profile dsh-bedrock]\nrole_arn = arn:aws:iam::1:role/x\nsource_profile = default\n", .profileHasOtherCredentials),
            ("[profile dsh-bedrock]\ncredential_process = vault aws\n", .profileHasOtherCredentials),
        ]
        for (config, outcome) in cases {
            let runner = FakeAWSCLIRunner()
            let result = try await makeSignIn(runner, profiles(config)).login(profile: "dsh-bedrock", region: "us-east-1")
            XCTAssertEqual(result.outcome, outcome, config)
            XCTAssertTrue(result.message.contains("dsh-bedrock"))
            XCTAssertTrue(runner.calls.isEmpty, "nothing may be run for a profile aws login would refuse")
        }
    }

    func testKeysInTheCredentialsFileCountToo() async throws {
        let runner = FakeAWSCLIRunner()
        let result = try await makeSignIn(runner, profiles(nil, "[work]\naws_access_key_id = AKIA\naws_secret_access_key = s\n"))
            .login(profile: "work", region: "us-east-1")
        XCTAssertEqual(result.outcome, .profileHasOtherCredentials)
        XCTAssertTrue(result.message.contains("access keys"))
    }

    func testBlankNamesAreRefused() async {
        let signIn = makeSignIn(FakeAWSCLIRunner(), profiles(nil))
        let noProfile = await awsAssertThrows(AWSCLIException.self) { _ = try await signIn.login(profile: "  ", region: "us-east-1") }
        XCTAssertEqual(noProfile?.kind, .invalid)
        let noRegion = await awsAssertThrows(AWSCLIException.self) { _ = try await signIn.login(profile: "p", region: "") }
        XCTAssertEqual(noRegion?.kind, .invalid)
        _ = await awsAssertThrows(AWSCLIException.self) { _ = try await signIn.ssoLogin(profile: "") }
    }

    func testExplainsFailures() {
        // Real messages from AWS CLI 2.37.5.
        let cases: [(exitCode: Int, stderr: String, outcome: AWSSignInOutcome)] = [
            (252, "aws: [ERROR]: An error occurred (ParamValidation): argument command: Found invalid choice 'login'", .cliTooOld),
            (253, "aws: [ERROR]: An error occurred (Configuration): Profile 'keys' is already configured with Access Key credentials.\n\nYou may run 'aws login --profile new-profile-name' to create a new profile with the specified name.", .profileHasOtherCredentials),
            (255, "aws: [ERROR]: Failed to retrieve an auth_code or state from the verification code", .failed),
            (255, "aws: [ERROR]: The pending authorization to retrieve an SSO token has expired. The login flow to retrieve an SSO token must be restarted.", .timedOut),
            (255, "aws: [ERROR]: Error loading or redeeming a login authorization code: Unable to complete the login process due to an expired authorization code. Please reauthenticate using 'aws login'.", .timedOut),
            (255, "aws: [ERROR]: Unable to create or refresh login credentials due to insufficient permissions. You may be missing permission for the 'signin:CreateOAuth2Token' action.", .notAllowed),
            (255, "aws: [ERROR]: Could not connect to the endpoint URL: \"https://us-east-1.signin.aws.amazon.com/v1/token\"", .failed),
            (255, "aws: [ERROR]: Unable to initialize the OAuth 2.0 authorization callback handler: Address already in use", .failed),
            (130, "", .cancelled),
        ]
        for (exitCode, stderr, outcome) in cases {
            let result = AWSSignIn.interpret(AWSCLIResult(exitCode: exitCode, stdout: "", stderr: "\n" + stderr + "\n"))
            XCTAssertEqual(result.outcome, outcome, stderr)
            XCTAssertFalse(result.message.contains("aws: [ERROR]"), result.message)
            XCTAssertFalse(result.succeeded)
        }
        let timedOut = AWSSignIn.interpret(AWSCLIResult(exitCode: -1, timedOut: true))
        XCTAssertEqual(timedOut.outcome, .timedOut)
        let tooOld = AWSSignIn.interpret(AWSCLIResult(exitCode: 252, stderr: "Found invalid choice 'login'"))
        XCTAssertTrue(tooOld.message.contains("2.32.0 or newer"))
        XCTAssertEqual(AWSSignIn.interpret(AWSCLIResult(exitCode: 0, stdout: "ok")).outcome, .signedIn)
    }

    func testAFailedLoginSkipsTheRegion() async throws {
        let runner = FakeAWSCLIRunner().onInteractive(["login"], sameDeviceOutput(),
            final: AWSCLIResult(exitCode: 255, stdout: "", stderr: "\naws: [ERROR]: Failed to retrieve an authorization code.\n"))
        let result = try await makeSignIn(runner, profiles(nil)).login()
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.contains("Failed to retrieve an authorization code."))
        XCTAssertEqual(result.details, "Failed to retrieve an authorization code.")
        XCTAssertEqual(result.link?.url, URL(string: Self.sameDeviceURL))
        XCTAssertTrue(runner.calls(to: ["configure"]).isEmpty)
        XCTAssertEqual(runner.calls[0].args, ["login", "--profile", "dsh-bedrock", "--region", "us-east-1"])
    }

    func testAProgramThatCantStartIsAFailedSignIn() async throws {
        let runner = FakeAWSCLIRunner().on(["login"]) { _ in throw AWSCLIStartError(executable: "/x/aws", reason: "the file doesn't exist.") }
        let result = try await makeSignIn(runner, profiles(nil)).login(profile: "p", region: "us-east-1")
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.message.hasPrefix("DSH couldn't start the AWS CLI:"), result.message)
    }

    func testFindsTheSignInURL() {
        let cases: [(line: String, found: Bool)] = [
            (Self.sameDeviceURL, true),
            ("  https://device.sso.us-east-1.amazonaws.com/  ", true),
            ("HTTPS://device.sso.us-east-1.amazonaws.com/", true),
            ("https://example.com/a b", false),
            ("https://example.com/a\tb", false),
            ("Please visit the following URL:", false),
            ("open https://example.com now", false),
            ("http://127.0.0.1:53123/oauth/callback", false),
            ("https://", false),
            ("", false),
        ]
        for (line, found) in cases { XCTAssertEqual(AWSSignIn.extractSignInURL(line) != nil, found, line) }
    }

    func testSSOSignInShowsTheDeviceCode() async throws {
        let runner = FakeAWSCLIRunner().onInteractive(["sso", "login"], [
            .line("Browser will not be automatically opened."),
            .line("Please visit the following URL:"),
            .line(""),
            .line("https://device.sso.us-east-1.amazonaws.com/"),
            .line(""),
            .line("Then enter the code:"),
            .line(""),
            .line("WDXB-PQRT"),
        ], final: AWSCLIResult(exitCode: 0, stdout: "Successfully logged into Start URL: https://corp.awsapps.com/start\n", stderr: ""))
        let links = AWSLockedBox<[AWSSignInLink]>([])
        let signIn = makeSignIn(runner, profiles("[profile corp-dev]\nsso_session = corp\nsso_account_id = 1\nsso_role_name = Dev\n"))
        let result = try await signIn.ssoLogin(profile: "corp-dev", options: AWSSignInOptions(remote: true, onSignInLink: { links.append($0) }))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.message, "Signed in to AWS IAM Identity Center.")
        XCTAssertEqual(result.link?.userCode, "WDXB-PQRT")
        XCTAssertEqual(result.link?.url, URL(string: "https://device.sso.us-east-1.amazonaws.com/"))
        XCTAssertEqual(links.value.count, 2)
        XCTAssertNil(links.value[0].userCode)
        XCTAssertEqual(links.value[1].userCode, "WDXB-PQRT")
        XCTAssertEqual(runner.calls[0].args, ["sso", "login", "--profile", "corp-dev", "--use-device-code", "--no-browser"])
    }

    func testSSOSignInNeedsAnSSOProfile() async throws {
        for config in ["[profile dsh-bedrock]\nlogin_session = x\n", "[profile other]\nregion = us-east-1\n"] {
            let runner = FakeAWSCLIRunner()
            let result = try await makeSignIn(runner, profiles(config)).ssoLogin(profile: "dsh-bedrock")
            XCTAssertEqual(result.outcome, .notSSOProfile)
            XCTAssertTrue(runner.calls.isEmpty)
        }
    }

    // MARK: Who is signed in

    func testVerifiesWhoIsSignedIn() async throws {
        let runner = FakeAWSCLIRunner().on(["sts", "get-caller-identity"], stdout: """
            {
                "UserId": "AIDASAMPLEUSERID",
                "Account": "123456789012",
                "Arn": "arn:aws:iam::123456789012:user/alice"
            }
            """)
        let identity = try await makeSignIn(runner, profiles(nil)).verify(profile: "dsh-bedrock", region: "eu-central-1")
        XCTAssertEqual(identity.account, "123456789012")
        XCTAssertEqual(identity.userID, "AIDASAMPLEUSERID")
        XCTAssertEqual(identity.displayAccount, "1234-5678-9012")
        XCTAssertEqual(identity.description, "Signed in to AWS account 1234-5678-9012 as alice.")
        XCTAssertEqual(runner.calls[0].args, ["sts", "get-caller-identity", "--profile", "dsh-bedrock", "--region", "eu-central-1", "--output", "json"])
    }

    func testAnAnswerWithoutAnAccountIsAnError() async {
        let runner = FakeAWSCLIRunner().on(["sts"], stdout: #"{"UserId":"X"}"#)
        let failure = await awsAssertThrows(AWSCLIException.self) { _ = try await makeSignIn(runner, profiles(nil)).verify() }
        XCTAssertEqual(failure?.localizedDescription, "AWS didn't say who is signed in.")
        XCTAssertEqual(failure?.error.details, #"{"UserId":"X"}"#)
    }

    func testNamesThePrincipal() {
        let cases: [(arn: String, name: String)] = [
            ("arn:aws:sts::123456789012:assumed-role/Developer/alice@example.com", "alice@example.com (role Developer)"),
            ("arn:aws:iam::123456789012:root", "the account's root user"),
            ("arn:aws:iam::123456789012:user/team/bob", "bob"),
            ("arn:aws:iam::123456789012:user/alice", "alice"),
            ("not an arn", "not an arn"),
        ]
        for (arn, name) in cases {
            XCTAssertEqual(AWSCallerIdentity(account: "123456789012", arn: arn, userID: "X").principalName, name, arn)
        }
        XCTAssertEqual(AWSCallerIdentity(account: "12345", arn: "a", userID: "").displayAccount, "12345", "only a 12-digit number is grouped")
        XCTAssertEqual(AWSCallerIdentity(account: "12345678901x", arn: "a", userID: "").displayAccount, "12345678901x")
    }

    func testVerifyingWithoutASignInAsksForOne() async {
        let runner = FakeAWSCLIRunner().fail(["sts"],
            stderr: "aws: [ERROR]: Unable to retrieve credentials: Error loading login session token: Unable to load a existing login session for session arn:aws:iam::1:user/a, Please reauthenticate with 'aws login'.",
            exitCode: 253)
        let signedOut = await awsAssertThrows(AWSSignInRequiredError.self) { _ = try await makeSignIn(runner, profiles(nil)).verify(profile: "dsh-bedrock") }
        XCTAssertEqual(signedOut?.profile, "dsh-bedrock")
    }
}

/// The sign-in against a stand-in `aws` script through the real runner: the URL, the questions and the
/// cancelling all cross the process boundary.
final class AWSSignInWithARealProcessTests: XCTestCase {
    private static let url = "https://us-east-1.signin.aws.amazon.com/v1/authorize?response_type=code&state=abc&redirect_uri=http%3A%2F%2F127.0.0.1%3A53123%2Foauth%2Fcallback"

    private func fakeAWS(_ dir: AWSScratchDirectory, login: String) -> String {
        dir.write("aws", """
            #!/bin/sh
            cd '\(dir.path)' || exit 99
            case "$1" in
              login)
                echo "$@" > login.args
            \(login)
                ;;
              configure)
                echo "$@" > configure.args
                ;;
              *) echo "unexpected: $*" >&2; exit 254 ;;
            esac
            """, executable: true)
    }

    func testABrowserSignInAnswersTheQuestionReportsTheLinkAndSavesTheRegion() async throws {
        let dir = awsScratch()
        let aws = fakeAWS(dir, login: """
                echo "Attempting to open your default browser. If the browser does not open, open the following URL."
                echo
                echo "\(Self.url)"
                echo
                printf 'Profile p is already configured to use session A. Do you want to overwrite it to use B instead? (y/n): '
                read answer
                echo
                echo "Updated profile p (overwrite=$answer)"
            """)
        let links = AWSLockedBox<[AWSSignInLink]>([])
        let output = AWSLockedBox<[String]>([])
        let signIn = AWSSignIn(cli: AWSCLI.forPath(aws), loadProfiles: { AWSProfiles.parse(config: "[profile p]\nlogin_session = old\n", credentials: nil) })
        let result = try await signIn.login(profile: "p", region: "eu-central-1", options: AWSSignInOptions(
            onOutput: { output.append($0) }, onSignInLink: { links.append($0) }))
        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertEqual(links.value.map(\.url), [URL(string: Self.url)!])
        XCTAssertTrue(output.value.contains("Updated profile p (overwrite=y)"), "\(output.value)")
        XCTAssertEqual(try String(contentsOfFile: dir["login.args"], encoding: .utf8), "login --profile p --region eu-central-1\n")
        XCTAssertEqual(try String(contentsOfFile: dir["configure.args"], encoding: .utf8), "configure set region eu-central-1 --profile p\n",
                       "the profile had no Region, so it is saved")
    }

    func testARemoteSignInPassesTheCodeThroughToTheCli() async throws {
        let dir = awsScratch()
        let aws = fakeAWS(dir, login: """
                echo "Browser will not be automatically opened."
                echo "Please visit the following URL:"
                echo
                echo "\(Self.url)"
                echo
                printf 'Enter the authorization code displayed in your browser: '
                read code
                echo
                echo "code=[$code]"
            """)
        let shown = AWSLockedBox<AWSSignInLink?>(nil)
        let output = AWSLockedBox<[String]>([])
        let signIn = AWSSignIn(cli: AWSCLI.forPath(aws), loadProfiles: { AWSProfiles.parse(config: nil, credentials: nil) })
        let result = try await signIn.login(profile: "p", region: "us-east-1", options: AWSSignInOptions(
            remote: true, onOutput: { output.append($0) },
            requestAuthorizationCode: { link in
                shown.mutate { $0 = link }
                return " abc123== \n"
            }))
        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertEqual(shown.value?.url, URL(string: Self.url))
        XCTAssertTrue(output.value.contains("code=[abc123==]"), "\(output.value)")
        XCTAssertEqual(try String(contentsOfFile: dir["login.args"], encoding: .utf8), "login --profile p --region us-east-1 --remote\n")
    }

    func testGivingUpOnTheCodeStopsTheRealCli() async throws {
        let dir = awsScratch()
        let aws = fakeAWS(dir, login: """
                echo "\(Self.url)"
                sleep 60 &
                echo $! > child.pid
                printf 'Enter the authorization code displayed in your browser: '
                read code
                echo "should not get here: $code"
                touch finished.marker
            """)
        let signIn = AWSSignIn(cli: AWSCLI.forPath(aws), loadProfiles: { AWSProfiles.parse(config: nil, credentials: nil) })
        let task = Task {
            try await signIn.login(profile: "p", region: "us-east-1", options: AWSSignInOptions(remote: true, requestAuthorizationCode: { _ in nil }))
        }
        guard let outcome = await awsOutcome(of: task, within: 30) else { return }
        let result = try outcome.get()
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.link?.url, URL(string: Self.url))
        XCTAssertFalse(dir.exists("finished.marker"))
        if let text = try? String(contentsOfFile: dir["child.pid"], encoding: .utf8), let child = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            await awsWaitUntil(5, "the CLI's child to be gone") { kill(child, 0) != 0 }
        }
    }

    func testCancellingTheSignInStopsTheRealCli() async throws {
        let dir = awsScratch()
        let aws = fakeAWS(dir, login: """
                echo "\(Self.url)"
                echo $$ > cli.pid
                sleep 60
            """)
        let signIn = AWSSignIn(cli: AWSCLI.forPath(aws), loadProfiles: { AWSProfiles.parse(config: nil, credentials: nil) })
        let sawLink = AWSLockedBox(false)
        let task = Task { try await signIn.login(profile: "p", region: "us-east-1", options: AWSSignInOptions(onSignInLink: { _ in sawLink.mutate { $0 = true } })) }
        await awsWaitUntil(10, "the sign-in link") { sawLink.value }
        task.cancel()
        await awsExpectCancelled(task)
        XCTAssertFalse(dir.exists("configure.args"), "a cancelled sign-in saves nothing")
        if let text = try? String(contentsOfFile: dir["cli.pid"], encoding: .utf8), let cli = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            await awsWaitUntil(5, "the CLI to be gone") { kill(cli, 0) != 0 }
        }
    }

    func testAFailingLoginIsExplainedFromTheRealStandardError() async throws {
        let dir = awsScratch()
        let aws = fakeAWS(dir, login: """
                echo "aws: [ERROR]: Unable to create or refresh login credentials due to insufficient permissions. You may be missing permission for the 'signin:CreateOAuth2Token' action." >&2
                exit 255
            """)
        let signIn = AWSSignIn(cli: AWSCLI.forPath(aws), loadProfiles: { AWSProfiles.parse(config: nil, credentials: nil) })
        let result = try await signIn.login(profile: "p", region: "us-east-1")
        XCTAssertEqual(result.outcome, .notAllowed)
        XCTAssertTrue(result.message.contains("SignInLocalDevelopmentAccess"), result.message)
        XCTAssertFalse(dir.exists("configure.args"))
    }

    func testVerifyThroughARealProcess() async throws {
        let dir = awsScratch()
        let aws = dir.write("aws", """
            #!/bin/sh
            case "$*" in
              "sts get-caller-identity --profile p --region us-east-1 --output json")
                echo '{"UserId": "AIDA", "Account": "123456789012", "Arn": "arn:aws:iam::123456789012:user/alice"}' ;;
              *) echo "Unable to locate credentials. You can configure credentials by running \\"aws login\\"." >&2; exit 253 ;;
            esac
            """, executable: true)
        let signIn = AWSSignIn(cli: AWSCLI.forPath(aws))
        let identity = try await signIn.verify(profile: "p", region: "us-east-1")
        XCTAssertEqual(identity.description, "Signed in to AWS account 1234-5678-9012 as alice.")
        let signedOut = await awsAssertThrows(AWSSignInRequiredError.self) { _ = try await signIn.verify(profile: "other", region: "us-east-1") }
        XCTAssertEqual(signedOut?.profile, "other")
    }
}
