import XCTest
@testable import VisionHarnessCore

/// The tools' rough edges: what a model gets back when output is too long, when it writes a number as text, when
/// an edit doesn't match, when a search has to skip a dependency folder — and that a stopped run stops its command.
final class ToolRobustnessTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-robust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func context(_ root: URL) -> ToolContext {
        ToolContext(workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                    client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: Long output

    func testLongOutputKeepsItsStartAndItsEndAndSaysWhatIsMissing() {
        let text = String(repeating: "a", count: 100) + String(repeating: "b", count: 1_000) + String(repeating: "c", count: 50)
        let fitted = OutputBudget.middleOut(text, head: 100, tail: 50)
        XCTAssertTrue(fitted.hasPrefix(String(repeating: "a", count: 100) + "\n… [1000 characters omitted here"), fitted)
        XCTAssertTrue(fitted.hasSuffix("] …\n" + String(repeating: "c", count: 50)), fitted)
        XCTAssertFalse(fitted.contains("b"))
    }

    func testOutputThatFitsIsLeftAlone() {
        XCTAssertEqual(OutputBudget.middleOut("short", head: 3, tail: 2), "short")
        XCTAssertEqual(OutputBudget.middleOut("", head: 10, tail: 10), "")
        XCTAssertEqual(RunShellCommandTool.terminalText("ok"), "ok")
    }

    func testLongCommandOutputKeepsTheEndWhereTheErrorIs() {
        let text = "START " + String(repeating: "x", count: 40_000) + " THE ERROR"
        let fitted = RunShellCommandTool.terminalText(text)
        XCTAssertTrue(fitted.hasPrefix("START "))
        XCTAssertTrue(fitted.hasSuffix(" THE ERROR"))
        XCTAssertLessThan(fitted.count, 17_000)
    }

    // MARK: Arguments written as text

    func testNumbersAndBooleansWrittenAsTextAreRead() {
        let args = JSONString(#"{"a":"120","b":" 7 ","c":"12.0","d":"many","yes":"true","no":"False","one":"1","odd":"perhaps","real":40,"flag":true}"#)
        XCTAssertEqual(JSONArgs.int(args, "a", default: 0), 120)
        XCTAssertEqual(JSONArgs.int(args, "b", default: 0), 7)
        XCTAssertEqual(JSONArgs.int(args, "c", default: 0), 12)
        XCTAssertEqual(JSONArgs.int(args, "d", default: 9), 9, "not a number: the default")
        XCTAssertEqual(JSONArgs.int(args, "real", default: 0), 40)
        XCTAssertEqual(JSONArgs.int(args, "missing", default: 3), 3)
        XCTAssertTrue(JSONArgs.bool(args, "yes", default: false))
        XCTAssertFalse(JSONArgs.bool(args, "no", default: true))
        XCTAssertTrue(JSONArgs.bool(args, "one", default: false))
        XCTAssertTrue(JSONArgs.bool(args, "odd", default: true), "not a boolean: the default")
        XCTAssertTrue(JSONArgs.bool(args, "flag", default: false))
    }

    func testReplaceAllWrittenAsTextStillReplacesAll() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("x x x\n", "f.txt", in: root)
        let result = await EditTool().execute(
            args: JSONString(#"{"file_path":"f.txt","old_string":"x","new_string":"y","replace_all":"true"}"#), in: context(root))
        XCTAssertTrue(result.output.hasPrefix("Edited f.txt: replaced 3"), result.output)
    }

    // MARK: edit

    func testAnEditOfAFileThatIsNotThereCreatesNothing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await EditTool().execute(
            args: JSONString(#"{"file_path":"Sources/Typo.swift","old_string":"let a = 1","new_string":"let a = 2"}"#), in: context(root))
        XCTAssertTrue(result.output.hasPrefix("Error:"), result.output)
        XCTAssertTrue(result.output.contains("does not exist"), result.output)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Typo.swift").path))
    }

    func testAnEmptyOldStringStillCreatesANewFileButNeverReplacesOne() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let args = JSONString(#"{"file_path":"new.txt","old_string":"","new_string":"hello\n"}"#)
        let created = await EditTool().execute(args: args, in: context(root))
        XCTAssertTrue(created.output.hasPrefix("Created new.txt"), created.output)
        let again = await EditTool().execute(args: args, in: context(root))
        XCTAssertTrue(again.output.hasPrefix("Error: new.txt already exists"), again.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt"), encoding: .utf8), "hello\n")
    }

    func testAnEditThatChangesNothingSaysSo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("same\n", "f.txt", in: root)
        let result = await EditTool().execute(
            args: JSONString(#"{"file_path":"f.txt","old_string":"same","new_string":"same"}"#), in: context(root))
        XCTAssertTrue(result.output.hasPrefix("Error: old_string and new_string are the same"), result.output)
    }

    func testAMissedEditSaysWhy() {
        let file = "func a() {\n    let x = 1\n    return x\n}\n\nfunc b() {}\n"
        XCTAssertEqual(EditTool.notFoundHint(needle: "2 |     let x = 1\n3 |     return x", in: file),
                       " old_string includes read_file's line-number prefixes (like \"12 | \"): leave them out.")
        XCTAssertEqual(EditTool.notFoundHint(needle: "  let x = 1\n  return x", in: file),
                       " The same lines are at 2–3 with different indentation or spacing: read those lines again and copy them exactly.")
        XCTAssertEqual(EditTool.notFoundHint(needle: "func a() {\n    let x = 2", in: file),
                       " Its first line is at line 1, but what follows there is different: read from line 1 and copy the current text.")
        XCTAssertEqual(EditTool.notFoundHint(needle: "nothing like it", in: file), "")
        XCTAssertEqual(EditTool.notFoundHint(needle: "  \n", in: file), "")
    }

    func testTheHintReachesTheModel() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a\n\tb\nc\n", "f.txt", in: root)
        let result = await EditTool().execute(
            args: JSONString(#"{"file_path":"f.txt","old_string":"    b","new_string":"    B"}"#), in: context(root))
        XCTAssertTrue(result.output.hasPrefix("Error: old_string not found in f.txt."), result.output)
        XCTAssertTrue(result.output.contains("The same lines are at 2–2"), result.output)
    }

    // MARK: grep and glob

    func testGrepLineNumbersAreRightInACrlfFileWithEmoji() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Every CRLF and every emoji before the match used to push the reported line further from the real one.
        let lines = (1...40).map { $0 == 37 ? "let needle = 1" : "// 🚀🚀 line \($0)" }
        try write(lines.joined(separator: "\r\n") + "\r\n", "win.swift", in: root)
        let result = await GrepTool().execute(args: JSONString(#"{"pattern":"needle"}"#), in: context(root))
        XCTAssertTrue(result.output.hasPrefix("win.swift:37: let needle = 1\n"), result.output)
        XCTAssertFalse(result.output.contains("\r"))
    }

    func testASearchSkipsDependencyFoldersAndFindsTheProjectsOwnFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("export const wanted = 1\n", "src/app.js", in: root)
        try write("export const wanted = 2\n", "node_modules/lib/index.js", in: root)
        try write("wanted\n", ".git/HEAD", in: root)
        let grep = await GrepTool().execute(args: JSONString(#"{"pattern":"wanted"}"#), in: context(root))
        XCTAssertTrue(grep.output.hasPrefix("src/app.js:1: export const wanted = 1\n(1 files with matches, 1 line)"), grep.output)
        // Named outright, a skipped folder is searched.
        let inside = await GrepTool().execute(args: JSONString(#"{"pattern":"wanted","path":"node_modules"}"#), in: context(root))
        XCTAssertTrue(inside.output.hasPrefix("lib/index.js:1:"), inside.output)
        let glob = await GlobTool().execute(args: JSONString(#"{"pattern":"**/*.js"}"#), in: context(root))
        XCTAssertTrue(glob.output.hasPrefix("src/app.js\n(1 match)"), glob.output)
    }

    func testABarePatternFindsFilesAtAnyDepth() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("{}", "package.json", in: root)
        try write("{}", "apps/web/tsconfig.json", in: root)
        try write("x", "apps/web/readme.md", in: root)
        let bare = await GlobTool().execute(args: JSONString(#"{"pattern":"*.json"}"#), in: context(root))
        XCTAssertTrue(bare.output.hasPrefix("apps/web/tsconfig.json\npackage.json\n(2 matches)"), bare.output)
        // With a folder in it, a pattern is matched from the top, as before.
        let rooted = await GlobTool().execute(args: JSONString(#"{"pattern":"apps/*/*.json"}"#), in: context(root))
        XCTAssertTrue(rooted.output.hasPrefix("apps/web/tsconfig.json\n(1 match)"), rooted.output)
    }

    func testAWalkThatHitsItsLimitSaysSoAndIsInNameOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["c.txt", "a.txt", "b.txt", "sub/d.txt", "sub/e.txt"] { try write("x", name, in: root) }
        let all = walkRelativePaths(root: root.path, limit: 10)
        XCTAssertEqual(all.paths, ["a.txt", "b.txt", "c.txt", "sub/d.txt", "sub/e.txt"], "a folder's files before its subfolders'")
        XCTAssertFalse(all.truncated)
        let some = walkRelativePaths(root: root.path, limit: 4)
        XCTAssertEqual(some.paths, ["a.txt", "b.txt", "c.txt", "sub/d.txt"])
        XCTAssertTrue(some.truncated)
        let exact = walkRelativePaths(root: root.path, limit: 5)
        XCTAssertFalse(exact.truncated, "everything was seen")
    }

    // MARK: The shell

    func testACommandsEnvironmentTurnsPagersAndPromptsOffButKeepsTheUsersOwn() {
        let env = PTY.commandEnvironment(base: ["PATH": "/usr/bin", "GIT_PAGER": "delta", "LANG": "de_DE.UTF-8"])
        XCTAssertEqual(env["PAGER"], "cat")
        XCTAssertEqual(env["GIT_PAGER"], "delta", "what the user set wins")
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(env["LANG"], "de_DE.UTF-8")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testACommandSeesNoPager() async {
        let (output, status, _) = await PTY.runCommand("echo pager=$PAGER prompt=$GIT_TERMINAL_PROMPT",
                                                       cwd: URL(fileURLWithPath: "/tmp"), timeout: 10)
        XCTAssertEqual(status, 0)
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("prompt=0"), text)
        if ProcessInfo.processInfo.environment["PAGER"] == nil { XCTAssertTrue(text.contains("pager=cat"), text) }
    }

    /// Stop must stop the command, not just the wait for it: the command used to run on to its own timeout.
    func testCancellingTheTaskKillsTheCommand() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("finished")
        let started = Date()
        let task = Task {
            await PTY.runCommand("sleep 20; touch '\(marker.path)'", cwd: root, timeout: 60)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the command was killed, not waited for")
        XCTAssertFalse(result.timedOut)
        XCTAssertNotEqual(result.exitStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testShellOutputReachesTheModelWithoutTerminalControlBytes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await RunShellCommandTool().execute(
            args: JSONString(#"{"command":"printf '\\033[31mred\\033[0m\\n'; printf 'one\\rtwo\\rthree\\n'"}"#), in: context(root))
        XCTAssertEqual(result.output, "red\nthree")
    }

    // MARK: The engine

    /// A client whose turns can end for any reason ("length": the reply ran into the output limit).
    private final class FinishingClient: LLMClient, @unchecked Sendable {
        struct Turn {
            var text = ""
            var calls: [ToolCall] = []
            var finish = "stop"
        }
        private let lock = NSLock()
        private var turns: [Turn]
        init(_ turns: [Turn]) { self.turns = turns }

        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            let turn: Turn = lock.withLock { turns.isEmpty ? Turn(text: "done") : turns.removeFirst() }
            return AsyncThrowingStream { continuation in
                if !turn.text.isEmpty { continuation.yield(.text(turn.text)) }
                continuation.yield(.done(calls: turn.calls, finish: turn.finish, usage: nil))
                continuation.finish()
            }
        }
        func listModels() async throws -> [String] { ["m"] }
    }

    /// Counts its calls; fails every time.
    private struct CountingFailure: ToolExecutor {
        static let name = "flaky"
        static let spec = ToolSpec(name: name, description: "fails", parameters: "{}")
        let counter: Counter
        func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
            counter.bump()
            return ToolResult(output: "Error: no such thing")
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }

    private func engine(_ client: any LLMClient, tools: [any ToolExecutor], root: URL, iterations: Int = 8) -> Engine {
        Engine(client: client, registry: ToolRegistry(tools: tools), systemPrompt: "system",
               config: .init(maxIterations: iterations, toolTimeout: 5, model: "test"),
               workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
               permissionGate: { _, _, _ in true })
    }

    private func toolOutputs(_ result: RunResult) -> [String] {
        result.messages.filter { $0.role == .tool }.compactMap(\.content)
    }

    func testACallCutOffByTheOutputLimitRunsNothingAndSaysSo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cut = ToolCall(id: "c1", name: "write_file", arguments: #"{"file_path":"big.txt","content":"aaaa"#)
        let client = FinishingClient([.init(calls: [cut], finish: "length"), .init(text: "smaller next time")])
        let result = try await engine(client, tools: [WriteFileTool()], root: root).run(messages: [], userText: "go") { _ in }
        let outputs = toolOutputs(result)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertTrue(outputs[0].hasPrefix("Error: this tool call was cut off by the output-token limit"), outputs[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("big.txt").path))
        XCTAssertEqual(result.finalText, "smaller next time")
    }

    func testACompleteCallInAReplyThatHitTheLimitStillRuns() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let whole = ToolCall(id: "c1", name: "write_file", arguments: #"{"file_path":"ok.txt","content":"fine"}"#)
        let client = FinishingClient([.init(calls: [whole], finish: "length"), .init(text: "done")])
        _ = try await engine(client, tools: [WriteFileTool()], root: root).run(messages: [], userText: "go") { _ in }
        let written = try String(contentsOf: root.appendingPathComponent("ok.txt"), encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("fine"), written)
    }

    func testCutOffArgumentsAreRecognised() {
        XCTAssertTrue(Engine.argumentsWereCutOff(#"{"file_path":"a","content":"abc"#))
        XCTAssertTrue(Engine.argumentsWereCutOff(#"{"a":"#))
        XCTAssertFalse(Engine.argumentsWereCutOff(#"{"a":1}"#))
        XCTAssertFalse(Engine.argumentsWereCutOff(""), "no arguments at all is not a cut-off call")
        XCTAssertFalse(Engine.argumentsWereCutOff("  "))
        XCTAssertFalse(Engine.argumentsWereCutOff("[1,2]"))
    }

    func testTheSameFailingCallAThirdTimeIsToldToChangeCourse() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        func call(_ id: String, _ args: String = "{}") -> ToolCall { ToolCall(id: id, name: "flaky", arguments: args) }
        let client = FinishingClient([.init(calls: [call("1")]), .init(calls: [call("2")]), .init(calls: [call("3")]),
                                      .init(calls: [call("4", #"{"other":true}"#)]), .init(text: "gave up")])
        let result = try await engine(client, tools: [CountingFailure(counter: counter)], root: root)
            .run(messages: [], userText: "go") { _ in }
        let outputs = toolOutputs(result)
        XCTAssertEqual(counter.value, 4, "every call still ran")
        XCTAssertEqual(outputs.count, 4)
        XCTAssertEqual(outputs[0], "Error: no such thing")
        XCTAssertEqual(outputs[1], "Error: no such thing")
        XCTAssertTrue(outputs[2].contains("has now failed 3 times in a row"), outputs[2])
        XCTAssertEqual(outputs[3], "Error: no such thing", "different arguments start the count again")
    }

    func testAnUnknownToolIsAnsweredWithTheToolsThereAre() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = FinishingClient([.init(calls: [ToolCall(id: "1", name: "read", arguments: "{}")]), .init(text: "ok")])
        let result = try await engine(client, tools: [ReadFileTool(), GrepTool()], root: root).run(messages: [], userText: "go") { _ in }
        XCTAssertEqual(toolOutputs(result).first, "Error: unknown tool 'read'. The tools are: grep, read_file.")
    }

    func testAResultTooLongForTheModelKeepsBothEnds() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...6_000).map { "line \($0) of the file" }.joined(separator: "\n")
        try write(lines, "big.txt", in: root)
        let read = ToolCall(id: "1", name: "run_shell_command", arguments: #"{"command":"cat big.txt"}"#)
        let client = FinishingClient([.init(calls: [read]), .init(text: "ok")])
        let result = try await engine(client, tools: [RunShellCommandTool()], root: root, iterations: 3)
            .run(messages: [], userText: "go") { _ in }
        let output = try XCTUnwrap(toolOutputs(result).first)
        XCTAssertTrue(output.hasPrefix("line 1 of the file\n"), String(output.prefix(80)))
        XCTAssertTrue(output.hasSuffix("line 6000 of the file"), String(output.suffix(80)))
        XCTAssertTrue(output.contains("characters omitted here"))
    }

    // MARK: An empty reply in the middle of the work

    func testABlankReplyAfterToolWorkIsAskedAgainInsteadOfEndingTheRun() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let call = ToolCall(id: "1", name: "echo", arguments: #"{"text":"hi"}"#)
        let client = FinishingClient([.init(calls: [call]), .init(text: "  \n"), .init(text: "All done: echoed hi.")])
        let result = try await engine(client, tools: [EchoTool()], root: root).run(messages: [], userText: "go") { _ in }
        XCTAssertEqual(result.finalText, "All done: echoed hi.")
        let nudges = result.messages.filter { $0.role == .user && $0.imageSource == "empty reply" }
        XCTAssertEqual(nudges.count, 1)
        XCTAssertFalse(result.messages.contains { $0.role == .assistant && ($0.content ?? "").isEmpty && ($0.toolCalls ?? []).isEmpty },
                       "the blank itself is not kept in the transcript")
    }

    func testAModelThatStaysBlankIsAskedTwiceAndThenTheRunEnds() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let call = ToolCall(id: "1", name: "echo", arguments: "{}")
        let client = FinishingClient([.init(calls: [call]), .init(text: ""), .init(text: ""), .init(text: "")])
        let result = try await engine(client, tools: [EchoTool()], root: root).run(messages: [], userText: "go") { _ in }
        XCTAssertEqual(result.finalText, "")
        XCTAssertEqual(result.messages.filter { $0.imageSource == "empty reply" }.count, 2)
    }

    func testABlankReplyIsLeftAloneWhenNoToolRanOrTheModelAlreadySpoke() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No tool ran: an empty answer is the answer (a subagent with nothing to report).
        let plain = try await engine(FinishingClient([.init(text: "")]), tools: [EchoTool()], root: root)
            .run(messages: [], userText: "go") { _ in }
        XCTAssertTrue(plain.messages.allSatisfy { $0.imageSource == nil })
        // It said its piece along with the tool call: the closing blank ends the run, as before.
        let call = ToolCall(id: "1", name: "echo", arguments: "{}")
        let spoke = try await engine(FinishingClient([.init(text: "Here is the result.", calls: [call]), .init(text: "")]),
                                     tools: [EchoTool()], root: root).run(messages: [], userText: "go") { _ in }
        XCTAssertTrue(spoke.messages.allSatisfy { $0.imageSource == nil })
        XCTAssertEqual(spoke.lastReplyText, "Here is the result.")
    }

    // MARK: The window

    func testTheSizeEstimateIsCorrectedByWhatTheServerCounts() {
        XCTAssertEqual(Engine.estimateScale(estimated: 10_000, counted: 13_000, current: 1), 1.3, accuracy: 0.001)
        XCTAssertEqual(Engine.estimateScale(estimated: 10_000, counted: 9_000, current: 1.3), 1, "never scaled down below the estimate")
        XCTAssertEqual(Engine.estimateScale(estimated: 500, counted: 9_000, current: 1), 1.6, "a short chat's ratio is the tool list: capped")
        XCTAssertEqual(Engine.estimateScale(estimated: 10_000, counted: nil, current: 1.4), 1.4, "no count: keep what is known")
        XCTAssertEqual(Engine.estimateScale(estimated: 0, counted: 100, current: 1.2), 1.2)
    }

    func testAnOverflowThatNamesNoLimitIsStillAnOverflow() {
        let bodies = [
            #"{"error":{"code":"context_length_exceeded","message":"Too many tokens."}}"#,
            "the request exceeds the available context size, try increasing it",
            "Prompt is too long",
            "input is too long for the model",
        ]
        for body in bodies {
            XCTAssertTrue(OpenAIClient.saysOverflow(body), body)
            guard case .overflow(let limit, _)? = OpenAIClient.overflow(in: body) else { return XCTFail(body) }
            XCTAssertEqual(limit, 0, body)
        }
        guard case .overflow(let limit, _)? = OpenAIClient.overflow(in: "This model's maximum context length is 262144 tokens") else {
            return XCTFail("the limit, when it is named")
        }
        XCTAssertEqual(limit, 262_144)
        XCTAssertNil(OpenAIClient.overflow(in: #"{"error":{"message":"Unknown model."}}"#))
        XCTAssertFalse(OpenAIClient.saysOverflow("rate limit exceeded"))
    }

    // MARK: A file that changed since the agent looked

    private func context(_ root: URL, ledger: FileLedger) -> ToolContext {
        ToolContext(workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                    client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []), fileLedger: ledger)
    }

    func testAWriteOverAFileThatChangedSinceItWasReadIsRefusedUntilItIsReadAgain() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one\n", "notes.txt", in: root)
        let ctx = context(root, ledger: FileLedger())
        _ = await ReadFileTool().execute(args: JSONString(#"{"file_path":"notes.txt"}"#), in: ctx)
        // The user saves the file in the editor.
        try write("one\ntwo, added by the user\n", "notes.txt", in: root)

        let overwrite = JSONString(#"{"file_path":"notes.txt","content":"ONE\n"}"#)
        let refused = await WriteFileTool().execute(args: overwrite, in: ctx)
        XCTAssertTrue(refused.output.hasPrefix("Error: notes.txt has changed on disk since you last read it"), refused.output)
        XCTAssertTrue(refused.files.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8),
                       "one\ntwo, added by the user\n", "the user's work is still there")

        _ = await ReadFileTool().execute(args: JSONString(#"{"file_path":"notes.txt"}"#), in: ctx)
        let written = await WriteFileTool().execute(args: overwrite, in: ctx)
        XCTAssertTrue(written.output.hasPrefix("Wrote"), written.output)
        // Its own write is something it has seen: the next one goes through.
        let again = await WriteFileTool().execute(args: JSONString(#"{"file_path":"notes.txt","content":"ONE!\n"}"#), in: ctx)
        XCTAssertTrue(again.output.hasPrefix("Wrote"), again.output)
    }

    func testAFileNeverReadAndANewFileAreWrittenAsBefore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("old\n", "unseen.txt", in: root)
        let ctx = context(root, ledger: FileLedger())
        let unseen = await WriteFileTool().execute(args: JSONString(#"{"file_path":"unseen.txt","content":"new\n"}"#), in: ctx)
        XCTAssertTrue(unseen.output.hasPrefix("Wrote"), unseen.output)
        let fresh = await WriteFileTool().execute(args: JSONString(#"{"file_path":"fresh.txt","content":"x\n"}"#), in: ctx)
        XCTAssertTrue(fresh.output.hasPrefix("Wrote"), fresh.output)
        // And with no ledger at all (a bare tool context), nothing is checked.
        let bare = await WriteFileTool().execute(args: JSONString(#"{"file_path":"unseen.txt","content":"z\n"}"#), in: context(root))
        XCTAssertTrue(bare.output.hasPrefix("Wrote"), bare.output)
    }

    func testAnEditOfAFileThatChangedStillAppliesAndSaysTheFileMovedOn() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha\nbeta\n", "f.txt", in: root)
        let ctx = context(root, ledger: FileLedger())
        _ = await ReadFileTool().execute(args: JSONString(#"{"file_path":"f.txt"}"#), in: ctx)
        try write("alpha\nbeta\ngamma from someone else\n", "f.txt", in: root)
        let edited = await EditTool().execute(
            args: JSONString(#"{"file_path":"f.txt","old_string":"alpha","new_string":"ALPHA"}"#), in: ctx)
        XCTAssertTrue(edited.output.hasPrefix("Edited f.txt: replaced 1 occurrence."), edited.output)
        XCTAssertTrue(edited.output.contains("had changed on disk since you last read it"), edited.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("f.txt"), encoding: .utf8),
                       "ALPHA\nbeta\ngamma from someone else\n")
        // An edit of a file as the agent last saw it carries no note.
        let plain = await EditTool().execute(
            args: JSONString(#"{"file_path":"f.txt","old_string":"beta","new_string":"BETA"}"#), in: ctx)
        XCTAssertEqual(plain.output, "Edited f.txt: replaced 1 occurrence.")
    }

    // MARK: Arguments that are nearly JSON

    /// What a tool would read from `raw` once the engine has repaired it. (Some inputs, such as a trailing comma,
    /// newer Foundation parsers accept as they are; then there is nothing to repair, and that is fine too.)
    private func repairedObject(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let fixed = ToolArguments.repaired(raw) ?? raw
        XCTAssertNil(ToolArguments.problem(fixed), "still not a JSON object: \(raw)", file: file, line: line)
        guard let value = try? JSONSerialization.jsonObject(with: Data(fixed.utf8)) as? [String: Any] else {
            XCTFail("repair is not a JSON object: \(fixed)", file: file, line: line)
            return [:]
        }
        return value
    }

    func testArgumentsThatAreNearlyJSONAreRepaired() {
        XCTAssertEqual(repairedObject("```json\n{\"a\": 1}\n```")["a"] as? Int, 1, "a fence")
        XCTAssertEqual(repairedObject("```\r\n{\"a\": 2}\r\n```")["a"] as? Int, 2, "a fence with CR LF lines")
        let trailing = repairedObject(#"{"a": [1, 2,], "b": "x",}"#)
        XCTAssertEqual(trailing["a"] as? [Int], [1, 2])
        XCTAssertEqual(trailing["b"] as? String, "x")
        let python = repairedObject(#"{"recursive": True, "hidden": False, "limit": None}"#)
        XCTAssertEqual(python["recursive"] as? Bool, true)
        XCTAssertEqual(python["hidden"] as? Bool, false)
        XCTAssertTrue(python["limit"] is NSNull)
        XCTAssertEqual(repairedObject("{\"content\": \"line one\nline two\tindented\"}")["content"] as? String,
                       "line one\nline two\tindented", "raw line breaks and tabs inside a string")
        XCTAssertEqual(repairedObject(#"{"pattern": "\d+\.swift"}"#)["pattern"] as? String, #"\d+\.swift"#,
                       "a regex backslash that is not a JSON escape")
        XCTAssertEqual(repairedObject(#""{\"path\": \"a.txt\"}""#)["path"] as? String, "a.txt", "the object sent as a string")
        XCTAssertEqual(repairedObject("Here are the arguments: {\"x\": 2} — that's all.")["x"] as? Int, 2, "words around it")
        XCTAssertEqual(repairedObject(#"{"note": "True, None, False", "n": 1,}"#)["note"] as? String, "True, None, False",
                       "words inside strings are left alone")
    }

    func testArgumentsThatAreFineOrBeyondRepairAreLeftAlone() {
        XCTAssertNil(ToolArguments.repaired(#"{"a": 1}"#), "already a JSON object")
        XCTAssertNil(ToolArguments.repaired(""), "no arguments")
        XCTAssertNil(ToolArguments.repaired("null"))
        XCTAssertNil(ToolArguments.repaired(#"{"file_path": "a", "content": "abc"#), "cut off")
        XCTAssertNil(ToolArguments.repaired("[1, 2]"), "an array is not made into an object")
        XCTAssertNil(ToolArguments.repaired("ls -la"))

        XCTAssertNil(ToolArguments.problem(#"{"a": 1}"#))
        XCTAssertNil(ToolArguments.problem(""))
        XCTAssertNil(ToolArguments.problem("  null "))
        XCTAssertEqual(ToolArguments.problem("[1]"), "a JSON array, not an object")
        XCTAssertEqual(ToolArguments.problem(#""path""#), "a JSON string, not an object")
        XCTAssertEqual(ToolArguments.problem("42"), "a single value, not an object")
        XCTAssertEqual(ToolArguments.problem("ls -la"), "not valid JSON")
    }

    func testARepairableCallRunsWithItsArguments() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A real line break inside the content string, and a trailing comma: what local models often send.
        let sloppy = ToolCall(id: "c1", name: "write_file", arguments: "{\"file_path\": \"notes.txt\", \"content\": \"one\ntwo\",}")
        let client = FinishingClient([.init(calls: [sloppy]), .init(text: "wrote it")])
        let result = try await engine(client, tools: [WriteFileTool()], root: root).run(messages: [], userText: "go") { _ in }
        let written = try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("one\ntwo"), written)
        XCTAssertEqual(result.finalText, "wrote it")
        // The transcript carries the repaired arguments, so the next request is valid JSON too.
        let sent = try XCTUnwrap(result.messages.first { $0.role == .assistant && $0.toolCalls != nil }?.toolCalls?.first)
        XCTAssertNil(ToolArguments.problem(sent.arguments.raw), sent.arguments.raw)
    }

    func testACallWithUnusableArgumentsRunsNothingAndSaysWhy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = ToolCall(id: "c1", name: "write_file", arguments: "file_path=notes.txt content=hello")
        let client = FinishingClient([.init(calls: [broken]), .init(text: "sorry")])
        let result = try await engine(client, tools: [WriteFileTool()], root: root).run(messages: [], userText: "go") { _ in }
        let outputs = toolOutputs(result)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertTrue(outputs[0].hasPrefix("Error: the arguments for write_file were not valid JSON, so nothing ran."), outputs[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(result.finalText, "sorry")
    }
}
