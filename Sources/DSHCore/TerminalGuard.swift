import Foundation
import Darwin

/// The keyboard tool acts as the user. Typing into a terminal emulator would
/// run shell commands without going through the permission gate that covers
/// `run_shell_command` and `process_start`, and typing into DSH itself would
/// talk to the agent's own composer. Both are refused; the agent is told to
/// use the shell tools, which ask when a command could change things.
public enum TerminalGuard {
    /// App bundle names whose windows must not receive synthesized typing.
    static let blocked: [String] = [
        "Terminal.app", "iTerm.app", "iTerm2.app", "Warp.app", "Ghostty.app", "kitty.app", "Alacritty.app",
        "Hyper.app", "WezTerm.app", "Tabby.app", "Rio.app", "Termius.app", "cool-retro-term.app", "DSH.app",
    ]

    /// Whether the app at this executable path is off limits for typing.
    public static func isBlocked(executablePath path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.contains { part in blocked.contains { $0.caseInsensitiveCompare(part) == .orderedSame } }
    }

    public static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func isBlocked(pid: pid_t) -> Bool {
        executablePath(pid: pid).map(isBlocked(executablePath:)) ?? false
    }

    /// The message the keyboard tool returns when it refuses.
    public static func refusal(appName: String) -> String {
        "Error: not typing into \(appName): keystrokes there run commands as you without the usual approval. Use run_shell_command or process_start (they ask before anything risky), or ask the user to type it."
    }
}
