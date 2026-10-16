import Foundation

// Qwen Code parity tools: glob, grep, read_many_files, exit_plan_mode.
// Names match https://qwenlm.github.io/qwen-code-docs/en/developers/tools/

// MARK: - tiny glob matcher

enum Glob {
    /// Convert a glob pattern to an anchored regex. `**/` crosses directories;
    /// `*` and `?` never cross `/`.
    static func regex(for pattern: String) -> NSRegularExpression? {
        var re = ""
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                if pattern[i...].hasPrefix("**/") {
                    re += "(?:.*/)?"
                    i = pattern.index(i, offsetBy: 3)
                    continue
                } else if pattern[i...].hasPrefix("**") {
                    re += ".*"
                    i = pattern.index(i, offsetBy: 2)
                    continue
                }
                re += "[^/]*"
            case "?":
                re += "[^/]"
            default:
                re += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = pattern.index(after: i)
        }
        return try? NSRegularExpression(pattern: "^\(re)$")
    }

    static func matches(_ pattern: String, _ relativePath: String,
                        filenameOnly: Bool = false) -> Bool {
        guard let regex = regex(for: pattern) else { return false }
        let target = filenameOnly ? (relativePath as NSString).lastPathComponent : relativePath
        let range = NSRange(location: 0, length: (target as NSString).length)
        return regex.firstMatch(in: target, options: [], range: range) != nil
    }
}

/// Recursive file walk returning paths relative to `root`.
/// Plain string APIs so it works from async contexts (FileEnumerator's
/// iteration is unavailable there).
func enumerateRelativePaths(root: String, limit: Int = 5000) -> [String] {
    var out: [String] = []
    walk(dir: root, prefix: "", out: &out, limit: limit)
    return out
}

private func walk(dir: String, prefix: String, out: inout [String], limit: Int) {
    guard out.count < limit,
          let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
    for entry in entries where !entry.hasPrefix(".") {
        guard out.count < limit else { return }
        let full = dir + "/" + entry
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
        let rel = prefix.isEmpty ? entry : prefix + "/" + entry
        if isDir.boolValue {
            walk(dir: full, prefix: rel, out: &out, limit: limit)
        } else {
            out.append(rel)
        }
    }
}

