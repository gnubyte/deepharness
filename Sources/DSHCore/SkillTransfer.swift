import Foundation

// MARK: - Running helper tools (unzip, zip, git) safely

enum SkillProcess {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Run a fixed executable with a fixed argv (never a shell string).
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:],
                    timeout: TimeInterval = 60) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { throw SkillError.io("Couldn't run \(URL(fileURLWithPath: exe).lastPathComponent): \(error.localizedDescription)") }
        let outBox = Box(), errBox = Box()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async { outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        readers.enter()
        DispatchQueue.global().async { errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
            throw SkillError.io("\(URL(fileURLWithPath: exe).lastPathComponent) timed out after \(Int(timeout))s.")
        }
        readers.wait()
        return (p.terminationStatus, String(decoding: outBox.get(), as: UTF8.self), String(decoding: errBox.get(), as: UTF8.self))
    }
}

// MARK: - Import

public struct ImportCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let skill: Skill
    /// A project-knowledge file (CLAUDE.md, AGENTS.md, .cursorrules) that becomes an always-on rule.
    public let isInstructionFile: Bool
    public let fileCount: Int
    public let totalBytes: Int
    /// Bundled scripts — listed so the user knows; never run by importing.
    public let hasScripts: Bool
    public let issues: [String]

    public var name: String { skill.name }
    public var description: String { skill.description }
    public var kind: SkillKind { skill.kind }
    public var origin: SkillOrigin { skill.origin }
}

public struct ImportPlan: Sendable {
    public let source: URL
    public let candidates: [ImportCandidate]
    /// Things found but not importable (e.g. Claude subagent definitions).
    public let notes: [String]
    /// A temporary extraction/clone to delete when done.
    public let temporaryRoot: URL?
}

public struct ImportResult: Sendable {
    public var imported: [URL] = []
    public var drafts: [SkillDraft] = []
    public var skipped: [String: String] = [:]
}

