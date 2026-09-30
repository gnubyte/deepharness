import Foundation
import Darwin

// MARK: - The AWS CLI
//
// The app never talks to AWS's sign-in or account APIs itself: the AWS CLI (v2) owns sign-in
// (`aws login`, `aws sso login`), keeps and refreshes the tokens, and makes the account calls (Bedrock
// model access, agreements, the Anthropic use-case form). The app runs it as a child process — never
// through a shell, so no argument is ever re-parsed — and reads its JSON output. Everything goes
// through `AWSCLIRunner`, so the setup flow is testable with scripted output and no AWS account.
// (`AWSCLITypes.swift` holds the result and error types and the `AWSCLICommands` contract.)

// MARK: Running a command

/// One finished line of output, as it arrived.
public struct AWSCLILine: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// How to run one AWS CLI command.
public struct AWSCLIRunOptions: Sendable {
    /// Text typed into the CLI's standard input before it is closed (ignored when `answerPrompt` is
    /// set). With neither, standard input is closed at once, so a question nobody expected ends the
    /// command instead of hanging it.
    public var standardInput: String?

    /// Answers the CLI's interactive questions. It is called with the unfinished last line of output —
    /// prompts such as "(y/n): " never end with a newline — each time more of it arrives, and returns
    /// what to type (a newline is added) or nil when that line isn't a question it knows. Once a line
    /// is answered it isn't offered again. Standard input stays open while it is set. It runs inside
    /// the run's task tree, so it sees cancellation (a closed window, a timeout) like any other work;
    /// if it throws, the CLI is stopped and the error is what `run` throws.
    public var answerPrompt: (@Sendable (String) async throws -> String?)?

    /// Extra environment variables for the CLI; a nil value removes the variable.
    public var environment: [String: String?]

    /// Each finished line of output (standard output and standard error), as it arrives, on a
    /// background queue.
    public var onLine: (@Sendable (AWSCLILine) -> Void)?

    /// Stop the CLI after this many seconds (nil = no limit). A timed-out run returns a result with
    /// `timedOut` set rather than throwing.
    public var timeout: TimeInterval?

    public init(standardInput: String? = nil,
                answerPrompt: (@Sendable (String) async throws -> String?)? = nil,
                environment: [String: String?] = [:],
                onLine: (@Sendable (AWSCLILine) -> Void)? = nil,
                timeout: TimeInterval? = nil) {
        self.standardInput = standardInput
        self.answerPrompt = answerPrompt
        self.environment = environment
        self.onLine = onLine
        self.timeout = timeout
    }
}

/// The program couldn't be started at all (missing, not executable, no permission).
public struct AWSCLIStartError: Error, LocalizedError, Sendable, Equatable {
    public let executable: String
    public let reason: String

    public init(executable: String, reason: String) {
        self.executable = executable
        self.reason = reason
    }

    public var errorDescription: String? { "Couldn't start the AWS CLI (\(executable)): \(reason)" }
}

/// Runs the AWS CLI. The real one starts the `aws` executable (`ProcessAWSCLIRunner`); tests script
/// the answers.
public protocol AWSCLIRunner: Sendable {
    /// Run `aws <args>`. Cancelling the task stops the CLI (and anything it started) and throws
    /// `CancellationError`; a program that can't start throws `AWSCLIStartError`.
    func run(_ args: [String], options: AWSCLIRunOptions) async throws -> AWSCLIResult
}

public extension AWSCLIRunner {
    func run(_ args: [String]) async throws -> AWSCLIResult {
        try await run(args, options: AWSCLIRunOptions())
    }
}

// MARK: - The real runner

/// Runs a real AWS CLI executable. The arguments go straight to the program (no shell, no quoting to
/// get wrong), output is read as UTF-8, and the environment is set so the CLI never waits on a pager,
/// an auto-prompt or the "set up your AI agent" question. Cancelling or timing out stops the CLI and
/// everything it started: it runs in its own process group, which gets SIGTERM and, if anything
/// ignores that, SIGKILL after a short grace period.
public final class ProcessAWSCLIRunner: AWSCLIRunner, Sendable {
    /// The program started: `aws`, or (for the installer's package checks and Homebrew) any other
    /// program given by its full path.
    public let executable: String

    private let baseEnvironment: [String: String]?
    private let killGrace: TimeInterval
    private let outputGrace: TimeInterval

    /// Set for every run. AWS_PAGER="" keeps output from being piped to a pager; the agent toolkit
    /// hint (CLI 2.36.50+) would otherwise ask a y/n question after a first `aws login`; auto-prompt
    /// would open an interactive command builder; UTF-8 so names with accents survive
    /// (AWS_CLI_OUTPUT_ENCODING is the CLI's own switch, PYTHONUTF8/PYTHONIOENCODING the older ones);
    /// the legacy error format is the one plain "An error occurred (Code) ..." line every 2.x prints.
    public static let standardEnvironment: [String: String] = [
        "AWS_PAGER": "",
        "AWS_CLI_AGENT_TOOLKIT_HINT_DISABLED": "true",
        "AWS_CLI_AUTO_PROMPT": "off",
        "AWS_CLI_OUTPUT_ENCODING": "UTF-8",
        "AWS_CLI_ERROR_FORMAT": "legacy",
        "PYTHONUTF8": "1",
        "PYTHONIOENCODING": "utf-8",
    ]

    /// Where the tools a profile might call (`credential_process` programs, Homebrew's) live. A GUI
    /// app inherits only /usr/bin:/bin:/usr/sbin:/sbin, so these are appended when missing.
    static let extraToolDirectories = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin"]

