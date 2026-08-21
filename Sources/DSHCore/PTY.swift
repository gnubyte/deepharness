import Foundation
import Darwin

/// A shell running on a pseudo-terminal.
///
/// `Process` cannot give a child a controlling terminal, and without one a
/// shell turns job control off and Ctrl-C reaches nothing. `forkpty` does the
/// session and TIOCSCTTY dance in the child before it returns, which is why
/// every terminal on this platform uses it — the child does nothing but
/// `execve` between fork and exec.
public final class PTY: @unchecked Sendable {
    private(set) var pid: pid_t = -1
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dsh.pty.read", qos: .userInitiated)

    /// Raw bytes from the shell, delivered on `queue`.
    public var onOutput: (@Sendable (Data) -> Void)?
    /// The shell exited; carries its status.
    public var onExit: (@Sendable (Int32) -> Void)?

    private(set) var isRunning = false

    public init() {}

    deinit { terminate() }

    /// Launch `shell` in `cwd` on a new pty sized `cols` x `rows`.
    @discardableResult
    public func start(shell: String, arguments: [String] = ["-l"], cwd: URL,
               cols: UInt16, rows: UInt16, environment: [String: String] = [:]) -> Bool {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var masterFD: Int32 = -1

        // Everything the child touches between fork and exec must already be
        // allocated: no Swift allocation is safe on the child side.
        let argv = Self.makeCArray([shell] + arguments)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TERM_PROGRAM"] = "DSH"
        for (key, value) in environment { env[key] = value }
        let envp = Self.makeCArray(env.map { "\($0.key)=\($0.value)" })
        let shellPath = strdup(shell)
        let cwdPath = strdup(cwd.path)
        defer {
            Self.freeCArray(argv)
            Self.freeCArray(envp)
            free(shellPath)
            free(cwdPath)
        }

        let child = forkpty(&masterFD, nil, nil, &size)
        if child < 0 { return false }
        if child == 0 {
            // --- child ---
            if let cwdPath { _ = chdir(cwdPath) }
            signal(SIGPIPE, SIG_DFL)
            signal(SIGINT, SIG_DFL)
            signal(SIGQUIT, SIG_DFL)
            execve(shellPath, argv, envp)
            _exit(127)
        }

        // --- parent ---
        pid = child
        master = masterFD
        isRunning = true

        // Non-blocking so a partial read never stalls the source.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [master] in close(master) }
        source.resume()
        readSource = source

        // Reap the shell so it never lingers as a zombie.
        let waiter = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        waiter.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, WNOHANG)
            waiter.cancel()
            guard let self else { return }
            self.isRunning = false
            self.drain()               // flush whatever the shell printed last
            self.onExit?(Self.exitCode(status))
        }
        waiter.resume()
        return true
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        // WIFEXITED / WEXITSTATUS are macros; unpack them by hand.
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }

    private func drain() {
        guard master >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, 16_384) }
            if count > 0 {
                onOutput?(Data(buffer[0..<count]))
                if count < 16_384 { break }
            } else {
                break   // 0 = EOF, -1 = EAGAIN
            }
        }
    }

    /// Send keystrokes to the shell.
    public func write(_ data: Data) {
        guard master >= 0, isRunning else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(master, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    public func write(_ text: String) { write(Data(text.utf8)) }

    /// Tell the shell the window changed, so `$COLUMNS` and redraws are right.
    public func resize(cols: UInt16, rows: UInt16) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        if pid > 0 { kill(pid, SIGWINCH) }
    }

    public func terminate() {
        guard isRunning else { return }
        isRunning = false
        if pid > 0 {
            // Signal the whole process group so the shell's children go too.
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
        }
        readSource?.cancel()
        readSource = nil
        master = -1
        pid = -1
    }

    // MARK: - C array helpers

    private static func makeCArray(_ values: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: values.count + 1)
        for (index, value) in values.enumerated() {
            array[index] = strdup(value)
        }
        array[values.count] = nil
        return array
    }

    private static func freeCArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var index = 0
        while let entry = array[index] {
            free(entry)
            index += 1
        }
        array.deallocate()
    }

    /// The user's login shell, or a sensible fallback.
    public static var defaultShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        for candidate in ["/bin/zsh", "/bin/bash", "/bin/sh"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/bin/sh"
    }
}
