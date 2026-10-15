import Foundation

// MARK: - Signing in to AWS
//
// `aws login` (AWS CLI 2.32.0+) signs the CLI in with the same sign-in as the AWS console: it starts a
// local callback server, opens the browser at https://<region>.signin.aws.amazon.com/v1/authorize?…, and
// saves a refreshable session in the profile (login_session). What it prints, from
// awscli/customizations/sso/utils.py (OpenBrowserHandler / PrintOnlyHandler) and login/utils.py:
//
//   Attempting to open your default browser. If the browser does not open, open the following URL.
//   If you are unable to open the URL on this device, run this command again with the '--remote' option.
//
//   https://us-east-1.signin.aws.amazon.com/v1/authorize?response_type=code&client_id=...
//
// With --remote (no browser on this machine) it prints "Browser will not be automatically opened.
// Please visit the following URL:", the URL, then asks "Enter the authorization code displayed in your
// browser: " (no newline) and reads the code from standard input. When the profile already holds a
// different login session it asks "... Do you want to overwrite it to use <session> instead? (y/n): ".
// It prompts for a Region unless --region is given, refuses profiles configured with SSO, keys, a role,
// a web identity or credential_process, and — only when it asked for the Region — saves it to the
// profile. The app always passes --region and then saves the Region itself (`aws configure set`),
// because the CLI refreshes the session later through that Region's sign-in endpoint.

/// Who AWS says is signed in (sts get-caller-identity).
public struct AWSCallerIdentity: Sendable, Equatable, CustomStringConvertible {
    public var account: String
    public var arn: String
    public var userID: String

    public init(account: String, arn: String, userID: String) {
        self.account = account
        self.arn = arn
        self.userID = userID
    }

    /// "1234-5678-9012", the way the AWS console shows account numbers.
    public var displayAccount: String {
        guard account.count == 12, account.allSatisfy({ $0.isASCII && $0.isNumber }) else { return account }
        return "\(account.prefix(4))-\(account.dropFirst(4).prefix(4))-\(account.suffix(4))"
    }

    /// The person or role: "alice" for arn:aws:iam::…:user/alice, "alice@example.com (role Developer)"
    /// for an assumed role, "the account's root user" for root.
    public var principalName: String {
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        let resource = parts.count == 6 ? String(parts[5]) : arn
        if resource == "root" { return "the account's root user" }
        let segments = resource.split(separator: "/", omittingEmptySubsequences: false)
        if segments.first == "assumed-role" && segments.count >= 3 { return "\(segments[segments.count - 1]) (role \(segments[1]))" }
        return segments.count >= 2 ? String(segments[segments.count - 1]) : resource
    }

    /// "Signed in to AWS account 1234-5678-9012 as alice."
    public var description: String { "Signed in to AWS account \(displayAccount) as \(principalName)." }
}

/// The sign-in page the CLI wants the user to open, and the code to type there (device-code sign-in to
/// IAM Identity Center only).
public struct AWSSignInLink: Sendable, Equatable {
    public var url: URL
    public var userCode: String?

    public init(url: URL, userCode: String? = nil) {
        self.url = url
        self.userCode = userCode
    }
}

public enum AWSSignInOutcome: Sendable, Equatable {
    case signedIn
    /// The user stopped it (declined to paste a code, or the CLI was interrupted).
    case cancelled
    /// The profile signs in with IAM Identity Center: use `AWSSignIn.ssoLogin`.
    case useSSOLogin
    /// The profile already uses keys, a role, a web identity or a credential program; `aws login`
    /// won't touch it. Pick another profile name (the app's own is "vision-bedrock").
    case profileHasOtherCredentials
    /// The profile isn't set up for IAM Identity Center (for `AWSSignIn.ssoLogin`).
    case notSSOProfile
    /// The AWS CLI is too old for this sign-in.
    case cliTooOld
    /// The browser part wasn't finished in time (the CLI waits 10 minutes).
    case timedOut
    /// The sign-in worked but this identity may not create CLI sessions.
    case notAllowed
    case failed
}

/// How a sign-in ended, in words for the guide.
public struct AWSSignInResult: Sendable, Equatable {
    public var outcome: AWSSignInOutcome
    public var message: String
    public var link: AWSSignInLink?
    public var details: String?

    public init(outcome: AWSSignInOutcome, message: String, link: AWSSignInLink? = nil, details: String? = nil) {
        self.outcome = outcome
        self.message = message
        self.link = link
        self.details = details
    }

    public var succeeded: Bool { outcome == .signedIn }
}

/// Options for `AWSSignIn.login` and `AWSSignIn.ssoLogin`.
public struct AWSSignInOptions: Sendable {
    /// For a machine without a browser: the CLI prints the link and the app asks the user for the code
    /// the browser shows afterwards (`requestAuthorizationCode`).
    public var remote: Bool