    public init(executable: String) {
        self.executable = executable
        self.baseEnvironment = nil
        self.killGrace = 2
        self.outputGrace = 2
    }

    /// For tests: a fixed base environment and short grace periods.
    init(executable: String, baseEnvironment: [String: String]?, killGrace: TimeInterval, outputGrace: TimeInterval) {
        self.executable = executable
        self.baseEnvironment = baseEnvironment
        self.killGrace = killGrace
        self.outputGrace = outputGrace
    }

    /// The environment of one run: this process's, plus `standardEnvironment`, plus a usable HOME and
    /// PATH, plus the caller's overrides (a nil value removes a variable — applied last, so a caller
    /// can remove even HOME).
    static func environment(base: [String: String], overrides: [String: String?], home: String = NSHomeDirectory()) -> [String: String] {
        var env = base
        for (name, value) in standardEnvironment { env[name] = value }
        if (env["HOME"] ?? "").isEmpty { env["HOME"] = home }
        var directories = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        for extra in extraToolDirectories + [(env["HOME"] ?? home) + "/.local/bin"] where !directories.contains(extra) {
            directories.append(extra)
        }
        env["PATH"] = directories.joined(separator: ":")
        for (name, value) in overrides {
            if let value { env[name] = value } else { env.removeValue(forKey: name) }
        }
        return env
    }

    public func run(_ args: [String], options: AWSCLIRunOptions) async throws -> AWSCLIResult {
        try Task.checkCancellation()
        let environment = Self.environment(base: baseEnvironment ?? ProcessInfo.processInfo.environment, overrides: options.environment)
        let run = AWSCLIProcessRun(executable: executable, arguments: args, options: options, environment: environment,
                                   killGrace: killGrace, outputGrace: outputGrace)
        return try await withTaskCancellationHandler {
            try await run.execute()
        } onCancel: {
            run.cancel()
        }
    }
}

// MARK: Process plumbing

/// A one-shot event that async code can wait for, optionally for a limited time. Waiting is not
/// cancellable on purpose: it is used for clean-up after a cancellation, when the task is already
/// cancelled and must still wait for the child to be gone.
final class AWSCLIGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var nextID = 0

    var opened: Bool { lock.withLock { isOpen } }

    func open() {
        let toResume: [CheckedContinuation<Bool, Never>] = lock.withLock {
            guard !isOpen else { return [] }
            isOpen = true
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        for waiter in toResume { waiter.resume(returning: true) }
    }

    /// True once opened; false if `limit` seconds passed first.
    @discardableResult
    func wait(upTo limit: TimeInterval? = nil) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let id: Int? = lock.withLock {
                if isOpen { return nil }
                let id = nextID
                nextID += 1
                waiters[id] = continuation
                return id
            }
            guard let id else {
                continuation.resume(returning: true)
                return
            }
            if let limit {
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0, limit)) { [self] in
                    let expired = lock.withLock { waiters.removeValue(forKey: id) }
                    expired?.resume(returning: false)
                }
            }
        }
    }

    /// A sleep that a cancelled task cannot cut short.
    static func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) { continuation.resume() }
        }
    }
}

/// Writes to the child's standard input, in order, off the caller's thread. The descriptor is only
/// touched on one serial queue, so a late write can never hit a descriptor number that has been
/// closed and reused.
private final class AWSCLIStdinWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dsh.aws-cli.stdin")
    private let fd: Int32
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        // A write to a child that already exited must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written > 0 { offset += written; continue }
                    if written < 0 && errno == EINTR { continue }
                    return // EPIPE: it exited before reading; its output says why.
                }
            }
        }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }
}

/// Reads one pipe without a thread parked in `read`: a dispatch source reports when bytes are there,
/// and can be cancelled when a grandchild (a browser the CLI opened) keeps the pipe open after the CLI
/// itself is gone. `onClose` runs on the reader's queue after the last chunk — at end of file or
/// after `stop()` — and the descriptor is closed by then.
private final class AWSCLIPipeReader: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let queue: DispatchQueue

    init(fd: Int32, label: String, onChunk: @escaping @Sendable ([UInt8]) -> Void, onClose: @escaping @Sendable () -> Void) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        queue = DispatchQueue(label: label)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let source = source
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    onChunk(Array(buffer[0..<count]))
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
                source.cancel() // end of file, or the pipe broke
                return
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
            onClose()
        }
    }

    func start() { source.resume() }
    func stop() { source.cancel() }
}

/// Turns one stream's bytes into finished lines (ANSI stripped, trailing CRs trimmed) and keeps the
/// unfinished last line for the prompt answerer. Fed from that stream's reader queue.
private final class AWSCLIStreamPump: @unchecked Sendable {
    let isError: Bool
    private let wantsPrompts: Bool
    private let onLine: (@Sendable (AWSCLILine) -> Void)?
    private let lock = NSLock()
    private var all: [UInt8] = []
    private var pending: [UInt8] = []
    private var generation = 0
    private var answeredGeneration = -1

    init(isError: Bool, wantsPrompts: Bool = false, onLine: (@Sendable (AWSCLILine) -> Void)?) {
        self.isError = isError
        self.wantsPrompts = wantsPrompts
        self.onLine = onLine
    }

    var text: String { lock.withLock { String(decoding: all, as: UTF8.self) } }

