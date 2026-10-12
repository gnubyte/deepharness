import XCTest
@testable import DSHCore

final class AgentTypesTests: XCTestCase {
    private var root: FleetTestDirectory!

    override func setUp() {
        super.setUp()
        root = FleetTestDirectory("dsh-agents")
    }

    override func tearDown() {
        root.remove()
        super.tearDown()
    }

    private func parse(_ text: String, name: String = "fallback", origin: String = "user") -> AgentDefinition? {
        AgentDefinition.parse(text, fallbackName: name, origin: origin, path: nil)
    }

    // MARK: - Definitions

    func testTheBuiltInTypesCoverTheUsualDivisionOfLabour() throws {
        let catalog = AgentCatalog.default
        XCTAssertEqual(catalog.all.map(\.name), ["general", "explore", "plan", "review", "worker"])
        XCTAssertNil(try XCTUnwrap(catalog.find(nil)).tools)
        XCTAssertEqual(catalog.find("general"), catalog.find(""))
        XCTAssertEqual(catalog.find("Explore"), catalog.find(" explore "))
        XCTAssertNil(catalog.find("wizard"))
        // Read-only types cannot change anything.
        for name in ["explore", "plan", "review"] {
            let tools = try XCTUnwrap(catalog.find(name)?.tools)
            XCTAssertFalse(tools.contains("write_file"), name)
            XCTAssertFalse(tools.contains("edit"), name)
        }
        XCTAssertFalse(try XCTUnwrap(catalog.find("explore")?.tools).contains("run_shell_command"))
        XCTAssertTrue(try XCTUnwrap(catalog.find("review")?.tools).contains("run_shell_command"))
        XCTAssertTrue(catalog.describe().contains("explore:"))
    }

    func testTheBuiltInsCarryTheirStepBudgetsAndPrompts() throws {
        let catalog = AgentCatalog.default
        XCTAssertNil(catalog.find("general")?.maxSteps)
        XCTAssertEqual(catalog.find("explore")?.maxSteps, 40)
        XCTAssertEqual(catalog.find("plan")?.maxSteps, 40)
        XCTAssertEqual(catalog.find("review")?.maxSteps, 40)
        XCTAssertEqual(catalog.find("worker")?.maxSteps, 60)
        XCTAssertTrue(try XCTUnwrap(catalog.find("explore")?.prompt).contains("read-only investigator"))
        XCTAssertTrue(try XCTUnwrap(catalog.find("plan")?.prompt).contains("You are a planner"))
        XCTAssertTrue(try XCTUnwrap(catalog.find("review")?.prompt).contains("code reviewer"))
        XCTAssertTrue(try XCTUnwrap(catalog.find("worker")?.prompt).contains("implementer"))
        XCTAssertEqual(AgentDefinition.builtIn.map(\.origin), Array(repeating: "built-in", count: 5))
    }

    func testAnAgentFileIsParsedLikeClaudeCodesFormat() throws {
        let def = try XCTUnwrap(AgentDefinition.parse(
            "---\nname: Test Runner\ndescription: Runs the tests and summarises failures\ntools: Read, Grep, Bash, Nonsense\nmodel: spark-2\nmax_steps: 25\n---\nRun `swift test` and report failures.\n",
            fallbackName: "fallback", origin: "project", path: URL(fileURLWithPath: "/x/x.md")))
        XCTAssertEqual(def.name, "test-runner")
        XCTAssertEqual(def.description, "Runs the tests and summarises failures")
        XCTAssertEqual(def.tools, ["read_file", "grep", "run_shell_command"])
        XCTAssertEqual(def.server, "spark-2")
        XCTAssertEqual(def.maxSteps, 25)
        XCTAssertEqual(def.prompt, "Run `swift test` and report failures.")
        XCTAssertEqual(def.origin, "project")
        XCTAssertEqual(def.path, URL(fileURLWithPath: "/x/x.md"))
    }

    func testListStyleToolsAndTheFileNameAsFallbackName() throws {
        let def = try XCTUnwrap(parse("---\ndescription: Looks around\ntools:\n  - read_file\n  - glob\nreadonly: true\n---\nLook.", name: "scout"))
        XCTAssertEqual(def.name, "scout")
        XCTAssertEqual(def.tools, ["read_file", "glob"])
        XCTAssertTrue(def.readOnly)
    }