    /// `aws login --redirect-port` (CLI 2.37.2+): a fixed port for the browser to return to.
    public var redirectPort: Int?

    /// Every line the CLI prints, as it arrives (background queue).
    public var onOutput: (@Sendable (String) -> Void)?

    /// The sign-in link as soon as the CLI prints it, so the guide can offer "Open the sign-in page
    /// again" (and show the code, for device-code SSO). Background queue.
    public var onSignInLink: (@Sendable (AWSSignInLink) -> Void)?

    /// Remote sign-in: ask the user for the authorization code the browser shows after they sign in.
    /// Return nil to give up. It runs inside the sign-in's task tree, so a window that closes can end
    /// the wait by observing cancellation (`withTaskCancellationHandler`) and returning nil.
    public var requestAuthorizationCode: (@Sendable (AWSSignInLink) async throws -> String?)?

    /// Answer to "Profile X is already configured to use session A. Do you want to overwrite it to use
    /// session B instead?" — the user asked to sign in, so yes by default.
    public var replaceExistingSession: Bool

    /// Safety limit on the whole sign-in in seconds (the CLI itself gives up after 10 minutes).
    public var timeout: TimeInterval

    public init(remote: Bool = false, redirectPort: Int? = nil,
                onOutput: (@Sendable (String) -> Void)? = nil,
                onSignInLink: (@Sendable (AWSSignInLink) -> Void)? = nil,
                requestAuthorizationCode: (@Sendable (AWSSignInLink) async throws -> String?)? = nil,
                replaceExistingSession: Bool = true,
                timeout: TimeInterval = 15 * 60) {
        self.remote = remote
        self.redirectPort = redirectPort
        self.onOutput = onOutput
        self.onSignInLink = onSignInLink
        self.requestAuthorizationCode = requestAuthorizationCode
        self.replaceExistingSession = replaceExistingSession
        self.timeout = timeout
    }
}

/// Signs the AWS CLI in (`aws login` or `aws sso login`) and checks who is signed in.
public final class AWSSignIn: Sendable {
    /// The profile the app creates for itself, so it never disturbs profiles the user already has. (Routes set up
    /// before the rename name the old one, `AppIdentity.Legacy.awsProfile`, and keep it: the profile is stored on the
    /// route.)
    public static let defaultProfile = AppIdentity.awsProfile

    /// The Region `login` uses when none is given (BedrockRegions.default in the Amazon Bedrock setup).
    public static let defaultRegion = "us-east-1"

    private let cli: AWSCLI
    private let loadProfiles: @Sendable () -> AWSProfiles

    public init(cli: AWSCLI, loadProfiles: (@Sendable () -> AWSProfiles)? = nil) {
        self.cli = cli
        self.loadProfiles = loadProfiles ?? { AWSProfiles.load() }
    }

    /// `aws login --profile P --region R [--remote] [--redirect-port N]`.
    public static func loginArguments(profile: String, region: String, remote: Bool = false, redirectPort: Int? = nil) -> [String] {
        var args = ["login", "--profile", profile, "--region", region]
        if remote { args.append("--remote") }
        if let redirectPort { args += ["--redirect-port", String(redirectPort)] }
        return args
    }

    /// `aws sso login --profile P` (device code and no browser when remote).
    public static func ssoLoginArguments(profile: String, remote: Bool = false) -> [String] {
        var args = ["sso", "login", "--profile", profile]
        if remote { args += ["--use-device-code", "--no-browser"] }
        return args
    }

    /// Sign in with the browser (`aws login`), into `profile`, then make sure the profile remembers
    /// `region`. Opens the user's browser; returns when they have signed in, given up, or the CLI's 10
    /// minutes ran out. The profile is checked first: one already set up with other credentials is left
    /// alone and the result says what to do instead. Cancelling the task stops the CLI and throws
    /// `CancellationError`.
    public func login(profile: String = AWSSignIn.defaultProfile, region: String = AWSSignIn.defaultRegion,
                      options: AWSSignInOptions = AWSSignInOptions()) async throws -> AWSSignInResult {
        try Self.require(profile, "The AWS profile name is empty.")
        try Self.require(region, "The AWS Region is empty.")
        let existing = loadProfiles().find(profile)
        if let existing, existing.kind == .sso {
            return AWSSignInResult(outcome: .useSSOLogin,
                                   message: "The AWS profile \"\(profile)\" signs in through IAM Identity Center (SSO), so DSH will use the SSO sign-in for it.")
        }
        if let existing, !existing.canUseAWSLogin {
            return AWSSignInResult(outcome: .profileHasOtherCredentials,
                                   message: "The AWS profile \"\(profile)\" already uses \(existing.kindDescription), which the browser sign-in won't replace. Use it as it is, or let DSH sign in with its own profile (\"\(Self.defaultProfile)\").")
        }

        var result = try await runSignIn(Self.loginArguments(profile: profile, region: region, remote: options.remote, redirectPort: options.redirectPort),
                                         options: options)
        if !result.succeeded { return result }

        // `aws login --region R` saves R only when it had to ask for it; the session's later refreshes need it.
        if (loadProfiles().find(profile)?.region ?? "").isEmpty {
            let set = try await cli.run(["configure", "set", "region", region, "--profile", profile], options: AWSCLIRunOptions(timeout: 60))
            if !set.succeeded {
                result.message = "Signed in, but DSH couldn't save the Region in the profile: \(AWSCLIErrors.cleanMessage(set.stderr + set.stdout))"
                return result
            }
        }
        result.message = "Signed in to AWS."
        return result
    }

