import Foundation
@testable import VisionHarnessCore

// MARK: - A scripted AWS CLI

/// A fake `AWSCLICommands` that answers from a script and records every call. Nothing is launched and
/// nothing touches AWS. Each rule matches the calls whose command words start with a given prefix
/// (the first matching rule wins) and gives fixed output, a failure, or a sequence of those (successive
/// calls get successive steps and the last repeats). The Windows tests' `FakeAwsCliRunner`, one level up:
/// it sits above the CLI's error reading, so a failure is scripted as the error the CLI layer would have
/// made of it (`ScriptedCLIFailure`).
final class ScriptedAWSCLI: AWSCLICommands, @unchecked Sendable {
    /// What one call to a rule does.
    enum Step: Sendable {
        /// The CLI succeeded and printed this (an empty text is the empty object, as with the real CLI).
        case output(String)
        /// The CLI failed with this error.
        case fail(ScriptedCLIFailure)
    }

    struct Call: Equatable, Sendable {
        enum Kind: Sendable { case json, checked }
        var kind: Kind
        var command: [String]
        var profile: String?
        var region: String?
        var timeout: TimeInterval?

        /// "--model-id" followed by "x" somewhere in the command.
        func hasPair(_ name: String, _ value: String) -> Bool {
            command.indices.dropLast().contains { command[$0] == name && command[$0 + 1] == value }
        }

        var joined: String { command.joined(separator: " ") }
    }

    /// Nobody scripted an answer for this call.
    struct NoAnswer: Error, CustomStringConvertible {
        let command: [String]
        var description: String { "No scripted AWS CLI answer for: aws \(command.joined(separator: " "))" }
    }

    /// The code under test kept calling the CLI without end (a polling loop that never stops): the fake gives
    /// up instead of letting the test run away with the machine's memory.
    struct RunawayLoop: Error, CustomStringConvertible {
        let calls: Int
        var description: String { "The code under test made \(calls) AWS CLI calls: an endless loop?" }
    }

    /// More calls than any test here needs (the most is a 15-minute wait: 61 checks).
    static let runawayLimit = 2_000

    private struct Rule {
        var prefix: [String]
        var steps: [Step]
        var next = 0
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var recorded: [Call] = []
    private var honorsCancellation = true

    /// Like the real CLI, a call made by a cancelled task stops with `CancellationError` before anything is
    /// recorded. Turn it off to check that the code under test notices cancellation by itself.
    var checksCancellation: Bool {
        get { lock.withLock { honorsCancellation } }
        set { lock.withLock { honorsCancellation = newValue } }
    }

    /// Calls starting with `prefix` get this output (first matching rule wins).
    @discardableResult
    func on(_ prefix: [String], _ stdout: String = "") -> ScriptedAWSCLI {
        onSequence(prefix, [.output(stdout)])
    }

    /// Calls starting with `prefix` fail like this.
    @discardableResult
    func fail(_ prefix: [String], _ failure: ScriptedCLIFailure) -> ScriptedAWSCLI {
        onSequence(prefix, [.fail(failure)])
    }

    /// Successive calls get successive steps; the last one repeats.
    @discardableResult
    func onSequence(_ prefix: [String], _ steps: [Step]) -> ScriptedAWSCLI {
        precondition(!steps.isEmpty)
        lock.withLock { rules.append(Rule(prefix: prefix, steps: steps)) }
        return self
    }

    var calls: [Call] { lock.withLock { recorded } }

    func calls(to prefix: String...) -> [Call] {
        calls.filter { $0.command.starts(with: prefix) }
    }

    // MARK: AWSCLICommands

    func runJSON(_ command: [String], profile: String?, region: String?, timeout: TimeInterval?) async throws -> JSONValue {
        let text = try step(.json, command, profile, region, timeout)
        // As the real CLI layer reads output: nothing is the empty object; something unreadable is an error.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        guard let value = JSONValue(parsing: trimmed) else {
            throw AWSCLIException(AWSCLIError(kind: .other, message: "The AWS CLI answered with something DSH couldn't read.",
                                              details: String(trimmed.prefix(500))))
        }
        return value
    }

