import Foundation

// MARK: - A run that stays away from the user's own data
//
// The screenshot mode (`Vision --snapshot <folder>`) opens the real windows over made-up chats, routes and a demo
// project. It must not read or write anything of the user's: their settings file, their data folder, their Keychain
// items, the instruction files and skills in their home folder. Everything that names one of those asks here first,
// so one switch moves all of them into a throwaway folder:
//
//   settings (UserDefaults)        → <root>/settings.plist
//   ~/Library/Application Support  → <root>/home/Library/Application Support (so the data folder is …/Vision)
//   the home folder (skills, CLAUDE.md, AGENTS.md …) → <root>/home
//   Keychain items (keys, vault)   → memory, gone when the app quits
//
// A normal launch has no root, and every answer is the usual one.

public enum IsolatedRun {
    /// The environment variable that names the throwaway folder. The launcher sets it (snapshot mode) before
    /// anything below is first read; it is read once.
    public static let environmentVariable = "VISION_ISOLATED_ROOT"

    /// The throwaway folder, or nil for a normal run.
    public static let root: URL? = root(fromEnvironment: getenv(environmentVariable).map { String(cString: $0) })

    /// The folder an environment value names: an absolute path, or nothing.
    public static func root(fromEnvironment value: String?) -> URL? {
        guard let value, value.hasPrefix("/"), value.count > 1 else { return nil }
        // `.standardized` only folds "." and ".."; it keeps a /private prefix (standardizedFileURL would drop it,
        // and paths read back from the disk would no longer start with the root's).
        return URL(fileURLWithPath: value, isDirectory: true).standardized
    }

    /// True while the app is kept away from the user's data.
    public static var isActive: Bool { root != nil }

    /// Stands in for the user's home folder.
    public static var home: URL? { root.map(home(in:)) }

    /// Stands in for `~/Library/Application Support`.
    public static var applicationSupport: URL? { root.map(applicationSupport(in:)) }

    static func home(in root: URL) -> URL { root.appendingPathComponent("home", isDirectory: true) }

    static func applicationSupport(in root: URL) -> URL {
        home(in: root).appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    /// The settings file inside `root`.
    public static func settingsFile(in root: URL) -> URL { root.appendingPathComponent("settings.plist") }

    /// Where the app's settings live: the app's own settings file, or — isolated — a plist inside the root (a suite
    /// named by an absolute path is kept in that file, and never touches the app's own domain). UserDefaults is
    /// thread-safe; it just isn't marked Sendable.
    nonisolated(unsafe) public static let defaults: UserDefaults = {
        guard let root else { return .standard }
        guard let isolated = UserDefaults(suiteName: settingsFile(in: root).path) else {
            preconditionFailure("could not open the isolated settings file")
        }
        return isolated
    }()
}
