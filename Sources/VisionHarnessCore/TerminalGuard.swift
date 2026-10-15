import Foundation
import Darwin

/// The keyboard tool acts as the user. Typing into a terminal emulator would
/// run shell commands without going through the permission gate that covers
/// `run_shell_command` and `process_start`, and typing into the harness itself
/// would talk to the agent's own composer and approval prompts. Both are
/// refused; the agent is told to use the shell tools, which ask when a command
/// could change things.
///
/// The harness recognises itself four ways, so neither a rename, a bundle
/// moved or renamed by the user, nor an unbundled `swift run` binary slips
/// through: its own process id, its bundle identifier (this build's and the
/// shipped ones), its own executable (a second copy of the same binary), and
/// the app bundle names it ships as.
public enum TerminalGuard {
    /// Terminal emulators: keystrokes there are shell commands.
    static let terminalBundleNames: [String] = [
        "Terminal.app", "iTerm.app", "iTerm2.app", "Warp.app", "Ghostty.app", "kitty.app", "Alacritty.app",
        "Hyper.app", "WezTerm.app", "Tabby.app", "Rio.app", "Termius.app", "cool-retro-term.app",
    ]

    /// The harness's own app bundle names. A copy of an older build (named
    /// before the rename) is still this harness, with the same composer and
    /// approval buttons, so the legacy name stays blocked too.
    static let harnessBundleNames: [String] = ["Vision.app", legacyHarnessBundleName]

    /// Legacy: the app bundle name before the Vision rename. Kept so an old
    /// copy of the app that is still installed and running is never typed into.
    static let legacyHarnessBundleName = "DSH.app"

    /// App bundle names whose windows must not receive synthesized typing.
    static let blocked: [String] = terminalBundleNames + harnessBundleNames

    /// The harness's bundle identifiers, current and legacy, blocked even
    /// when the bundle itself has been renamed on disk.
    static let harnessBundleIdentifiers: [String] = ["com.503cm.vision.mac", legacyHarnessBundleIdentifier]

    /// Legacy: the bundle identifier before the Vision rename (an old build).
    static let legacyHarnessBundleIdentifier = "dev.local.dsh.mac"

    /// Who this process is. Captured once: none of it changes while running.
    public struct Identity: Sendable, Equatable {
        public var pid: pid_t
        public var bundleIdentifier: String?
        public var executablePath: String?

        public init(pid: pid_t, bundleIdentifier: String?, executablePath: String?) {
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.executablePath = executablePath
        }

        public static let current: Identity = {
            let pid = ProcessInfo.processInfo.processIdentifier
            return Identity(pid: pid,
                            bundleIdentifier: Bundle.main.bundleIdentifier,
                            executablePath: TerminalGuard.executablePath(pid: pid) ?? Bundle.main.executablePath)
        }()
    }

    /// What the guard knows about the process that would receive the keys.
    public struct Target: Sendable, Equatable {
        public var pid: pid_t
        public var executablePath: String?
        public var bundleIdentifier: String?

        public init(pid: pid_t, executablePath: String?, bundleIdentifier: String?) {
            self.pid = pid
            self.executablePath = executablePath
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// Look a running process up by pid: its executable, and the identifier
    /// of the app bundle that executable lives in (nil for a bare binary).
    public static func target(pid: pid_t) -> Target {
        let path = executablePath(pid: pid)
        return Target(pid: pid, executablePath: path, bundleIdentifier: path.flatMap(bundleIdentifier(executablePath:)))
    }

    /// Whether the app at this executable path is off limits for typing, by
    /// the name of a bundle it lives in.
    public static func isBlocked(executablePath path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.contains { part in blocked.contains { $0.caseInsensitiveCompare(part) == .orderedSame } }
    }

    /// Whether typing into this process is refused: it is this harness (by
    /// pid, bundle identifier or executable), any build of the harness (by
    /// bundle identifier), or a terminal or harness bundle by name.
    public static func isBlocked(_ target: Target, ownIdentity own: Identity = .current) -> Bool {
        if target.pid == own.pid { return true }
        if let theirs = target.bundleIdentifier {
            let ours = [own.bundleIdentifier].compactMap { $0 }.filter { !$0.isEmpty } + harnessBundleIdentifiers
            if ours.contains(where: { theirs.caseInsensitiveCompare($0) == .orderedSame }) { return true }
        }
        if let theirs = target.executablePath, let ours = own.executablePath,
           canonicalPath(theirs) == canonicalPath(ours) {
            return true
        }
        return target.executablePath.map(isBlocked(executablePath:)) ?? false
    }

    public static func isBlocked(pid: pid_t) -> Bool {
        isBlocked(target(pid: pid))
    }

    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The bundle identifier of the innermost `.app` an executable lives in
    /// (a helper app nested in another app reports its own identifier).
    public static func bundleIdentifier(executablePath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.lastIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        let bundlePath = parts[...index].joined(separator: "/")
        return Bundle(path: bundlePath)?.bundleIdentifier
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The message the keyboard tool returns when it refuses.
    public static func refusal(appName: String) -> String {
        "Error: not typing into \(appName): keystrokes there run commands as you without the usual approval. Use run_shell_command or process_start (they ask before anything risky), or ask the user to type it."
    }

    /// The message when the app in front cannot be identified. Typing blind
    /// could land in a terminal or in the harness itself, so it is refused.
    public static func unknownFrontmostRefusal() -> String {
        "Error: can't tell which app is in front, so not typing (the keys could land in a terminal or in this app). Allow this app to control System Events in System Settings → Privacy & Security → Automation, then try again."
    }
}