    func runChecked(_ command: [String], profile: String?, region: String?, timeout: TimeInterval?) async throws -> AWSCLIResult {
        AWSCLIResult(exitCode: 0, stdout: try step(.checked, command, profile, region, timeout))
    }

    private func step(_ kind: Call.Kind, _ command: [String], _ profile: String?, _ region: String?, _ timeout: TimeInterval?) throws -> String {
        if checksCancellation { try Task.checkCancellation() }
        let (chosen, count): (Step?, Int) = lock.withLock {
            recorded.append(Call(kind: kind, command: command, profile: profile, region: region, timeout: timeout))
            guard let index = rules.firstIndex(where: { command.starts(with: $0.prefix) }) else { return (nil, recorded.count) }
            let step = rules[index].steps[min(rules[index].next, rules[index].steps.count - 1)]
            rules[index].next += 1
            return (step, recorded.count)
        }
        if count > Self.runawayLimit { throw RunawayLoop(calls: count) }
        switch chosen {
        case nil: throw NoAnswer(command: command)
        case .output(let text)?: return text
        case .fail(let failure)?: throw failure.error(profile: profile)
        }
    }
}

// MARK: - The failures the CLI layer makes of the AWS CLI's error output

/// The error the CLI layer turns a failed `aws` run into, for the error texts the setup tests use. Each
/// is exactly what the Windows app's `AwsCliErrors.Classify` makes of the CLI's legacy-format line (the
/// dsh-windows repository's tests script those lines; these are the results, checked against it), so a
/// test can say "the CLI printed an access-denied error" without depending on the CLI layer being tested.
struct ScriptedCLIFailure: Sendable {
    private var make: @Sendable (String?) -> any Error

    func error(profile: String?) -> any Error { make(profile) }

    private init(_ make: @escaping @Sendable (String?) -> any Error) { self.make = make }

    private static func cli(_ error: AWSCLIError) -> ScriptedCLIFailure {
        ScriptedCLIFailure { _ in AWSCLIException(error) }
    }

    /// The line the CLI prints: "aws: [ERROR]: An error occurred (Code) when calling the Op operation: message".
    static func line(code: String, operation: String, message: String) -> String {
        "aws: [ERROR]: An error occurred (\(code)) when calling the \(operation) operation: \(message)"
    }

    private static let deniedAdvice = "Ask whoever manages your AWS account to allow it — DSH can show the exact policy to send them."

    /// AccessDeniedException naming the refused action ("… is not authorized to perform: bedrock:X because …").
    static func accessDenied(operation: String, permission: String) -> ScriptedCLIFailure {
        let text = line(code: "AccessDeniedException", operation: operation,
                        message: "User: arn:aws:iam::111122223333:user/alice is not authorized to perform: \(permission) because no identity-based policy allows the \(permission) action")
        return cli(AWSCLIError(kind: .accessDenied, message: "Your AWS permissions don't allow \(permission). \(deniedAdvice)",
                               code: "AccessDeniedException", operation: operation, permission: permission, details: text))
    }

    /// AccessDeniedException that doesn't name the action: the app names it "bedrock:<Operation>".
    static func accessDeniedWithoutAction(operation: String, message: String = "denied") -> ScriptedCLIFailure {
        let text = line(code: "AccessDeniedException", operation: operation, message: message)
        let permission = "bedrock:\(operation)"
        return cli(AWSCLIError(kind: .accessDenied, message: "Your AWS permissions don't allow \(permission). \(deniedAdvice)",
                               code: "AccessDeniedException", operation: operation, permission: permission, details: text))
    }

    /// AccessDenied that names neither the action nor the operation ("An error occurred (AccessDenied): Access
    /// Denied"): the app has nothing to name the permission after.
    static let accessDeniedUnnamed = cli(AWSCLIError(
        kind: .accessDenied, message: "Your AWS permissions don't allow this. \(deniedAdvice)", code: "AccessDenied",
        details: "aws: [ERROR]: An error occurred (AccessDenied): Access Denied"))

