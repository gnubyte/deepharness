import XCTest
@testable import DSHCore

/// A throwaway project + fake home + fake app-support, so nothing reads the
/// developer's real ~/.claude, ~/.cursor or skills.
final class SkillFixture {
    let base: URL
    let project: URL
    let home: URL
    let support: URL
    var locations: SkillLocations { SkillLocations(home: home, appSupport: support) }

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dsh-skills-\(UUID().uuidString)")
        project = base.appendingPathComponent("project")
        home = base.appendingPathComponent("home")
        support = base.appendingPathComponent("support")
        for dir in [project, home, support] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func write(_ relative: String, in root: URL? = nil, _ text: String) throws -> URL {
        let url = (root ?? project).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func skill(_ relative: String, name: String, description: String, body: String = "Do the thing.", in root: URL? = nil,
               extra: String = "") throws {
        try write("\(relative)/SKILL.md", in: root, "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n\(body)\n")
    }
}

// MARK: - Frontmatter

final class SkillDocumentTests: XCTestCase {
    func testFoldedAndLiteralBlockScalars() {
        let doc = SkillDocument.parse("""
        ---
        name: folded
        description: >
          Use when the build
          fails on CI.

          Second paragraph.
        notes: |
          line one
          line two
        ---
        # Body
        """)
        XCTAssertEqual(doc["name"], "folded")
        XCTAssertEqual(doc["description"], "Use when the build fails on CI.\nSecond paragraph.")
        XCTAssertEqual(doc["notes"], "line one\nline two")
        XCTAssertEqual(doc.body, "# Body")
    }

    func testListsInEveryShapeCursorAndClaudeWrite() {
        let doc = SkillDocument.parse("""
        ---
        description: Canon bible
        globs:
          - "docs/lore/**"
          - "server/data/content/dialogue/**"
        allowed-tools: Read, Grep, Bash(git *)
        paths: [src/**/*.ts, "test/**"]
        also: "*.{ts,tsx},*.md"
        alwaysApply: false
        environments:
          - local
        ---
        """)
        XCTAssertEqual(doc.list("globs"), ["docs/lore/**", "server/data/content/dialogue/**"])
        XCTAssertEqual(doc.list("allowed-tools"), ["Read", "Grep", "Bash(git *)"])
        XCTAssertEqual(doc.list("paths"), ["src/**/*.ts", "test/**"])
        XCTAssertEqual(doc.list("also"), ["*.{ts,tsx}", "*.md"], "braces keep their commas")
        XCTAssertEqual(doc.bool("alwaysApply"), false)
        XCTAssertEqual(doc.list("environments"), ["local"])
    }

    func testQuotingCommentsMultilinePlainAndOddInput() {
        let doc = SkillDocument.parse("\u{FEFF}---\r\nname: x\r\ndescription: \"has: colon and \\\"quotes\\\"\"\r\nplain: hello # a comment\r\nwrapped: first\r\n  second\r\n---\r\nbody\r\n")
        XCTAssertEqual(doc["description"], "has: colon and \"quotes\"")
        XCTAssertEqual(doc["plain"], "hello")
        XCTAssertEqual(doc["wrapped"], "first second")
        XCTAssertEqual(doc.body, "body\n")
        XCTAssertFalse(SkillDocument.parse("no frontmatter").hadFrontmatter)
        XCTAssertFalse(SkillDocument.parse("---\nname: x\nnever closed").hadFrontmatter, "unterminated is not frontmatter")
        XCTAssertEqual(SkillDocument.parse("---\n---\nbody").fields.count, 0)
    }

