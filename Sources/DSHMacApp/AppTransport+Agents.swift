import Foundation
import DSHCore

// MARK: - Subagents across servers
//
// With more than one model server (say two DGX Sparks and Amazon Bedrock), the main model talks to the
// primary and hands side tasks to the other servers, so they run in parallel instead of queueing.

extension AppTransport {
    /// `/agents`: where subagents run and what is running.
    func agentsCommand(_ vm: SessionVM) {
        var lines: [String] = []
        let main = config.mainRoute
        let workers = workerRoutes
        if main == nil {
            lines.append("**Model servers:** none configured.")
        } else if workers.isEmpty {
            lines.append("**Model server:** subagents share the one server. Turn on “Use for subagents” for more routes in Settings › Models to spread them across machines.")
            if let main { lines.append("- 🖥 main **\(Self.routeLabel(main))** — \(main.model)") }
        } else {
            lines.append("**Model servers** (the main model handles the chat; subagents go to the other servers first):")
            if let main { lines.append("- 🖥 main **\(Self.routeLabel(main))** — \(main.model)") }
            for worker in workers {
                lines.append("- ⚙ subagents **\(Self.routeLabel(worker))** — \(worker.model), \(worker.subagentParallel ?? 2) at a time")
            }
        }
        vm.note(lines.joined(separator: "\n"))
    }
}
