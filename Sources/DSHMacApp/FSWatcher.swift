import Foundation
import CoreServices
import DSHCore

/// Recursive filesystem watcher over a project folder.
///
/// The agent writes files from a background task and the user edits the same
/// files in the editor; both need to see the other's changes without a manual
/// refresh. FSEvents gives us one stream for the whole tree instead of a
/// descriptor per directory.
final class FSWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dsh.fswatcher", qos: .utility)
    private let handler: @Sendable ([URL]) -> Void
    private let root: URL

    /// `handler` is called on the main queue with the paths that changed,
    /// coalesced over a short window.
    init(root: URL, handler: @escaping @Sendable ([URL]) -> Void) {
        self.root = root
        self.handler = handler
        start()
    }

    deinit { stop() }

    private func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            // `kFSEventStreamCreateFlagUseCFTypes` makes this a CFArray of CFString.
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            let urls = paths.prefix(count).map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return }
            DispatchQueue.main.async { watcher.handler(urls) }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,                       // coalescing window, seconds
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Names never shown in the file tree, and never watched for reload.
enum FileFilter {
    static let ignoredDirectories: Set<String> = [
        ".git", ".build", "node_modules", ".swiftpm", "DerivedData",
        ".next", "dist", "build", "target", "__pycache__", ".venv", "venv",
        ".mypy_cache", ".pytest_cache", ".gradle", ".idea", "Pods",
    ]

    static let ignoredFiles: Set<String> = [".DS_Store"]

    static func isIgnored(_ url: URL, isDirectory: Bool) -> Bool {
        let name = url.lastPathComponent
        if ignoredFiles.contains(name) { return true }
        if isDirectory && ignoredDirectories.contains(name) { return true }
        return false
    }

    /// Anything under an ignored directory is noise for reload purposes too.
    static func isNoise(_ url: URL) -> Bool {
        for component in url.pathComponents {
            if ignoredDirectories.contains(component) || ignoredFiles.contains(component) { return true }
        }
        return false
    }

    /// Extensions the editor will open as text. Anything else opens in Finder.
    static let textExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "java", "kt",
        "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "php", "pl", "lua", "sh",
        "bash", "zsh", "fish", "sql", "r", "jl", "scala", "clj", "ex", "exs", "erl",
        "hs", "ml", "cs", "vb", "dart", "zig", "nim",
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "properties",
        "md", "markdown", "mdx", "txt", "rst", "adoc", "tex", "csv", "tsv", "log",
        "html", "htm", "xml", "svg", "css", "scss", "sass", "less",
        "gitignore", "gitattributes", "dockerfile", "makefile", "cmake", "gradle",
        "plist", "entitlements", "xcconfig", "podspec", "lock", "patch", "diff",
    ]

    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty { return textExtensions.contains(ext) }
        // Extensionless files that are conventionally text.
        let name = url.lastPathComponent.lowercased()
        return ["makefile", "dockerfile", "readme", "license", "changelog",
                "package.swift", "cargo.toml", "gemfile", "rakefile", "procfile",
                "brewfile", ".gitignore", ".env"].contains(name)
    }

    /// A guard against opening a 200 MB log in a text view.
    static var maxEditableBytes: Int { EditorBuffer.maxEditableBytes }
}