    func testReadOnlyWithoutAToolListMeansTheReadOnlyTools() throws {
        let def = try XCTUnwrap(parse("---\nname: peek\ndescription: d\nreadonly: true\n---\nb", name: "peek"))
        XCTAssertEqual(def.tools, AgentDefinition.readOnlyTools)
    }

    func testToolNamesThatMeanNothingHereLeaveOnlyTheReadingToolsNeverEverything() throws {
        // "tools: Task" in a Claude agent file means "restricted" — reading it as "unrestricted" would hand that agent the
        // shell. A line left blank says the same thing more quietly.
        for line in ["tools: Foo, Bar", "tools:", "tools: []", "tools: \"\""] {
            let def = try XCTUnwrap(parse("---\nname: odd\ndescription: d\n\(line)\n---\nb", name: "odd"), line)
            XCTAssertEqual(def.tools, AgentDefinition.readOnlyTools, line)
            XCTAssertTrue(def.isReadOnly, line)
        }
    }

    func testACommentedOutToolInAnIndentedListNeverGrantsTheShell() throws {
        for block in ["tools:\n  - Read\n  - Grep\n  # - Bash",
                      "tools:\n  # - Bash",
                      "tools:\n  # none of the shell tools",
                      "tools:\n  - Read # just this\n  # - Bash"] {
            let def = try XCTUnwrap(parse("---\nname: careful\ndescription: d\n\(block)\n---\nb", name: "careful"), block)
            let tools = try XCTUnwrap(def.tools, block)
            XCTAssertFalse(tools.contains("run_shell_command"), block)
            XCTAssertFalse(tools.contains("write_file"), block)
            XCTAssertFalse(tools.contains("edit"), block)
        }
    }

    func testACommentInsideAListIsNotAnItemAndDoesNotLoseTheList() throws {
        let def = try XCTUnwrap(parse("---\nname: careful\ndescription: d\ntools:\n  - Read\n  # - Bash\n  - Grep\n---\nb", name: "careful"))
        XCTAssertEqual(def.tools, ["read_file", "grep"])
        // The same for a list written inline and continued over several lines.
        let inline = try XCTUnwrap(parse("---\nname: careful\ndescription: d\ntools: [Read,\n  # Bash is not wanted\n  Glob]\n---\nb", name: "careful"))
        XCTAssertEqual(inline.tools, ["read_file", "glob"])
    }

    func testACommentInsideABlockScalarIsItsText() throws {
        // (`|` keeps the lines as written, comment-looking ones included.)
        let def = try XCTUnwrap(parse("---\nname: doc\ndescription: |\n  Line one\n  # not a comment\n  Line three\n---\nbody", name: "doc"))
        XCTAssertEqual(def.description, "Line one\n# not a comment\nLine three")
    }

    func testACommentBesideAScalarIsNotPartOfIt() throws {
        let def = try XCTUnwrap(parse("---\nname: x\ndescription: Does things\n  # a remark\nmodel: spark-3\n---\nbody", name: "x"))
        XCTAssertEqual(def.description, "Does things")
        XCTAssertEqual(def.server, "spark-3")
    }

    func testAToolsBlockTheReaderCannotMakeSenseOfStillRestrictsTheAgent() throws {
        // The frontmatter reader has no use for a nested mapping and drops the key; the line itself is proof that the file
        // meant to restrict its agent, so the agent gets the reading tools — not every tool.
        let def = try XCTUnwrap(parse("---\nname: mapped\ndescription: d\ntools:\n  read: true\n  bash: false\n---\nb", name: "mapped"))
        XCTAssertEqual(def.tools, AgentDefinition.readOnlyTools)
        XCTAssertTrue(def.isReadOnly)
    }

    func testAFileWithoutAToolsListKeepsEveryTool() throws {
        let def = try XCTUnwrap(parse("---\nname: free\ndescription: d\n---\nb", name: "free"))
        XCTAssertNil(def.tools)
        XCTAssertFalse(def.isReadOnly)
    }

    func testAToolsLineInAnyCaseIsStillALine() throws {
        // The key is read case-insensitively from the text itself, so a restriction written as "Tools:" is never lost.
        let def = try XCTUnwrap(parse("---\nname: shouty\ndescription: d\nTools: Nonsense\n---\nb", name: "shouty"))
        XCTAssertEqual(def.tools, AgentDefinition.readOnlyTools)
    }