    /// Sign in to IAM Identity Center for a profile already set up with `aws configure sso`.
    public func ssoLogin(profile: String, options: AWSSignInOptions = AWSSignInOptions()) async throws -> AWSSignInResult {
        try Self.require(profile, "The AWS profile name is empty.")
        if loadProfiles().find(profile)?.kind != .sso {
            return AWSSignInResult(outcome: .notSSOProfile,
                                   message: "The AWS profile \"\(profile)\" isn't set up for IAM Identity Center (SSO). Set it up with \"aws configure sso\", or sign in with the browser instead.")
        }
        var result = try await runSignIn(Self.ssoLoginArguments(profile: profile, remote: options.remote), options: options)
        if result.succeeded { result.message = "Signed in to AWS IAM Identity Center." }
        return result
    }

    /// Who is signed in: `aws sts get-caller-identity`. Throws `AWSSignInRequiredError` when nobody is.
    public func verify(profile: String = AWSSignIn.defaultProfile, region: String? = nil) async throws -> AWSCallerIdentity {
        let json = try await cli.runJSON(["sts", "get-caller-identity"], profile: profile, region: region, timeout: nil)
        guard let account = json["Account"]?.string, !account.isEmpty, let arn = json["Arn"]?.string, !arn.isEmpty else {
            throw AWSCLIException(AWSCLIError(kind: .other, message: "AWS didn't say who is signed in.", details: json.serialized()))
        }
        return AWSCallerIdentity(account: account, arn: arn, userID: json["UserId"]?.string ?? "")
    }

    private static func require(_ value: String, _ message: String) throws {
        if AWSCLIText.trimmed(value).isEmpty { throw AWSCLIException(AWSCLIError(kind: .invalid, message: message)) }
    }

    // MARK: Running the sign-in

    private func runSignIn(_ args: [String], options: AWSSignInOptions) async throws -> AWSSignInResult {
        let state = SignInRun(options: options)
        let runOptions = AWSCLIRunOptions(
            answerPrompt: { prompt in try await state.answer(prompt) },
            onLine: { line in state.handle(line) },
            timeout: options.timeout)
        // The CLI runs in a task of its own so that giving up on the code (below) can stop it without
        // cancelling the caller; the caller's own cancellation is passed on to it.
        let cli = cli
        let task = Task { try await cli.run(args, options: runOptions) }
        state.attach(task)
        let result: AWSCLIResult
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError where state.gaveUp && !Task.isCancelled {
            return AWSSignInResult(outcome: .cancelled, message: "Sign-in stopped: no authorization code was entered.", link: state.link)
        } catch let error as AWSCLIStartError {
            return AWSSignInResult(outcome: .failed, message: "DSH couldn't start the AWS CLI: \(error.localizedDescription)", link: state.link)
        }
        // Answering "n" ends `aws login` successfully without touching the profile.
        if result.succeeded && state.keptOldSession {
            return AWSSignInResult(outcome: .cancelled, message: "Kept the existing AWS sign-in; the profile wasn't changed.", link: state.link)
        }
        return Self.interpret(result, link: state.link)
    }

    /// The bits of one sign-in that the CLI's output callbacks and the prompt answerer share.
    private final class SignInRun: @unchecked Sendable {
        private let options: AWSSignInOptions
        private let lock = NSLock()
        private var _link: AWSSignInLink?
        private var _gaveUp = false
        private var _keptOldSession = false
        private var task: Task<AWSCLIResult, any Error>?
        private var cancelWhenAttached = false

        init(options: AWSSignInOptions) { self.options = options }

        var link: AWSSignInLink? { lock.withLock { _link } }
        var gaveUp: Bool { lock.withLock { _gaveUp } }
        var keptOldSession: Bool { lock.withLock { _keptOldSession } }

        func attach(_ task: Task<AWSCLIResult, any Error>) {
            let cancelNow: Bool = lock.withLock {
                self.task = task
                return cancelWhenAttached
            }
            if cancelNow { task.cancel() }
        }