    func testRenderRoundTripsAndKeepsOrder() {
        var doc = SkillDocument(body: "Body text.\n", hadFrontmatter: true)
        doc["name"] = "my-skill"
        doc["description"] = "Use when: colons, \"quotes\" and # hashes appear"
        doc.setList("globs", ["a/**", "*.{ts,tsx}"])
        doc["alwaysApply"] = "true"
        let text = doc.render()
        XCTAssertTrue(text.hasPrefix("---\nname: my-skill\ndescription:"))
        let back = SkillDocument.parse(text)
        XCTAssertEqual(back["description"], doc["description"])
        XCTAssertEqual(back.list("globs"), ["a/**", "*.{ts,tsx}"])
        XCTAssertEqual(back.bool("alwaysApply"), true)
        XCTAssertEqual(back.order, ["name", "description", "globs", "alwaysApply"])
        XCTAssertEqual(back.body, "Body text.\n")
    }

    func testRealWorldClaudeSkillWithLongDescription() {
        let long = String(repeating: "Use when JUDGING a Meshy asset — a body concept, a raw mesh. ", count: 5)
        let doc = SkillDocument.parse("---\nname: meshy-critique\ndescription: \(long)\n---\n\n# Critiquing\n")
        XCTAssertEqual(doc["description"], long.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Naming / arguments

final class SkillNamingTests: XCTestCase {
    func testSlugAndValidity() {
        XCTAssertEqual(SkillNaming.slug("Run  Tests!"), "run-tests")
        XCTAssertEqual(SkillNaming.slug("  --Godot_Debugging--  "), "godot-debugging")
        XCTAssertEqual(SkillNaming.slug("frontend:component"), "frontend-component")
        XCTAssertEqual(SkillNaming.slug("日本語"), "")
        XCTAssertEqual(SkillNaming.slug(String(repeating: "a", count: 90)).count, 64)
        XCTAssertTrue(SkillNaming.isValidName("godot-debugging"))
        XCTAssertFalse(SkillNaming.isValidName("Godot Debugging"))
        XCTAssertFalse(SkillNaming.isValidName("-x"))
        XCTAssertEqual(SkillNaming.unique("x") { ["x", "x-2"].contains($0) }, "x-3")
    }

    func testArgumentExpansion() {
        XCTAssertEqual(SkillArguments.split(#"one "two words" 'three four' five"#), ["one", "two words", "three four", "five"])
        XCTAssertEqual(SkillArguments.expand("Fix $ARGUMENTS now", arguments: "the bug"), "Fix the bug now")
        XCTAssertEqual(SkillArguments.expand("a=$1 b=$2 c=$3 d=$10", arguments: "x y"), "a=x b=y c= d=$10", "only $1-$9 are positional")
        XCTAssertEqual(SkillArguments.expand("No placeholders.", arguments: "extra"), "No placeholders.\n\nARGUMENTS: extra")
        XCTAssertEqual(SkillArguments.expand("No placeholders.", arguments: ""), "No placeholders.")
    }
}

// MARK: - Discovery

final class SkillCatalogTests: XCTestCase {
    var fx: SkillFixture!
    override func setUpWithError() throws { fx = try SkillFixture() }
    override func tearDownWithError() throws { fx.cleanup() }

    private func populate() throws {
        try fx.skill(".dsh/skills/mine", name: "mine", description: "Use when DSH-owned.")
        try fx.skill(".agents/skills/shared", name: "shared", description: "Use when agents-standard.")
        try fx.skill(".claude/skills/claudey", name: "claudey", description: "Use when Claude.",
                     extra: "allowed-tools: Read, Grep\nargument-hint: <file>\n")
        try fx.skill(".claude/skills/private-flow", name: "private-flow", description: "User-only flow.",
                     extra: "disable-model-invocation: true\n")
        try fx.write(".claude/commands/deploy.md", "---\ndescription: Ship it\nargument-hint: <env>\n---\nDeploy to $ARGUMENTS")
        try fx.write(".claude/commands/frontend/component.md", "Make a component named $1")
        try fx.write(".claude/rules/style.md", "Use tabs.")
        try fx.write(".claude/rules/tests.md", "---\npaths:\n  - \"**/*.test.ts\"\n---\nWrite tests first.")
        try fx.write(".cursor/rules/lore.mdc", "---\ndescription: Canon bible for narrative work\nglobs:\n  - \"docs/lore/**\"\nalwaysApply: false\n---\nCanon rules.")
        try fx.write(".cursor/rules/always.mdc", "---\ndescription: House rules\nalwaysApply: true\n---\nBe kind.")
        try fx.write(".cursor/rules/manual.mdc", "---\nalwaysApply: false\n---\nOnly when asked.")
        try fx.skill(".cursor/skills/cursory", name: "cursory", description: "Use when Cursor.")
        try fx.skill(".claude/skills/dupe", name: "dupe", description: "claude copy")
        try fx.skill(".dsh/skills/dupe", name: "dupe", description: "dsh copy")
        try fx.skill(".claude/skills", name: "x", description: "y", in: fx.home) // ~/.claude/skills/SKILL.md is not a skill dir
        try fx.skill(".claude/skills/homey", name: "homey", description: "Use when at home.", in: fx.home)
        try fx.skill(".cursor/skills/homecursor", name: "homecursor", description: "Cursor home.", in: fx.home)
        try fx.skill("skills/usery", name: "usery", description: "Use when user-wide.", in: fx.support)
        try fx.skill("skills-builtin/godot-debugging", name: "godot-debugging", description: "Use when Godot.", in: fx.support)
        try fx.skill(".dsh/skills/_drafts/nope", name: "nope", description: "hidden")
    }

    func testDiscoversEveryLayout() throws {
        try populate()
        let all = SkillCatalog.loadAll(project: fx.project, locations: fx.locations)
        let byName = Dictionary(grouping: all, by: \.name)
        for name in ["mine", "shared", "claudey", "private-flow", "deploy", "frontend:component", "style", "tests",
                     "lore", "always", "manual", "cursory", "homey", "homecursor", "usery", "godot-debugging"] {
            XCTAssertNotNil(byName[name], "missing \(name)")
        }
        XCTAssertNil(byName["nope"], "underscore folders are not skills")

        func s(_ n: String) -> Skill { byName[n]![0] }
        XCTAssertEqual(s("mine").origin, .dsh); XCTAssertEqual(s("mine").scope, .project)
        XCTAssertEqual(s("claudey").origin, .claude); XCTAssertEqual(s("claudey").allowedTools, ["Read", "Grep"])
        XCTAssertEqual(s("claudey").argumentHint, "<file>")
        XCTAssertFalse(s("private-flow").modelInvocable)
        XCTAssertEqual(s("deploy").kind, .command); XCTAssertFalse(s("deploy").modelInvocable)
        XCTAssertEqual(s("deploy").argumentHint, "<env>")
        XCTAssertEqual(s("frontend:component").kind, .command)
        XCTAssertTrue(s("style").alwaysApply, "a Claude rule without paths always loads")
        XCTAssertFalse(s("tests").alwaysApply); XCTAssertEqual(s("tests").globs, ["**/*.test.ts"])
        XCTAssertEqual(s("lore").globs, ["docs/lore/**"]); XCTAssertEqual(s("lore").origin, .cursor); XCTAssertEqual(s("lore").kind, .rule)
        XCTAssertTrue(s("always").alwaysApply)
        XCTAssertFalse(s("manual").modelInvocable, "a description-less, glob-less Cursor rule is manual")
        XCTAssertEqual(s("homey").scope, .user); XCTAssertEqual(s("homey").origin, .claude)
        XCTAssertEqual(s("usery").origin, .dsh); XCTAssertEqual(s("usery").scope, .user)
        XCTAssertEqual(s("godot-debugging").origin, .builtin)
    }

    func testPrecedenceShadowingAndLoad() throws {
        try populate()
        let all = SkillCatalog.loadAll(project: fx.project, locations: fx.locations)
        let dupes = all.filter { $0.name == "dupe" }
        XCTAssertEqual(dupes.count, 2)
        XCTAssertEqual(dupes.first { !$0.shadowed }?.description, "dsh copy", ".dsh beats .claude")
        XCTAssertEqual(dupes.first { $0.shadowed }?.origin, .claude)
        XCTAssertEqual(SkillCatalog.load(project: fx.project, locations: fx.locations).filter { $0.name == "dupe" }.count, 1)
    }

    func testSourcesCanBeSwitchedOff() throws {
        try populate()
        let names = Set(SkillCatalog.load(project: fx.project, locations: fx.locations, sources: [.agents]).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["mine", "shared", "usery", "godot-debugging"]))
        XCTAssertTrue(names.isDisjoint(with: ["claudey", "deploy", "style", "lore", "cursory", "homey"]))
    }

    func testNoProjectStillFindsUserAndBuiltinSkills() throws {
        try populate()
        let names = Set(SkillCatalog.load(project: nil, locations: fx.locations).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["usery", "homey", "godot-debugging"]))
        XCTAssertFalse(names.contains("mine"))
    }

    func testNewInstructionFilesAreKnowledge() throws {
        try fx.write(".cursorrules", "Cursor house rules.")
        try fx.write(".claude/CLAUDE.md", "Claude notes.")
        try fx.write("CLAUDE.local.md", "Local notes.")
        let context = ProjectContext.load(root: fx.project, locations: fx.locations)
        XCTAssertEqual(context.instructions.map(\.label), [".claude/CLAUDE.md", "CLAUDE.local.md", ".cursorrules"])
    }
}

// MARK: - Prompt + use_skill

final class SkillPromptTests: XCTestCase {
    var fx: SkillFixture!
    var skills: [Skill] = []
    override func setUpWithError() throws {
        fx = try SkillFixture()
        try fx.skill(".dsh/skills/alpha", name: "alpha", description: "Use when doing alpha work.", body: "ALPHA STEPS")
        try fx.skill(".dsh/skills/beta", name: "beta", description: "Use when doing beta work.", body: "BETA $ARGUMENTS")
        try fx.write(".dsh/skills/beta/scripts/run.sh", "echo hi")
        try fx.write(".claude/commands/ship.md", "SHIP $1")
        try fx.write(".cursor/rules/always.mdc", "---\ndescription: House\nalwaysApply: true\n---\nALWAYS BE TESTING")
        try fx.write(".cursor/rules/glob.mdc", "---\ndescription: Lore\nglobs: [\"docs/**\"]\n---\nLORE BODY")
        skills = SkillCatalog.load(project: fx.project, locations: fx.locations)
    }
    override func tearDownWithError() throws { fx.cleanup() }

    private func id(_ name: String) -> String { skills.first { $0.name == name }!.id }

    func testAlwaysRulesAndCatalogAreSeparatedFromPinned() {
        let r = SkillPrompt.build(skills: skills, selection: SkillSelection())
        XCTAssertTrue(r.text.contains("Rules that always apply"))
        XCTAssertTrue(r.text.contains("ALWAYS BE TESTING"))
        XCTAssertTrue(r.text.contains("- alpha: Use when doing alpha work."))
        XCTAssertTrue(r.text.contains("- glob: Lore (files: docs/**)"))
        XCTAssertFalse(r.text.contains("ALPHA STEPS"), "catalog lists descriptions, not bodies")
        XCTAssertFalse(r.text.contains("- ship:"), "commands are user-invoked, not offered to the model")
        XCTAssertFalse(r.text.contains("- always:"), "always-on rules are injected, not listed")
        XCTAssertTrue(r.text.contains("use_skill"))
    }

    func testPinnedSkillIsInjectedInFullWithItsDirectory() {
        let r = SkillPrompt.build(skills: skills, selection: SkillSelection(pinned: [id("alpha"), id("ship")]))
        XCTAssertTrue(r.text.contains("Skills the user selected for this chat"))
        XCTAssertTrue(r.text.contains("ALPHA STEPS"))
        XCTAssertTrue(r.text.contains("SHIP"), "a user can pin a command")
        XCTAssertTrue(r.text.contains(skills.first { $0.name == "alpha" }!.directory.path))
        XCTAssertFalse(r.text.contains("- alpha:"), "pinned skills leave the catalog")
        XCTAssertEqual(Set(r.injected.map(\.name)), ["alpha", "ship", "always"])
    }

    func testManualModeHidesTheCatalogButKeepsPinned() {
        let r = SkillPrompt.build(skills: skills, selection: SkillSelection(pinned: [id("beta")], auto: false))
        XCTAssertFalse(r.text.contains("Available skills"))
        XCTAssertTrue(r.text.contains("BETA"))
        XCTAssertTrue(r.text.contains("ALWAYS BE TESTING"), "always-on rules are not optional")
    }

    func testDisabledSkillsVanishEverywhere() {
        let r = SkillPrompt.build(skills: skills, selection: SkillSelection(pinned: [id("alpha")], disabled: [id("alpha"), id("always")]))
        XCTAssertFalse(r.text.contains("alpha"))
        XCTAssertFalse(r.text.contains("ALWAYS BE TESTING"))
    }

    func testOversizedSkillIsCappedNotDropped() throws {
        try fx.skill(".dsh/skills/huge", name: "huge", description: "Use when huge.", body: String(repeating: "x", count: 100_000))
        let all = SkillCatalog.load(project: fx.project, locations: fx.locations)
        let huge = all.first { $0.name == "huge" }!
        let r = SkillPrompt.build(skills: all, selection: SkillSelection(pinned: [huge.id]))
        XCTAssertTrue(r.text.contains("[… truncated"))
        XCTAssertLessThan(r.text.count, SkillPrompt.totalCap + 20_000)
    }

    func testUseSkillLoadsBodyArgumentsAndBundledFiles() async throws {
        let tool = UseSkillTool(skills: skills)
        let ctx = ToolContext(workspace: fx.project, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: fx.project),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let ok = await tool.execute(args: #"{"name":"beta","arguments":"the widget"}"#, in: ctx)
        XCTAssertTrue(ok.output.contains("# Skill: beta (DSH skill, project)"))
        XCTAssertTrue(ok.output.contains("BETA the widget"))
        XCTAssertTrue(ok.output.contains("- scripts/run.sh"))
        XCTAssertTrue(ok.output.contains("Base directory:"))

        let slashForm = await tool.execute(args: #"{"name":"/Alpha"}"#, in: ctx)
        XCTAssertTrue(slashForm.output.contains("ALPHA STEPS"), "case and leading slash are forgiven")

        let unknown = await tool.execute(args: #"{"name":"nope"}"#, in: ctx)
        XCTAssertTrue(unknown.output.hasPrefix("Error:") && unknown.output.contains("alpha, beta"))

        let command = await tool.execute(args: #"{"name":"ship"}"#, in: ctx)
        XCTAssertTrue(command.output.contains("user runs themselves"))
    }
}

// MARK: - Drafts, approval, management

final class SkillDraftTests: XCTestCase {
    var fx: SkillFixture!
    override func setUpWithError() throws { fx = try SkillFixture() }
    override func tearDownWithError() throws { fx.cleanup() }

    private func ctx() -> ToolContext {
        ToolContext(workspace: fx.project, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: fx.project),
                    client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
    }

    func testProposeCreatesAnInactiveDraftThatApprovalActivates() async throws {
        let tool = ProposeSkillTool(projectRoot: fx.project, locations: fx.locations)
        let result = await tool.execute(args: JSONString(#"{"name":"Godot Export Android","description":"Use when exporting a Godot project to Android.","instructions":"1. Install the export templates.\n2. Run the export command.\n3. Verify the APK installs."}"#), in: ctx())
        XCTAssertTrue(result.output.contains("NOT active"), result.output)

        XCTAssertTrue(SkillCatalog.load(project: fx.project, locations: fx.locations).isEmpty, "a draft is not a skill")
        let drafts = SkillDrafts.list(locations: fx.locations)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].name, "godot-export-android")
        XCTAssertEqual(drafts[0].source, "agent")
        XCTAssertEqual(drafts[0].scope, .project)

        let landed = try SkillDrafts.approve(drafts[0], projectRoot: fx.project, locations: fx.locations)
        XCTAssertTrue(landed.path.hasSuffix(".dsh/skills/godot-export-android/SKILL.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: landed.deletingLastPathComponent().appendingPathComponent("draft.json").path))
        XCTAssertTrue(SkillDrafts.list(locations: fx.locations).isEmpty)
        let live = SkillCatalog.load(project: fx.project, locations: fx.locations)
        XCTAssertEqual(live.map(\.name), ["godot-export-android"])
        XCTAssertEqual(live[0].origin, .dsh)
    }

    func testProposeValidatesAndRejectsJunk() async throws {
        let tool = ProposeSkillTool(projectRoot: fx.project, locations: fx.locations)
        for bad in [#"{"name":"","description":"d","instructions":"long enough instructions here"}"#,
                    #"{"name":"x","description":"","instructions":"long enough instructions here"}"#,
                    #"{"name":"x","description":"d","instructions":"short"}"#] {
            let r = await tool.execute(args: JSONString(bad), in: ctx())
            XCTAssertTrue(r.output.hasPrefix("Error:"), r.output)
        }
        XCTAssertTrue(SkillDrafts.list(locations: fx.locations).isEmpty)
    }

    func testUserScopeApprovalAndConflictPolicies() throws {
        let text = "---\nname: shared-tool\ndescription: Use when sharing.\n---\n\nSteps."
        let first = try SkillDrafts.create(text: text, scope: .user, projectRoot: nil, source: "ai", locations: fx.locations)
        let landed = try SkillDrafts.approve(first, projectRoot: nil, locations: fx.locations)
        XCTAssertTrue(landed.path.contains("support/skills/shared-tool"))

        let second = try SkillDrafts.create(text: text, scope: .user, projectRoot: nil, source: "ai", locations: fx.locations)
        XCTAssertEqual(second.id, "shared-tool", "drafts are separate from active skills")
        XCTAssertThrowsError(try SkillDrafts.approve(second, projectRoot: nil, conflict: .fail, locations: fx.locations)) {
            XCTAssertTrue(($0 as? SkillError)?.errorDescription?.contains("already exists") ?? false)
        }
        XCTAssertEqual(SkillDrafts.list(locations: fx.locations).count, 1, "a failed approval keeps the draft")
        let renamed = try SkillDrafts.approve(second, projectRoot: nil, conflict: .rename, locations: fx.locations)
        XCTAssertTrue(renamed.path.contains("shared-tool-2"))
    }

    func testProjectDraftNeedsAProjectAndRetargetWorks() throws {
        let d = try SkillDrafts.create(text: "---\nname: p\ndescription: Use when p.\n---\nBody text here.", scope: .project,
                                       projectRoot: nil, source: "ai", locations: fx.locations)
        XCTAssertThrowsError(try SkillDrafts.approve(d, projectRoot: nil, locations: fx.locations))
        try SkillDrafts.retarget(d, scope: .user, projectRoot: nil)
        let moved = SkillDrafts.list(locations: fx.locations)[0]
        XCTAssertEqual(moved.scope, .user)
        XCTAssertNoThrow(try SkillDrafts.approve(moved, projectRoot: nil, locations: fx.locations))
    }

    func testEditingAndRejectingDrafts() throws {
        let d = try SkillDrafts.create(text: "---\nname: e\ndescription: Use when e.\n---\nBody text here.", scope: .user,
                                       projectRoot: nil, source: "ai", locations: fx.locations)
        try SkillDrafts.update(d, text: "---\nname: Edited Name\ndescription: Use when edited.\n---\nNew body.")
        XCTAssertEqual(SkillDrafts.list(locations: fx.locations)[0].name, "edited-name")
        XCTAssertThrowsError(try SkillDrafts.update(d, text: "no frontmatter and no name"))
        try SkillDrafts.reject(SkillDrafts.list(locations: fx.locations)[0])
        XCTAssertTrue(SkillDrafts.list(locations: fx.locations).isEmpty)
    }

    func testNormalizeRepairsAndRefuses() throws {
        let (slug, text) = try SkillDrafts.normalize("Just instructions, no header.", fallbackName: "Quick Fix", fallbackDescription: "Use when quick.")
        XCTAssertEqual(slug, "quick-fix")
        XCTAssertTrue(text.hasPrefix("---\nname: quick-fix\ndescription: Use when quick.\n---"))
        XCTAssertThrowsError(try SkillDrafts.normalize("---\ndescription: d\n---\nbody"))       // no name
        XCTAssertThrowsError(try SkillDrafts.normalize("---\nname: n\ndescription: d\n---\n   \n"))  // no instructions
        // No description: the body's first line stands in.
        XCTAssertTrue(try SkillDrafts.normalize("---\nname: n\n---\nFirst line of the body.").text.contains("description: First line of the body."))
    }

    func testManagerCreateAdoptAndReadOnlyForForeignFiles() throws {
        // Adopt a Cursor rule: it becomes a DSH skill and keeps its globs / alwaysApply.
        try fx.write(".cursor/rules/style.mdc", "---\ndescription: Style guide\nglobs: [\"src/**\"]\nalwaysApply: true\n---\nUse tabs.")
        try fx.write(".claude/commands/ship.md", "---\ndescription: Ship\nargument-hint: <env>\n---\nShip $ARGUMENTS")
        let all = SkillCatalog.load(project: fx.project, locations: fx.locations)
        let rule = all.first { $0.name == "style" }!
        XCTAssertThrowsError(try SkillManager.write(rule, text: "x"), "foreign files are edited only after adopting")
        let adopted = try SkillManager.adopt(rule, scope: .project, projectRoot: fx.project, locations: fx.locations)
        let copy = SkillDocument.parse(try String(contentsOf: adopted, encoding: .utf8))
        XCTAssertEqual(copy["name"], "style"); XCTAssertEqual(copy.list("globs"), ["src/**"]); XCTAssertEqual(copy.bool("alwaysApply"), true)
        XCTAssertEqual(copy.body.trimmingCharacters(in: .whitespacesAndNewlines), "Use tabs.")

        let cmd = try SkillManager.adopt(all.first { $0.name == "ship" }!, scope: .user, projectRoot: nil, locations: fx.locations)
        let cmdDoc = SkillDocument.parse(try String(contentsOf: cmd, encoding: .utf8))
        XCTAssertEqual(cmdDoc.bool("disable-model-invocation"), true, "a command stays user-only")
        XCTAssertEqual(cmdDoc["argument-hint"], "<env>")

        // The adopted DSH copy now shadows the Cursor original and is editable.
        let after = SkillCatalog.loadAll(project: fx.project, locations: fx.locations).filter { $0.name == "style" }
        XCTAssertEqual(after.first { !$0.shadowed }?.origin, .dsh)
        XCTAssertNoThrow(try SkillManager.write(after.first { !$0.shadowed }!, text: "---\nname: style\ndescription: Style guide v2\n---\nx"))

        // Creating a skill by hand.
        let made = try SkillManager.create(text: SkillManager.scaffold(name: "My Workflow", description: "Use when testing."),
                                           scope: .user, projectRoot: nil, locations: fx.locations)
        XCTAssertTrue(made.path.hasSuffix("skills/my-workflow/SKILL.md"))
        XCTAssertThrowsError(try SkillManager.create(text: SkillManager.scaffold(name: "My Workflow", description: "Use when testing."),
                                                     scope: .user, projectRoot: nil, locations: fx.locations))
    }
}

// MARK: - Lint

final class SkillLintTests: XCTestCase {
    func testFlagsMissingPiecesAndSecrets() {
        XCTAssertTrue(SkillLint.check("just text").contains { $0.severity == .error })
        XCTAssertTrue(SkillLint.check("---\nname: x\n---\nbody body body").contains { $0.message.contains("description") && $0.severity == .error })
        XCTAssertTrue(SkillLint.check("---\nname: Bad Name\ndescription: Use when testing lint rules.\n---\nbody").contains { $0.message.contains("lowercase-hyphen") })
        let secret = SkillLint.check("---\nname: s\ndescription: Use when deploying to production.\n---\nexport KEY=sk-abcdefghijklmnopqrstuvwxyz123456")
        XCTAssertTrue(secret.contains { $0.message.contains("secret") })
        let good = SkillLint.check("---\nname: good-skill\ndescription: Use when you need to lint a Swift package before a release.\n---\n\n# Steps\n1. Run it.\n")
        XCTAssertTrue(good.filter { $0.severity >= .warning }.isEmpty, "\(good)")
        let vague = SkillLint.check("---\nname: v\ndescription: Deployment things and stuff here\n---\nbody")
        XCTAssertTrue(vague.contains { $0.severity == .info })
    }
}

// MARK: - Generator

final class SkillGeneratorTests: XCTestCase {
    func testExtractHandlesFencesThinkingAndChatter() {
        let file = "---\nname: a\ndescription: Use when a.\n---\nBody"
        XCTAssertEqual(SkillGenerator.extract(from: file), file)
        XCTAssertEqual(SkillGenerator.extract(from: "```markdown\n\(file)\n```"), file)
        XCTAssertEqual(SkillGenerator.extract(from: "let me think</think>\n\(file)"), file)
        XCTAssertEqual(SkillGenerator.extract(from: "Sure! Here's the skill:\n\(file)"), file)
    }

    func testGenerateNormalizesAndRetriesOnInvalidOutput() async throws {
        let bad = ScriptedClient.Turn(text: "I can't do that, sorry.")
        let good = ScriptedClient.Turn(text: "```markdown\n---\nname: Release Notes\ndescription: Use when writing release notes from git history.\n---\n\n# Release notes\n1. Run git log.\n2. Group by type.\n```")
        let client = ScriptedClient(turns: [bad, good])
        let out = try await SkillGenerator.generate(client: client, model: "m",
                                                    request: .init(goal: "write release notes", existingNames: ["deploy"]))
        XCTAssertEqual(out.name, "release-notes")
        XCTAssertTrue(out.text.hasPrefix("---\nname: release-notes\n"))
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(client.requests[1].messages[0].content?.contains("rejected") ?? false)
        XCTAssertEqual(client.requests[0].thinking, .low, "generation must not inherit a slow max-effort default")
        XCTAssertTrue(client.requests[0].messages[0].content?.contains("deploy") ?? false, "existing names are passed along")
    }

    func testGenerateGivesUpAfterTwoBadReplies() async {
        let client = ScriptedClient(turns: [.init(text: "nope"), .init(text: "still nope")])
        do {
            _ = try await SkillGenerator.generate(client: client, model: "m", request: .init(goal: "x"))
            XCTFail("should throw")
        } catch { XCTAssertTrue(error is SkillError) }
    }

    func testDigestKeepsTheRecentPartAndSkipsImages() {
        var msgs: [LLMMessage] = []
        for i in 0..<400 { msgs.append(.user("question \(i) " + String(repeating: "x", count: 200))); msgs.append(.assistant("answer \(i)")) }
        msgs.append(LLMMessage(role: .user, content: "[image]", attachments: nil, imageSource: "screenshot"))
        let d = SkillGenerator.digest(msgs, limit: 3_000)
        XCTAssertTrue(d.contains("answer 399"))
        XCTAssertFalse(d.contains("answer 0"))
        XCTAssertFalse(d.contains("[image]"))
        XCTAssertLessThan(d.count, 4_500)
        XCTAssertTrue(SkillGenerator.userPrompt(.init(goal: "g", conversation: [.user("hi")])).contains("<conversation>"))
    }
}
