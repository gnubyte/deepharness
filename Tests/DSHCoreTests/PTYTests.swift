import XCTest
@testable import DSHCore

/// These spawn a real shell on a real pty. `forkpty` in a multi-threaded
/// process is the riskiest thing in the app, so it is worth proving rather
/// than assuming.
final class PTYTests: XCTestCase {

    /// Runs `command` in a shell on a pty and returns what the screen shows.
    private func runOnPTY(_ command: String,
                          rows: Int = 24, cols: Int = 80,
                          timeout: TimeInterval = 15) throws -> Screen {
        let pty = PTY()
        let screen = Screen(rows: rows, cols: cols)
        let exited = XCTestExpectation(description: "shell exits")

        pty.onOutput = { screen.feed($0) }
        pty.onExit = { _ in exited.fulfill() }

        let started = pty.start(shell: "/bin/sh", arguments: [],
                                cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                                cols: UInt16(cols), rows: UInt16(rows))
        XCTAssertTrue(started, "forkpty should hand back a running shell")
        guard started else { throw XCTSkip("no pty available") }

        pty.write("\(command)\nexit\n")
        wait(for: [exited], timeout: timeout)
        Thread.sleep(forTimeInterval: 0.2)   // let the last read land
        pty.terminate()
        return screen
    }

    func testShellRunsAndOutputReachesTheScreen() throws {
        let screen = try runOnPTY("echo dsh-marker-42")
        XCTAssertTrue(screen.text.contains("dsh-marker-42"),
                      "expected the echoed marker on screen, got:\n\(screen.text)")
    }

    func testWorkingDirectoryIsTheProjectFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("sentinel.txt"),
                          atomically: true, encoding: .utf8)

        let pty = PTY()
        let screen = Screen()
        let exited = XCTestExpectation(description: "exit")
        pty.onOutput = { screen.feed($0) }
        pty.onExit = { _ in exited.fulfill() }

        XCTAssertTrue(pty.start(shell: "/bin/sh", arguments: [], cwd: root, cols: 80, rows: 24))
        pty.write("ls\nexit\n")
        wait(for: [exited], timeout: 15)
        Thread.sleep(forTimeInterval: 0.2)
        pty.terminate()
        XCTAssertTrue(screen.text.contains("sentinel.txt"),
                      "expected the shell to start in cwd, got:\n\(screen.text)")
    }

    /// The pty must report the size we gave it, or full-screen programs wrap
    /// at the wrong column.
    func testTerminalSizeIsReportedToTheShell() throws {
        let screen = try runOnPTY("stty size", rows: 30, cols: 100)
        XCTAssertTrue(screen.text.contains("30 100"),
                      "expected `stty size` to report 30x100, got:\n\(screen.text)")
    }

    func testResizeUpdatesTheShellsView() throws {
        let pty = PTY()
        let screen = Screen()
        let exited = XCTestExpectation(description: "exit")
        pty.onOutput = { screen.feed($0) }
        pty.onExit = { _ in exited.fulfill() }

        XCTAssertTrue(pty.start(shell: "/bin/sh", arguments: [],
                                cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                                cols: 80, rows: 24))
        Thread.sleep(forTimeInterval: 0.4)
        pty.resize(cols: 132, rows: 40)
        Thread.sleep(forTimeInterval: 0.3)
        pty.write("stty size\nexit\n")
        wait(for: [exited], timeout: 15)
        Thread.sleep(forTimeInterval: 0.2)
        pty.terminate()
        XCTAssertTrue(screen.text.contains("40 132"),
                      "expected the resize to reach the shell, got:\n\(screen.text)")
    }

    func testExitStatusIsReported() throws {
        let pty = PTY()
        let exited = XCTestExpectation(description: "exit")
        let status = StatusBox()
        pty.onOutput = { _ in }
        pty.onExit = { code in status.value = code; exited.fulfill() }

        XCTAssertTrue(pty.start(shell: "/bin/sh", arguments: [],
                                cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                                cols: 80, rows: 24))
        pty.write("exit 3\n")
        wait(for: [exited], timeout: 15)
        pty.terminate()
        XCTAssertEqual(status.value, 3)
    }

    /// Colour must survive the pty, or every build log renders grey.
    func testANSIColourSurvivesTheRoundTrip() throws {
        let screen = try runOnPTY("printf '\\033[31mRED\\033[0m\\n'")
        XCTAssertTrue(screen.anyCell { $0.character == "R" && $0.style.foreground == .indexed(1) },
                      "expected a red 'R' somewhere on screen")
    }

    func testTerminateIsSafeToCallTwice() {
        let pty = PTY()
        XCTAssertTrue(pty.start(shell: "/bin/sh", arguments: [],
                                cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
                                cols: 80, rows: 24))
        pty.terminate()
        pty.terminate()
        XCTAssertFalse(pty.isRunning)
    }

    func testDefaultShellIsExecutable() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: PTY.defaultShell))
    }

    // MARK: - runCommand (pty-backed capture used by run_shell_command)

    func testRunCommandCapturesOutputAndExitStatus() async {
        let (output, status, timedOut) = await PTY.runCommand(
            "echo hi-pty-run; exit 0", cwd: URL(fileURLWithPath: "/tmp"), timeout: 10)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(status, 0)
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("hi-pty-run"), "expected marker in output, got: \(text)")
    }

    func testRunCommandReportsNonZeroExit() async {
        let (_, status, timedOut) = await PTY.runCommand("exit 7", cwd: URL(fileURLWithPath: "/tmp"), timeout: 10)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(status, 7)
    }

    /// The regression this whole fix targets: a command that prints a prompt
    /// and then waits for interactive input used to block for the entire
    /// timeout with no signal. It must now be stopped early — by the idle
    /// limit, well under the total timeout — with the prompt in the output.
    func testRunCommandStopsOnInteractivePrompt() async {
        let start = Date()
        let (output, status, timedOut) = await PTY.runCommand(
            "printf 'need-a-password: '; read -r secret",
            cwd: URL(fileURLWithPath: "/tmp"), timeout: 6)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(timedOut, "a prompt-waiting command must be flagged as stopped")
        XCTAssertGreaterThan(status, 0, "it should have been killed, not exited cleanly")
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("need-a-password:"),
                      "the prompt should be in the captured output, got: \(text)")
        // Idle limit for a 6s total is 5.4s, so it should stop well before 6.
        XCTAssertLessThan(elapsed, 6.0,
                          "should stop on the idle limit, not the full timeout (\(elapsed)s)")
    }

    /// A quiet-but-legitimately-slow command (no output) must NOT be killed on
    /// the idle limit — only on the full timeout. This is the "don't kill my
    /// slow build" guarantee.
    func testRunCommandAllowsQuietSlowCommandUntilFullTimeout() async {
        // Sleeps 2.5s with no output, then prints. Total timeout 6s is plenty.
        let (output, status, timedOut) = await PTY.runCommand(
            "sleep 2.5; echo finished-quietly", cwd: URL(fileURLWithPath: "/tmp"), timeout: 6)
        XCTAssertFalse(timedOut, "a quiet command that finishes in time must not be stopped")
        XCTAssertEqual(status, 0)
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("finished-quietly"), "got: \(text)")
    }
}

/// The emulator is main-actor-confined in the app (`PTY.onOutput` hops before
/// touching it). Tests read it from the pty's queue, so it gets a lock.
private final class Screen: @unchecked Sendable {
    private let lock = NSLock()
    private let emulator: TerminalEmulator

    init(rows: Int = 24, cols: Int = 80) {
        emulator = TerminalEmulator(rows: rows, cols: cols)
    }

    func feed(_ data: Data) {
        lock.lock(); emulator.feed(data); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return emulator.allLines.map { emulator.plainText($0) }.joined(separator: "\n")
    }

    /// Any cell matching the predicate, read under the lock.
    func anyCell(_ matches: (TerminalCell) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return emulator.allLines.contains { $0.contains(where: matches) }
    }
}

/// Small box so the exit callback can hand a value back across threads.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32?
    var value: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
