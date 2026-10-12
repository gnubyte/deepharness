import Foundation

// MARK: - The sensitive-data shield
//
// A transparent wrapper around the client of a route that isn't private. The engine, the UI and the saved chats
// never see anything different — placeholders exist only on the wire:
//  1. Outbound, in transcript order (the system prompt, then each message's text, tool results, the string values
//     inside earlier tool calls' arguments, the text of attached text files), every distinct sensitive value gets a
//     placeholder by order of first appearance: ⟦EMAIL_1⟧, ⟦SECRET_1⟧ … The same value always gets the same one
//     within a request, and because the transcript only grows, from one turn to the next as well (which keeps the
//     provider's prompt cache working) — so no mapping is stored anywhere.
//  2. A note at the end of the system prompt tells the model what the placeholders are.
//  3. Inbound, placeholders in text, reasoning and tool-call arguments become the real values again before
//     anything leaves the wrapper — inside JSON string values, with proper escaping.
//  4. Afterwards it reports how many values of each kind were masked (never the values themselves).

/// What was masked in one request.
public struct ShieldReport: Sendable, Equatable {
    /// The route it went to.
    public var route: String
    /// Distinct values masked, by kind.
    public var counts: [SensitiveCategory: Int]
    /// The request carried images, which can't be checked.
    public var images: Bool

    public init(route: String, counts: [SensitiveCategory: Int], images: Bool = false) {
        self.route = route
        self.counts = counts
        self.images = images
    }

    public var isEmpty: Bool { counts.values.allSatisfy { $0 == 0 } }

    /// "Masked 2 emails and 1 key before sending to Kimi Code"
    public var summary: String? {
        let parts = SensitiveCategory.allCases.compactMap { category in
            counts[category].flatMap { $0 > 0 ? category.counted($0) : nil }
        }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "Masked \(list) before sending to \(route)"
    }

    /// The kinds masked, for the chip's details ("Email addresses, Secrets and keys") — never the values.
    public var categories: String {
        var names: [String] = []
        for category in SensitiveCategory.allCases where (counts[category] ?? 0) > 0 {
            let name = category.settingName
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: ", ")
    }
}

/// The placeholders of one request: each distinct value has one, numbered per kind in order of first appearance.
public struct ShieldMap: Sendable, Equatable {
    private(set) var byValue: [String: String] = [:]
    private(set) var byPlaceholder: [String: String] = [:]
    private var next: [SensitiveCategory: Int] = [:]
    /// Distinct values, by kind.
    public private(set) var counts: [SensitiveCategory: Int] = [:]

    public init() {}

    public var isEmpty: Bool { byValue.isEmpty }

    /// The placeholder for `value`, made the first time it is seen.
    mutating func placeholder(_ value: String, _ category: SensitiveCategory) -> String {
        if let known = byValue[value] { return known }
        let n = (next[category] ?? 0) + 1
        next[category] = n
        counts[category, default: 0] += 1
        let placeholder = "⟦\(category.tag)_\(n)⟧"
        byValue[value] = placeholder
        byPlaceholder[placeholder] = value
        return placeholder
    }

    /// The real value behind a placeholder.
    public func value(of placeholder: String) -> String? { byPlaceholder[placeholder] }

    /// `text` with every known placeholder back to its value (unknown ones stay as they are).
    public func restore(_ text: String) -> String {
        guard !byPlaceholder.isEmpty, text.contains("⟦") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in SensitiveDetector.placeholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            guard let value = byPlaceholder[token] else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + value
            last = match.range.location + match.range.length
        }
        guard last > 0 else { return text }
        return out + ns.substring(from: last)
    }
}

/// Puts placeholders back in streamed text. Text arrives in pieces, so a trailing partial placeholder (`⟦EMA`) is
/// held back — at most 32 characters — until it completes or clearly isn't one; `flush` lets go of the rest.
public struct PlaceholderRestorer: Sendable {
    let map: ShieldMap
    private var pending = ""
    static let longest = 32

    public init(map: ShieldMap) { self.map = map }

    /// The text that can go out now.
    public mutating func feed(_ chunk: String) -> String {
        pending += chunk
        if let open = pending.lastIndex(of: "⟦") {
            let tail = pending[open...]
            if !tail.contains("⟧"), tail.count <= Self.longest, Self.couldBePlaceholder(tail) {
                let ready = String(pending[..<open])
                pending = String(tail)
                return map.restore(ready)
            }
        }
        let ready = pending
        pending = ""
        return map.restore(ready)
    }

    /// Whatever is still held back.
    public mutating func flush() -> String {
        let rest = pending
        pending = ""
        return map.restore(rest)
    }