    func testDisallowedToolsAreReadAndApplied() throws {
        let def = try XCTUnwrap(parse("---\nname: careful\ndescription: d\ndisallowedTools: Bash, Write\n---\nb", name: "careful"))
        XCTAssertNil(def.tools)
        XCTAssertEqual(def.disallowedTools, ["run_shell_command", "write_file"])
        for key in ["disallowed_tools", "disallowed-tools"] {
            let other = try XCTUnwrap(parse("---\nname: careful\ndescription: d\n\(key): Edit\n---\nb", name: "careful"))
            XCTAssertEqual(other.disallowedTools, ["edit"], key)
        }
    }

    func testToolNamesAreMappedFromClaudeCodesToTheseOnes() {
        let names = ["Read", "View", "Grep", "Search", "Glob", "Find", "LS", "Bash", "Shell", "Edit", "MultiEdit", "Write",
                     "WebFetch", "WebSearch", "TodoWrite", "process_start", "memory_search", "\"Read\"", "'Grep'", "run-shell-command"]
        XCTAssertEqual(AgentDefinition.resolveTools(names),
                       ["read_file", "grep", "glob", "list_directory", "run_shell_command", "edit", "write_file", "web_fetch",
                        "todo_write", "process_start", "memory_search"])
        XCTAssertNil(AgentDefinition.resolveTools(["Task", "NotebookRead", "mcp__github__list"]))
        XCTAssertNil(AgentDefinition.resolveTools([]))
    }

    func testReadOnlyIsJudgedFromTheToolsNotTheName() throws {
        XCTAssertTrue(try XCTUnwrap(AgentDefinition.builtIn.first { $0.name == "explore" }).isReadOnly)
        XCTAssertFalse(try XCTUnwrap(AgentDefinition.builtIn.first { $0.name == "review" }).isReadOnly)   // it can run commands
        XCTAssertFalse(try XCTUnwrap(AgentDefinition.builtIn.first { $0.name == "general" }).isReadOnly)
        // A project file that replaces "explore" with one that has every tool is not read-only.
        let replaced = try XCTUnwrap(parse("---\nname: explore\ndescription: mine\n---\nDo anything.", name: "explore", origin: "project"))
        XCTAssertFalse(replaced.isReadOnly)
        XCTAssertTrue(AgentCatalog.default.readOnlyType("explore"))
        XCTAssertFalse(AgentCatalog.default.readOnlyType("worker"))
        XCTAssertFalse(AgentCatalog.default.readOnlyType("wizard"), "an unknown type is a general agent, which can write")
        XCTAssertFalse(AgentCatalog([replaced]).readOnlyType("explore"))
    }

    func testClaudeModelShortcutsAreNotServers() throws {
        for (text, server) in [("---\nname: x\nmodel: sonnet\n---\nbody", String?.none),
                               ("---\nname: x\nmodel: inherit\n---\nbody", nil),
                               ("---\nname: x\nmodel: opus\n---\nbody", nil),
                               ("---\nname: x\nmodel: haiku\n---\nbody", nil),
                               ("---\nname: x\nmodel: fast\n---\nbody", nil),
                               ("---\nname: x\nmodel: \"\"\n---\nbody", nil),
                               ("---\nname: x\nserver: spark-3\n---\nbody", "spark-3"),
                               ("---\nname: x\nserver: spark-3\nmodel: sonnet\n---\nbody", "spark-3")] {
            XCTAssertEqual(parse(text, name: "x")?.server, server, text)
        }
    }

    func testTheStepBudgetIsReadAndBounded() throws {
        for (line, steps) in [("max_steps: 25", Int?.some(25)), ("maxSteps: 12", 12), ("max-steps: 7", 7),
                              ("max_steps: 5000", 200), ("max_steps: 0", nil), ("max_steps: -3", nil), ("max_steps: lots", nil)] {
            XCTAssertEqual(parse("---\nname: x\n\(line)\n---\nbody", name: "x")?.maxSteps, steps, line)
        }
        XCTAssertNil(parse("---\nname: x\n---\nbody", name: "x")?.maxSteps)
    }

    func testNamesAreSluggedAndTheDescriptionFallsBackToTheBody() throws {
        XCTAssertEqual(parse("---\nname: My_Agent  v2!\n---\nbody", name: "x")?.name, "my-agent-v2")
        XCTAssertEqual(parse("---\nname: --Ünï--\n---\nbody", name: "x")?.name, "ünï")
        let long = String(repeating: "word ", count: 60)
        let def = try XCTUnwrap(parse("---\nname: x\n---\n\(long)", name: "x"))
        XCTAssertEqual(def.description.count, 140)
        XCTAssertTrue(long.hasPrefix(def.description))
    }

