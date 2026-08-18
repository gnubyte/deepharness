import Foundation
import DSHKit

// Headless smoke test: drives DSHKit against a live harness and prints what it
// observes. This is the transport's own verification, independent of any UI.

let base = URL(string: ProcessInfo.processInfo.environment["DSH_URL"] ?? "http://127.0.0.1:3099")!
let provider = ProcessInfo.processInfo.environment["DSH_PROVIDER"] ?? "ollama-local"
let model = ProcessInfo.processInfo.environment["DSH_MODEL"] ?? "qwen2.5:0.5b"

func log(_ s: String) { print(s); fflush(stdout) }

let api = APIClient(baseURL: base)

// 1. Unary reachability
let host = try await api.hostDescribe()
log("[1] host.describe -> version=\(host["version"]?.stringValue ?? "?") cwd=\(host["cwd"]?.stringValue ?? "?")")

// 2. Provider topology
let provs = try await api.providers()
let active = provs.filter { $0["active"]?.boolValue == true }.compactMap { $0["provider"]?.stringValue }
log("[2] llm.providers -> \(provs.count) total, active: \(active.joined(separator: ", "))")

// 3. Session lifecycle
let sessionId = try await api.sessionCreate()
log("[3] session.create -> \(sessionId)")

try await api.selectModel(sessionId, provider: provider, model: model)
log("[4] session.selectModel -> \(provider)/\(model)")

// 4. Open the mux stream and fold frames through the assembler
let stream = EventStream(baseURL: base, kind: .mux)
var assembler = TranscriptAssembler()
let done = SendableBox()

let consumer = Task {
    for await signal in await stream.signals() {
        switch signal {
        case .frame(let frame):
            guard frame.sessionId == sessionId else { continue }
            if frame.type == "session/event", let event = frame.event {
                assembler.apply(event: event)
                if event["type"]?.stringValue == "turn/end" { await done.set() }
            }
        case .reconnected:
            log("    [stream reconnected]")
        case .closed(let err):
            if let err { log("    [stream closed: \(err)]") }
            return
        }
    }
}

// Give the socket a moment to attach before prompting.
try await Task.sleep(nanoseconds: 700_000_000)
log("[5] mux stream open")

try await api.prompt(sessionId, content: [["type": "text", "text": "Say the single word: HELLO"]])
log("[6] session.prompt sent — streaming:")

let deadline = Date().addingTimeInterval(90)
var lastRendered = ""
while Date() < deadline, await !done.get() {
    try await Task.sleep(nanoseconds: 200_000_000)
    let live = assembler.items.filter { $0.streaming }.map(\.text).joined()
    if live != lastRendered, !live.isEmpty {
        lastRendered = live
        log("    …\(live.suffix(60).replacingOccurrences(of: "\n", with: "⏎"))")
    }
}
consumer.cancel()
await stream.stop()

log("\n=== RESULT ===")
log("running: \(assembler.running)  usage: in=\(assembler.usage.inputTokens) out=\(assembler.usage.outputTokens)")
if let t = assembler.title { log("title: \(t)") }
if let e = assembler.lastError { log("error: \(e)") }
for item in assembler.items {
    let tag: String
    switch item.kind {
    case .user: tag = "USER"
    case .assistant: tag = "ASSISTANT"
    case .reasoning: tag = "REASONING"
    case .toolCall(let n): tag = "TOOL→ \(n)"
    case .toolResult(let n): tag = "TOOL← \(n)"
    case .notice: tag = "NOTICE"
    }
    let body = item.text.replacingOccurrences(of: "\n", with: " ").prefix(140)
    log("  [\(item.seq)] \(tag): \(body)")
}
log("\nitems: \(assembler.items.count)")

/// Minimal actor box so the frame consumer can signal completion.
actor SendableBox {
    private var value = false
    func set() { value = true }
    func get() -> Bool { value }
}