    /// Feed a chunk; returns the unfinished last line and its generation when it is a candidate for
    /// the prompt answerer (non-empty and not answered yet).
    func consume(_ chunk: [UInt8]) -> (prompt: String, generation: Int)? {
        var finished: [String] = []
        let candidate: (String, Int)? = lock.withLock {
            all.append(contentsOf: chunk)
            var lineStart = 0
            for index in chunk.indices where chunk[index] == 0x0A {
                pending.append(contentsOf: chunk[lineStart..<index])
                finished.append(Self.decode(pending))
                pending.removeAll(keepingCapacity: true)
                generation += 1
                lineStart = index + 1
            }
            pending.append(contentsOf: chunk[lineStart...])
            guard wantsPrompts, !pending.isEmpty, answeredGeneration != generation else { return nil }
            return (AWSCLIText.stripANSI(String(decoding: pending, as: UTF8.self)), generation)
        }
        if let onLine { for line in finished { onLine(AWSCLILine(line, isError: isError)) } }
        return candidate
    }

    /// The stream ended: the last line had no newline.
    func flush() {
        let last: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return Self.decode(pending)
        }
        if let last { onLine?(AWSCLILine(last, isError: isError)) }
    }

    func isAnswered(_ generation: Int) -> Bool { lock.withLock { answeredGeneration == generation } }
    func markAnswered(_ generation: Int) { lock.withLock { answeredGeneration = generation } }

    private static func decode(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        while end > 0 && bytes[end - 1] == 0x0D { end -= 1 }
        return AWSCLIText.stripANSI(String(decoding: bytes[0..<end], as: UTF8.self))
    }
}

/// One run of one child process: pipes, readers, prompt answering, the time limit and the kill. All
/// mutable state is guarded by `lock`; `AWSCLIProcessRun.cancel()` may be called from any thread at
/// any time, including before the child exists.
private final class AWSCLIProcessRun: @unchecked Sendable {
    private struct PromptOffer: Sendable {
        let text: String
        let generation: Int
    }

    private let executable: String
    private let arguments: [String]
    private let options: AWSCLIRunOptions
    private let environment: [String: String]
    private let killGrace: TimeInterval
    private let outputGrace: TimeInterval

    private let lock = NSLock()
    private var process: Process?
    private var pid: pid_t = 0
    private var started = false
    private var exited = false
    private var exitCode = 0
    private var cancelRequested = false
    private var timedOut = false
    private var answerError: (any Error)?
    private var consumer: Task<Void, Never>?

    private let exitGate = AWSCLIGate()

    init(executable: String, arguments: [String], options: AWSCLIRunOptions, environment: [String: String],
         killGrace: TimeInterval, outputGrace: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.options = options
        self.environment = environment
        self.killGrace = killGrace
        self.outputGrace = outputGrace
    }

    // MARK: Cancelling

    /// Stop the CLI and everything it started. Safe from any thread, any number of times.
    func cancel() {
        let task: Task<Void, Never>? = lock.withLock {
            cancelRequested = true
            return consumer
        }
        task?.cancel()
        terminateTree()
    }

    private func timeoutFired() {
        let stop: Bool = lock.withLock {
            guard !exited, !cancelRequested else { return false }
            timedOut = true
            return true
        }
        if stop { terminateTree() }
    }

    private func failAnswer(_ error: any Error) {
        // Nobody can answer the question now; don't leave the CLI waiting for it. (An answerer that
        // fails because the run is already ending is not the story.)
        let stop: Bool = lock.withLock {
            guard !exited, !cancelRequested, !timedOut, answerError == nil else { return false }
            answerError = error
            return true
        }
        if stop { terminateTree() }
    }

    /// SIGTERM to the child's process group (it leads its own), then SIGKILL after the grace period
    /// for anything that ignored it.
    private func terminateTree() {
        let target: pid_t? = lock.withLock { started && !exited ? pid : nil }
        guard let target else { return }
        Self.signalGroup(target, SIGTERM)
        kill(target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [weak self] in
            self?.forceKill(target)
        }
    }

    private func forceKill(_ target: pid_t) {
        let leaderAlive = lock.withLock { !exited }
        if leaderAlive { kill(target, SIGKILL) }
        if Self.groupAlive(target) { Self.signalGroup(target, SIGKILL) }
    }

    /// Signal a whole process group. Only ever a real child's group: kill(-0) would be this process's own
    /// group and kill(-1) every process there is.
    private static func signalGroup(_ group: pid_t, _ signal: Int32) {
        guard group > 1 else { return }
        kill(-group, signal)
    }

    private static func groupAlive(_ group: pid_t) -> Bool {
        guard group > 1 else { return false }
        return kill(-group, 0) == 0 || errno == EPERM
    }

    // MARK: Running