public enum SkillImporter {
    static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "py", "rb", "pl", "js", "mjs", "ts", "command", "swift", "lua", "php", "ps1", "bat", "cmd", "gd"]
    static let skipDirectories: Set<String> = [".git", "node_modules", ".build", ".godot", "worktrees", "__pycache__", ".venv", "venv", "Pods", "DerivedData"]
    static let instructionFileNames: Set<String> = ["CLAUDE.md", "AGENTS.md", "QWEN.md", ".cursorrules", "CLAUDE.local.md"]

    // MARK: Scanning

    public static func scan(_ source: URL) throws -> ImportPlan {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw SkillError.notFound("\(source.lastPathComponent) doesn't exist.") }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDir)
        if isDir.boolValue { return try scanFolder(source, temporaryRoot: nil) }
        let ext = source.pathExtension.lowercased()
        if ext == "zip" {
            let dir = try unzip(source)
            return try scanFolder(dir, temporaryRoot: dir, displaySource: source)
        }
        return try scanFile(source)
    }

    /// Fetch from `https://…`: a `.zip`, `.md`/`.mdc` file, or a git repository
    /// (GitHub `…/tree/<branch>/<folder>` links import just that folder).
    public static func scan(remote raw: String) async throws -> ImportPlan {
        guard var comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == "https", let host = comps.host, !host.isEmpty else {
            throw SkillError.invalid("Enter an https:// link to a repository, .zip, or .md file.")
        }
        comps.fragment = nil
        let path = comps.path
        let ext = (path as NSString).pathExtension.lowercased()
        let fm = FileManager.default
        if ["zip", "md", "mdc"].contains(ext), let url = comps.url {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw SkillError.io("The server replied \(http.statusCode).")
            }
            guard data.count <= 60_000_000 else { throw SkillError.tooLarge("That download is too large.") }
            let tmp = SkillFiles.stagingDirectory()
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let file = tmp.appendingPathComponent((path as NSString).lastPathComponent.nonEmptyOr("download.\(ext)"))
            try data.write(to: file)
            let plan = try scan(file)
            return ImportPlan(source: url, candidates: plan.candidates, notes: plan.notes,
                              temporaryRoot: plan.temporaryRoot ?? tmp)
        }
        // Git repository. A GitHub tree link names a branch and a subfolder.
        var repoPath = path
        var branch: String?
        var subfolder: String?
        let parts = path.split(separator: "/").map(String.init)
        if host == "github.com", parts.count >= 4, parts[2] == "tree" {
            repoPath = "/" + parts[0...1].joined(separator: "/")
            branch = parts[3]
            if parts.count > 4 { subfolder = parts[4...].joined(separator: "/") }
        }
        while repoPath.hasSuffix("/") { repoPath.removeLast() }
        comps.path = repoPath
        comps.query = nil
        guard let cloneURL = comps.url?.absoluteString else { throw SkillError.invalid("That link isn't valid.") }
        let dest = SkillFiles.stagingDirectory()
        var args = ["clone", "--depth", "1", "--single-branch", "--no-tags"]
        if let branch { args += ["--branch", branch] }
        args += ["--", cloneURL, dest.path]
        let result = try await Task.detached {
            try SkillProcess.run("/usr/bin/git", args, env: ["GIT_TERMINAL_PROMPT": "0"], timeout: 90)
        }.value
        guard result.status == 0 else {
            try? fm.removeItem(at: dest)
            let why = result.err.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "git clone failed"
            throw SkillError.io("Couldn't fetch the repository: \(why)")
        }
        let root = subfolder.map { dest.appendingPathComponent($0) } ?? dest
        guard fm.fileExists(atPath: root.path) else {
            try? fm.removeItem(at: dest)
            throw SkillError.notFound("The folder “\(subfolder ?? "")” isn't in that repository.")
        }
        return try scanFolder(root, temporaryRoot: dest, displaySource: URL(string: raw))
    }

    static func scanFile(_ file: URL) throws -> ImportPlan {
        let ext = file.pathExtension.lowercased()
        guard ext == "md" || ext == "mdc" || file.lastPathComponent == ".cursorrules" else {
            throw SkillError.unsupported("Choose a folder, a .zip, or a .md / .mdc file.")
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw SkillError.io("Can't read that file.") }
        let doc = SkillDocument.parse(text)
        let lower = file.lastPathComponent.lowercased()
        // SKILL.md alone: import its folder.
        if lower == "skill.md" { return try scanFolder(file.deletingLastPathComponent(), temporaryRoot: nil) }
        let isInstruction = instructionFileNames.contains(file.lastPathComponent)
        let name = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".", with: "")
        let root = SkillRoot(url: file.deletingLastPathComponent(), rank: 0, origin: ext == "mdc" ? .cursor : .dsh,
                             scope: .user, layout: .commandFiles)
        var skill = SkillCatalog.build(doc, url: file, fallbackName: isInstruction ? SkillNaming.slug(file.lastPathComponent) : name,
                                       root: root, kind: .rule, claudeRuleStyle: ext == "md")
        if isInstruction { skill.alwaysApply = true }
        return ImportPlan(source: file, candidates: [candidate(skill, instruction: isInstruction)], notes: [], temporaryRoot: nil)
    }

    static func scanFolder(_ folder: URL, temporaryRoot: URL?, displaySource: URL? = nil) throws -> ImportPlan {
        let fm = FileManager.default
        var candidates: [ImportCandidate] = []
        var notes: [String] = []
        var seen = Set<String>()
        var visited = 0

        func add(_ c: ImportCandidate) {
            if seen.insert(c.skill.url.standardizedFileURL.path).inserted { candidates.append(c) }
        }

        func origin(of url: URL) -> SkillOrigin {
            let parts = Set(url.standardizedFileURL.pathComponents)
            if parts.contains(".claude") || parts.contains(".claude-plugin") { return .claude }
            if parts.contains(".cursor") { return .cursor }
            if parts.contains(".agents") { return .agents }
            if parts.contains(".qwen") { return .qwen }
            if parts.contains(".dsh") { return .dsh }
            return .dsh
        }

        // A folder that is itself a skill.
        if fm.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) {
            let root = SkillRoot(url: folder.deletingLastPathComponent(), rank: 0, origin: origin(of: folder), scope: .user, layout: .skillDirs)
            if let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) {
                add(candidate(SkillCatalog.build(SkillDocument.parse(text), url: folder.appendingPathComponent("SKILL.md"),
                                                 fallbackName: folder.lastPathComponent, root: root, kind: .skill)))
            }
            return ImportPlan(source: displaySource ?? folder, candidates: candidates, notes: notes, temporaryRoot: temporaryRoot)
        }

        // Top-level project knowledge.
        for name in instructionFileNames.sorted() + [".claude/CLAUDE.md"] {
            let file = folder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let root = SkillRoot(url: folder, rank: 0, origin: name == ".cursorrules" ? .cursor : (name.contains("CLAUDE") ? .claude : .dsh),
                                 scope: .user, layout: .commandFiles)
            var doc = SkillDocument.parse(text)
            if doc["description"] == nil { doc["description"] = "Project instructions imported from \(name)." }
            var skill = SkillCatalog.build(doc, url: file, fallbackName: SkillNaming.slug(name), root: root, kind: .rule)
            skill.alwaysApply = true
            add(candidate(skill, instruction: true))
        }

        func walk(_ dir: URL, depth: Int) {
            guard depth <= 6, visited < 4_000 else { return }
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                            options: []) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                visited += 1
                let name = entry.lastPathComponent
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                guard values?.isDirectory == true else {
                    // Loose rules: any .mdc, or .md under a `rules` folder.
                    let ext = entry.pathExtension.lowercased()
                    let parent = dir.lastPathComponent
                    if ext == "mdc" || (ext == "md" && parent == "rules") {
                        let claude = entry.standardizedFileURL.pathComponents.contains(".claude")
                        let root = SkillRoot(url: dir, rank: 0, origin: origin(of: entry), scope: .user, layout: .ruleFiles(claudeStyle: claude))
                        if let text = try? String(contentsOf: entry, encoding: .utf8) {
                            add(candidate(SkillCatalog.build(SkillDocument.parse(text), url: entry,
                                                             fallbackName: entry.deletingPathExtension().lastPathComponent,
                                                             root: root, kind: .rule, claudeRuleStyle: claude)))
                        }
                    }
                    continue
                }
                if skipDirectories.contains(name) { continue }
                let manifest = entry.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: manifest.path), let text = try? String(contentsOf: manifest, encoding: .utf8) {
                    let root = SkillRoot(url: dir, rank: 0, origin: origin(of: entry), scope: .user, layout: .skillDirs)
                    add(candidate(SkillCatalog.build(SkillDocument.parse(text), url: manifest, fallbackName: name, root: root, kind: .skill)))
                    continue      // a skill's own folder is its content, not a place to search
                }
                if name == "commands" {
                    let parentName = dir.lastPathComponent
                    let isPlugin = fm.fileExists(atPath: dir.appendingPathComponent(".claude-plugin").path)
                    if parentName == ".claude" || isPlugin || dir.standardizedFileURL == folder.standardizedFileURL {
                        let root = SkillRoot(url: entry, rank: 0, origin: .claude, scope: .user, layout: .commandFiles)
                        for command in SkillCatalog.scanCommands(root) { add(candidate(command)) }
                        continue
                    }
                }
                if name == "agents", dir.lastPathComponent == ".claude" || fm.fileExists(atPath: dir.appendingPathComponent(".claude-plugin").path) || dir.standardizedFileURL == folder.standardizedFileURL {
                    let count = ((try? fm.contentsOfDirectory(atPath: entry.path)) ?? []).filter { $0.hasSuffix(".md") }.count
                    if count > 0 { notes.append("\(count) Claude subagent definition\(count == 1 ? "" : "s") in \(name)/ can't be imported (DSH has no subagent files).") }
                    continue
                }
                walk(entry, depth: depth + 1)
            }
        }
        walk(folder, depth: 0)
        if candidates.isEmpty { notes.append("No skills, rules, or commands were found there.") }
        return ImportPlan(source: displaySource ?? folder, candidates: candidates, notes: notes, temporaryRoot: temporaryRoot)
    }

    static func candidate(_ skill: Skill, instruction: Bool = false) -> ImportCandidate {
        let fm = FileManager.default
        var count = 1, bytes = 0, scripts = false
        if skill.kind == .skill, let en = fm.enumerator(at: skill.directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            count = 0
            for case let file as URL in en {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                count += 1
                bytes += values?.fileSize ?? 0
                if scriptExtensions.contains(file.pathExtension.lowercased()) { scripts = true }
                if let attrs = try? fm.attributesOfItem(atPath: file.path), let perm = attrs[.posixPermissions] as? NSNumber, perm.intValue & 0o111 != 0 { scripts = true }
            }
        } else {
            bytes = (try? fm.attributesOfItem(atPath: skill.url.path)[.size] as? Int) ?? 0
        }
        let text = (try? String(contentsOf: skill.url, encoding: .utf8)) ?? ""
        let issues = SkillLint.check(text).filter { $0.severity >= .warning && !$0.message.contains("frontmatter") }.map(\.message)
        return ImportCandidate(id: skill.url.standardizedFileURL.path, skill: skill, isInstructionFile: instruction,
                               fileCount: count, totalBytes: bytes, hasScripts: scripts, issues: issues)
    }

    // MARK: Zip

    static func unzip(_ zip: URL) throws -> URL {
        let fm = FileManager.default
        let list = try SkillProcess.run("/usr/bin/unzip", ["-Z1", zip.path], timeout: 30)
        guard list.status == 0 else { throw SkillError.io("That doesn't look like a valid zip file.") }
        let names = list.out.split(separator: "\n").map(String.init)
        guard names.count <= 5_000 else { throw SkillError.tooLarge("That archive has too many files.") }
        for name in names {
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                throw SkillError.invalid("That archive has unsafe paths (\(name)); it was not opened.")
            }
        }
        let info = try SkillProcess.run("/usr/bin/unzip", ["-Zt", zip.path], timeout: 30)
        if let range = info.out.range(of: #"(\d+) bytes uncompressed"#, options: .regularExpression),
           let bytes = Int(info.out[range].split(separator: " ")[0]), bytes > 150_000_000 {
            throw SkillError.tooLarge("That archive expands to \(bytes / 1_000_000) MB — too large to be skills.")
        }
        let dest = SkillFiles.stagingDirectory()
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let result = try SkillProcess.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", dest.path, "-x", "__MACOSX/*"], timeout: 90)
        guard result.status == 0 || result.status == 1 else {    // 1 = warnings only
            try? fm.removeItem(at: dest)
            throw SkillError.io("Couldn't extract the archive: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // Belt and braces: nothing outside `dest`, no symlinks.
        if let en = fm.enumerator(at: dest, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let base = dest.standardizedFileURL.path
            for case let item as URL in en {
                if !item.standardizedFileURL.path.hasPrefix(base) || (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    try? fm.removeItem(at: item)
                }
            }
        }
        return dest
    }

    public static func dispose(_ plan: ImportPlan) {
        if let tmp = plan.temporaryRoot { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: Importing

    /// Import the chosen candidates. As drafts, they wait in the approval queue;
    /// otherwise they go straight to the DSH store (the user's selection in the
    /// import sheet is the approval).
    public static func perform(_ plan: ImportPlan, selecting ids: Set<String>, scope: SkillScope, projectRoot: URL?,
                               asDraft: Bool, conflict: ConflictPolicy = .rename,
                               locations: SkillLocations = .standard) throws -> ImportResult {
        var result = ImportResult()
        let base = asDraft ? nil : try SkillManager.base(scope: scope, projectRoot: projectRoot, locations: locations)
        for cand in plan.candidates where ids.contains(cand.id) {
            let slug = SkillNaming.slug(cand.skill.name).nonEmptyOr("imported-skill")
            let staged = SkillFiles.stagingDirectory()
            do {
                try SkillConverter.writeSkillFolder(cand.skill, to: staged, name: slug)
                if asDraft {
                    let draft = try SkillDrafts.stage(folder: staged, scope: scope, projectRoot: projectRoot, source: "import",
                                                      note: "Imported from \(cand.origin.label) \(cand.kind.label.lowercased()) “\(cand.skill.name)”",
                                                      locations: locations)
                    result.drafts.append(draft)
                    try? FileManager.default.removeItem(at: staged)
                } else if let base {
                    let landed = try SkillFiles.place(staged, at: base.appendingPathComponent(slug), conflict: conflict)
                    result.imported.append(landed.appendingPathComponent("SKILL.md"))
                }
            } catch {
                try? FileManager.default.removeItem(at: staged)
                result.skipped[cand.skill.name] = error.localizedDescription
            }
        }
        return result
    }
}

// MARK: - Export

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    /// `<slug>/SKILL.md` — a plain skill folder, the shape Claude/Agent Skills uploads and most repos use.
    case portable
    case claude, cursor, agents, dsh
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .portable: "Portable skill folders"
        case .claude: "Claude Code (.claude/skills)"
        case .cursor: "Cursor (.cursor/rules, .mdc)"
        case .agents: "Agent Skills (.agents/skills)"
        case .dsh: "DSH (.dsh/skills)"
        }
    }

    public var detail: String {
        switch self {
        case .portable: "One folder per skill with SKILL.md — zip and share anywhere."
        case .claude: "Drop into a project (or ~/.claude) and Claude Code picks the skills up."
        case .cursor: "Rules as .mdc files; skills with bundled files go to .cursor/skills."
        case .agents: "The cross-tool .agents/skills layout."
        case .dsh: "This app's own layout."
        }
    }
}

public enum SkillExporter {
    /// Lay `skills` out under `root` in `format`. Returns the files/folders written.
    @discardableResult
    public static func write(_ skills: [Skill], format: ExportFormat, into root: URL,
                             conflict: ConflictPolicy = .fail) throws -> [URL] {
        let fm = FileManager.default
        var written: [URL] = []
        var used = Set<String>()
        for skill in skills {
            let slug = SkillNaming.unique(SkillNaming.slug(skill.name).nonEmptyOr("skill")) { used.contains($0) }
            used.insert(slug)
            switch format {
            case .cursor where skill.kind != .skill || skill.resources().isEmpty:
                guard let text = SkillConverter.cursorRule(for: skill) else { continue }
                let dir = root.appendingPathComponent(".cursor/rules", isDirectory: true)
                var target = dir.appendingPathComponent("\(slug).mdc")
                if fm.fileExists(atPath: target.path) {
                    switch conflict {
                    case .fail: throw SkillError.exists("\(slug).mdc already exists in .cursor/rules.")
                    case .replace: try fm.removeItem(at: target)
                    case .rename:
                        let name = SkillNaming.unique(slug) { fm.fileExists(atPath: dir.appendingPathComponent("\($0).mdc").path) }
                        target = dir.appendingPathComponent("\(name).mdc")
                    }
                }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try text.write(to: target, atomically: true, encoding: .utf8)
                written.append(target)
            default:
                let sub: String
                switch format {
                case .portable: sub = slug
                case .claude: sub = ".claude/skills/\(slug)"
                case .cursor: sub = ".cursor/skills/\(slug)"
                case .agents: sub = ".agents/skills/\(slug)"
                case .dsh: sub = ".dsh/skills/\(slug)"
                }
                let staged = SkillFiles.stagingDirectory()
                do {
                    try SkillConverter.writeSkillFolder(skill, to: staged, name: slug)
                    written.append(try SkillFiles.place(staged, at: root.appendingPathComponent(sub), conflict: conflict))
                } catch {
                    try? fm.removeItem(at: staged)
                    throw error
                }
            }
        }
        return written
    }

    /// Build a zip of `skills` in `format`. Portable zips hold the skill
    /// folders at the top; the other layouts hold their dot-folders.
    public static func zip(_ skills: [Skill], format: ExportFormat, to zipURL: URL) throws {
        let fm = FileManager.default
        let staging = SkillFiles.stagingDirectory()
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try write(skills, format: format, into: staging, conflict: .rename)
        if format != .portable {
            let readme = """
            Skills exported from DSH (\(format.label)).

            Unzip this into a project folder (or your home folder for user-wide skills); the tool picks them up from there.
            Each skill is plain Markdown — read SKILL.md before trusting a skill you didn't write: skills can tell an agent to run commands.
            """
            try readme.write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        }
        try? fm.removeItem(at: zipURL)
        let result = try SkillProcess.run("/usr/bin/zip", ["-r", "-q", "-X", zipURL.path, "."], cwd: staging, timeout: 60)
        guard result.status == 0 else { throw SkillError.io("Couldn't create the zip: \(result.err)") }
    }
}
