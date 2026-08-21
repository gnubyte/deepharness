import XCTest
@testable import DSHCore

// MARK: - Markdown

final class MarkdownTests: XCTestCase {
    func testHeadingsAndParagraphs() {
        let blocks = Markdown.parse("# Title\n\nSome text.\n")
        guard case .heading(let level, let text) = blocks[0] else { return XCTFail("expected heading") }
        XCTAssertEqual(level, 1)
        XCTAssertEqual(text, "Title")
        guard case .paragraph(let body) = blocks[1] else { return XCTFail("expected paragraph") }
        XCTAssertEqual(body, "Some text.")
    }

    func testFencedCodeKeepsLanguageAndBody() {
        let blocks = Markdown.parse("```swift\nlet x = 1\n```")
        guard case .code(let language, let body) = blocks[0] else { return XCTFail("expected code") }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(body, "let x = 1")
    }

    /// A response still streaming has an open fence; it should render as code
    /// rather than as literal backticks.
    func testUnterminatedFenceClosesAtEndOfInput() {
        let blocks = Markdown.parse("```\npartial output")
        guard case .code(_, let body) = blocks[0] else { return XCTFail("expected code") }
        XCTAssertEqual(body, "partial output")
    }

    func testBulletsOrdinalsAndTaskItems() {
        let blocks = Markdown.parse("- one\n2. two\n- [ ] todo\n- [x] done")
        let markers = blocks.compactMap { block -> String? in
            if case .listItem(let marker, _, _) = block { return marker }
            return nil
        }
        XCTAssertEqual(markers, ["•", "2.", "☐", "☑"])
    }

    func testNestedListDepth() {
        let blocks = Markdown.parse("- top\n  - nested")
        guard case .listItem(_, _, let depth) = blocks[1] else { return XCTFail("expected item") }
        XCTAssertEqual(depth, 1)
    }

    func testPipeTable() {
        let source = """
        | Name | Value |
        |------|-------|
        | a    | 1     |
        | b    | 2     |
        """
        let blocks = Markdown.parse(source)
        guard case .table(let header, let rows) = blocks[0] else { return XCTFail("expected table") }
        XCTAssertEqual(header, ["Name", "Value"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["b", "2"])
    }

    func testPipesWithoutDelimiterStayProse() {
        let blocks = Markdown.parse("| this is not | a table")
        if case .table = blocks[0] { XCTFail("should not parse as a table") }
    }

    func testQuotesAndRules() {
        let blocks = Markdown.parse("> quoted\n\n---")
        guard case .quote(let text) = blocks[0] else { return XCTFail("expected quote") }
        XCTAssertEqual(text, "quoted")
        guard case .rule = blocks[1] else { return XCTFail("expected rule") }
    }
}

// MARK: - Plugins

final class PluginTests: XCTestCase {
    func testInterpolationQuotesArguments() {
        let command = PluginTool.interpolate("swift test --filter ${name}",
                                             with: ["name": "My Tests"])
        XCTAssertEqual(command, "swift test --filter 'My Tests'")
    }

    /// The whole point of quoting: an argument cannot break out of its slot.
    func testInterpolationNeutralisesInjection() {
        let command = PluginTool.interpolate("echo ${text}",
                                             with: ["text": "hi; rm -rf /"])
        XCTAssertEqual(command, "echo 'hi; rm -rf /'")
        XCTAssertFalse(command.hasSuffix("rm -rf /"))
    }

