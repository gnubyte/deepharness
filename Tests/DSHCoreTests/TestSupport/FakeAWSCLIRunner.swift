import XCTest
@testable import DSHCore

// MARK: - A scripted AWS CLI, and the small tools the AWS tests share
//
// Nothing here launches a process or touches AWS: `FakeAWSCLIRunner` answers calls by command prefix,
// records them, and can play an interactive run (lines, prompts, waiting for a cancel).

/// One step of a scripted interactive CLI run.
enum FakeAWSCLIStep {
    /// A finished line of output.
    case line(String, isError: Bool = false)
    /// A question without a newline; the run waits for the answer (forever, like the real CLI, when
    /// nobody answers — only cancelling ends it).
    case prompt(String)
    /// Wait until the run is cancelled.
    case hang
}

/// A scripted `AWSCLIRunner`: each rule matches calls whose arguments start with a given command,
/// answers with fixed output (or a script with prompts), and every call is recorded.
final class FakeAWSCLIRunner: AWSCLIRunner, @unchecked Sendable {
    struct Call: Sendable {
        let args: [String]
        let options: AWSCLIRunOptions

        /// "--profile" followed by "p" somewhere in the arguments.
        func hasPair(_ name: String, _ value: String) -> Bool {
            zip(args, args.dropFirst()).contains { $0 == name && $1 == value }
        }

        var joined: String { args.joined(separator: " ") }
    }

    struct NoAnswer: Error, CustomStringConvertible {
        let description: String
    }

    private let lock = NSLock()
    private var rules: [(prefix: [String], respond: @Sendable (Call) async throws -> AWSCLIResult)] = []
    private var recorded: [Call] = []
    private var recordedAnswers: [(prompt: String, answer: String?)] = []

    var calls: [Call] { lock.withLock { recorded } }

    /// Every prompt offered to the answerer and what it answered.
    var answers: [(prompt: String, answer: String?)] { lock.withLock { recordedAnswers } }

    func calls(to prefix: [String]) -> [Call] { calls.filter { Self.starts($0.args, with: prefix) } }

    /// Calls starting with `prefix` get this output (the first matching rule wins).
    @discardableResult
    func on(_ prefix: [String], stdout: String = "", stderr: String = "", exitCode: Int = 0) -> FakeAWSCLIRunner {
        on(prefix) { _ in AWSCLIResult(exitCode: exitCode, stdout: stdout, stderr: stderr) }
    }

    /// A failure as the CLI prints it (legacy error format).
    @discardableResult
    func fail(_ prefix: [String], stderr: String, exitCode: Int = 254) -> FakeAWSCLIRunner {
        on(prefix, stdout: "", stderr: "\n" + stderr + "\n", exitCode: exitCode)
    }

    /// Successive calls get successive results; the last one repeats.
    @discardableResult
    func onSequence(_ prefix: [String], _ results: [AWSCLIResult]) -> FakeAWSCLIRunner {
        let index = AWSLockedBox(0)
        return on(prefix) { _ in
            let next = index.mutate { value -> Int in defer { value += 1 }; return value }
            return results[min(next, results.count - 1)]
        }
    }

    @discardableResult
    func on(_ prefix: [String], respond: @escaping @Sendable (Call) async throws -> AWSCLIResult) -> FakeAWSCLIRunner {
        lock.withLock { rules.append((prefix, respond)) }
        return self
    }

    /// An interactive run: lines go to `onLine`, prompts to the answerer (whose answers are recorded),
    /// then it ends with `final` (its stdout appended to what was printed).
    @discardableResult
    func onInteractive(_ prefix: [String], _ steps: [FakeAWSCLIStep], final: AWSCLIResult) -> FakeAWSCLIRunner {
        on(prefix) { [self] call in
            var stdout = ""
            var stderr = ""
            for step in steps {
                switch step {
                case .line(let text, let isError):
                    if isError { stderr += text + "\n" } else { stdout += text + "\n" }
                    call.options.onLine?(AWSCLILine(text, isError: isError))
                case .prompt(let text):
                    stdout += text
                    let answer = try await call.options.answerPrompt?(text)
                    lock.withLock { recordedAnswers.append((text, answer)) }
                    if answer == nil { try await Self.waitUntilCancelled() }
                    stdout += "\n"
                case .hang:
                    try await Self.waitUntilCancelled()
                }
            }
            return AWSCLIResult(exitCode: final.exitCode, stdout: stdout + final.stdout, stderr: stderr + final.stderr, timedOut: final.timedOut)
        }
    }

    func run(_ args: [String], options: AWSCLIRunOptions) async throws -> AWSCLIResult {
        try Task.checkCancellation()
        let call = Call(args: args, options: options)
        let respond: (@Sendable (Call) async throws -> AWSCLIResult)? = lock.withLock {
            recorded.append(call)
            return rules.first { Self.starts(args, with: $0.prefix) }?.respond
        }
        guard let respond else { throw NoAnswer(description: "No fake AWS CLI answer for: aws \(call.joined)") }
        return try await respond(call)
    }

