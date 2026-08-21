import Foundation

// MARK: - read_file

public struct ReadFileTool: ToolExecutor {
    public static let name = "read_file"
    public static let spec = ToolSpec(
        name: name,
        description: "Read a text file. Returns contents with 1-based line numbers. Use start_line/end_line for large files (defaults to the first 1000 lines). Paths may be relative to the project folder.",
        parameters: """
        {"type":"object","properties":{"file_path":{"type":"string","description":"Path of the file to read"},"start_line":{"type":"integer","description":"First line to read (1-based, inclusive)"},"end_line":{"type":"integer","description":"Last line to read (inclusive)"},"description":{"type":"string","description":"Short reason for reading"}},"required":["file_path"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "file_path"), !raw.isEmpty else {
            return .init(output: "Error: file_path is required.")
        }
        let (url, _) = context.policy.resolve(raw)
        do {
            let text: String
            if let data = try? Data(contentsOf: url) {
                text = String(decoding: data, as: UTF8.self)
                    // Replace CRLF and lone CR so line math is sane.
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
            } else if let s = try? String(contentsOf: url, encoding: .utf8) {
                text = s
            } else {
                return .init(output: "Error: cannot read \(url.lastPathComponent): not a readable text file (binary or missing).")
            }
            let lines = text.components(separatedBy: "\n")
            let total = lines.count
        let start = max(1, Self.int(args, "start_line", default: 1))
        let end = min(total, max(start, Self.int(args, "end_line", default: min(total, start + 999))))
        guard start <= end, start <= total else {
            return .init(output: "Error: no such line range (file has \(total) lines).")
        }
            let out = lines[(start - 1)..<end].enumerated().map { i, line in
                String(format: "%d | %@", i + start, line)
            }.joined(separator: "\n")
            let more = end < total ? "\n\n(File has \(total) lines total; showing \(start)-\(end).)" : ""
            return .init(output: out + more)
        } catch {
            return .init(output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - write_file

public struct WriteFileTool: ToolExecutor {
    public static let name = "write_file"
    public static let spec = ToolSpec(
        name: name,
        description: "Create or overwrite a file with the given contents. Parent directories are created as needed.",
        parameters: """
        {"type":"object","properties":{"file_path":{"type":"string"},"content":{"type":"string","description":"Full file contents"},"description":{"type":"string"}},"required":["file_path","content"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "file_path"), let content = Self.string(args, "content") else {
            return .init(output: "Error: file_path and content are required.")
        }
        let (url, _) = context.policy.resolve(raw)
        let existed: Bool
        do {
            var isDir: ObjCBool = false
            existed = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            let change = FileChange(url, existed ? .modified : .created)
            return .init(output: "Wrote \(content.count) characters to \(url.lastPathComponent).", files: [change])
        } catch {
            return .init(output: "Error: write failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - edit (old_string/new_string)

public struct EditTool: ToolExecutor {
    public static let name = "edit"
    public static let spec = ToolSpec(
        name: name,
        description: "Replace an exact block of text in a file. old_string must match exactly (including whitespace) and must be unique in the file unless replace_all is true. Creates the file with just new_string when the file does not exist.",
        parameters: """
        {"type":"object","properties":{"file_path":{"type":"string"},"old_string":{"type":"string","description":"Exact text to find"},"new_string":{"type":"string","description":"Replacement text"},"replace_all":{"type":"boolean","description":"Replace every occurrence"},"description":{"type":"string"}},"required":["file_path","old_string","new_string"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "file_path"),
              let old = Self.string(args, "old_string"),
              let new = Self.string(args, "new_string") else {
            return .init(output: "Error: file_path, old_string and new_string are required.")
        }
        let replaceAll = Self.bool(args, "replace_all", default: false)
        let (url, _) = context.policy.resolve(raw)

        guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
            // New file from an edit: only the replacement text lands in it.
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true)
                try new.write(to: url, atomically: true, encoding: .utf8)
                return .init(output: "Created \(url.lastPathComponent) with the new block.",
                             files: [FileChange(url, .created)])
            } catch {
                return .init(output: "Error: \(error.localizedDescription)")
            }
        }

        let occurrences = existing.components(separatedBy: old).count - 1
        guard occurrences >= 1 else {
            return .init(output: "Error: old_string not found in \(url.lastPathComponent). Read the file and copy the exact text (whitespace matters).")
        }
        if occurrences > 1 && !replaceAll {
            return .init(output: "Error: old_string matches \(occurrences) times. Include more surrounding lines to make it unique, or set replace_all=true.")
        }

        let updated: String
        if replaceAll {
            updated = existing.replacingOccurrences(of: old, with: new)
        } else {
            guard let r = existing.range(of: old) else {
                return .init(output: "Error: old_string not found.")
            }
            updated = existing.replacingCharacters(in: r, with: new)
        }
        do {
            _ = url
            try updated.write(to: url, atomically: true, encoding: .utf8)
            let n = replaceAll ? occurrences : 1
            return .init(output: "Edited \(url.lastPathComponent): replaced \(n) occurrence\(n == 1 ? "" : "s").",
                         files: [FileChange(url, .modified)])
        } catch {
            return .init(output: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - list_directory

public struct ListDirectoryTool: ToolExecutor {
    public static let name = "list_directory"
    public static let spec = ToolSpec(
        name: name,
        description: "List files and directories. Non-recursive by default; pass recursive=true for a full tree.",
        parameters: """
        {"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default: project folder)"},"recursive":{"type":"boolean"}},"required":[]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let raw = Self.string(args, "path") ?? "."
        let (url, _) = context.policy.resolve(raw)
        let recursive = Self.bool(args, "recursive", default: false)

        do {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return .init(output: "Error: \(url.path) is not a directory.")
            }
            let lines: [String]
            if recursive {
                lines = Self.walk(url)
            } else {
                let entries = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
                lines = entries.sorted { lhs, rhs in
                    let lDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let rDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return lDir == rDir ? lhs.lastPathComponent < rhs.lastPathComponent : lDir
                }.map { e in
                    let isDirectory = (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return (isDirectory ? "📁 " : "  ") + e.lastPathComponent
                }
            }
            return .init(output: lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"))
        } catch {
            return .init(output: "Error: \(error.localizedDescription)")
        }
    }

    private static func walk(_ root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles], errorHandler: { _, _ in false }) else {
            return []
        }
        var out: [String] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - root.pathComponents.count
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let indent = String(repeating: "  ", count: max(0, depth - 1))
            out.append(indent + (isDir ? "📁 " : "  ") + url.lastPathComponent)
            if out.count >= 500 {
                out.append("… (truncated at 500 entries)")
                break
            }
        }
        return out
    }
}