    /// ResourceNotFoundException: the message is AWS's own.
    static func notFound(operation: String, message: String) -> ScriptedCLIFailure {
        cli(AWSCLIError(kind: .notFound, message: message, code: "ResourceNotFoundException", operation: operation,
                        details: line(code: "ResourceNotFoundException", operation: operation, message: message)))
    }

    static func conflict(operation: String, message: String) -> ScriptedCLIFailure {
        cli(AWSCLIError(kind: .conflict, message: message, code: "ConflictException", operation: operation,
                        details: line(code: "ConflictException", operation: operation, message: message)))
    }

    /// ValidationException: "AWS didn't accept the request: …".
    static func validation(operation: String, message: String) -> ScriptedCLIFailure {
        cli(AWSCLIError(kind: .invalid, message: "AWS didn't accept the request: \(message)", code: "ValidationException",
                        operation: operation, details: line(code: "ValidationException", operation: operation, message: message)))
    }

    static func throttled(operation: String) -> ScriptedCLIFailure {
        cli(AWSCLIError(kind: .throttled, message: "AWS is busy right now (too many requests). Wait a moment and try again.",
                        code: "ThrottlingException", operation: operation,
                        details: line(code: "ThrottlingException", operation: operation, message: "Rate exceeded")))
    }

    /// Any other AWS error (InternalServerException, …): its message, kind `.other`.
    static func service(code: String, operation: String, message: String) -> ScriptedCLIFailure {
        cli(AWSCLIError(kind: .other, message: message, code: code, operation: operation,
                        details: line(code: code, operation: operation, message: message)))
    }

    /// The SSO token ran out: not a CLI error but the sign-in-again error, for the profile of the call.
    static let ssoExpired = ScriptedCLIFailure { profile in
        AWSSignInRequiredError(profile: (profile?.isEmpty ?? true) ? "default" : profile!,
                               message: "Your AWS IAM Identity Center (SSO) sign-in has expired. Sign in again.")
    }

    /// Any error at all (a cancellation, an I/O failure).
    static func error(_ error: any Error) -> ScriptedCLIFailure {
        ScriptedCLIFailure { _ in error }
    }
}

// MARK: - A clock that jumps

/// The clock and sleep `BedrockSetup` waits with, without waiting: sleeping moves the time on by the
/// delay and returns at once, so a 15-minute polling loop runs instantly and exactly. Records every
/// delay. (The Windows tests' `BedrockWaitClock`.)
final class BedrockWaitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recordedDelays: [TimeInterval] = []
    /// Called (outside the lock) on every sleep, before the time moves: lets a test cancel mid-wait.
    var onSleep: (@Sendable () -> Void)?

    let start: Date

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.start = start
        current = start
    }

    var now: Date { lock.withLock { current } }

    var delays: [TimeInterval] { lock.withLock { recordedDelays } }

    var elapsed: TimeInterval { now.timeIntervalSince(start) }

    func sleep(_ seconds: TimeInterval) async throws {
        onSleep?()
        try Task.checkCancellation()
        lock.withLock {
            recordedDelays.append(seconds)
            current = current.addingTimeInterval(seconds)
        }
    }

    /// `BedrockSetup`'s `now` and `sleep` parameters.
    var nowClosure: @Sendable () -> Date { { [self] in now } }
    var sleepClosure: @Sendable (TimeInterval) async throws -> Void { { [self] seconds in try await sleep(seconds) } }
}

/// Progress reports, collected in order (the callback may run on any thread).
final class BedrockProgressLog<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    /// Called (outside the lock) after each report is recorded.
    var onReport: (@Sendable (Element) -> Void)?

    var all: [Element] { lock.withLock { items } }

    var callback: @Sendable (Element) -> Void {
        { [self] value in
            lock.withLock { items.append(value) }
            onReport?(value)
        }
    }
}
