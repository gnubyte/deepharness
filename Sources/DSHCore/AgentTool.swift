import Foundation

// MARK: - agent (subagents)
//
// Spawns a child `Engine` that works a self-contained task in a bounded
// loop, then returns a final report. The child inherits the parent's
// model, permission gate, and workspace/policy; it does NOT inherit the
// `agent` tool itself (no nested subagents).

public struct AgentTool: ToolExecutor {
    public static let name = "agent"
    public static let spec = ToolSpec(
        name: name,
        description: "Spawn a subagent to work a self-contained task (e.g. 'find every usage of X and report the call sites'). It gets the same tools (except agent), works autonomously in a bounded loop, and returns a final report. Prefer this over doing long exploration yourself when the task is well-scoped.",
        parameters: """
        {"type":"object","properties":{"description":{"type":"string","description":"What to name this subagent"},"prompt":{"type":"string","description":"The complete task for the subagent. It cannot ask you questions — everything it needs goes here."}},"required":["description","prompt"]}
        """
    )

    /// Subagents get fewer iterations than the top-level session.
    private static let subagentMaxIterations = 20

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let desc = Self.string(args, "description") ?? "subagent"
        let prompt = Self.string(args, "prompt") ?? ""
        guard !prompt.isEmpty else {
            return ToolResult(output: "Error: prompt is required.")
        }
        guard context.depth < 1 else {
            return ToolResult(output: "Error: nested subagents are not allowed (depth limit).")
        }

        // Same capabilities as the parent, minus `agent` itself.
        let subRegistry = ToolRegistry.standard(depth: context.depth + 1)
        let config = EngineConfig(
            maxIterations: Self.subagentMaxIterations,
            toolTimeout: 300,
            model: context.model
        )
        let engine = Engine(
            client: context.client,
            registry: subRegistry,
            systemPrompt: Self.subagentPrompt(workspace: context.workspace,
                                              permissionPreset: context.policy.preset),
            config: config,
            workspace: context.workspace,
            policy: context.policy,
            permissionGate: context.requestPermission,
            onTodos: { _ in }
        )

        do {
            let result = try await engine.run(messages: [], userText: prompt, sink: { _ in })
            let report: String
            if !result.finalText.isEmpty {
                report = result.finalText
            } else {
                report = "Subagent completed without a final report. Its tool work (if any) has already been applied in the workspace."
            }
            return ToolResult(output: "Subagent '\(desc)' finished.\n\n\(report)")
        } catch {
            return ToolResult(output: "Subagent '\(desc)' failed: \(error.localizedDescription)")
        }
    }

    static func subagentPrompt(workspace: URL, permissionPreset: PermissionPreset) -> String {
        """
        You are a focused subagent. Work autonomously: read and run tools as needed to answer \
        the task in the user message. Do not ask questions — make reasonable assumptions and \
        state them in your final answer. Keep your final answer concise and factual; it is \
        returned to the main agent, not to a human.
        Workspace: \(workspace.path)
        Permission preset: \(permissionPreset.rawValue). If a tool is denied, do not retry the \
        same action; note the limitation in your report instead.
        """
    }
}