    /// `⟦`, `⟦EM`, `⟦EMAIL_`, `⟦EMAIL_1` — the start of a placeholder.
    static func couldBePlaceholder(_ tail: Substring) -> Bool {
        var sawUnderscore = false
        for ch in tail.dropFirst() {
            if ch == "_" {
                if sawUnderscore { return false }
                sawUnderscore = true
            } else if sawUnderscore {
                guard ch.isASCII, ch.isNumber else { return false }
            } else {
                guard ch.isASCII, ch.isUppercase else { return false }
            }
        }
        return true
    }
}

public enum Shield {
    /// What the model is told about the placeholders.
    public static let note = "Privacy: some values in this conversation were replaced with placeholders such as ⟦EMAIL_1⟧ or ⟦SECRET_1⟧ before they reached you. Use a placeholder exactly as written wherever you need that value — in replies, code or tool calls — and the app puts the real value back on the user's computer. Don't ask for the real values and don't guess them."

    /// Matches already found in a text, by text (the transcript only grows, so most of it was seen before).
    public final class MatchCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [(NSRange, SensitiveCategory)]] = [:]
        private let limit: Int

        public init(limit: Int = 4_000) { self.limit = limit }

        func matches(_ text: String, _ detector: SensitiveDetector) -> [(NSRange, SensitiveCategory)] {
            if let hit = lock.withLock({ entries[text] }) { return hit }
            let found = detector.matches(in: text).map { (NSRange($0.range, in: text), $0.category) }
            lock.withLock {
                if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
                entries[text] = found
            }
            return found
        }
    }

    /// `text` with its sensitive values replaced, numbering through `map`.
    static func mask(_ text: String, _ detector: SensitiveDetector, _ map: inout ShieldMap, _ cache: MatchCache) -> String {
        guard !text.isEmpty else { return text }
        let found = cache.matches(text, detector)
        guard !found.isEmpty else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for (range, category) in found {
            out += ns.substring(with: NSRange(location: last, length: range.location - last))
            out += map.placeholder(ns.substring(with: range), category)
            last = range.location + range.length
        }
        return out + ns.substring(from: last)
    }

    /// Tool-call arguments with the sensitive values inside their string values replaced. The JSON is parsed and
    /// its string values rewritten (keys and everything else stay as they are); arguments that aren't JSON are
    /// masked as text.
    static func maskArguments(_ json: String, _ detector: SensitiveDetector, _ map: inout ShieldMap, _ cache: MatchCache) -> String {
        var local = map
        let rewritten = rewriteStringValues(json) { mask($0, detector, &local, cache) }
        if let rewritten {
            map = local
            return rewritten
        }
        return mask(json, detector, &map, cache)
    }

    /// Tool-call arguments with the placeholders back, inside JSON string values and escaped as JSON (quotes,
    /// backslashes, control characters). Arguments that aren't JSON get the values put back as text.
    public static func restoreArguments(_ json: String, _ map: ShieldMap) -> String {
        guard !map.isEmpty, json.contains("⟦") || json.contains("\\u27e6") || json.contains("\\u27E6") else { return json }
        return rewriteStringValues(json) { map.restore($0) } ?? map.restore(json)
    }

    /// Rewrite the decoded value of every JSON string that isn't an object key with `transform`, re-encoding the
    /// ones that changed; everything else is kept exactly. Nil when `json` isn't JSON.
    static func rewriteStringValues(_ json: String, _ transform: (String) -> String) -> String? {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        let scalars = Array(json.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "\"" else {
                out.append(scalar)
                i += 1
                continue
            }
            // A string literal, to its closing quote.
            var j = i + 1
            while j < scalars.count {
                if scalars[j] == "\\" { j += 2; continue }
                if scalars[j] == "\"" { break }
                j += 1
            }
            let end = min(j, scalars.count - 1)
            let literal = String(String.UnicodeScalarView(scalars[i...end]))
            // A key is followed by a colon.
            var k = end + 1
            while k < scalars.count, scalars[k] == " " || scalars[k] == "\t" || scalars[k] == "\n" || scalars[k] == "\r" { k += 1 }
            let isKey = k < scalars.count && scalars[k] == ":"
            if !isKey, let decoded = decodeLiteral(literal) {
                let changed = transform(decoded)
                if changed != decoded {
                    out.append(contentsOf: ("\"" + VaultPlaceholders.jsonEscaped(changed) + "\"").unicodeScalars)
                    i = end + 1
                    continue
                }
            }
            out.append(contentsOf: literal.unicodeScalars)
            i = end + 1
        }
        return String(out)
    }

    private static func decodeLiteral(_ literal: String) -> String? {
        guard let data = literal.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }

    /// A request with its sensitive values replaced and the note added — and the placeholders it used, and
    /// whether it carries images (which can't be checked).
    public static func mask(_ request: LLMRequest, detector: SensitiveDetector,
                            cache: MatchCache = MatchCache()) -> (request: LLMRequest, map: ShieldMap, images: Bool) {
        var map = ShieldMap()
        var images = false
        let system = mask(request.systemPrompt, detector, &map, cache)
        var messages: [LLMMessage] = []
        messages.reserveCapacity(request.messages.count)
        for original in request.messages {
            var message = original
            if let content = message.content { message.content = mask(content, detector, &map, cache) }
            if let calls = message.toolCalls {
                message.toolCalls = calls.map { call in
                    ToolCall(id: call.id, name: call.name, arguments: maskArguments(call.arguments.raw, detector, &map, cache))
                }
            }
            if let attachments = message.attachments {
                message.attachments = attachments.map { attachment in
                    switch attachment.kind {
                    case .image:
                        images = true
                        return attachment
                    case .file:
                        // A text file is checked like any text; anything else goes as it is.
                        guard let text = String(data: attachment.data, encoding: .utf8) else { return attachment }
                        return MessageAttachment(kind: .file, name: attachment.name,
                                                 data: Data(mask(text, detector, &map, cache).utf8))
                    }
                }
            }
            messages.append(message)
        }
        // The note, once, at the end of the first system message.
        var prompt = system
        if !prompt.contains(note) {
            if !prompt.isEmpty {
                prompt += "\n\n" + note
            } else if let first = messages.firstIndex(where: { $0.role == .system }) {
                if !(messages[first].content ?? "").contains(note) {
                    messages[first].content = (messages[first].content ?? "") + "\n\n" + note
                }
            } else {
                prompt = note
            }
        }
        let masked = LLMRequest(systemPrompt: prompt, messages: messages, tools: request.tools, model: request.model,
                                temperature: request.temperature, maxTokens: request.maxTokens, thinking: request.thinking)
        return (masked, map, images)
    }
}