        /// Stop the CLI (not the caller).
        private func stopRun() {
            let running: Task<AWSCLIResult, any Error>? = lock.withLock {
                cancelWhenAttached = true
                return task
            }
            running?.cancel()
        }

        func handle(_ line: AWSCLILine) {
            options.onOutput?(line.text)
            let trimmed = AWSCLIText.trimmed(line.text)
            let update: AWSSignInLink? = lock.withLock {
                if let url = AWSSignIn.extractSignInURL(line.text) {
                    _link = AWSSignInLink(url: url, userCode: _link?.userCode)
                    return _link
                }
                if var current = _link, AWSSignIn.userCodeRegex.matches(trimmed) {
                    current.userCode = trimmed
                    _link = current
                    return current
                }
                return nil
            }
            if let update { options.onSignInLink?(update) }
        }

        func answer(_ prompt: String) async throws -> String? {
            let text = AWSCLIText.trimmed(prompt)
            let lowered = text.lowercased()
            if lowered.hasSuffix("(y/n):") && lowered.contains("overwrite") {
                lock.withLock { _keptOldSession = !options.replaceExistingSession }
                return options.replaceExistingSession ? "y" : "n"
            }
            // The agent-toolkit question (CLI 2.36.50+) is switched off by environment; if it still comes, decline.
            if lowered.hasSuffix("[y/n/never]:") { return "n" }
            if lowered.hasPrefix("enter the authorization code") && text.hasSuffix(":") {
                var code: String?
                if let ask = options.requestAuthorizationCode, let current = link { code = try await ask(current) }
                guard let code, !AWSCLIText.trimmed(code).isEmpty else {
                    lock.withLock { _gaveUp = true }
                    stopRun()
                    return nil
                }
                return AWSCLIText.trimmed(code)
            }
            return nil
        }
    }

    // MARK: Reading what the CLI said

    /// What a finished `aws login` / `aws sso login` run means.
    public static func interpret(_ result: AWSCLIResult, link: AWSSignInLink? = nil) -> AWSSignInResult {
        if result.succeeded { return AWSSignInResult(outcome: .signedIn, message: "Signed in to AWS.", link: link) }
        let text = (result.stderr + "\n" + result.stdout).lowercased()
        let details = AWSCLIErrors.cleanMessage(AWSCLIText.trimmed(result.stderr).isEmpty ? result.stdout : result.stderr)
        func has(_ phrase: String) -> Bool { text.contains(phrase.lowercased()) }
        func outcome(_ outcome: AWSSignInOutcome, _ message: String) -> AWSSignInResult {
            AWSSignInResult(outcome: outcome, message: message, link: link, details: details)
        }
        if result.timedOut || has("pending authorization to retrieve an SSO token has expired") {
            return outcome(.timedOut, "The sign-in page wasn't completed in time. Start the sign-in again and finish it in the browser.")
        }
        if result.exitCode == 130 { return outcome(.cancelled, "Sign-in stopped.") }
        if has("is already configured with") {
            return outcome(.profileHasOtherCredentials,
                           "That AWS profile already has other credentials, which the browser sign-in won't replace. Let DSH sign in with its own profile (\"\(defaultProfile)\") instead.")
        }
        if has("Found invalid choice") || has("Invalid choice") || has("Unknown options") {
            return outcome(.cliTooOld,
                           "This AWS CLI can't sign in this way yet (it needs version \(AWSCLI.minimumVersion) or newer). Update the AWS CLI — DSH can do it for you.")
        }
        if has("Failed to retrieve an auth_code or state") || has("Failed to decode the verification code") || has("does not match expected value") {
            return outcome(.failed, "That authorization code wasn't accepted. Copy the whole code the browser shows and try again.")
        }
        if has("expired authorization code") {
            return outcome(.timedOut, "The authorization code expired before it was used. Sign in again and paste the new code straight away.")
        }
        if has("Unable to initialize the OAuth 2.0 authorization callback handler") {
            return outcome(.failed, "The AWS CLI couldn't open a local port for the browser to come back to. Try again, choose another port, or use the sign-in for machines without a browser.")
        }
        let error = AWSCLIErrors.classify(result, service: "signin")
        switch error.kind {
        case .accessDenied: return outcome(.notAllowed, error.message)
        case .network: return outcome(.failed, error.message)
        default: return outcome(.failed, "Sign-in didn't finish: \(details)")
        }
    }

    /// The sign-in URL on a line of the CLI's output (it prints the URL alone on its line).
    public static func extractSignInURL(_ line: String) -> URL? {
        let trimmed = AWSCLIText.trimmed(line)
        guard trimmed.lowercased().hasPrefix("https://"), !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// IAM Identity Center device codes look like "ABCD-EFGH".
    fileprivate static let userCodeRegex = AWSCLIRegex(#"^[A-Z0-9]{4}-[A-Z0-9]{4}$"#)
}
