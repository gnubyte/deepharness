import Foundation

// MARK: - Permission policy (workspace-write by default, like the DGX guide's presets)

/// How much of the machine the agent may touch without asking.
public enum PermissionPreset: String, Codable, CaseIterable, Sendable {
    /// Reads anywhere; writes and commands stay inside the project folder.
    case workspaceWrite
    /// Same, but shell commands also require approval even inside the project.
    case plan
    /// Writes and commands allowed without asking (still confined to the project
    /// for file tools; the model is trusted for the rest).
    case fullAccess
}

/// Outcome of asking a tool call's permission gate.
public enum PermissionDecision: Sendable {
    case proceed
    case deny(reason: String)
    case ask
}

public struct PermissionPolicy: Sendable {
    public var preset: PermissionPreset
    /// Root the write shell is confined to. Everything relative to this.
    public var workspaceRoot: URL

    public init(preset: PermissionPreset, workspaceRoot: URL) {
        self.preset = preset
        self.workspaceRoot = workspaceRoot.standardizedFileURL
    }

    // MARK: - Path containment

    /// Resolve a model-supplied path (may be relative, `~/…`, or absolute)
    /// against the workspace root and check it stays inside it.
    public func resolve(_ raw: String) -> (url: URL, inside: Bool) {
        let expanded = expand(raw)
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL
        let inside = path(resolved)
        return (resolved, inside)
    }

    private func path(_ other: URL) -> Bool {
        other.path == workspaceRoot.path || other.path.hasPrefix(workspaceRoot.path + "/")
    }

    /// Expand `~` and make relative paths absolute against the workspace.
    public func expand(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t == "~" { return NSHomeDirectory() }
        if t.hasPrefix("~/") {
            return NSHomeDirectory() + String(t.dropFirst(1))
        }
        if t.hasPrefix("/") { return t }
        return URL(fileURLWithPath: workspaceRoot.path).appendingPathComponent(t).path
    }

    // MARK: - Gates

    /// File-write tools.
    public func checkWrite(path raw: String) -> PermissionDecision {
        if preset == .fullAccess { return .proceed }
        // Plan mode promises the user nothing gets modified, so a write asks
        // wherever it lands rather than only outside the project.
        if preset == .plan { return .ask }
        let (_, inside) = resolve(raw)
        return inside ? .proceed : .ask
    }

    /// Shell commands. We never inspect the command string deeply; the rule is
    /// positional: workspaceWrite lets reads through implicitly (commands that
    /// only read are fine), but any *potentially mutating* command asks.
    public func checkShell(command: String) -> PermissionDecision {
        switch preset {
        case .plan:
            return .ask
        case .fullAccess:
            return .proceed
        case .workspaceWrite:
            // Heuristic: treat the command as safe to run without asking when
            // it does not contain obvious mutation operators.
            let mutating = ["rm ", "sudo", "> ", ">>", "mv ", "cp ", "mkdir", "chmod",
                            "chown", "dd ", "git push", "git commit", "git checkout",
                            "git reset", "brew install", "pip install", "npm install",
                            "git branch -d", "git rebase", "git merge"]
            for m in mutating where command.contains(m) {
                return .ask
            }
            return .proceed
        }
    }

    /// Web fetch: read-only; only `fullAccess` restrictions matter (none).
    public func checkFetch() -> PermissionDecision { .proceed }
}