    func execute() async throws -> AWSCLIResult {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: executable) else {
            throw AWSCLIStartError(executable: executable, reason: "the file doesn't exist.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AWSCLIStartError(executable: executable, reason: "it isn't an executable file.")
        }

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        var inPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0, pipe(&inPipe) == 0 else {
            let reason = String(cString: strerror(errno))
            for fd in outPipe + errPipe + inPipe where fd >= 0 { close(fd) }
            throw AWSCLIStartError(executable: executable, reason: "couldn't create pipes (\(reason)).")
        }
        // Only the child's own copies of these may survive an exec. Foundation's Process closes every
        // other descriptor in its children, but not every spawner in this app does (the terminal's
        // forkpty doesn't): a child started at the same moment would inherit our pipe ends and keep
        // them open after we close them, so end of file would wait for it.
        for fd in outPipe + errPipe + inPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle(fileDescriptor: inPipe[0], closeOnDealloc: false)
        child.standardOutput = FileHandle(fileDescriptor: outPipe[1], closeOnDealloc: false)
        child.standardError = FileHandle(fileDescriptor: errPipe[1], closeOnDealloc: false)
        child.terminationHandler = { [weak self] finished in self?.processExited(finished) }

        if lock.withLock({ cancelRequested }) {
            for fd in outPipe + errPipe + inPipe { close(fd) }
            throw CancellationError()
        }
        do {
            try await Self.spawn(child)
        } catch {
            for fd in outPipe + errPipe + inPipe { close(fd) }
            throw AWSCLIStartError(executable: executable, reason: error.localizedDescription)
        }
        // The parent's copies of the child's ends: closed, so end of file arrives when the child is gone.
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])
        defer { lock.withLock { process = nil } }
        let cancelledWhileStarting: Bool = lock.withLock {
            process = child
            pid = child.processIdentifier
            started = true
            return cancelRequested
        }
        if cancelledWhileStarting { terminateTree() }

        // Standard input: the text and then end of file, or held open for the answerer.
        let stdin = AWSCLIStdinWriter(fd: inPipe[1])
        let answer = options.answerPrompt
        if answer == nil {
            if let input = options.standardInput { stdin.write(Data(input.utf8)) }
            stdin.close()
        }

        // Output.
        let (offers, offerSink) = AsyncStream<PromptOffer>.makeStream()
        let outPump = AWSCLIStreamPump(isError: false, wantsPrompts: answer != nil, onLine: options.onLine)
        let errPump = AWSCLIStreamPump(isError: true, onLine: options.onLine)
        let outClosed = AWSCLIGate()
        let errClosed = AWSCLIGate()
        let outReader = AWSCLIPipeReader(fd: outPipe[0], label: "dsh.aws-cli.stdout", onChunk: { chunk in
            if let candidate = outPump.consume(chunk) {
                offerSink.yield(PromptOffer(text: candidate.prompt, generation: candidate.generation))
            }
        }, onClose: {
            outPump.flush()
            outClosed.open()
        })
        let errReader = AWSCLIPipeReader(fd: errPipe[0], label: "dsh.aws-cli.stderr", onChunk: { chunk in
            _ = errPump.consume(chunk)
        }, onClose: {
            errPump.flush()
            errClosed.open()
        })

        // The prompt answerer works through the offers one at a time, like the CLI asks them.
        let consumerDone = AWSCLIGate()
        if let answer {
            let task = Task { [self] in
                defer { consumerDone.open() }
                for await offer in offers {
                    if Task.isCancelled { break }
                    if outPump.isAnswered(offer.generation) { continue }
                    let reply: String?
                    do {
                        reply = try await answer(offer.text)
                    } catch is CancellationError {
                        break
                    } catch {
                        failAnswer(error)
                        break
                    }
                    guard let reply else { continue }
                    outPump.markAnswered(offer.generation)
                    stdin.write(Data((reply + "\n").utf8))
                }
            }
            let cancelNow: Bool = lock.withLock {
                consumer = task
                return cancelRequested
            }
            if cancelNow { task.cancel() }
        } else {
            consumerDone.open()
        }

        var limit: DispatchWorkItem?
        if let seconds = options.timeout {
            let item = DispatchWorkItem { [weak self] in self?.timeoutFired() }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds), execute: item)
            limit = item
        }

        outReader.start()
        errReader.start()

        // Wait for the child. A cancelled or timed-out run also waits for its whole process group to
        // be gone, so nothing it started outlives the call.
        await exitGate.wait()
        limit?.cancel()
        let stoppedByUs = lock.withLock { cancelRequested || timedOut || answerError != nil }
        if stoppedByUs { await waitForGroupToDie() }

        // A grandchild (a browser the CLI opened) can inherit the pipes and hold them open, so the last
        // output is waited for only briefly.
        let cap = stoppedByUs ? min(outputGrace, 1) : outputGrace
        let deadline = Date().addingTimeInterval(cap)
        await outClosed.wait(upTo: cap)
        await errClosed.wait(upTo: max(0, deadline.timeIntervalSinceNow))
        outReader.stop()
        errReader.stop()
        await outClosed.wait(upTo: 1)
        await errClosed.wait(upTo: 1)

        offerSink.finish()
        let task = lock.withLock { consumer }
        task?.cancel()
        await consumerDone.wait(upTo: 1)
        stdin.close()

        let (code, cancelled, didTimeOut, failure) = lock.withLock { (exitCode, cancelRequested, timedOut, answerError) }
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
        if didTimeOut { return AWSCLIResult(exitCode: -1, stdout: outPump.text, stderr: errPump.text, timedOut: true) }
        return AWSCLIResult(exitCode: code, stdout: outPump.text, stderr: errPump.text)
    }

    private struct SpawnedProcess: @unchecked Sendable {
        let process: Process
    }

    /// Start the program on a dispatch thread: the first launch of a big, freshly installed executable
    /// can take a second (macOS checks it), which must not hold up one of the few threads Swift's tasks run on.
    private static func spawn(_ child: Process) async throws {
        let spawned = SpawnedProcess(process: child)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                do {
                    try spawned.process.run()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func processExited(_ finished: Process) {
        // Like a shell (and .NET): a child killed by a signal exits with 128 + the signal.
        let code = finished.terminationReason == .uncaughtSignal ? 128 + Int(finished.terminationStatus) : Int(finished.terminationStatus)
        lock.withLock {
            exited = true
            exitCode = code
        }
        exitGate.open()
    }

    /// After the child itself is gone: anything left in its process group had SIGTERM too; wait out the
    /// grace period for it to obey, then SIGKILL it.
    private func waitForGroupToDie() async {
        let group: pid_t = lock.withLock { pid }
        let deadline = Date().addingTimeInterval(killGrace)
        while Self.groupAlive(group) && Date() < deadline { await AWSCLIGate.sleep(0.02) }
        if Self.groupAlive(group) {
            Self.signalGroup(group, SIGKILL)
            let last = Date().addingTimeInterval(1)
            while Self.groupAlive(group) && Date() < last { await AWSCLIGate.sleep(0.02) }
        }
    }
}

// MARK: - Finding it and checking its version

/// A version number as the AWS CLI prints it ("2.33.4"). .NET's `Version` has no Swift counterpart.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.init(major: major, minor: minor, patch: patch)
    }

    /// "2.33.4" (or "2.33", which means 2.33.0); nil for anything else.
    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Where the app looks for the AWS CLI. `forThisMachine()` is the real list; tests build their own.
