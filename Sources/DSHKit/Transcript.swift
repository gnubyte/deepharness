import Foundation

/// One renderable item in a conversation.
public struct TranscriptItem: Identifiable, Sendable {
    public enum Kind: Sendable {
        case user
        case assistant
        case reasoning
        case toolCall(name: String)
        case toolResult(name: String)
        case notice
    }

    public let id: String
    public var kind: Kind
    public var text: String
    public var seq: Int
    /// True while deltas are still landing on this item.
    public var streaming: Bool
    /// Attachment ids referenced by this item, for lazy image fetch.
    public var attachmentIds: [String]
    /// Turn this item belongs to, so a turn's produced files can be shown with it.
    public var turn: Int

    public init(
        id: String,
        kind: Kind,
        text: String,
        seq: Int,
        streaming: Bool = false,
        attachmentIds: [String] = [],
        turn: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.seq = seq
        self.streaming = streaming
        self.attachmentIds = attachmentIds
        self.turn = turn
    }
}

/// Live token usage for the current turn.
public struct Usage: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
}

/// Folds the `session/event` stream into a renderable transcript.
///
/// The chunk vocabulary is the verified one: `block-start` opens a block,
/// `text-delta` appends to it, `block-end` seals it with the committed block,
/// `usage` reports tokens, and `finish` ends the model response. Committed
/// `assistant/message` events supersede streamed text, because the committed
/// form is authoritative and streamed deltas can be superseded by a retry.
public struct TranscriptAssembler: Sendable {
    public private(set) var items: [TranscriptItem] = []
    public private(set) var usage = Usage()
    public private(set) var running = false
    public private(set) var title: String?
    /// Set when the last turn ended abnormally, e.g. a provider error.
    public private(set) var lastError: String?

    /// Keyed by block index within the active step.
    private var openBlocks: [Int: String] = [:]
    /// callId → tool name, so a result can name the tool that produced it.
    private var toolNames: [String: String] = [:]
    /// callId → paths a pending mutation would change, promoted on success.
    private var pendingMutations: [String: [String]] = [:]
    /// turn → files successfully created or modified, first-seen order.
    private var producedByTurn: [Int: [String]] = [:]
    /// Render intent accompanying the event currently being applied.
    private var currentView: JSONValue?
    private var turn = 0
    private var step = 0

    public init() {}

    /// Record a host-side failure in the conversation.
    ///
    /// Agent errors arrive with no turn position, so they belong in the
    /// transcript where the user is already reading — not in a modal that
    /// interrupts and then discards the text.
    public mutating func pushNotice(_ message: String) {
        let seq = (items.last?.seq ?? 0) + 1
        items.append(TranscriptItem(
            id: "notice-\(seq)-\(message.hashValue)",
            kind: .notice,
            text: message,
            seq: seq
        ))
    }

    /// Apply one event as it arrives from either carrier.
    ///
    /// `session.history` wraps each event as `{event: …, view?: …}` while the
    /// mux stream delivers `event` and `view` as siblings on the frame. Both
    /// carriers supply the render intent, so unwrap and pass it through.
    public mutating func applyHistoryEntry(_ entry: JSONValue) {
        apply(event: entry["event"] ?? entry, view: entry["view"])
    }

    /// Files successfully created or modified during one turn, first-seen order.
    public func producedFiles(turn: Int) -> [String] {
        producedByTurn[turn] ?? []
    }

    /// The last turn that produced anything, for rendering a trailing row.
    public var turnsWithProducedFiles: [Int] {
        producedByTurn.keys.sorted()
    }

    public mutating func reset() {
        items = []
        usage = Usage()
        running = false
        title = nil
        lastError = nil
        openBlocks = [:]
        toolNames = [:]
        pendingMutations = [:]
        producedByTurn = [:]
        currentView = nil
    }

    /// Apply one `session/event` payload with its optional render intent.
    ///
    /// Unknown event types are ignored by design — the vocabulary grows
    /// upstream and an unknown event is not an error.
    public mutating func apply(event: JSONValue, view: JSONValue? = nil) {
        currentView = view
        defer { currentView = nil }
        applyEvent(event)
    }

