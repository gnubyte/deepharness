import Foundation

// MARK: - The AWS CLI: the contract the setup layer is written against
//
// The app never talks to AWS's sign-in or account APIs itself: the AWS CLI (v2) owns sign-in
// (`aws login`, `aws sso login`), keeps and refreshes the tokens, and makes the account calls
// (Bedrock model access, agreements, the Anthropic use-case form). The app runs it as a child
// process — never through a shell — and reads its JSON output. The pieces that need only "run a
// command and give me its JSON" (Bedrock setup, the credential source) depend on `AWSCLICommands`,
// so they are testable with scripted output and no AWS account.

/// What one run of the AWS CLI printed and how it ended.
public struct AWSCLIResult: Sendable, Equatable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
    /// True when the app stopped it because it ran past its time limit (the exit code is then -1).
    public var timedOut: Bool

    public init(exitCode: Int, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum AWSCLIFailure: Sendable, Equatable {
    /// Not signed in, or the sign-in ran out: sign in again.
    case signInRequired
    /// An IAM policy doesn't allow the call (`AWSCLIError.permission` says which).
    case accessDenied
    /// This CLI doesn't know the command or option: it is too old.
    case notSupported
    /// AWS couldn't be reached (offline, proxy, VPN, TLS inspection).
    case network
    case throttled
    case notFound
    case conflict
    /// AWS rejected the request's contents (ValidationException, bad parameters, no Region).
    case invalid
    case timedOut
    case other
}

/// What went wrong, for people (`message`) and for the log (`details`).
public struct AWSCLIError: Sendable, Equatable {
    public var kind: AWSCLIFailure
    public var message: String
    public var code: String?
    public var operation: String?
    /// The IAM action that was refused, e.g. "bedrock:ListFoundationModels".
    public var permission: String?
    public var details: String

    public init(kind: AWSCLIFailure, message: String, code: String? = nil, operation: String? = nil,
                permission: String? = nil, details: String = "") {
        self.kind = kind
        self.message = message
        self.code = code
        self.operation = operation
        self.permission = permission
        self.details = details
    }
}

/// An AWS CLI command failed for a reason other than the sign-in (a sign-in problem is an
/// `AWSSignInRequiredError`, which the app answers by opening the browser).
public struct AWSCLIException: Error, LocalizedError, Sendable {
    public let error: AWSCLIError
    public init(_ error: AWSCLIError) { self.error = error }
    public var kind: AWSCLIFailure { error.kind }
    public var errorDescription: String? { error.message }
}

/// "Run an AWS CLI command for a profile and Region": the surface `BedrockSetup` and friends use.
public protocol AWSCLICommands: Sendable {
    /// Run `aws <command> [--profile P] [--region R] --output json` and parse what it printed (an
    /// empty object when it printed nothing, as commands without a response body do). Failures throw
    /// `AWSSignInRequiredError` (sign in again) or `AWSCLIException` with a plain-language message.
    func runJSON(_ command: [String], profile: String?, region: String?, timeout: TimeInterval?) async throws -> JSONValue

    /// Run a command that must succeed; same failures as `runJSON`.
    func runChecked(_ command: [String], profile: String?, region: String?, timeout: TimeInterval?) async throws -> AWSCLIResult
}

public extension AWSCLICommands {
    func runJSON(_ command: [String], profile: String?, region: String?) async throws -> JSONValue {
        try await runJSON(command, profile: profile, region: region, timeout: nil)
    }

    func runChecked(_ command: [String], profile: String?, region: String?) async throws -> AWSCLIResult {
        try await runChecked(command, profile: profile, region: region, timeout: nil)
    }
}