public struct AWSCLISearch: Sendable {
    /// A path the user picked in Settings; tried first.
    public var explicitPath: String?
    /// Folders searched for `fileName`, in order (PATH).
    public var pathDirectories: [String]
    /// Full paths where the installers put it.
    public var knownLocations: [String]
    public var fileName: String
    public var fileExists: @Sendable (String) -> Bool
    /// Paths compare without case (off on macOS: the CLI is `aws`, and a second spelling of the same
    /// file only costs one more `--version` run).
    public var ignoreCase: Bool

    public init(explicitPath: String? = nil, pathDirectories: [String] = [], knownLocations: [String] = [],
                fileName: String = "aws", fileExists: @escaping @Sendable (String) -> Bool = AWSCLISearch.isExecutableFile,
                ignoreCase: Bool = false) {
        self.explicitPath = explicitPath
        self.pathDirectories = pathDirectories
        self.knownLocations = knownLocations
        self.fileName = fileName
        self.fileExists = fileExists
        self.ignoreCase = ignoreCase
    }

    /// A regular file (or a link to one) that this user may run.
    public static let isExecutableFile: @Sendable (String) -> Bool = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// The real search. A GUI app inherits a minimal PATH, so besides the PATH folders it looks where
    /// the installers put the CLI: the AWS package for all users (`/usr/local/bin/aws`, or
    /// `/usr/local/aws-cli/aws`), Homebrew (`/opt/homebrew/bin/aws` on Apple silicon, `/usr/local/bin/aws`
    /// on Intel) and the current-user package (`~/aws-cli/aws`, usually linked from `~/.local/bin/aws`).
    public static func forThisMachine(explicitPath: String? = nil,
                                      environment: [String: String] = ProcessInfo.processInfo.environment,
                                      home: String = NSHomeDirectory()) -> AWSCLISearch {
        func expand(_ path: String) -> String {
            if path == "~" { return home }
            return path.hasPrefix("~/") ? home + String(path.dropFirst(1)) : path
        }
        var seen = Set<String>()
        let directories = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespaces)) }
            .filter { !$0.isEmpty }
            .map(expand)
            .filter { seen.insert($0).inserted }
        return AWSCLISearch(
            explicitPath: explicitPath.map(expand),
            pathDirectories: directories,
            knownLocations: knownLocations(home: home),
            fileName: "aws",
            ignoreCase: false)
    }

    /// Where the installers put the CLI, most likely first.
    public static func knownLocations(home: String) -> [String] {
        ["/usr/local/bin/aws", "/opt/homebrew/bin/aws", "/usr/local/aws-cli/aws", home + "/.local/bin/aws", home + "/aws-cli/aws"]
    }
}

/// Whether the AWS CLI is there and new enough for the app.
public enum AWSCLIStatus: Sendable, Equatable {
    /// No `aws` anywhere the app looks.
    case missing
    /// Found, but older than `AWSCLI.minimumVersion` (AWS CLI v1 included).
    case tooOld(version: SemanticVersion, path: String)
    /// Found, but it didn't run or didn't say which version it is.
    case broken(path: String, problem: String)
    case ready(version: SemanticVersion, path: String)

    /// A sentence for the setup guide.
    public var summary: String {
        switch self {
        case .missing:
            return "The AWS CLI isn't installed. DSH can install it for you."
        case .tooOld(let version, _):
            return version.major < 2
                ? "AWS CLI \(version) is installed, but DSH needs version 2. DSH can install it for you."
                : "AWS CLI \(version) is installed, but signing in from the browser needs \(AWSCLI.minimumVersion) or newer. DSH can update it."
        case .broken(let path, let problem):
            return "The AWS CLI at \(path) didn't start properly (\(problem)). DSH can reinstall it."
        case .ready(let version, _):
            return "AWS CLI \(version) is ready."
        }
    }

    public var isReady: Bool { if case .ready = self { return true } else { return false } }

    /// Where the CLI was found (nil when missing).
    public var path: String? {
        switch self {
        case .missing: return nil
        case .tooOld(_, let path), .broken(let path, _), .ready(_, let path): return path
        }
    }

    /// The version it reported (nil when missing or broken).
    public var version: SemanticVersion? {
        switch self {
        case .tooOld(let version, _), .ready(let version, _): return version
        case .missing, .broken: return nil
        }
    }
}

// MARK: - The AWS CLI at one path

/// The AWS CLI at one path: running commands, reading their JSON, and turning failures into
/// plain-language errors.
public final class AWSCLI: AWSCLICommands, Sendable {
    /// `aws login` (sign in with the browser, using the AWS console sign-in) arrived in 2.32.0.
    public static let minimumVersion = SemanticVersion(2, 32, 0)

    /// How long an account call may take before the app gives up on it.
    public static let defaultTimeout: TimeInterval = 120

    public let runner: any AWSCLIRunner