    func testEmptyFilesAreIgnored() {
        XCTAssertNil(parse("---\nname: nothing\n---\n", name: "nothing"))
        XCTAssertNil(parse("body", name: "!!!"))
        XCTAssertNil(parse("", name: "empty"))
    }

    func testAFileWithNoFrontmatterIsAPromptNamedAfterItsFile() throws {
        let def = try XCTUnwrap(parse("Review the migration carefully.\nCheck rollbacks.", name: "Migration Checker"))
        XCTAssertEqual(def.name, "migration-checker")
        XCTAssertEqual(def.prompt, "Review the migration carefully.\nCheck rollbacks.")
        XCTAssertTrue(def.description.hasPrefix("Review the migration carefully."))
        XCTAssertNil(def.tools)
    }

    // MARK: - Catalog files

    func testProjectAgentsOverrideUserAgentsWhichOverrideBuiltIns() throws {
        let user = root.folder("user-agents")
        try root.write("user-agents/explore.md", "---\nname: explore\ndescription: My own explorer\n---\nBe thorough.")
        try root.write("user-agents/helper.md", "---\ndescription: User helper\n---\nHelp.")
        try root.write("proj/.dsh/agents/helper.md", "---\ndescription: Project helper\n---\nHelp in this project.")
        try root.write("proj/.claude/agents/docs.md", "---\ndescription: Writes docs\ntools: Read, Write\n---\nWrite docs.")
        try root.write("proj/.dsh/agents/broken.md", "---\n---\n")

        let catalog = AgentCatalog.load(workspace: root.url.appendingPathComponent("proj"), userDirectories: [user])
        XCTAssertEqual(catalog.find("explore")?.description, "My own explorer")
        XCTAssertEqual(catalog.find("explore")?.origin, "user")
        XCTAssertEqual(catalog.find("helper")?.description, "Project helper")
        XCTAssertEqual(catalog.find("helper")?.origin, "project")
        XCTAssertEqual(catalog.find("docs")?.tools, ["read_file", "write_file"])
        XCTAssertNil(catalog.find("broken"))
        // Built-ins come first, in their usual order; the rest follow alphabetically.
        XCTAssertEqual(catalog.all.prefix(5).map(\.name), ["general", "explore", "plan", "review", "worker"])
        XCTAssertEqual(catalog.all.dropFirst(5).map(\.name), ["docs", "helper"])
        XCTAssertEqual(catalog.find("docs")?.path?.lastPathComponent, "docs.md")
    }

    func testDshAgentsBeatClaudeAgentsInTheSameProject() throws {
        try root.write("proj/.claude/agents/twin.md", "---\ndescription: from .claude\n---\nA.")
        try root.write("proj/.dsh/agents/twin.md", "---\ndescription: from .dsh\n---\nB.")
        let catalog = AgentCatalog.load(workspace: root.url.appendingPathComponent("proj"), userDirectories: [])
        XCTAssertEqual(catalog.find("twin")?.description, "from .dsh")
    }

