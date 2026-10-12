import Foundation

// MARK: - Sensitive data: what counts, and finding it
//
// Before a request goes to a model that isn't private (an online service), the values that would identify a
// person or open a door — keys and passwords, email addresses, phone numbers, ID and card numbers, IP addresses
// (off by default), the user's own custom terms (client names, project code names), and every secret in the
// Credentials Vault — are replaced with placeholders such as ⟦EMAIL_1⟧. `ShieldClient` does the replacing; this
// file says what to look for. The Windows app has the same detectors, checked by the same test cases.

/// A kind of sensitive value, and the label its placeholders carry.
public enum SensitiveCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case secret, email, phone, id, card, ip, term

    /// "SECRET" in ⟦SECRET_1⟧.
    public var tag: String {
        switch self {
        case .secret: "SECRET"
        case .email: "EMAIL"
        case .phone: "PHONE"
        case .id: "ID"
        case .card: "CARD"
        case .ip: "IP"
        case .term: "TERM"
        }
    }

    init?(tag: String) {
        guard let found = Self.allCases.first(where: { $0.tag == tag }) else { return nil }
        self = found
    }

    /// "1 key", "2 emails", "3 phone numbers".
    public func counted(_ n: Int) -> String {
        let (one, many): (String, String) = switch self {
        case .secret: ("key", "keys")
        case .email: ("email", "emails")
        case .phone: ("phone number", "phone numbers")
        case .id: ("ID number", "ID numbers")
        case .card: ("card number", "card numbers")
        case .ip: ("IP address", "IP addresses")
        case .term: ("custom term", "custom terms")
        }
        return "\(n) \(n == 1 ? one : many)"
    }

    /// The setting's name ("Secrets and keys").
    public var settingName: String {
        switch self {
        case .secret: "Secrets and keys"
        case .email: "Email addresses"
        case .phone: "Phone numbers"
        case .id, .card: "ID and card numbers"
        case .ip: "IP addresses"
        case .term: "Custom terms"
        }
    }
}

/// What the user chose in Settings ▸ AI Models ▸ Sensitive data.
public struct ShieldSettings: Codable, Sendable, Equatable {
    /// "Mask sensitive data before sending it to models that aren't private."
    public var enabled = true
    public var secrets = true
    public var emails = true
    public var phones = true
    /// ID and card numbers.
    public var ids = true
    public var ips = false
    public var terms = true
    /// One per line: client names, patient names, project code names (case-insensitive, whole words); a line
    /// starting with `re:` is a regular expression.
    public var customTerms: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every field optional, so a settings file from a later build (or an earlier one) still loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ShieldSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        secrets = try c.decodeIfPresent(Bool.self, forKey: .secrets) ?? defaults.secrets
        emails = try c.decodeIfPresent(Bool.self, forKey: .emails) ?? defaults.emails
        phones = try c.decodeIfPresent(Bool.self, forKey: .phones) ?? defaults.phones
        ids = try c.decodeIfPresent(Bool.self, forKey: .ids) ?? defaults.ids
        ips = try c.decodeIfPresent(Bool.self, forKey: .ips) ?? defaults.ips
        terms = try c.decodeIfPresent(Bool.self, forKey: .terms) ?? defaults.terms
        customTerms = try c.decodeIfPresent([String].self, forKey: .customTerms) ?? []
    }

    /// Whether a category is switched on.
    public func isOn(_ category: SensitiveCategory) -> Bool {
        switch category {
        case .secret: secrets
        case .email: emails
        case .phone: phones
        case .id, .card: ids
        case .ip: ips
        case .term: terms
        }
    }
}

/// One sensitive value found in a text.
public struct SensitiveMatch: Equatable, Sendable {
    public var range: Range<String.Index>
    public var category: SensitiveCategory
}

/// Finds sensitive values in text. Built from the settings and the vault's secrets; thread-safe.
public struct SensitiveDetector: Sendable {
    public let settings: ShieldSettings
    /// The vault's values: always masked, whatever the switches say.
    public let vaultValues: [String]
    private let customPatterns: [NSRegularExpression]

