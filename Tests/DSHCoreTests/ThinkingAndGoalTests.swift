import XCTest
@testable import DSHCore

final class ThinkingTests: XCTestCase {
    private func body(_ profile: ProviderProfile, _ thinking: ThinkingLevel?) throws -> [String: Any] {
        let request = LLMRequest(systemPrompt: "", messages: [.user("hi")], tools: [],
                                 model: profile.model, thinking: thinking)
        let data = try OpenAIClient(profile: profile).makeBody(request)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private let spark = ProviderProfile(kind: .openAI, name: "Spark", baseURL: "https://192.168.68.69:11443/v1",
                                        model: "qwen3.8-27b-sglang")
    private let openAI = ProviderProfile(kind: .openAI, name: "OpenAI", baseURL: "https://api.openai.com/v1",
                                         model: "o4-mini")

    override func setUp() { ReasoningEffortCache.shared.reset() }

    func testSelfHostedIsDecidedByHostNotKind() {
        XCTAssertTrue(spark.isSelfHosted)          // kind .openAI but a LAN box
        XCTAssertFalse(openAI.isSelfHosted)
        XCTAssertFalse(ProviderProfile(kind: .openRouter, name: "r", baseURL: "https://openrouter.ai/api/v1", model: "x").isSelfHosted)
    }

    func testOffDisablesThinkingViaTemplateKwargs() throws {
        let b = try body(spark, .off)
        XCTAssertEqual((b["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        XCTAssertNil(b["reasoning_effort"])
    }

    func testEffortGoesTopLevelAndIntoTemplateKwargs() throws {
        let b = try body(spark, .medium)
        let kw = b["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(kw?["enable_thinking"] as? Bool, true)
        XCTAssertEqual(kw?["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(b["reasoning_effort"] as? String, "medium")
    }

    func testMaxMapsToXhigh() throws {
        XCTAssertEqual(try body(spark, .max)["reasoning_effort"] as? String, "xhigh")
    }

    func testHostedAPIGetsOnlyTopLevelEffortAndNothingWhenOff() throws {
        let on = try body(openAI, .high)
        XCTAssertEqual(on["reasoning_effort"] as? String, "high")
        XCTAssertNil(on["chat_template_kwargs"])
        let off = try body(openAI, .off)
        XCTAssertNil(off["reasoning_effort"])
        XCTAssertNil(off["chat_template_kwargs"])
    }

    func testProfileDefaultAppliesWhenRequestHasNone() throws {
        var p = spark
        p.thinking = .low
        XCTAssertEqual(try body(p, nil)["reasoning_effort"] as? String, "low")
        XCTAssertNil(try body(spark, nil)["chat_template_kwargs"])   // nothing set: server default
    }

    /// The exact 400 Qwen3.8's template raises for "high".
    func testEffortCorrectionFromQwenTemplateError() {
        let err = #"{"object":"error","message":"Unexpected reasoning effort high. Supported types are xhigh (default), medium, and low.","type":"BadRequest","code":400}"#
        XCTAssertEqual(OpenAIClient.effortCorrection(requested: "high", errorBody: err), "xhigh")
        XCTAssertEqual(OpenAIClient.effortCorrection(requested: "minimal",
                       errorBody: "Unexpected reasoning effort minimal. Supported types are xhigh (default), medium, and low."), "low")
        XCTAssertNil(OpenAIClient.effortCorrection(requested: "high", errorBody: "model not found"))
    }

    func testLearnedEffortIsUsedOnTheWire() throws {
        let route = "\(spark.baseURL)|\(spark.model)"
        ReasoningEffortCache.shared.learn(route: route, requested: "high", accepted: "xhigh")
        XCTAssertEqual(try body(spark, .high)["reasoning_effort"] as? String, "xhigh")
    }

    func testUserInputLevels() {
        XCTAssertEqual(ThinkingLevel(userInput: "fast"), .off)
        XCTAssertEqual(ThinkingLevel(userInput: "XHIGH"), .max)
        XCTAssertEqual(ThinkingLevel(userInput: "medium"), .medium)
        XCTAssertNil(ThinkingLevel(userInput: "banana"))
    }

    func testModernQwenFallbackIsNot32K() {
        XCTAssertEqual(FallbackContextWindow.limit(for: "qwen3.8-27b-sglang"), 262_144)
        XCTAssertEqual(FallbackContextWindow.limit(for: "qwen3.8-flash-next"), 262_144)
        XCTAssertEqual(FallbackContextWindow.limit(for: "qwen3:8b"), 32_768)
    }
}

final class SlashAndGoalTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(SlashCommand.parse("/compact"), .compact(focus: nil))
        XCTAssertEqual(SlashCommand.parse("/compact keep the API design"), .compact(focus: "keep the API design"))
        XCTAssertEqual(SlashCommand.parse("  /goal ship the build  "), .goal("ship the build"))
        XCTAssertEqual(SlashCommand.parse("/think high"), .think("high"))
        XCTAssertEqual(SlashCommand.parse("/context"), .context)
        XCTAssertNil(SlashCommand.parse("/Users/me/project/file.swift is broken"))
        XCTAssertNil(SlashCommand.parse("please /compact later"))
    }

    func testGoalMarkers() {
        XCTAssertEqual(GoalProtocol.status(of: "All tests pass.\n\nGOAL_COMPLETE"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "Done.\n**GOAL_COMPLETE**\n"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "Need a key.\nGOAL_BLOCKED: the OpenAI API key"), .blocked("the OpenAI API key"))
        // Mentioning the protocol mid-reply is not completion.
        XCTAssertEqual(GoalProtocol.status(of: "I'll write GOAL_COMPLETE when everything is verified.\nNext I will run the tests."), .working)
        XCTAssertEqual(GoalProtocol.status(of: ""), .working)
    }

    func testGoalMarkerVariantsModelsActuallyWrite() {
        // Marker first, summary after — the loop must not spin forever on it.
        XCTAssertEqual(GoalProtocol.status(of: "GOAL_COMPLETE\n\nSummary:\n- fixed a\n- fixed b\n- fixed c\n- tests pass"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "All green.\n✅ GOAL_COMPLETE"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "All green.\n`GOAL_COMPLETE`."), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "All green.\n## GOAL_COMPLETE"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "All green.\nStatus: GOAL_COMPLETE"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "All green.\nGOAL COMPLETE"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "All green.\n<GOAL_COMPLETE>"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "Stuck.\n**GOAL_BLOCKED**: which database should I use?"),
                       .blocked("which database should I use"))
        XCTAssertEqual(GoalProtocol.status(of: "Stuck.\nGOAL_BLOCKED"), .blocked("The agent needs your input."))
        // The last marker line wins.
        XCTAssertEqual(GoalProtocol.status(of: "GOAL_BLOCKED: need a key\nFound it in .env after all.\nGOAL_COMPLETE"), .complete)
        // Prose around the marker is not a marker.
        XCTAssertEqual(GoalProtocol.status(of: "Once the tests pass I will print GOAL_COMPLETE."), .working)
        XCTAssertEqual(GoalProtocol.status(of: "I am not GOAL_BLOCKED yet, continuing."), .working)
        XCTAssertEqual(GoalProtocol.status(of: "This is not a GOAL_COMPLETE situation"), .working)
        // A marker inside a code block (e.g. echoing source) doesn't count.
        XCTAssertEqual(GoalProtocol.status(of: "Here's the file:\n```\nGOAL_COMPLETE\n```\nStill working."), .working)
    }

    func testMarkdownLabelledMarkersFromReview() {
        XCTAssertEqual(GoalProtocol.status(of: "All done.\n**Status:** GOAL_COMPLETE"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "All done.\nStatus: **GOAL_COMPLETE**"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "All done.\nFinal status: `GOAL_COMPLETE`"), .complete)
        XCTAssertEqual(GoalProtocol.status(of: "Stuck.\n**Status:** GOAL_BLOCKED: need the API key"), .blocked("need the API key"))
        // Status reports and recaps are not a verdict.
        XCTAssertEqual(GoalProtocol.status(of: "Checklist:\n- tests: pass\n- GOAL_BLOCKED: no"), .working)
        XCTAssertEqual(GoalProtocol.status(of: "Goal blocked: no\nContinuing with the parser."), .working)
        XCTAssertEqual(GoalProtocol.status(of: "Resuming.\nLast round ended with:\nGOAL_BLOCKED: need the DB password\nYou gave it above, so I ran the migration.\nNext: seed data.\nThen the API."), .working)
        XCTAssertEqual(GoalProtocol.status(of: "Recap:\n- Previously: GOAL_BLOCKED on the DB password (answered)"), .working)
        // A one-line code span doesn't swallow the rest of the reply.
        XCTAssertEqual(GoalProtocol.status(of: "```swift build```\nAll green.\nGOAL_COMPLETE"), .complete)
        // Thinking left inline by a server without a reasoning parser.
        XCTAssertEqual(GoalProtocol.status(of: "<think>\nWhen everything passes I end with:\nGOAL_COMPLETE\nBut 3 tests fail.\n</think>\nThree tests still fail; fixing next."), .working)
        XCTAssertEqual(GoalProtocol.status(of: "<think>checking</think>\nAll verified.\nGOAL_COMPLETE"), .complete)
        // Buried markers are noticed so the next round can ask for them plainly.
        let buried = "All tests pass.\nGOAL_COMPLETE\n\nChanges:\n- a\n- b\n- c"
        XCTAssertEqual(GoalProtocol.status(of: buried), .working)
        XCTAssertTrue(GoalProtocol.mentionsMarker(buried))
        XCTAssertTrue(GoalProtocol.continuation("g", round: 2, hitIterationLimit: false, markerMisplaced: true).contains("did not count"))
    }

    func testGoalPromptsCarryTheGoal() {
        XCTAssertTrue(GoalProtocol.kickoff("fix the build").contains("fix the build"))
        let c = GoalProtocol.continuation("fix the build", round: 3, hitIterationLimit: true)
        XCTAssertTrue(c.contains("fix the build") && c.contains("round 3") && c.contains("cut off"))
        // No round budget: the model is never told it has N rounds.
        XCTAssertFalse(c.contains("round 3 of"))
        let e = GoalProtocol.continuation("fix the build", round: 4, hitIterationLimit: false, error: "HTTP 400: bad")
        XCTAssertTrue(e.contains("HTTP 400: bad") && e.contains("round 4"))
        // Prompts themselves must never read as a verdict if echoed.
        XCTAssertEqual(GoalProtocol.status(of: c), .working)
        XCTAssertEqual(GoalProtocol.status(of: e), .working)
    }

    func testAutoGoalProtocol() {
        let k = GoalProtocol.kickoffAuto("refactor the parser")
        XCTAssertTrue(k.contains("refactor the parser"))
        XCTAssertTrue(k.contains("GOAL_COMPLETE"))
        XCTAssertTrue(k.contains("unattended"))
        // Auto prompts must not promise to ask the user for confirmation.
        XCTAssertFalse(k.contains("Stop it any time"))
        let c = GoalProtocol.continuationAuto("refactor the parser", round: 2, hitIterationLimit: false)
        XCTAssertTrue(c.contains("round 2"))
        XCTAssertTrue(c.contains("unattended"))
        // Blocked marker still recognized after the auto reminder.
        XCTAssertEqual(GoalProtocol.status(of: c + "\nGOAL_BLOCKED: need the API key"),
                       .blocked("need the API key"))
        XCTAssertEqual(GoalProtocol.status(of: "done\nGOAL_COMPLETE"), .complete)
        let r = GoalProtocol.resumeAuto("refactor the parser")
        XCTAssertTrue(r.hasPrefix("[Resuming]") && r.contains("refactor the parser") && r.contains("unattended"))
        XCTAssertTrue(GoalProtocol.resume("x").hasPrefix("[Resuming]"))
        XCTAssertFalse(GoalProtocol.resume("x").contains("unattended"))
    }
}

final class CompactionForceTests: XCTestCase {
    private func big(_ n: Int) -> String { String(repeating: "x", count: n * 4) }

    func testForcedCompactionIgnoresThreshold() {
        let t: [LLMMessage] = [.user("a"), .assistant(big(500)), .user("b"), .assistant(big(500)), .user("c"), .assistant("ok")]
        XCTAssertNil(Compaction.plan(usedTokens: 1_000, limit: 1_000_000, transcript: t))
        let plan = Compaction.plan(usedTokens: 1_000, limit: 1_000_000, transcript: t, force: true)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.toKeep.first?.role, .user)
    }

    func testOneLongTurnFallsBackToAssistantBoundary() {
        var t: [LLMMessage] = [.user("do the thing")]
        for i in 0..<30 {
            let call = ToolCall(id: "c\(i)", name: "read_file", arguments: "{}")
            t.append(.assistant("step \(i)", calls: [call]))
            t.append(.toolResult(id: "c\(i)", name: "read_file", output: big(2_000)))
        }
        let used = TokenEstimate.request(systemPrompt: "", messages: t)
        let plan = Compaction.plan(usedTokens: used, limit: 64_000, transcript: t)
        XCTAssertNotNil(plan, "a single huge turn must still be compactable")
        XCTAssertEqual(plan?.toKeep.first?.role, .assistant)
    }

    func testKeepBudgetIsCappedOnHugeWindows() {
        var t: [LLMMessage] = []
        for i in 0..<400 { t.append(.user("q\(i)")); t.append(.assistant(big(2_000))) }
        let used = TokenEstimate.request(systemPrompt: "", messages: t)
        let plan = Compaction.plan(usedTokens: used, limit: 1_000_000, transcript: t)!
        let kept = TokenEstimate.request(systemPrompt: "", messages: plan.toKeep)
        XCTAssertLessThanOrEqual(kept, Compaction.maxKeepTokens + 4_000)
    }

    func testPreviousSummaryIsCarriedWhole() {
        let long = String(repeating: "fact ", count: 2_000)
        let msgs: [LLMMessage] = [.system(Compaction.summaryHeader + long), .user("next"), .assistant("ok")]
        let prompt = Compaction.summaryPrompt(for: msgs, budgetTokens: 1_000)
        XCTAssertTrue(prompt.contains(long))
        XCTAssertTrue(prompt.contains("<earlier-summary>"))
    }

    func testStripThinking() {
        XCTAssertEqual(Compaction.stripThinking("hmm let me think</think>\n\nThe note"), "\n\nThe note")
        XCTAssertEqual(Compaction.stripThinking("plain"), "plain")
    }
}
