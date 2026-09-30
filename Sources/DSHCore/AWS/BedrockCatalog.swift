import Foundation

// MARK: - Models

/// A Bedrock model the app can chat with.
///
/// - `modelID`: the base model id ("anthropic.claude-sonnet-4-5-20250929-v1:0"); access checks use it.
/// - `invokeID`: what to send as the model when chatting: `modelID` for on-demand models, else an
///   inference profile id ("us.anthropic…"); nil when it can't be called in this Region.
/// - `lifecycle`: "ACTIVE" (only those are listed).
/// - `recommended`: the newest of a family the app suggests for coding (Claude Sonnet, Opus, Haiku,
///   Nova Pro, Llama, Mistral, DeepSeek, Qwen, gpt-oss).
public struct BedrockModel: Identifiable, Hashable, Sendable {
    public var modelID: String
    public var name: String
    public var provider: String
    public var inputModalities: [String]
    public var streaming: Bool
    public var lifecycle: String
    public var inferenceTypes: [String]
    public var invokeID: String?
    public var recommended: Bool

    public init(modelID: String, name: String, provider: String, inputModalities: [String], streaming: Bool,
                lifecycle: String, inferenceTypes: [String], invokeID: String?, recommended: Bool = false) {
        self.modelID = modelID
        self.name = name
        self.provider = provider
        self.inputModalities = inputModalities
        self.streaming = streaming
        self.lifecycle = lifecycle
        self.inferenceTypes = inferenceTypes
        self.invokeID = invokeID
        self.recommended = recommended
    }

    public var id: String { modelID }

    public var acceptsImages: Bool { inputModalities.contains { BedrockText.equals($0, "IMAGE") } }

    public var canInvoke: Bool { invokeID != nil }

    /// Called through a cross-Region inference profile rather than by its own id.
    public var usesInferenceProfile: Bool { invokeID != nil && invokeID != modelID }

    /// Anthropic models need the one-time use-case form.
    public var isAnthropic: Bool {
        BedrockText.hasPrefix(modelID, "anthropic.", ignoringCase: true) || BedrockText.equals(provider, "Anthropic")
    }

    /// "Claude Sonnet 4.5 (Anthropic)".
    public var displayName: String { provider.isEmpty ? name : "\(name) (\(provider))" }
}

// MARK: - The catalog

/// Turning the CLI's model and inference-profile listings into `BedrockModel`s.
public enum BedrockCatalog {
    private struct Profile {
        var id: String
        var prefix: String
        var modelIDs: Set<String>
    }