    private mutating func applyEvent(_ event: JSONValue) {
        guard let type = event["type"]?.stringValue else { return }
        let seq = event["seq"]?.intValue ?? items.count
        let data = event["data"]

        switch type {
        case "turn/start":
            running = true
            lastError = nil
            turn = data?["turn"]?.intValue ?? (turn + 1)

        case "step/start":
            step = data?["step"]?.intValue ?? (step + 1)
            openBlocks = [:]

        case "user/message":
            // Only human-authored prompts render as user turns. The same event
            // carries runtime context injections (`agent-instructions`,
            // `plugin`, `skill-catalog`, …) that are model-visible but are not
            // something the person typed.
            let body = Self.messageBody(data)
            guard body["source"]?["kind"]?.stringValue == "user" else { break }
            let content = body["content"]?.arrayValue ?? []
            let text = Self.flattenText(content)
            let ids = Self.attachmentIds(content)
            // A user message may arrive both optimistically and from the log;
            // key on the durable message id so it lands once.
            let id = body["id"]?.stringValue ?? "user-\(seq)"
            upsert(TranscriptItem(id: id, kind: .user, text: text, seq: seq, attachmentIds: ids, turn: turn))

        case "assistant/chunk":
            applyChunk(data, seq: seq)

        case "assistant/message":
            // Committed form supersedes the streamed blocks for this step.
            let body = Self.messageBody(data)
            let content = body["content"]?.arrayValue ?? []
            let text = Self.flattenText(content)
            let ids = Self.attachmentIds(content)
            let id = body["id"]?.stringValue ?? "assistant-\(turn)-\(step)"
            let streamed = items.filter { $0.id.hasPrefix("stream-\(turn)-\(step)-") }
            // Keep the streamed item's position so the message does not jump to
            // the tail when the committed event arrives with a later seq.
            let anchor = streamed.map(\.seq).min() ?? seq
            items.removeAll { $0.id.hasPrefix("stream-\(turn)-\(step)-") }
            if !text.isEmpty || !ids.isEmpty {
                upsert(TranscriptItem(id: id, kind: .assistant, text: text, seq: anchor, attachmentIds: ids, turn: turn))
            }
            if let u = data?["usage"] {
                usage.inputTokens = u["inputTokens"]?.intValue ?? usage.inputTokens
                usage.outputTokens = u["outputTokens"]?.intValue ?? usage.outputTokens
            }
            openBlocks = [:]

        case "tool/call":
            let name = data?["name"]?.stringValue ?? "tool"
            let callId = data?["callId"]?.stringValue ?? "call-\(seq)"
            // `arguments` is a JSON *string* on the wire; pretty-print it so the
            // card is readable instead of one escaped line.
            let args = data?["arguments"]?.stringValue.map(Self.prettyJSON) ?? ""
            toolNames[callId] = name
            // Stage any files this call would change. They only count as
            // produced once the result comes back successful.
            let paths = Self.mutatedPaths(currentView)
            if !paths.isEmpty { pendingMutations[callId] = paths }
            upsert(TranscriptItem(id: callId, kind: .toolCall(name: name), text: args, seq: seq, turn: turn))

        case "tool/result":
            // The result nests under `data.message.content[]` as tool-result
            // blocks and carries no tool name, so correlate on the call id.
            let body = Self.messageBody(data)
            let blocks = body["content"]?.arrayValue ?? []
            let callId = blocks.compactMap { $0["toolCallId"]?.stringValue }.first
                ?? body.path("source", "callId")?.stringValue
            let name = callId.flatMap { toolNames[$0] } ?? "tool"
            let isError = blocks.contains { $0["isError"]?.boolValue == true }
            let text = blocks.flatMap { $0["content"]?.arrayValue ?? [] }
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: "\n")
            let id = callId.map { "\($0)-result" } ?? "result-\(seq)"

            // Only a successful mutation produces a file. Failed and cancelled
            // calls contribute nothing, and each path appears once per turn in
            // first-seen order.
            if let callId {
                let staged = pendingMutations.removeValue(forKey: callId) ?? []
                if !isError, !staged.isEmpty {
                    var produced = producedByTurn[turn] ?? []
                    for path in staged where !produced.contains(path) {
                        produced.append(path)
                    }
                    producedByTurn[turn] = produced
                }
            }

            upsert(TranscriptItem(
                id: id,
                kind: isError ? .notice : .toolResult(name: name),
                text: isError && !text.isEmpty ? "\(name): \(text)" : text,
                seq: seq,
                turn: turn
            ))

        case "session/title":
            title = data?["title"]?.stringValue ?? title

        case "step/end":
            openBlocks = [:]

        case "turn/end":
            running = false
            for (idx, _) in openBlocks { sealBlock(idx) }
            openBlocks = [:]
            if let reason = data?["reason"], reason["kind"]?.stringValue == "error" {
                lastError = reason.path("error", "message")?.stringValue ?? "the turn ended with an error"
                upsert(TranscriptItem(id: "error-\(turn)", kind: .notice, text: lastError!, seq: seq))
            }

        default:
            break
        }
    }

    // MARK: - Streaming chunks

    private mutating func applyChunk(_ data: JSONValue?, seq: Int) {
        guard let chunk = data?["chunk"], let kind = chunk["type"]?.stringValue else { return }
        let index = chunk["index"]?.intValue ?? 0

        switch kind {
        case "block-start":
            openBlocks[index] = ""
            let blockType = chunk["blockType"]?.stringValue ?? "text"
            upsert(TranscriptItem(
                id: streamId(index),
                kind: blockType == "thinking" ? .reasoning : .assistant,
                text: "",
                seq: seq,
                streaming: true,
                turn: turn
            ))

        case "text-delta":
            let delta = chunk["text"]?.stringValue ?? ""
            openBlocks[index, default: ""] += delta
            if let i = items.firstIndex(where: { $0.id == streamId(index) }) {
                items[i].text = openBlocks[index] ?? ""
            } else {
                upsert(TranscriptItem(id: streamId(index), kind: .assistant, text: delta, seq: seq, streaming: true, turn: turn))
            }

        case "block-end":
            // The sealed block carries the authoritative text for this block.
            if let text = chunk.path("block", "text")?.stringValue {
                openBlocks[index] = text
                if let i = items.firstIndex(where: { $0.id == streamId(index) }) {
                    items[i].text = text
                }
            }
            sealBlock(index)

        case "usage":
            usage.inputTokens = chunk.path("usage", "inputTokens")?.intValue ?? usage.inputTokens
            usage.outputTokens = chunk.path("usage", "outputTokens")?.intValue ?? usage.outputTokens

        case "finish":
            for (idx, _) in openBlocks { sealBlock(idx) }

        default:
            break
        }
    }

    private func streamId(_ index: Int) -> String { "stream-\(turn)-\(step)-\(index)" }

    private mutating func sealBlock(_ index: Int) {
        if let i = items.firstIndex(where: { $0.id == streamId(index) }) {
            items[i].streaming = false
        }
        openBlocks[index] = nil
    }

    private mutating func upsert(_ item: TranscriptItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
            items.sort { $0.seq < $1.seq }
        }
    }

    // MARK: - Content helpers

    /// Unwrap a message event's body.
    ///
    /// `assistant/message` nests the message under `data.message` while
    /// `user/message` carries its fields directly on `data`. Both shapes are
    /// live on the wire, so read through whichever one this event uses.
    static func messageBody(_ data: JSONValue?) -> JSONValue {
        guard let data else { return .object([:]) }
        return data["message"] ?? data
    }

    /// Paths a call would change, or none if it is not a mutation.
    ///
    /// A mutation is recognised by *render intent*, not tool name — a diff
    /// card, or a generic card declaring `kind: "edit"` — so a new mutation
    /// tool joins simply by declaring what it does. Reads and searches
    /// contribute nothing even though they also carry `locations`.
    static func mutatedPaths(_ intent: JSONValue?) -> [String] {
        guard let intent, intent["for"]?.stringValue == "call",
              let view = intent["view"] else { return [] }

        let isDiff = view["card"]?.stringValue == "diff"
        let isEdit = view["card"]?.stringValue == "generic" && view["kind"]?.stringValue == "edit"
        guard isDiff || isEdit else { return [] }

        var paths: [String] = []
        // A diff card's own file list is the most precise statement of what
        // changes; `locations` is the follow-along fallback.
        for diff in view["diffs"]?.arrayValue ?? [] {
            if let path = diff["path"]?.stringValue, !paths.contains(path) { paths.append(path) }
        }
        for location in view["locations"]?.arrayValue ?? [] {
            if let path = location["path"]?.stringValue, !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// Concatenate the text blocks of a core content array.
    static func flattenText(_ content: [JSONValue]) -> String {
        content.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }.joined()
    }

    /// Collect durable image attachment ids referenced by a content array.
    static func attachmentIds(_ content: [JSONValue]) -> [String] {
        content.compactMap { block -> String? in
            guard block["type"]?.stringValue == "image" else { return nil }
            return block.path("attachment", "id")?.stringValue
                ?? block.path("attachment", "attachmentId")?.stringValue
        }
    }

    static func compactJSON(_ value: JSONValue) -> String {
        if let s = value.stringValue { return s }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Re-indent a JSON string for display, leaving non-JSON text untouched.
    static func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return raw }
        return String(decoding: pretty, as: UTF8.self)
    }
}