    func testOnlyMarkdownFilesInsideTheFolderAreRead() throws {
        let user = root.folder("agents")
        try root.write("agents/real.md", "---\ndescription: real\n---\nbody")
        try root.write("agents/LOUD.MD", "---\ndescription: shouted\n---\nbody")
        try root.write("agents/notes.txt", "---\ndescription: not an agent\n---\nbody")
        try root.write("agents/.hidden.md", "---\ndescription: metadata\n---\nbody")
        try root.write("agents/._real.md", "\u{0}\u{0}junk that a network volume leaves behind")
        try root.write("agents/nested/deep.md", "---\ndescription: too deep\n---\nbody")
        try FileManager.default.createDirectory(at: user.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        let catalog = AgentCatalog.load(workspace: nil, userDirectories: [user])
        XCTAssertEqual(catalog.all.dropFirst(5).map(\.name), ["loud", "real"])
    }

    func testAnOversizeAgentFileIsSkipped() throws {
        let user = root.folder("agents")
        try root.write("agents/small.md", "---\ndescription: fine\n---\nbody")
        try root.write("agents/huge.md", "---\ndescription: huge\n---\n" + String(repeating: "x", count: 200_100))
        let catalog = AgentCatalog.load(workspace: nil, userDirectories: [user])
        XCTAssertEqual(catalog.all.dropFirst(5).map(\.name), ["small"])
    }

    func testMissingFoldersAreFine() {
        let catalog = AgentCatalog.load(workspace: root.url.appendingPathComponent("nowhere"),
                                        userDirectories: [root.url.appendingPathComponent("also-nowhere")])
        XCTAssertEqual(catalog.all.count, AgentDefinition.builtIn.count)
        XCTAssertEqual(catalog, AgentCatalog.default)
    }

    func testTheUsersOwnFoldersAreTheAppsAndClaudeCodes() {
        let folders = AgentCatalog.defaultUserDirectories().map(\.path)
        XCTAssertEqual(folders.count, 2)
        XCTAssertTrue(folders.first?.hasSuffix("Application Support/DSHMac/agents") ?? false, "\(folders)")
        XCTAssertTrue(folders.last?.hasSuffix("/.claude/agents") ?? false, "\(folders)")
    }

    func testTheDescriptionListsTheFirstTenTypesBriefly() {
        var types = AgentDefinition.builtIn
        for index in 0..<8 { types.append(AgentDefinition(name: "extra-\(index)", description: String(repeating: "d", count: 300))) }
        let text = AgentCatalog(types).describe()
        XCTAssertTrue(text.hasPrefix("general: A capable all-round worker"))
        XCTAssertTrue(text.hasSuffix("extra-4: " + String(repeating: "d", count: 130)))
        XCTAssertFalse(text.contains("extra-5"), "only ten types are listed")
        XCTAssertFalse(text.contains(String(repeating: "d", count: 131)))
    }

    func testTheStampChangesWhenAnAgentFileIsAddedEditedOrRemoved() throws {
        let user = root.folder("agents")
        let project = root.url.appendingPathComponent("project")
        let first = AgentCatalog.stamp(workspace: project, userDirectories: [user])
        XCTAssertEqual(first, AgentCatalog.stamp(workspace: project, userDirectories: [user]), "unchanged: same stamp")

        try root.write("agents/reviewer.md", "---\nname: reviewer\ndescription: d\n---\nbody")
        let added = AgentCatalog.stamp(workspace: project, userDirectories: [user])
        XCTAssertNotEqual(first, added)

        try root.write("agents/reviewer.md", "---\nname: reviewer\ndescription: a longer description\n---\nbody")
        let edited = AgentCatalog.stamp(workspace: project, userDirectories: [user])
        XCTAssertNotEqual(added, edited)

        try root.write("project/.claude/agents/local.md", "---\nname: local\ndescription: d\n---\nbody")
        XCTAssertNotEqual(edited, AgentCatalog.stamp(workspace: project, userDirectories: [user]))

        try FileManager.default.removeItem(at: user.appendingPathComponent("reviewer.md"))
        try FileManager.default.removeItem(at: project.appendingPathComponent(".claude/agents/local.md"))
        XCTAssertEqual(first, AgentCatalog.stamp(workspace: project, userDirectories: [user]))
    }

    func testTheStampNoticesAFileTouchedWithoutChangingItsSize() throws {
        let user = root.folder("agents")
        let file = try root.write("agents/a.md", "---\ndescription: aaaa\n---\nbody")
        let before = AgentCatalog.stamp(workspace: nil, userDirectories: [user])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: file.path)
        XCTAssertNotEqual(before, AgentCatalog.stamp(workspace: nil, userDirectories: [user]))
    }

    func testTheStampIgnoresTheOrderFoldersAndFilesAreListedIn() throws {
        let first = root.folder("first")
        let second = root.folder("second")
        try root.write("first/a.md", "---\ndescription: one\n---\nbody")
        try root.write("first/b.md", "---\ndescription: two\n---\nbody")
        try root.write("second/c.md", "---\ndescription: three\n---\nbody")
        // Summed, not chained: the same files give the same stamp whichever folder is asked first.
        XCTAssertEqual(AgentCatalog.stamp(workspace: nil, userDirectories: [first, second]),
                       AgentCatalog.stamp(workspace: nil, userDirectories: [second, first]))
        XCTAssertNotEqual(AgentCatalog.stamp(workspace: nil, userDirectories: [first, second]),
                          AgentCatalog.stamp(workspace: nil, userDirectories: [first]))
    }

    // MARK: - The agent tool with types