@discardableResult
func isDirectory(_ path: String) -> Bool {
    var isDir = ObjCBool(false)
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

// MARK: - glob

public struct GlobTool: ToolExecutor {
    public static let name = "glob"
    public static let spec = ToolSpec(
        name: name,
        description: "Find files matching a glob pattern (e.g. 'Sources/**/*.swift', '*.json'). Returns matching paths relative to the search directory.",
        parameters: """
        {"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern to match files"},"path":{"type":"string","description":"Directory to search in (default: project folder)"}},"required":["pattern"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let pattern = Self.string(args, "pattern"), !pattern.isEmpty else {
            return .init(output: "Error: pattern is required.")
        }
        let raw = Self.string(args, "path") ?? "."
        let (root, _) = context.policy.resolve(raw)
        guard isDirectory(root.path) else {
            return .init(output: "Error: \(root.path) is not a directory.")
        }
        var matches: [String] = []
        for rel in enumerateRelativePaths(root: root.path) {
            if !isDirectory(root.appendingPathComponent(rel).path), Glob.matches(pattern, rel) {
                matches.append(rel)
                if matches.count >= 500 { break }
            }
        }
        if matches.isEmpty { return .init(output: "No files matched pattern '\(pattern)'.") }
        matches.sort()
        let truncated = matches.count >= 500 ? "\n… (truncated at 500)" : ""
        return .init(output: matches.joined(separator: "\n") + truncated +
            "\n(\(matches.count) match\(matches.count == 1 ? "" : "es"))")
    }
}

// MARK: - grep

public struct GrepTool: ToolExecutor {
    public static let name = "grep"
    public static let spec = ToolSpec(
        name: name,
        description: "Search file contents with a regex (literal strings work as-is). Searches files under the project folder; pass include to restrict to files matching a glob (e.g. '*.swift'). Returns matching lines as path:line: text.",
        parameters: """
        {"type":"object","properties":{"pattern":{"type":"string","description":"Regex (or literal text) to search for"},"path":{"type":"string","description":"Directory to search in (default: project folder)"},"include":{"type":"string","description":"Only search files matching this glob, e.g. '*.swift'"}},"required":["pattern"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let pattern = Self.string(args, "pattern"), !pattern.isEmpty else {
            return .init(output: "Error: pattern is required.")
        }
        let rawDir = Self.string(args, "path") ?? "."
        let include = Self.string(args, "include")
        let (root, _) = context.policy.resolve(rawDir)
        guard isDirectory(root.path) else {
            return .init(output: "Error: \(root.path) is not a directory.")
        }

        var regex: NSRegularExpression?
        do { regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
        catch {
            // Regex was invalid: fall back to literal search.
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            do { regex = try NSRegularExpression(pattern: escaped, options: [.caseInsensitive]) }
            catch { return .init(output: "Error: invalid search pattern: \(pattern)") }
        }
        guard let rx = regex else { return .init(output: "Error: invalid search pattern: \(pattern)") }

        let includeIsBare = include?.contains("/") == false
        var hits: [String] = []
        var hitFiles = 0
        var scanned = 0
        for rel in enumerateRelativePaths(root: root.path, limit: 3000) {
            if let include, !Glob.matches(include, rel, filenameOnly: includeIsBare == true) { continue }
            let full = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: full, encoding: .utf8) else { continue }
            scanned += 1
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches: [NSTextCheckingResult] = rx.matches(in: text, options: [], range: range)
            guard !matches.isEmpty else { continue }
            hitFiles += 1
            let lines = text.components(separatedBy: "\n")
            for m in matches {
                let upTo = String(text.prefix(m.range.location))
                let lineNo = upTo.components(separatedBy: "\n").count
                guard lineNo >= 1, lineNo <= lines.count else { continue }
                let snippet = lines[lineNo - 1].trimmingCharacters(in: .whitespaces)
                guard !snippet.isEmpty else { continue }
                hits.append("\(rel):\(lineNo): \(snippet)")
                if hits.count >= 200 { break }
            }
            if hits.count >= 200 { break }
        }
        if hits.isEmpty {
            return .init(output: "No matches found for '\(rx.pattern)' (\(scanned) files scanned).")
        }
        return .init(output: hits.joined(separator: "\n") +
            "\n(\(hitFiles) files with matches, \(hits.count) line\(hits.count == 1 ? "" : "s"))")
    }
}

// MARK: - read_many_files

public struct ReadManyFilesTool: ToolExecutor {
    public static let name = "read_many_files"
    public static let spec = ToolSpec(
        name: name,
        description: "Read several small files at once. `paths` is a comma-separated list of file paths (relative to the project folder). Each file is capped at 500 lines — use read_file for bigger ones.",
        parameters: """
        {"type":"object","properties":{"paths":{"type":"string","description":"Comma-separated list of file paths to read"}},"required":["paths"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let paths = Self.string(args, "paths") else {
            return .init(output: "Error: paths (comma-separated file paths) is required.")
        }
        var chunks: [String] = []
        var failures: [String] = []
        for raw in paths.split(separator: ",", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            let (url, _) = context.policy.resolve(raw)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let all = text.components(separatedBy: "\n")
                let shown = all.prefix(500).joined(separator: "\n")
                chunks.append("=== \(url.lastPathComponent) ===\n\(shown)"
                    + (all.count > 500 ? "\n… (truncated, \(all.count) lines total)" : ""))
            } else {
                failures.append(raw)
            }
        }
        var out = chunks.joined(separator: "\n\n")
        if !failures.isEmpty {
            out += (out.isEmpty ? "" : "\n\n") + "Could not read: " + failures.joined(separator: ", ")
        }
        return .init(output: out.isEmpty ? "Error: no readable files." : out)
    }
}

// MARK: - exit_plan_mode

/// Signals the end of planning: the agent asked the user for approval to act.
public struct ExitPlanModeTool: ToolExecutor {
    public static let name = "exit_plan_mode"
    public static let spec = ToolSpec(
        name: name,
        description: "Call this when you have finished writing a plan and want the user to approve starting to implement it. Pass the plan summary in `plan`.",
        parameters: """
        {"type":"object","properties":{"plan":{"type":"string","description":"Short summary of the plan to execute"}},"required":["plan"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let plan = Self.string(args, "plan") ?? "(no plan summary)"
        return .init(output: "Plan presented to the user: \(plan)\nImplementation may begin once approved.")
    }
}