    /// Model families to suggest, in the order shown. Newest of each is "recommended".
    private static let families: [(family: String, pattern: NSRegularExpression)] = [
        ("Claude Sonnet", regex(#"^anthropic\.claude-(?:[\d-]+-)?sonnet"#)),
        ("Claude Opus", regex(#"^anthropic\.claude-(?:[\d-]+-)?opus"#)),
        ("Claude Haiku", regex(#"^anthropic\.claude-(?:[\d-]+-)?haiku"#)),
        ("Amazon Nova Pro", regex(#"^amazon\.nova-(?:\d+-)?pro"#)),
        ("Llama", regex(#"^meta\.llama"#)),
        ("Mistral", regex(#"^mistral\."#)),
        ("DeepSeek", regex(#"^deepseek\."#)),
        ("Qwen", regex(#"^qwen\."#)),
        ("gpt-oss", regex(#"^openai\.gpt-oss"#)),
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants above; one that doesn't compile is a bug caught by the first test run.
        try! NSRegularExpression(pattern: pattern)
    }

    /// Build the model list from `bedrock list-foundation-models` and `bedrock list-inference-profiles`
    /// output: ACTIVE models that stream text, each with the id to call it by in `region`. Variants that
    /// only run on provisioned throughput (and no profile covers) are left out. Sorted: callable first,
    /// then the suggested families, then by provider and name.
    public static func build(foundationModels: JSONValue?, inferenceProfiles: JSONValue?, region: String) -> [BedrockModel] {
        let profiles = parseProfiles(inferenceProfiles)
        var models: [BedrockModel] = []
        for node in foundationModels?["modelSummaries"]?.array ?? [] {
            guard node.object != nil, let id = BedrockJSON.string(node, "modelId"), !id.isEmpty else { continue }
            var lifecycle = ""
            if let life = node["modelLifecycle"], life.object != nil { lifecycle = BedrockJSON.string(life, "status") ?? "" }
            let outputs = BedrockJSON.strings(node["outputModalities"])
            let streaming = BedrockJSON.bool(node, "responseStreamingSupported", default: false)
            guard BedrockText.equals(lifecycle, "ACTIVE"), streaming,
                  outputs.contains(where: { BedrockText.equals($0, "TEXT") }) else { continue }
            let inference = BedrockJSON.strings(node["inferenceTypesSupported"])
            let invokeID = chooseInvokeID(modelID: id, inferenceTypes: inference, profiles: profiles, region: region)
            // Provisioned throughput needs a purchase the app can't make; nothing else could carry the call.
            if invokeID == nil, !inference.isEmpty, inference.allSatisfy({ BedrockText.equals($0, "PROVISIONED") }) { continue }
            models.append(BedrockModel(
                modelID: id, name: BedrockJSON.string(node, "modelName") ?? id,
                provider: BedrockJSON.string(node, "providerName") ?? "",
                inputModalities: BedrockJSON.strings(node["inputModalities"]), streaming: streaming,
                lifecycle: lifecycle.uppercased(), inferenceTypes: inference, invokeID: invokeID))
        }

        // The newest callable model of each family is recommended (a tie goes to the one listed first).
        var newest: [Int: BedrockModel] = [:]
        for model in models where model.canInvoke {
            let family = familyIndex(model.modelID)
            guard family < families.count else { continue }
            if let best = newest[family], RecencyComparer.compare(model.modelID, best.modelID) <= 0 { continue }
            newest[family] = model
        }
        let recommended = Set(newest.values.map(\.modelID))

        struct Row {
            var model: BedrockModel
            var index: Int
            var family: Int
        }
        let rows = models.enumerated().map { index, model -> Row in
            var model = model
            if recommended.contains(model.modelID) { model.recommended = true }
            return Row(model: model, index: index, family: familyIndex(model.modelID))
        }
        // The chain of keys, ending in the listing position so the order is total (a stable sort).
        func precedes(_ a: Row, _ b: Row) -> Bool {
            if a.model.canInvoke != b.model.canInvoke { return a.model.canInvoke }
            if a.model.recommended != b.model.recommended { return a.model.recommended }
            if a.family != b.family { return a.family < b.family }
            let recency = RecencyComparer.compare(a.model.modelID, b.model.modelID)
            if recency != 0 { return recency > 0 }
            let provider = BedrockText.compareIgnoringCase(a.model.provider, b.model.provider)
            if provider != 0 { return provider < 0 }
            let name = BedrockText.compareIgnoringCase(a.model.name, b.model.name)
            if name != 0 { return name < 0 }
            return a.index < b.index
        }
        return rows.sorted(by: precedes).map(\.model)
    }

    /// The id to call `modelID` by in `region`: itself when it supports on-demand calls, else the system
    /// inference profile for it whose prefix comes first in `BedrockRegions.profilePrefixes(for:)` (any
    /// other listed one after those), else nil.
    public static func chooseInvokeID(modelID: String, inferenceTypes: [String], inferenceProfiles: JSONValue?,
                                      region: String) -> String? {
        chooseInvokeID(modelID: modelID, inferenceTypes: inferenceTypes, profiles: parseProfiles(inferenceProfiles),
                       region: region)
    }

    private static func chooseInvokeID(modelID: String, inferenceTypes: [String], profiles: [Profile],
                                       region: String) -> String? {
        if inferenceTypes.contains(where: { BedrockText.equals($0, "ON_DEMAND") }) { return modelID }
        let preferred = BedrockRegions.profilePrefixes(for: region)
        var best: (rank: Int, id: String)?
        for profile in profiles where profile.modelIDs.contains(modelID) || BedrockText.hasSuffix(profile.id, "." + modelID) {
            // A prefix nearer the front of the preference list wins; unlisted prefixes come after all of them,
            // and among equals the profile listed first.
            let rank = preferred.firstIndex(of: profile.prefix) ?? preferred.count
            if best == nil || rank < best!.rank { best = (rank, profile.id) }
        }
        return best?.id
    }

    private static func parseProfiles(_ inferenceProfiles: JSONValue?) -> [Profile] {
        var list: [Profile] = []
        for node in inferenceProfiles?["inferenceProfileSummaries"]?.array ?? [] {
            guard node.object != nil, let id = BedrockJSON.string(node, "inferenceProfileId"), !id.isEmpty else { continue }
            // Profiles the user made themselves (APPLICATION) or that aren't usable aren't system routes.
            if let status = BedrockJSON.string(node, "status"), !BedrockText.equals(status, "ACTIVE") { continue }
            if let type = BedrockJSON.string(node, "type"), !BedrockText.equals(type, "SYSTEM_DEFINED") { continue }
            var modelIDs = Set<String>()
            for model in node["models"]?.array ?? [] {
                if let arn = BedrockJSON.string(model, "modelArn"), let range = arn.range(of: "foundation-model/", options: .literal) {
                    modelIDs.insert(String(arn[range.upperBound...]))
                }
            }
            let scalars = id.unicodeScalars
            var prefix = ""
            if let dot = scalars.firstIndex(of: "."), dot != scalars.startIndex { prefix = String(scalars[..<dot]) }
            list.append(Profile(id: id, prefix: prefix, modelIDs: modelIDs))
        }
        return list
    }

    // MARK: Families

    /// Where a model sits in `families`; `families.count` for one that isn't in any.
    static func familyIndex(_ modelID: String) -> Int {
        let range = NSRange(location: 0, length: (modelID as NSString).length)
        for (index, entry) in families.enumerated() where entry.pattern.firstMatch(in: modelID, options: [], range: range) != nil {
            return index
        }
        return families.count
    }

    /// The family a model belongs to ("Claude Sonnet"), or nil.
    public static func familyOf(_ modelID: String) -> String? {
        let index = familyIndex(modelID)
        return index < families.count ? families[index].family : nil
    }

    // MARK: Recency

    /// Orders model ids oldest to newest within a family: first the version numbers in the name
    /// (claude-sonnet-4-5 is 4.5, newer than claude-sonnet-4 and claude-3-7-sonnet), then the release
    /// date (YYYYMMDD), then the "-v2" revision.
    public enum RecencyComparer {
        struct Key: Equatable {
            var version: [Int64]
            var date: Int64
            var revision: Int64
        }

        /// Negative when `x` is older than `y`, zero when they rank alike, positive when `x` is newer.
        public static func compare(_ x: String, _ y: String) -> Int {
            let a = key(x), b = key(y)
            for i in 0..<max(a.version.count, b.version.count) {
                let left = i < a.version.count ? a.version[i] : 0
                let right = i < b.version.count ? b.version[i] : 0
                if left != right { return left < right ? -1 : 1 }
            }
            if a.date != b.date { return a.date < b.date ? -1 : 1 }
            if a.revision != b.revision { return a.revision < b.revision ? -1 : 1 }
            return 0
        }

        /// "-v1:0" or "-1:0" at the end.
        private static let suffix = BedrockCatalog.regex(#"-v?(\d+)(?::[0-9a-z]+)*$"#)
        private static let number = BedrockCatalog.regex(#"\d+"#)

        static func key(_ modelID: String) -> Key {
            // The provider ("anthropic.", or a profile's "us.anthropic.") says nothing about recency.
            var id = modelID
            let scalars = modelID.unicodeScalars
            if let dot = scalars.firstIndex(of: ".") { id = String(scalars[scalars.index(after: dot)...]) }

            var revision: Int64 = 0
            var text = id as NSString
            if let match = suffix.firstMatch(in: id, options: [], range: NSRange(location: 0, length: text.length)) {
                revision = integer(text.substring(with: match.range(at: 1))) ?? 0
                id = text.substring(to: match.range.location)
                text = id as NSString
            }
            var date: Int64 = 0
            var version: [Int64] = []
            for match in number.matches(in: id, options: [], range: NSRange(location: 0, length: text.length)) {
                let digits = text.substring(with: match.range)
                guard let n = integer(digits) else { continue }
                if digits.utf8.count == 8 && digits.hasPrefix("20") {
                    date = n
                } else if date == 0 {
                    version.append(n)
                }
            }
            return Key(version: version, date: date, revision: revision)
        }

        /// Plain ASCII digits that fit an Int64 (a digit sequence of any other script, or one too long, is skipped).
        private static func integer(_ digits: String) -> Int64? {
            digits.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } ? Int64(digits) : nil
        }
    }
}

// MARK: - Reading the CLI's JSON

/// Readers for the CLI's JSON that are lenient the way the rest of the app's argument readers are
/// (models and the CLI print "true" and "10" as strings often enough that refusing them only costs a
/// retry): a value of the wrong type reads as missing.
enum BedrockJSON {
    /// The string at `key`; nil when it is missing or not a JSON string (a number is not turned into text).
    static func string(_ node: JSONValue?, _ key: String) -> String? {
        node?[key]?.string
    }

    /// A JSON boolean, or the text "true"/"yes"/"1" and "false"/"no"/"0" (any case), else `default`.
    static func bool(_ node: JSONValue?, _ key: String, default fallback: Bool) -> Bool {
        guard let value = node?[key] else { return fallback }
        if let flag = value.bool { return flag }
        if let text = value.string {
            switch BedrockText.trimmed(text).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: break
            }
        }
        return fallback
    }

    /// A whole JSON number that fits an Int32, or such a number written as text (" 2 ", "+2"), else `default`.
    static func int(_ node: JSONValue?, _ key: String, default fallback: Int) -> Int {
        guard let value = node?[key] else { return fallback }
        if case .number(let number) = value {
            if number.rounded() == number, number >= Double(Int32.min), number <= Double(Int32.max) { return Int(number) }
            return fallback
        }
        if let text = value.string, let n = Int32(BedrockText.trimmed(text)) { return Int(n) }
        return fallback
    }

    /// The string elements of an array (other elements, and a non-array, give nothing).
    static func strings(_ node: JSONValue?) -> [String] {
        (node?.array ?? []).compactMap(\.string)
    }
}

// MARK: - Text the way the C# app compared it

/// String comparisons that ignore how Swift would normally treat Unicode equivalence: the setup
/// layer matches ids and statuses from AWS the way the Windows app does (ordinal, or ordinal ignoring
/// case), and trims what people type the way .NET's `Trim()` does.
enum BedrockText {
    /// Both ends without white space as .NET's `string.Trim()` sees it (`char.IsWhiteSpace`): U+0009–U+000D,
    /// U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F and U+3000. (Not
    /// `CharacterSet.whitespacesAndNewlines`, which also strips the zero-width space U+200B.)
    static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhiteSpace($0) }),
              let last = scalars.lastIndex(where: { !isWhiteSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    static func isWhiteSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// .NET's `string.IsNullOrWhiteSpace`.
    static func isBlank(_ text: String?) -> Bool {
        guard let text else { return true }
        return trimmed(text).isEmpty
    }

    /// `StringComparison.OrdinalIgnoreCase` equality.
    static func equals(_ a: String, _ b: String) -> Bool {
        compareIgnoringCase(a, b) == 0
    }

    /// `OrdinalIgnoreCase` ordering: compare the upper-cased UTF-16 code units (so "_" sorts after letters).
    static func compareIgnoringCase(_ a: String, _ b: String) -> Int {
        var left = upperCased(a).makeIterator()
        var right = upperCased(b).makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (x?, y?):
                if x != y { return x < y ? -1 : 1 }
            }
        }
    }

    static func hasPrefix(_ text: String, _ prefix: String, ignoringCase: Bool = false) -> Bool {
        if ignoringCase { return upperCased(text).starts(with: upperCased(prefix)) }
        return text.utf8.starts(with: prefix.utf8)
    }

    /// The UTF-16 code units of `text` upper-cased one character at a time, as .NET's ordinal
    /// comparisons do: a letter whose upper case is more than one character (ß) stays as it is.
    private static func upperCased(_ text: String) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                let v = UInt16(scalar.value)
                out.append(v >= 0x61 && v <= 0x7A ? v - 0x20 : v)
                continue
            }
            let mapped = scalar.properties.uppercaseMapping.unicodeScalars
            out.append(contentsOf: String(mapped.count == 1 ? mapped.first! : scalar).utf16)
        }
        return out
    }

    /// Ordinal `EndsWith`.
    static func hasSuffix(_ text: String, _ suffix: String) -> Bool {
        text.utf8.reversed().starts(with: suffix.utf8.reversed())
    }
}