    private func context(_ client: any LLMClient, catalog: AgentCatalog? = nil, fleet: AgentFleet? = nil,
                         roster: AgentRoster? = nil) -> ToolContext {
        fleetContext(client, root: root.url, fleet: fleet, roster: roster, catalog: catalog,
                     registry: ToolRegistry.standard(agents: catalog).adding([EchoTool(), FleetStubTool("memory_search")]),
                     contextWindow: 8_000)
    }

    func testASpecialistOnlyGetsItsToolsAndItsPrompt() async throws {
        let client = ScriptedClient(turns: [.init(text: "Found it: Program.cs:12")])
        let result = await AgentTool().execute(
            args: #"{"description":"find main","prompt":"where is main?","agent_type":"explore"}"#,
            in: context(client))

        XCTAssertTrue(result.output.hasPrefix("Subagent 'find main' finished.\n(explore agent · "), result.output)
        XCTAssertTrue(result.output.contains("Found it: Program.cs:12"))
        XCTAssertEqual(client.requests.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        let offered = request.tools.map(\.name)
        XCTAssertTrue(offered.contains("read_file"))
        XCTAssertTrue(offered.contains("grep"))
        XCTAssertFalse(offered.contains("write_file"))
        XCTAssertFalse(offered.contains("run_shell_command"))
        XCTAssertFalse(offered.contains("echo"))
        XCTAssertFalse(offered.contains("agent"))
        XCTAssertFalse(offered.contains("delegate"))
        XCTAssertTrue(request.systemPrompt.contains("read-only investigator"))
        XCTAssertTrue(request.systemPrompt.contains("You are a focused subagent"))
    }

    func testTheGeneralWorkerKeepsEveryToolExceptTheAgentOnes() async throws {
        let client = ScriptedClient(turns: [.init(text: "ok")])
        let extras: [any ToolExecutor] = ToolRegistry.backgroundAgentTools() + [QueueAddTool(add: { _, _, _, _ in "" })]
        let registry = ToolRegistry.standard().adding([EchoTool(), FleetStubTool("memory_search")] + extras)
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#,
                                      in: fleetContext(client, root: root.url, registry: registry))
        let offered = try XCTUnwrap(client.requests.first).tools.map(\.name)
        XCTAssertTrue(offered.contains("write_file"))
        XCTAssertTrue(offered.contains("echo"))
        XCTAssertTrue(offered.contains("memory_search"))
        for gone in ["agent", "delegate", "agent_status", "agent_stop", "queue_task"] {
            XCTAssertFalse(offered.contains(gone), gone)
        }
    }