    private static func starts(_ args: [String], with prefix: [String]) -> Bool {
        args.count >= prefix.count && zip(args, prefix).allSatisfy { $0 == $1 }
    }

    /// Sleeps until the task is cancelled (which throws `CancellationError`).
    static func waitUntilCancelled() async throws {
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }
}

// MARK: - Small shared tools

/// A value several threads touch (callbacks arrive on background queues).
final class AWSLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    @discardableResult
    func mutate<Result>(_ change: (inout Value) -> Result) -> Result { lock.withLock { change(&stored) } }
}

extension AWSLockedBox where Value: RangeReplaceableCollection {
    func append(_ element: Value.Element) { mutate { $0.append(element) } }
}

/// A clock the test moves by hand.
final class AWSTestClock: @unchecked Sendable {
    /// 2026-09-29 12:00:00 UTC.
    static let epoch = Date(timeIntervalSince1970: 1_790_683_200)

    private let current: AWSLockedBox<Date>

    init(_ start: Date = AWSTestClock.epoch) { current = AWSLockedBox(start) }

    var now: Date { current.value }

    func advance(by seconds: TimeInterval) { current.mutate { $0 = $0.addingTimeInterval(seconds) } }

    /// For `AWSCLICredentialSource(now:)`.
    var reader: @Sendable () -> Date { { [self] in now } }
}

/// Cancels a task that doesn't exist yet: the callback that asks for it can fire before the task's
/// handle has been stored.
final class AWSCancelSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var requested = false

    func arm(_ action: @escaping @Sendable () -> Void) {
        let fireNow: Bool = lock.withLock {
            self.action = action
            return requested
        }
        if fireNow { action() }
    }

    func fire() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            requested = true
            return self.action
        }
        action?()
    }
}

/// A scratch folder under $TMPDIR (the sandbox refuses the system's temporary folder), removed by
/// the test's teardown.
final class AWSScratchDirectory: @unchecked Sendable {
    let path: String

    init(_ label: String) {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        path = URL(fileURLWithPath: base).appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    subscript(name: String) -> String { path + "/" + name }

    /// Write a text file (creating folders as needed); returns its path.
    @discardableResult
    func write(_ name: String, _ text: String, executable: Bool = false) -> String {
        writeData(name, Data(text.utf8), executable: executable)
    }

    @discardableResult
    func writeData(_ name: String, _ data: Data, executable: Bool = false) -> String {
        let file = self[name]
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: file))
        chmod(file, executable ? 0o755 : 0o644)
        return file
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: self[name]) }

    func remove() { try? FileManager.default.removeItem(atPath: path) }

    /// Every file under the folder (relative to it), sorted.
    func files() -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: path) else { return [] }
        return (walker.allObjects as? [String] ?? []).filter {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: self[$0], isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }.sorted()
    }
}

extension XCTestCase {
    /// A scratch folder that goes away when the test ends.
    func awsScratch(_ label: String = "dsh-aws") -> AWSScratchDirectory {
        let directory = AWSScratchDirectory(label)
        addTeardownBlock { directory.remove() }
        return directory
    }

    /// Runs `body`, which must throw an error of type `Expected`; returns it (nil, after recording a
    /// failure, when nothing or something else was thrown).
    func awsAssertThrows<Expected: Error>(_ type: Expected.Type, file: StaticString = #filePath, line: UInt = #line,
                                       _ body: () async throws -> Void) async -> Expected? {
        do {
            try await body()
            XCTFail("expected \(Expected.self) to be thrown", file: file, line: line)
        } catch let error as Expected {
            return error
        } catch {
            XCTFail("expected \(Expected.self), got \(error)", file: file, line: line)
        }
        return nil
    }

    /// Waits for `task` and says how it ended; a task that never ends fails the test (instead of hanging
    /// the run) and returns nil.
    func awsOutcome<Value: Sendable>(of task: Task<Value, any Error>, within seconds: TimeInterval = 30,
                                     file: StaticString = #filePath, line: UInt = #line) async -> Result<Value, any Error>? {
        let finished = AWSCLIGate()
        let outcome = AWSLockedBox<Result<Value, any Error>?>(nil)
        Task {
            let result = await task.result
            outcome.mutate { $0 = result }
            finished.open()
        }
        guard await finished.wait(upTo: seconds) else {
            XCTFail("the task hadn't ended after \(Int(seconds)) seconds", file: file, line: line)
            return nil
        }
        return outcome.value
    }

    /// The task must end by throwing `CancellationError` (and must end at all: false when it didn't).
    @discardableResult
    func awsExpectCancelled<Value: Sendable>(_ task: Task<Value, any Error>, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        guard let outcome = await awsOutcome(of: task, file: file, line: line) else { return false }
        switch outcome {
        case .success: XCTFail("expected CancellationError, but the task succeeded", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)", file: file, line: line)
        }
        return true
    }

    /// Polls until `condition` holds (up to `seconds`).
    func awsWaitUntil(_ seconds: TimeInterval = 5, _ message: @autoclosure () -> String = "condition", file: StaticString = #filePath,
                   line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for \(message())", file: file, line: line)
    }
}