    public init(runner: any AWSCLIRunner) {
        self.runner = runner
    }

    public static func forPath(_ path: String) -> AWSCLI {
        AWSCLI(runner: ProcessAWSCLIRunner(executable: path))
    }

    /// The CLI a `.ready` status points at (nil for any other status).
    public static func from(ready status: AWSCLIStatus) -> AWSCLI? {
        guard case .ready(_, let path) = status else { return nil }
        return forPath(path)
    }

    // MARK: Locating

    /// Every existing `aws` executable, most preferred first: the explicit path, then PATH (what the
    /// user's own terminal runs), then the installers' known folders.
    public static func candidates(_ search: AWSCLISearch) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        func consider(_ path: String?) {
            guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let full = absolutePath(path)
            let key = search.ignoreCase ? full.lowercased() : full
            if seen.insert(key).inserted && search.fileExists(full) { found.append(full) }
        }
        consider(search.explicitPath)
        for directory in search.pathDirectories {
            let trimmed = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            consider(trimmed == "/" ? "/" + search.fileName : trimmed + "/" + search.fileName)
        }
        for known in search.knownLocations { consider(known) }
        return found
    }

    /// The first `aws` executable found, or nil.
    public static func locate(_ search: AWSCLISearch? = nil) -> String? {
        candidates(search ?? AWSCLISearch.forThisMachine()).first
    }

    /// A rooted path with "." / ".." / repeated slashes resolved textually (relative ones against the
    /// working directory) — what .NET's `Path.GetFullPath` does; symlinks are left alone.
    static func absolutePath(_ path: String) -> String {
        let rooted = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var parts: [Substring] = []
        for part in rooted.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Find the AWS CLI and check it: the first candidate that is new enough wins; otherwise the best
    /// of the rest (the newest too-old one) is reported. Cancelling stops the search and reports what
    /// was found so far.
    public static func check(search: AWSCLISearch? = nil,
                             runnerFor: (@Sendable (String) -> any AWSCLIRunner)? = nil) async -> AWSCLIStatus {
        let makeRunner: @Sendable (String) -> any AWSCLIRunner = runnerFor ?? { path in ProcessAWSCLIRunner(executable: path) }
        func describe(_ result: AWSCLIResult) -> String {
            let text = AWSCLIText.firstLine(AWSCLIText.trimmed(AWSCLIText.trimmed(result.stderr).isEmpty ? result.stdout : result.stderr))
            return text.isEmpty ? "exit code \(result.exitCode)" : AWSCLIText.prefix(text, 200)
        }
        var best = AWSCLIStatus.missing
        for path in candidates(search ?? AWSCLISearch.forThisMachine()) {
            if Task.isCancelled { break }
            let status: AWSCLIStatus
            do {
                let result = try await makeRunner(path).run(["--version"], options: AWSCLIRunOptions(timeout: 60))
                if let version = parseVersion(result.stdout + "\n" + result.stderr) {
                    status = version >= minimumVersion ? .ready(version: version, path: path) : .tooOld(version: version, path: path)
                } else {
                    status = .broken(path: path, problem: result.timedOut ? "it didn't answer" : describe(result))
                }
            } catch is CancellationError {
                break
            } catch {
                status = .broken(path: path, problem: error.localizedDescription)
            }
            if status.isReady { return status }
            switch (best, status) {
            case (.missing, _):
                best = status
            case (.broken, .tooOld):
                best = status
            case (.tooOld(let old, _), .tooOld(let newer, _)) where newer > old:
                best = status
            default:
                break
            }
        }
        return best
    }

    /// "aws-cli/2.33.4 Python/3.13.9 Darwin/25 exe/arm64" → 2.33.4; v1 prints "aws-cli/1.x.y".
    public static func parseVersion(_ text: String) -> SemanticVersion? {
        guard let match = versionRegex.firstMatch(in: text),
              let major = match.group(at: 1).flatMap({ Int($0) }),
              let minor = match.group(at: 2).flatMap({ Int($0) }),
              let patch = match.group(at: 3).flatMap({ Int($0) }) else { return nil }
        return SemanticVersion(major, minor, patch)
    }

    private static let versionRegex = AWSCLIRegex(#"aws-cli/(\d{1,6})\.(\d{1,6})\.(\d{1,6})"#)

    /// `aws --version` through this CLI; nil when it doesn't say.
    public func version() async throws -> SemanticVersion? {
        let result = try await runner.run(["--version"], options: AWSCLIRunOptions(timeout: 60))
        return Self.parseVersion(result.stdout + "\n" + result.stderr)
    }

    // MARK: Running commands

    public func run(_ args: [String], options: AWSCLIRunOptions = AWSCLIRunOptions()) async throws -> AWSCLIResult {
        try await runner.run(args, options: options)
    }

    /// `<command> [--profile P] [--region R] [--output json]`. The CLI's own paging (it fetches every
    /// page and merges them) stays on.
    public static func arguments(_ command: [String], profile: String?, region: String?, json: Bool = true) -> [String] {
        var args = command
        if let profile, !profile.isEmpty { args += ["--profile", profile] }
        if let region, !region.isEmpty { args += ["--region", region] }
        if json { args += ["--output", "json"] }
        return args
    }

    /// Run a command that must succeed. Failures become `AWSSignInRequiredError` (sign in again) or
    /// `AWSCLIException` with a plain-language message.
    public func runChecked(_ command: [String], profile: String?, region: String?, timeout: TimeInterval?) async throws -> AWSCLIResult {
        let args = Self.arguments(command, profile: profile, region: region)
        let result = try await runner.run(args, options: AWSCLIRunOptions(timeout: timeout ?? Self.defaultTimeout))
        if !result.succeeded { throw AWSCLIErrors.toError(AWSCLIErrors.classify(result, service: args.first), profile: profile) }
        return result
    }

    /// Run a command and parse what it printed as JSON (an empty object when it printed nothing, as
    /// commands without a response body do).
    public func runJSON(_ command: [String], profile: String?, region: String?, timeout: TimeInterval?) async throws -> JSONValue {
        let result = try await runChecked(command, profile: profile, region: region, timeout: timeout)
        let text = AWSCLIText.trimmed(result.stdout)
        if text.isEmpty { return .object([:]) }
        guard let json = JSONValue(parsing: text) else {
            throw AWSCLIException(AWSCLIError(kind: .other, message: "The AWS CLI answered with something DSH couldn't read.",
                                              details: AWSCLIText.prefix(text, 500)))
        }
        return json.isNull ? .object([:]) : json
    }
}

// MARK: - Errors in plain language

/// Reads the AWS CLI's error output. The texts matched are the CLI's and botocore's own
/// (awscli/errorhandler.py, botocore/exceptions.py, the login and SSO credential providers).
public enum AWSCLIErrors {
    /// Classify a failed run. `service` is the command's first word ("bedrock", "sts"), used to name
    /// the IAM permission when AWS's message doesn't.
    public static func classify(_ result: AWSCLIResult, service: String? = nil) -> AWSCLIError {
        let raw = AWSCLIText.trimmed(AWSCLIText.trimmed(result.stderr).isEmpty ? result.stdout : result.stderr)
        let text = AWSCLIText.normalizeNewlines(raw)
        if result.timedOut {
            return AWSCLIError(kind: .timedOut, message: "AWS took too long to answer. Check your internet connection and try again.", details: raw)
        }

        let client = clientErrorRegex.firstMatch(in: text)
        let code = client?.group("code")
        let operation = client?.group("op")
        let awsMessage = client?.group("msg").map(AWSCLIText.trimmed)
        let lowered = text.lowercased()
        func has(_ phrase: String) -> Bool { lowered.contains(phrase.lowercased()) }
        func codeIs(_ codes: String...) -> Bool {
            guard let code else { return false }
            return codes.contains { $0.caseInsensitiveCompare(code) == .orderedSame }
        }
        func signIn(_ message: String) -> AWSCLIError {
            AWSCLIError(kind: .signInRequired, message: message, code: code, operation: operation, details: raw)
        }
        func other(_ kind: AWSCLIFailure, _ message: String) -> AWSCLIError {
            AWSCLIError(kind: kind, message: message, code: code, operation: operation, details: raw)
        }

        // `aws login` succeeded in the browser but the identity may not create CLI tokens.
        if has("insufficient permissions") && has("signin:CreateOAuth2Token") {
            return AWSCLIError(kind: .accessDenied,
                               message: "Your AWS permissions don't allow signing in from the AWS CLI (signin:CreateOAuth2Token). Ask whoever manages your AWS account to attach the AWS managed policy SignInLocalDevelopmentAccess to you.",
                               code: code, operation: operation, permission: "signin:CreateOAuth2Token", details: raw)
        }
        if has("change in your password") {
            return signIn("Your AWS password changed since you signed in. Sign in again with the new password.")
        }
        if has("Your session has expired") || has("reauthenticate using 'aws login'") || has("reauthenticate with 'aws login'")
            || has("Error loading login session token") || has("refreshing a login session profile") {
            return signIn("Your AWS sign-in has expired. Sign in again — DSH opens your browser.")
        }
        if has("Error loading SSO Token") || has("SSO session associated with this profile has expired")
            || has("Token has expired and refresh failed") || has("retrieving token from sso") || has("UnauthorizedSSOTokenError") {
            return signIn("Your AWS IAM Identity Center (SSO) sign-in has expired. Sign in again.")
        }
        if has("Unable to locate credentials") || has("no credentials found") || has("NoCredentials")
            || (has("config profile") && has("could not be found")) {
            return signIn("DSH isn't signed in to AWS yet. Sign in to continue.")
        }
        if codeIs("ExpiredToken", "ExpiredTokenException", "RequestExpired") || has("security token included in the request is expired") {
            return signIn("Your AWS sign-in has expired. Sign in again.")
        }
        if codeIs("UnrecognizedClientException", "InvalidClientTokenId", "InvalidSignatureException")
            || has("security token included in the request is invalid") {
            return signIn("AWS didn't accept the saved sign-in. Sign in again.")
        }

        if codeIs("AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "AuthorizationError") || has("not authorized to perform") {
            let permission: String?
            if let match = permissionRegex.firstMatch(in: text), let named = match.group(at: 1) {
                permission = named
            } else if let operation, let service, !service.isEmpty {
                permission = "\(service):\(operation)"
            } else {
                permission = nil
            }
            let what = permission ?? "this"
            let message = has("explicit deny")
                ? "An AWS policy explicitly blocks \(what) for your sign-in (for example a policy set by your organization). Ask whoever manages your AWS account."
                : "Your AWS permissions don't allow \(what). Ask whoever manages your AWS account to allow it — DSH can show the exact policy to send them."
            return AWSCLIError(kind: .accessDenied, message: message, code: code, operation: operation, permission: permission, details: raw)
        }
        if has("Found invalid choice") || has("Invalid choice") || has("Unknown options") {
            return other(.notSupported, "This version of the AWS CLI doesn't have that command. Update the AWS CLI — DSH can do it for you.")
        }
        if has("Could not connect to the endpoint URL") || has("Connect timeout on endpoint URL") || has("Read timeout on endpoint URL")
            || has("SSL validation failed") || has("Failed to connect to proxy") || has("ProxyConnectionError") || has("EndpointConnectionError") {
            return other(.network, "DSH couldn't reach AWS. Check your internet connection (and any proxy or VPN), then try again.")
        }
        if codeIs("ThrottlingException", "Throttling", "TooManyRequestsException", "ServiceQuotaExceededException") || has("Rate exceeded") {
            return other(.throttled, "AWS is busy right now (too many requests). Wait a moment and try again.")
        }
        if has("You must specify a region") {
            return other(.invalid, "No AWS Region is set. Pick a Region and try again.")
        }
        if codeIs("ResourceNotFoundException", "NotFoundException", "NoSuchEntity") {
            return other(.notFound, awsMessage ?? "AWS couldn't find that.")
        }
        if codeIs("ConflictException") {
            return other(.conflict, awsMessage ?? "AWS says this is already in progress.")
        }
        if codeIs("ValidationException", "ParamValidation", "InvalidParameterException") {
            return other(.invalid, "AWS didn't accept the request: \(awsMessage ?? cleanMessage(text))")
        }
        return other(.other, awsMessage ?? cleanMessage(text))
    }

    /// The error a caller should see: sign-in problems as `AWSSignInRequiredError` (the app opens the
    /// sign-in), the rest as `AWSCLIException`.
    public static func toError(_ error: AWSCLIError, profile: String?) -> any Error {
        error.kind == .signInRequired
            ? AWSSignInRequiredError(profile: profile.flatMap { $0.isEmpty ? nil : $0 } ?? "default", message: error.message)
            : AWSCLIException(error)
    }

    /// The CLI's own words without its "aws: [ERROR]:" prefix and usage text.
    public static func cleanMessage(_ text: String) -> String {
        let marker = "aws: [ERROR]:"
        var lines: [String] = []
        for line in AWSCLIText.normalizeNewlines(text).components(separatedBy: "\n") {
            var line = AWSCLIText.trimmed(line)
            if line.hasPrefix(marker) { line = AWSCLIText.trimmed(String(line.dropFirst(marker.count))) }
            if line.lowercased().hasPrefix("usage:") { break }
            if line.isEmpty || line == "Additional error details:" { continue }
            lines.append(line)
        }
        let message = clientErrorPrefixRegex.replacing(in: lines.joined(separator: " "), with: "")
        return message.isEmpty ? "The AWS CLI stopped with an error." : AWSCLIText.prefix(message, 500)
    }

    /// botocore's ClientError: "An error occurred (Code) when calling the Op operation (reached max
    /// retries: 4): message".
    private static let clientErrorRegex = AWSCLIRegex(
        #"An error occurred \((?<code>[^)]+)\)(?: when calling the (?<op>\w+) operation)?(?: \(reached max retries: \d+\))?: (?<msg>[^\n]*)"#)

    private static let clientErrorPrefixRegex = AWSCLIRegex(
        #"An error occurred \([^)]+\)(?: when calling the \w+ operation)?(?: \(reached max retries: \d+\))?: "#)

    /// "... is not authorized to perform: bedrock:InvokeModel on resource ..."
    private static let permissionRegex = AWSCLIRegex(#"not authorized to perform:?\s+([A-Za-z0-9-]+:[A-Za-z0-9*]+)"#)
}

// MARK: - Text helpers

/// The bits of string handling the CLI layer shares (the C# `TextUtil`), kept `internal`.
enum AWSCLIText {
    /// At most `max` characters from the start.
    static func prefix(_ text: String, _ max: Int) -> String {
        max <= 0 ? "" : String(text.prefix(max))
    }

    /// CRLF and lone CR become LF. (Swift treats "\r\n" as ONE character, so splitting on "\n" without
    /// this would miss Windows line endings.)
    static func normalizeNewlines(_ text: String) -> String {
        text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
    }

    /// The first non-empty line (the whole string if it has none).
    static func firstLine(_ text: String) -> String {
        for line in text.components(separatedBy: "\n") where !line.isEmpty { return line }
        return text
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove ANSI escape sequences (CSI, OSC and two-byte escapes) that some tools emit even when
    /// their output is piped.
    static func stripANSI(_ text: String) -> String {
        text.contains("\u{1B}") ? ansiRegex.replacing(in: text, with: "") : text
    }

    private static let ansiRegex = AWSCLIRegex(#"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)?|[@-Z\\-_])"#)
}

/// A compiled regular expression that can live in a `static let` (NSRegularExpression is immutable and
/// thread-safe, but isn't marked Sendable).
struct AWSCLIRegex: @unchecked Sendable {
    private let expression: NSRegularExpression

    init(_ pattern: String) {
        // The patterns are constants in this module; a bad one is a programming error the tests hit.
        expression = try! NSRegularExpression(pattern: pattern)
    }

    struct Match {
        fileprivate let text: String
        fileprivate let result: NSTextCheckingResult

        /// A named group; nil when it didn't take part in the match.
        func group(_ name: String) -> String? { slice(result.range(withName: name)) }
        func group(at index: Int) -> String? { slice(result.range(at: index)) }

        private func slice(_ range: NSRange) -> String? {
            range.location == NSNotFound ? nil : (text as NSString).substring(with: range)
        }
    }

    func firstMatch(in text: String) -> Match? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { Match(text: text, result: $0) }
    }

    func matches(_ text: String) -> Bool { firstMatch(in: text) != nil }

    func replacing(in text: String, with template: String) -> String {
        expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