    func testEmbeddedSingleQuoteSurvives() {
        let quoted = PluginTool.shellQuote("it's fine")
        XCTAssertEqual(quoted, #"'it'\''s fine'"#)
    }

    func testMissingArgumentBecomesEmptyString() {
        XCTAssertEqual(PluginTool.interpolate("run ${missing}", with: [:]), "run ''")
    }

    func testSafeWordsAreNotQuoted() {
        XCTAssertEqual(PluginTool.interpolate("git show ${ref}", with: ["ref": "HEAD~1"]),
                       "git show 'HEAD~1'")   // '~' is not in the safe set
        XCTAssertEqual(PluginTool.interpolate("cat ${path}", with: ["path": "src/main.swift"]),
                       "cat src/main.swift")
    }

    func testNumbersAndBooleansStringify() {
        XCTAssertEqual(PluginTool.interpolate("-n ${count} -v ${flag}",
                                              with: ["count": 3, "flag": true]),
                       "-n 3 -v true")
    }

    func testManifestDecodesWithInlineSchema() throws {
        let json = """
        {"name":"demo","description":"d","tools":[
          {"name":"t","description":"does a thing",
           "parameters":{"type":"object","properties":{"a":{"type":"string"}}},
           "command":"echo ${a}"}]}
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.tools.count, 1)
        let tool = PluginTool(plugin: manifest.name, declaration: manifest.tools[0])
        XCTAssertEqual(tool.name, "t")
        XCTAssertTrue(tool.spec.parameters.contains("\"type\":\"object\""))
        // Approval defaults on: a plugin runs arbitrary shell.
        XCTAssertNil(manifest.tools[0].requiresApproval)
    }

    func testPluginToolsCannotShadowBuiltins() {
        let manifest = PluginManifest(name: "p", tools: [
            .init(name: "read_file", description: "hijack", command: "cat"),
            .init(name: "mine", description: "fine", command: "true"),
        ])
        let tools = PluginLoader.tools(from: [manifest],
                                       reserved: Set(ToolRegistry.standard().names))
        XCTAssertEqual(tools.map(\.name), ["mine"])
    }

    func testRegistryResolvesPluginToolsByInstanceName() {
        let manifest = PluginManifest(name: "p", tools: [
            .init(name: "deploy", description: "d", command: "true"),
        ])
        let registry = ToolRegistry.standard()
            .adding(PluginLoader.tools(from: [manifest], reserved: []))
        XCTAssertNotNil(registry.tool(named: "deploy"))
        XCTAssertTrue(registry.specs.contains { $0.name == "deploy" })
        // Built-ins still resolve.
        XCTAssertNotNil(registry.tool(named: "read_file"))
    }
}

// MARK: - Project context

final class ProjectContextTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoadsInstructionFiles() throws {
        try "Follow the house style.".write(to: root.appendingPathComponent("AGENTS.md"),
                                            atomically: true, encoding: .utf8)
        try "Remember the port is 8002.".write(to: root.appendingPathComponent("MEMORY.md"),
                                               atomically: true, encoding: .utf8)
        let context = ProjectContext.load(root: root)
        XCTAssertEqual(context.instructions.map(\.label), ["AGENTS.md", "MEMORY.md"])

        let prompt = context.promptSupplement(environment: "ENV")
        XCTAssertTrue(prompt.contains("Follow the house style."))
        XCTAssertTrue(prompt.contains("Remember the port is 8002."))
        XCTAssertTrue(prompt.contains("ENV"))
    }

    func testEmptyInstructionFileIsIgnored() throws {
        try "   \n".write(to: root.appendingPathComponent("QWEN.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(ProjectContext.load(root: root).instructions.isEmpty)
    }

    func testSkillCatalogListsNameAndDescriptionOnly() throws {
        let dir = root.appendingPathComponent(".agents/skills/deploy")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: deploy
        description: Use when shipping a release build.
        ---

        # Deploy
        Secret detail that should not be in the catalog line.
        """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let context = ProjectContext.load(root: root)
        XCTAssertEqual(context.skills.map(\.name), ["deploy"])
        let prompt = context.promptSupplement(environment: "")
        XCTAssertTrue(prompt.contains("Use when shipping a release build."))
        XCTAssertFalse(prompt.contains("Secret detail"))
    }

    func testProjectSkillsWinOverUserSkillsOnNameClash() throws {
        for (path, rankLabel) in [(".dsh/skills/x", "high"), (".agents/skills/x", "low")] {
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: x\ndescription: \(rankLabel)\n---\n"
                .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let context = ProjectContext.load(root: root)
        XCTAssertEqual(context.skills.count, 1)
        XCTAssertEqual(context.skills[0].description, "high")
    }

    func testFrontmatterParsing() {
        let parsed = ProjectContext.frontmatter("---\nname: a\ndescription: \"quoted: value\"\n---\nbody")
        XCTAssertEqual(parsed["name"], "a")
        XCTAssertEqual(parsed["description"], "quoted: value")
        XCTAssertTrue(ProjectContext.frontmatter("no frontmatter here").isEmpty)
    }

    func testSetUpMemoryCreatesScaffoldIdempotently() throws {
        let first = try ProjectContext.setUpMemory(root: root)
        XCTAssertEqual(first.count, 2)
        let second = try ProjectContext.setUpMemory(root: root)
        XCTAssertTrue(second.isEmpty, "existing files must not be overwritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("MEMORY.md").path))
    }

    func testCreateSkillWritesFrontmatter() throws {
        let url = try ProjectContext.createSkill(root: root, name: "Run Tests",
                                                 description: "Use before opening a PR.")
        XCTAssertTrue(url.path.hasSuffix(".agents/skills/run-tests/SKILL.md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(ProjectContext.frontmatter(text)["description"], "Use before opening a PR.")
    }

    func testEnvironmentBlockStatesTheGroundTruth() {
        let block = ProjectContext.environmentBlock(workspace: root, model: "qwen3",
                                                    preset: .workspaceWrite)
        XCTAssertTrue(block.contains(root.path))
        XCTAssertTrue(block.contains("qwen3"))
        XCTAssertTrue(block.contains("workspaceWrite"))
    }

    func testGitBranchReadsHead() throws {
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/x\n".write(to: git.appendingPathComponent("HEAD"),
                                                atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectContext.gitBranch(at: root), "feature/x")
    }

    func testGitBranchIsNilOutsideARepository() {
        XCTAssertNil(ProjectContext.gitBranch(at: root))
    }
}

// MARK: - Permissions

final class PermissionTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/dsh-project").standardizedFileURL

    private func policy(_ preset: PermissionPreset) -> PermissionPolicy {
        PermissionPolicy(preset: preset, workspaceRoot: root)
    }

    func testRelativePathsResolveInsideTheWorkspace() {
        let (url, inside) = policy(.workspaceWrite).resolve("src/main.swift")
        XCTAssertEqual(url.path, "/tmp/dsh-project/src/main.swift")
        XCTAssertTrue(inside)
    }

    func testTraversalEscapesAreDetected() {
        let (_, inside) = policy(.workspaceWrite).resolve("../../etc/passwd")
        XCTAssertFalse(inside)
    }

    /// A sibling directory sharing a name prefix is *not* inside the project.
    func testPrefixSiblingIsNotInside() {
        let (_, inside) = policy(.workspaceWrite).resolve("/tmp/dsh-project-other/file")
        XCTAssertFalse(inside)
    }

    func testWriteInsideProceedsAndOutsideAsks() {
        guard case .proceed = policy(.workspaceWrite).checkWrite(path: "notes.md") else {
            return XCTFail("inside the project should proceed")
        }
        guard case .ask = policy(.workspaceWrite).checkWrite(path: "/etc/hosts") else {
            return XCTFail("outside the project should ask")
        }
    }

    func testFullAccessWritesAnywhereWithoutAsking() {
        guard case .proceed = policy(.fullAccess).checkWrite(path: "/etc/hosts") else {
            return XCTFail("full access should proceed")
        }
    }

    /// Plan mode tells the user nothing will be modified, so the policy has to
    /// back that up even for a write inside the project.
    func testPlanModeAsksBeforeWritingAnywhere() {
        guard case .ask = policy(.plan).checkWrite(path: "notes.md") else {
            return XCTFail("plan mode should ask before writing inside the project")
        }
        guard case .ask = policy(.plan).checkWrite(path: "/etc/hosts") else {
            return XCTFail("plan mode should ask before writing outside the project")
        }
    }

    func testPlanModeAsksBeforeEveryCommand() {
        guard case .ask = policy(.plan).checkShell(command: "ls") else {
            return XCTFail("plan mode should ask even for a read-only command")
        }
    }

    func testMutatingCommandsAskUnderWorkspaceWrite() {
        for command in ["rm -rf build", "git push origin main", "brew install jq", "echo x > out"] {
            guard case .ask = policy(.workspaceWrite).checkShell(command: command) else {
                return XCTFail("\(command) should ask")
            }
        }
    }

    func testReadOnlyCommandsRunWithoutAsking() {
        for command in ["ls -la", "git status", "swift build"] {
            guard case .proceed = policy(.workspaceWrite).checkShell(command: command) else {
                return XCTFail("\(command) should proceed")
            }
        }
    }

    func testTildeExpansion() {
        XCTAssertEqual(policy(.workspaceWrite).expand("~"), NSHomeDirectory())
        XCTAssertEqual(policy(.workspaceWrite).expand("~/x"), NSHomeDirectory() + "/x")
    }
}

// MARK: - Qwen XML tool-call fallback

final class XMLToolCallTests: XCTestCase {
    private let lt = String(UnicodeScalar(60))
    private let gt = String(UnicodeScalar(62))

    func testFunctionStyleBlock() {
        let text = """
        Sure, reading it now.
        \(lt)function=read_file\(gt)
        \(lt)parameter=file_path\(gt)src/main.swift\(lt)/parameter\(gt)
        \(lt)/function\(gt)
        """
        let parsed = XMLToolCalls.parse(text)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "read_file")
        XCTAssertEqual(parsed[0].arguments["file_path"], "src/main.swift")
        // The JSON handed to the engine must read back as the same path.
        // (Foundation escapes "/" as "\/", which is valid and round-trips.)
        XCTAssertEqual(JSONArgs.string(parsed[0].argumentsJSON, "file_path"), "src/main.swift")
    }

    func testToolNameStyleBlock() {
        let text = """
        \(lt)tool_name\(gt)run_shell_command
        \(lt)parameter_name\(gt)command\(lt)/parameter_name\(gt)
        swift build
        \(lt)/tool_name\(gt)
        """
        let parsed = XMLToolCalls.parse(text)
        XCTAssertEqual(parsed.first?.name, "run_shell_command")
        XCTAssertEqual(parsed.first?.arguments["command"], "swift build")
    }

    func testPlainProseIsNotAToolCall() {
        XCTAssertFalse(XMLToolCalls.containsBlock("I would call read_file here, but I won't."))
        XCTAssertTrue(XMLToolCalls.parse("nothing to see").isEmpty)
    }
}

// MARK: - Glob

final class GlobTests: XCTestCase {
    func testStarDoesNotCrossDirectories() {
        XCTAssertTrue(Glob.matches("*.swift", "main.swift"))
        XCTAssertFalse(Glob.matches("*.swift", "src/main.swift"))
    }

    func testDoubleStarCrossesDirectories() {
        XCTAssertTrue(Glob.matches("**/*.swift", "a/b/c.swift"))
        XCTAssertTrue(Glob.matches("**/*.swift", "c.swift"))
    }

    func testQuestionMarkMatchesOneCharacter() {
        XCTAssertTrue(Glob.matches("?.txt", "a.txt"))
        XCTAssertFalse(Glob.matches("?.txt", "ab.txt"))
    }

    func testPrefixedPattern() {
        XCTAssertTrue(Glob.matches("Sources/**/*.swift", "Sources/DSHCore/Engine.swift"))
        XCTAssertFalse(Glob.matches("Sources/**/*.swift", "Tests/DSHCoreTests/X.swift"))
    }
}