/// Who decides about masking: the user's settings and the vault's secrets, read when a client is made. The app
/// keeps it current; nil (`ProviderClients.shield` unset) means no masking at all (the engine's own tests).
public final class ShieldPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: ShieldSettings
    private let vaultValues: @Sendable () -> [String]

    public init(settings: ShieldSettings = ShieldSettings(), vaultValues: @escaping @Sendable () -> [String] = { [] }) {
        self.settings = settings
        self.vaultValues = vaultValues
    }

    public var current: ShieldSettings {
        get { lock.withLock { settings } }
        set { lock.withLock { settings = newValue } }
    }

    /// What to look for now; nil when there is nothing (the switch is off and the vault is empty).
    public func detector() -> SensitiveDetector? {
        let detector = SensitiveDetector(settings: current, vaultValues: vaultValues())
        return detector.isActive ? detector : nil
    }
}

/// The wrapper itself (see the top of this file).
public struct ShieldClient: ProviderClient {
    public let inner: any ProviderClient
    public let detector: SensitiveDetector
    private let onReport: (@Sendable (ShieldReport) -> Void)?
    private let cache: Shield.MatchCache

    public init(inner: any ProviderClient, detector: SensitiveDetector,
                onReport: (@Sendable (ShieldReport) -> Void)? = nil) {
        self.inner = inner
        self.detector = detector
        self.onReport = onReport
        self.cache = Shield.MatchCache()
    }

    public var profile: ProviderProfile { inner.profile }

    public func listModels() async throws -> [String] { try await inner.listModels() }

    public func modelInfo(_ model: String?) async -> ModelInfo? { await inner.modelInfo(model) }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let (masked, map, images) = Shield.mask(request, detector: detector, cache: cache)
        let inner = self.inner, report = self.onReport
        let route = inner.profile.name.isEmpty ? inner.profile.model : inner.profile.name
        return AsyncThrowingStream { continuation in
            let task = Task {
                var text = PlaceholderRestorer(map: map)
                var reasoning = PlaceholderRestorer(map: map)
                func flushHeld() {
                    let t = text.flush()
                    if !t.isEmpty { continuation.yield(.text(t)) }
                    let r = reasoning.flush()
                    if !r.isEmpty { continuation.yield(.reasoning(r)) }
                }
                do {
                    for try await event in inner.stream(masked) {
                        switch event {
                        case .text(let delta):
                            let out = text.feed(delta)
                            if !out.isEmpty { continuation.yield(.text(out)) }
                        case .reasoning(let delta):
                            let out = reasoning.feed(delta)
                            if !out.isEmpty { continuation.yield(.reasoning(out)) }
                        case .done(let calls, let finish, let usage, let state):
                            flushHeld()
                            let restored = calls.map { call in
                                ToolCall(id: call.id, name: call.name, arguments: Shield.restoreArguments(call.arguments.raw, map))
                            }
                            if !map.isEmpty || images {
                                report?(ShieldReport(route: route, counts: map.counts, images: images))
                            }
                            continuation.yield(.done(calls: restored, finish: finish, usage: usage, providerState: state))
                        }
                    }
                    flushHeld()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