    func testAnUnknownTypeIsRefusedWithTheChoices() async {
        let client = ScriptedClient(turns: [])
        let result = await AgentTool().execute(args: #"{"description":"d","prompt":"p","agent_type":"wizard"}"#, in: context(client))
        XCTAssertTrue(result.output.hasPrefix("Error: unknown agent_type 'wizard'. Available: general:"), result.output)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testTheToolDescriptionListsTheTypes() throws {
        let catalog = AgentCatalog(AgentDefinition.builtIn + [AgentDefinition(name: "docs", description: "Writes documentation")])
        XCTAssertTrue(AgentTool.spec(for: catalog).description.contains("docs: Writes documentation"))
        XCTAssertTrue(DelegateTool(catalog: catalog).spec.description.contains("explore:"))
        XCTAssertTrue(DelegateTool.spec(for: catalog).description.contains("docs: Writes documentation"))
        XCTAssertTrue(try XCTUnwrap(ToolRegistry.standard().tool(named: "agent")).spec.parameters.contains("agent_type"))
        // The registry passes the chat's own types to both tools.
        let registry = ToolRegistry.standard(agents: catalog)
        XCTAssertTrue(try XCTUnwrap(registry.tool(named: "agent")).spec.description.contains("docs: Writes documentation"))
        XCTAssertTrue(try XCTUnwrap(registry.tool(named: "delegate")).spec.description.contains("docs: Writes documentation"))
        XCTAssertTrue(registry.specs.first { $0.name == "agent" }?.description.contains("docs:") ?? false)
        // …and without any, the built-in ones.
        XCTAssertFalse(try XCTUnwrap(ToolRegistry.standard().tool(named: "agent")).spec.description.contains("docs:"))
        XCTAssertTrue(AgentTool.spec.description.contains("explore:"))
    }

    func testAStepBudgetAskedOfATypeIsHonouredAndWrappedUp() async throws {
        let catalog = AgentCatalog([AgentDefinition(name: "brief", description: "d", maxSteps: 2)])
        let client = ScriptedClient(turns: [
            .init(calls: [ToolCall(id: "a", name: "echo", arguments: #"{"text":"1"}"#)]),
            .init(calls: [ToolCall(id: "b", name: "echo", arguments: #"{"text":"2"}"#)]),
            .init(text: "Ran out of steps but here is what I found."),
        ])
        let result = await AgentTool().execute(args: #"{"description":"d","prompt":"p","agent_type":"brief"}"#,
                                               in: context(client, catalog: catalog))
        XCTAssertTrue(result.output.contains("Ran out of steps but here is what I found."), result.output)
        XCTAssertEqual(client.requests.count, 3)
        // The last request is the wrap-up: the whole transcript so far, then the note asking for the report.
        let last = try XCTUnwrap(client.requests.dropFirst(2).first)
        XCTAssertEqual(last.messages.last?.role, .user)
        XCTAssertTrue(last.messages.last?.content?.contains("you have used your whole step budget") ?? false)
    }

    func testATypeWithoutAStepBudgetGetsTheDefaultOfThirty() async {
        let catalog = AgentCatalog([AgentDefinition(name: "general", description: "d")])
        let client = ScriptedClient(turns: (0..<40).map { i in
            ScriptedClient.Turn(calls: [ToolCall(id: "c\(i)", name: "echo", arguments: "{\"text\":\"\(i)\"}")])
        })
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#, in: context(client, catalog: catalog))
        // Thirty working steps, then the request for the report.
        XCTAssertEqual(client.requests.count, 31)
    }

    // MARK: - Roster

    func testTheRosterFollowsARunFromStartToFinish() async throws {
        let roster = AgentRoster()
        let seen = FleetLog<AgentRun>()
        roster.onChange = { seen.append($0) }
        let client = ScriptedClient(turns: [.init(calls: [ToolCall(id: "a", name: "echo", arguments: #"{"text":"look"}"#)]),
                                            .init(text: "the report")])
        _ = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#, in: context(client, roster: roster))

        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(roster.all.count, 1)
        XCTAssertEqual(run.description, "scan")
        XCTAssertEqual(run.agentType, "general")
        XCTAssertEqual(run.status, .done)
        XCTAssertEqual(run.steps, 1)
        XCTAssertEqual(run.report, "the report")
        XCTAssertNotNil(run.finishedAt)
        XCTAssertFalse(run.isBackground)
        XCTAssertNil(run.server, "a lone route is not named")
        XCTAssertEqual(run.activity, "done")
        XCTAssertTrue(seen.all.contains { $0.activity.hasPrefix("echo:") })
        XCTAssertTrue(seen.all.contains { $0.activity == "writing the report" })
        XCTAssertTrue(roster.running.isEmpty)
        XCTAssertEqual(seen.all.first?.status, .running)
        XCTAssertEqual(seen.all.last?.status, .done)
    }

    func testAFailedRunIsRecordedAsFailed() async throws {
        let roster = AgentRoster()
        let client = FlakyClient(failures: Int.max, error: LLMError.http(401, "no key"), turns: [])
        _ = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#, in: context(client, roster: roster))
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(roster.all.count, 1)
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.report?.contains("no key") ?? false)
        XCTAssertEqual(run.activity, "failed")
    }

    func testStoppingMarksTheRunStopped() async throws {
        let roster = AgentRoster()
        let blocking = FleetBlockingClient()
        let ctx = context(blocking, roster: roster)
        let running = FleetPending { await AgentTool().execute(args: #"{"description":"long","prompt":"p"}"#, in: ctx) }
        let started = await fleetEventually { blocking.hasStarted }
        XCTAssertTrue(started)
        XCTAssertEqual(roster.running.count, 1)
        running.cancel()
        let result = try await running.value()
        XCTAssertEqual(result.output, "Error: cancelled by user.")
        XCTAssertEqual(roster.all.count, 1)
        XCTAssertEqual(roster.all.first?.status, .stopped)
        XCTAssertEqual(roster.all.first?.report, "Stopped before it finished.")
    }

    func testARosterListenerThatComesBackIntoTheRosterCostsNeitherTheRunNorTheServerSlot() async throws {
        // (A C# listener could throw; a Swift one can't. What it can do is look at the roster and the fleet while it is
        // told — which must neither deadlock nor lose a slot.)
        let roster = AgentRoster()
        let heard = FleetLog<AgentRunStatus>()
        roster.onChange = { [unowned roster] run in
            _ = roster.all
            heard.append(run.status)
        }
        let fleet = AgentFleet()
        fleet.configure([fleetServer("a", FleetReportsClient("the report"), primary: true),
                         fleetServer("b", FleetReportsClient("the report"))])
        fleet.onChange = { [unowned fleet] in _ = fleet.snapshot() }

        let ctx = context(ScriptedClient(turns: []), fleet: fleet, roster: roster)
        let running = FleetPending {
            await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#, in: ctx)
        }
        let result = try await running.value()

        XCTAssertTrue(result.output.contains("the report"))
        XCTAssertEqual(roster.all.first?.status, .done)
        XCTAssertTrue(heard.all.contains(.done))
        XCTAssertTrue(fleet.snapshot().allSatisfy { $0.inFlight == 0 }, "no slot leaked")
    }

    func testTheRosterKeepsItsListBounded() {
        let roster = AgentRoster()
        for index in 0..<100 {
            roster.finish(roster.begin(description: "t\(index)", agentType: "general", background: false), status: .done, report: "r")
        }
        XCTAssertLessThanOrEqual(roster.all.count, 60)
        XCTAssertEqual(roster.all.last?.description, "t99")
        let running = roster.begin(description: "live", agentType: "general", background: true)
        roster.clearFinished()
        XCTAssertEqual(roster.all.map(\.id), [running])
    }

    func testARunningRunIsNeverDroppedToKeepTheListBounded() {
        let roster = AgentRoster()
        let live = (0..<70).map { roster.begin(description: "live\($0)", agentType: "general", background: true) }
        XCTAssertEqual(roster.all.count, 70, "nothing finished, so nothing may go")
        XCTAssertEqual(roster.running.count, 70)
        roster.finish(live[3], status: .done, report: "r")
        _ = roster.begin(description: "one more", agentType: "general", background: false)
        XCTAssertNil(roster.run(live[3]), "the oldest finished run goes first")
        XCTAssertNotNil(roster.run(live[0]))
    }

    func testARunRecordsItsProgressAndFreezesWhenItEnds() {
        let clock = FleetTestClock()
        let roster = AgentRoster(now: { clock.now })
        let changes = FleetLog<AgentRun>()
        roster.onChange = { changes.append($0) }
        let id = roster.begin(description: "scan", agentType: "explore", background: true)
        XCTAssertEqual(roster.run(id)?.activity, "starting")
        XCTAssertEqual(roster.run(id)?.isBackground, true)
        roster.setServer(id, "spark-2")
        roster.note(id, "waiting for a free server")
        roster.note(id, "grep: TODO", step: true)
        roster.note(id, "grep: FIXME", step: true)
        clock.advance(seconds: 42)
        XCTAssertEqual(roster.run(id)?.elapsed(at: clock.now), 42)
        roster.finish(id, status: .failed, report: "the server said no")
        clock.advance(seconds: 100)
        let run = roster.run(id)
        XCTAssertEqual(run?.server, "spark-2")
        XCTAssertEqual(run?.steps, 2)
        XCTAssertEqual(run?.activity, "failed")
        XCTAssertEqual(run?.elapsed(at: clock.now), 42, "a finished run stops counting")
        // Once over, a run no longer changes.
        roster.note(id, "late news", step: true)
        roster.finish(id, status: .done, report: "too late")
        XCTAssertEqual(roster.run(id)?.status, .failed)
        XCTAssertEqual(roster.run(id)?.report, "the server said no")
        XCTAssertEqual(roster.run(id)?.steps, 2)
        XCTAssertNil(roster.run("a99"))
        XCTAssertEqual(changes.all.first?.id, id)
        XCTAssertGreaterThanOrEqual(changes.all.count, 6)
    }

    func testClearingTheFinishedRunsSaysSoWithAnEmptyRun() {
        let roster = AgentRoster()
        let heard = FleetLog<String>()
        roster.onChange = { heard.append($0.id) }
        roster.finish(roster.begin(description: "old", agentType: "general", background: false), status: .done, report: "r")
        roster.clearFinished()
        XCTAssertEqual(heard.all.last, "", "an empty id is the roster telling listeners the finished runs are gone")
        XCTAssertTrue(roster.all.isEmpty)
    }

    func testRunIdsCountUp() {
        let roster = AgentRoster()
        XCTAssertEqual(roster.begin(description: "a", agentType: "general", background: false), "a1")
        XCTAssertEqual(roster.begin(description: "b", agentType: "general", background: false), "a2")
    }
}