    public init(settings: ShieldSettings, vaultValues: [String] = []) {
        self.settings = settings
        self.vaultValues = Array(Set(vaultValues.filter { $0.count >= 4 })).sorted { $0.count > $1.count }
        var patterns: [NSRegularExpression] = []
        if settings.enabled && settings.terms {
            for line in settings.customTerms {
                let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty else { continue }
                if term.lowercased().hasPrefix("re:") {
                    let source = String(term.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if !source.isEmpty, let regex = try? NSRegularExpression(pattern: source) { patterns.append(regex) }
                } else {
                    let escaped = NSRegularExpression.escapedPattern(for: term)
                    if let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])",
                                                            options: [.caseInsensitive]) {
                        patterns.append(regex)
                    }
                }
            }
        }
        customPatterns = patterns
    }

    /// Whether there is anything to look for.
    public var isActive: Bool { settings.enabled || !vaultValues.isEmpty }

    // MARK: Patterns

    private struct Pattern {
        let regex: NSRegularExpression
        let category: SensitiveCategory
        /// The capture group holding the value (0 = the whole match).
        var group = 0
        /// Extra check on the value (Luhn, mod-97, not a placeholder…).
        var accept: (@Sendable (String) -> Bool)? = nil
    }

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let secretPatterns: [Pattern] = [
        // A private key, header to footer (or to the end of a text that cuts it off).
        Pattern(regex: re(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#), category: .secret),
        Pattern(regex: re(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#), category: .secret),
        Pattern(regex: re(#"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#), category: .secret),
        Pattern(regex: re(#"\bgithub_pat_[A-Za-z0-9_]{60,}\b"#), category: .secret),
        Pattern(regex: re(#"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}\b"#), category: .secret),
        Pattern(regex: re(#"\bsk-ant-[A-Za-z0-9_\-]{20,}\b"#), category: .secret),
        Pattern(regex: re(#"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#), category: .secret),
        Pattern(regex: re(#"\bAIza[0-9A-Za-z_\-]{35}\b"#), category: .secret),
        Pattern(regex: re(#"\b[rs]k_(?:live|test)_[0-9A-Za-z]{16,}\b"#), category: .secret),
        Pattern(regex: re(#"\bsst_[0-9a-f]{8}_[A-Za-z0-9_\-]{20,}\b"#), category: .secret),
        Pattern(regex: re(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#), category: .secret),
        // Bearer <token>: the token.
        Pattern(regex: re(#"\bBearer\s+([A-Za-z0-9._~+/=\-]{16,})"#, [.caseInsensitive]), category: .secret, group: 1),
        // scheme://user:PASSWORD@host: the password.
        Pattern(regex: re(#"\b[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]+:([^\s/]+)@[A-Za-z0-9\[]"#), category: .secret, group: 1,
                accept: { !SensitiveDetector.isPlaceholderValue($0) }),
        // password = …, api_key: "…", "token": "…": the value.
        Pattern(regex: re(#"(password|passwd|pwd|secret|api[_-]?key|token|access[_-]?key)["']?\s*[:=]\s*["']?([^\s"']{6,})"#, [.caseInsensitive]),
                category: .secret, group: 2, accept: { !SensitiveDetector.isPlaceholderValue($0) }),
    ]

    private static let emailPattern = Pattern(regex: re(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#), category: .email)

    private static let phonePatterns: [Pattern] = [
        // E.164
        Pattern(regex: re(#"(?<![\w+])\+[1-9]\d{7,14}(?!\d)"#), category: .phone),
        // North American, with at least one separator (a plain run of digits in code isn't a phone number).
        Pattern(regex: re(#"(?<![\w(])\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4}(?!\d)"#), category: .phone),
    ]

    private static let idPatterns: [Pattern] = [
        // US Social Security number
        Pattern(regex: re(#"\b\d{3}-\d{2}-\d{4}\b"#), category: .id),
        // IBAN, with a valid check
        Pattern(regex: re(#"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#), category: .id, accept: { SensitiveDetector.ibanIsValid($0) }),
        // A card number: 13–19 digits, single spaces or dashes between them allowed, only when Luhn says so.
        Pattern(regex: re(#"(?<![\d\-])\d(?:[ \-]?\d){12,18}(?![\d])"#), category: .card, accept: { SensitiveDetector.isCardNumber($0) }),
    ]

    private static let ipPattern = Pattern(regex: re(#"(?<![vV\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\d])(?!\.\d)"#), category: .ip,
                                           accept: { SensitiveDetector.isMaskableIPv4($0) })

    /// Placeholders already in a text: never matched inside.
    static let placeholderRegex = re(#"⟦[A-Z]+_\d+⟧"#)

    // MARK: Finding

    /// The sensitive values in `text`, in order, never overlapping: where detectors overlap the longest match wins,
    /// and nothing inside an existing placeholder counts.
    public func matches(in text: String) -> [SensitiveMatch] {
        guard isActive, !text.isEmpty else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var candidates: [(range: NSRange, category: SensitiveCategory)] = []

        func run(_ pattern: Pattern) {
            for match in pattern.regex.matches(in: text, range: whole) {
                let range = match.range(at: pattern.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                if let accept = pattern.accept, !accept(ns.substring(with: range)) { continue }
                candidates.append((range, pattern.category))
            }
        }

        // The vault's secrets: exact values, always.
        for value in vaultValues {
            var search = whole
            while search.length > 0 {
                let found = ns.range(of: value, options: [.literal], range: search)
                guard found.location != NSNotFound else { break }
                candidates.append((found, .secret))
                let next = found.location + found.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        if settings.enabled {
            if settings.secrets { Self.secretPatterns.forEach(run) }
            if settings.emails { run(Self.emailPattern) }
            if settings.phones { Self.phonePatterns.forEach(run) }
            if settings.ids { Self.idPatterns.forEach(run) }
            if settings.ips { run(Self.ipPattern) }
            if settings.terms {
                for regex in customPatterns { run(Pattern(regex: regex, category: .term)) }
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Existing placeholders are off limits.
        let taken = Self.placeholderRegex.matches(in: text, range: whole).map(\.range)
        // Longest first; then earliest. Where matches overlap the longest one wins — and covers the others too, so
        // no part of anything detected is left showing (a password in a URL that also reads as an email address).
        candidates.sort { $0.range.length != $1.range.length ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
        var chosen: [(range: NSRange, category: SensitiveCategory)] = []
        for candidate in candidates {
            if taken.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 }) { continue }
            if let i = chosen.firstIndex(where: { NSIntersectionRange($0.range, candidate.range).length > 0 }) {
                chosen[i].range = NSUnionRange(chosen[i].range, candidate.range)
            } else {
                chosen.append(candidate)
            }
        }
        chosen.sort { $0.range.location < $1.range.location }
        // A match that grew may now reach the next one: join them (the earlier, longer one names the kind).
        var joined: [(range: NSRange, category: SensitiveCategory)] = []
        for item in chosen {
            if let last = joined.last, NSIntersectionRange(last.range, item.range).length > 0 {
                joined[joined.count - 1].range = NSUnionRange(last.range, item.range)
            } else {
                joined.append(item)
            }
        }
        chosen = joined
        return chosen.compactMap { item in
            Range(item.range, in: text).map { SensitiveMatch(range: $0, category: item.category) }
        }
    }

    // MARK: Checks

    /// A value that stands in for a secret rather than being one: `***`, `<your key>`, `${TOKEN}`, `xxxx`,
    /// `changeme`, `your-api-key`, a vault placeholder, a call.
    static func isPlaceholderValue(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;)"))
        let lower = value.lowercased()
        if value.isEmpty { return true }
        if value.allSatisfy({ $0 == "*" || $0 == "•" || $0 == "." }) { return true }
        if value.hasPrefix("<") || value.hasPrefix("${") || value.hasPrefix("$(") || value.hasPrefix("{{") || value.hasPrefix("%") { return true }
        if value.hasPrefix("⟦") { return true }
        if lower.hasPrefix("xxx") || lower.hasPrefix("changeme") || lower.hasPrefix("your-") || lower.hasPrefix("your_") { return true }
        if lower.hasPrefix("process.env") || lower.hasPrefix("os.environ") || lower.contains("getenv") { return true }
        return false
    }

    /// 13–19 digits (separators aside) that pass the Luhn check.
    static func isCardNumber(_ raw: String) -> Bool {
        let digits = raw.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        // A run of one digit (0000 0000 …) is no card.
        if Set(digits).count == 1 { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// An IBAN whose check digits are right (ISO 13616 mod-97).
    static func ibanIsValid(_ iban: String) -> Bool {
        let compact = iban.uppercased().filter { !$0.isWhitespace }
        guard compact.count >= 15, compact.count <= 34 else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for ch in rearranged {
            if let digit = ch.wholeNumberValue, ch.isASCII {
                remainder = (remainder * 10 + digit) % 97
            } else if let ascii = ch.asciiValue, ch.isLetter {
                let value = Int(ascii) - 55   // A = 10 … Z = 35
                remainder = (remainder * 100 + value) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    /// A dotted quad with every octet ≤ 255, other than 127.0.0.1 and 0.0.0.0.
    static func isMaskableIPv4(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0).map { $0 <= 255 } ?? false }) else { return false }
        return raw != "127.0.0.1" && raw != "0.0.0.0"
    }
}
