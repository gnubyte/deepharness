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
        /// Narrows the value's range (a trailing full stop, surrounding quotes) or turns it down (nil).
        var refine: (@Sendable (NSString, NSRange) -> NSRange?)? = nil
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
        // password = "…", "api_key": '…': a quoted value is the secret.
        Pattern(regex: re(assignmentKey + #""([^"\n]{6,})""#, [.caseInsensitive]), category: .secret, group: 1,
                accept: { !SensitiveDetector.isPlaceholderValue($0) }),
        Pattern(regex: re(assignmentKey + #"'([^'\n]{6,})'"#, [.caseInsensitive]), category: .secret, group: 1,
                accept: { !SensitiveDetector.isPlaceholderValue($0) }),
        // password: hunter2pass — a bare value only when it looks like a secret rather than code
        // (`let token: String`, `token = getToken()`, `password = user_password` are code).
        Pattern(regex: re(assignmentKey + #"([^\s"'`;,(){}\[\]<>]{6,})"#, [.caseInsensitive]), category: .secret, group: 1,
                refine: { SensitiveDetector.bareSecret($0, $1) }),
        // DB_PASSWORD=… in an env file: the value, always (unless it stands in for one).
        Pattern(regex: re(#"^\s*(?:export\s+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|ACCESS_KEY)[A-Z0-9_]*\s*=\s*(\S+)"#,
                          [.anchorsMatchLines]),
                category: .secret, group: 1, refine: { SensitiveDetector.envValue($0, $1) }),
    ]

    /// `password`, `"api_key"`, `token =`: the start of an assignment whose value is a secret.
    private static let assignmentKey = #"(?:password|passwd|pwd|secret|api[_-]?key|token|access[_-]?key)["']?\s*[:=]\s*"#

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
                var range = match.range(at: pattern.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                if let refine = pattern.refine {
                    guard let refined = refine(ns, range), refined.length > 0 else { continue }
                    range = refined
                }
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
        let taken = Self.placeholderRanges(in: ns)
        // In order of where they start (the longer first). Matches that overlap become one, named by the longest of
        // them — so no part of anything detected is left showing (a password in a URL that also reads as an email
        // address). One sorted sweep, so a file with thousands of values is as quick as a sentence.
        candidates.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location
                                                                  : $0.range.length > $1.range.length }
        var chosen: [(range: NSRange, category: SensitiveCategory)] = []
        var longest = 0
        var nextTaken = 0
        for candidate in candidates {
            let start = candidate.range.location, end = start + candidate.range.length
            while nextTaken < taken.count, taken[nextTaken].location + taken[nextTaken].length <= start { nextTaken += 1 }
            if nextTaken < taken.count, taken[nextTaken].location < end { continue }
            if let last = chosen.last, start < last.range.location + last.range.length {
                chosen[chosen.count - 1].range = NSUnionRange(last.range, candidate.range)
                if candidate.range.length > longest {
                    longest = candidate.range.length
                    chosen[chosen.count - 1].category = candidate.category
                }
            } else {
                chosen.append(candidate)
                longest = candidate.range.length
            }
        }
        return chosen.compactMap { item in
            Range(item.range, in: text).map { SensitiveMatch(range: $0, category: item.category) }
        }
    }

    /// The placeholders already in a text, in order.
    static func placeholderRanges(in text: NSString) -> [NSRange] {
        guard text.range(of: "⟦").location != NSNotFound else { return [] }
        return placeholderRegex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range)
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
        // $GITHUB_TOKEN: a reference to another variable.
        if value.range(of: #"^\$[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Words that name a type rather than being a value (`let token: String`, `password: string;`).
    static let typeWords: Set<String> = [
        "String", "string", "str", "Int", "int", "Integer", "Bool", "bool", "boolean", "Boolean", "number", "Number",
        "any", "Any", "Data", "Date", "URL", "Object", "object", "None", "null", "nil", "true", "false", "undefined",
        "Optional", "SecureString", "char", "bytes", "Buffer", "Uint8Array", "Secret", "Token", "Password",
        "Credential", "Credentials",
    ]

    private static let dottedPath = re(#"^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+$"#)
    // Identifiers, in letters only: with digits allowed, a password such as Tr0ub4dorX9 would read as PascalCase.
    private static let pascalCase = re(#"^[A-Z][a-z]+(?:[A-Z][a-z]*)+$"#)
    private static let camelCase = re(#"^[a-z]+(?:[A-Z][a-z]*)+$"#)
    private static let snakeCase = re(#"^[a-z]+(?:_[a-z]+)+$"#)

    /// The value of `password: …` written without quotes, when it looks like a secret rather than code: not a type,
    /// a dotted path or an identifier, and it has a digit or a symbol in it, or is 8 letters or more all in one case
    /// (`correcthorse`). A trailing `?`, `!` or `.` is punctuation, not part of it.
    static func bareSecret(_ text: NSString, _ range: NSRange) -> NSRange? {
        var range = range
        if let last = UnicodeScalar(text.character(at: range.location + range.length - 1)), "?!.".unicodeScalars.contains(last) {
            range.length -= 1
        }
        guard range.length > 0 else { return nil }
        let value = text.substring(with: range)
        guard !isPlaceholderValue(value), !typeWords.contains(value) else { return nil }
        let whole = NSRange(location: 0, length: (value as NSString).length)
        for identifier in [dottedPath, pascalCase, camelCase, snakeCase] where identifier.firstMatch(in: value, range: whole) != nil {
            return nil
        }
        let scalars = value.unicodeScalars
        let symbolOrDigit = scalars.contains { !(("a"..."z").contains($0) || ("A"..."Z").contains($0) || $0 == "_") }
        let oneCase = value.count >= 8
            && (scalars.allSatisfy { ("a"..."z").contains($0) } || scalars.allSatisfy { ("A"..."Z").contains($0) })
        return symbolOrDigit || oneCase ? range : nil
    }

    /// The value of an env-file line, without the quotes around it; nil when it stands in for a secret
    /// (`${OTHER}`, `$(command)`, `<your key>`).
    static func envValue(_ text: NSString, _ range: NSRange) -> NSRange? {
        var range = range
        if range.length >= 2 {
            let first = text.character(at: range.location), last = text.character(at: range.location + range.length - 1)
            if first == last, first == 0x22 || first == 0x27 {   // "…" or '…'
                range = NSRange(location: range.location + 1, length: range.length - 2)
            }
        }
        guard range.length > 0, !isPlaceholderValue(text.substring(with: range)) else { return nil }
        return range
    }

    /// 14–19 digits (separators aside) that start like a payment card (Visa, Mastercard, Amex, Discover, JCB,
    /// Diners, UnionPay) and pass the Luhn check. The prefix rule keeps millisecond timestamps (17…) and other
    /// long numbers in code from being taken for cards — a tenth of any digit run passes Luhn by chance.
    static func isCardNumber(_ raw: String) -> Bool {
        let digits = raw.compactMap { $0.wholeNumberValue }
        guard (14...19).contains(digits.count), hasCardPrefix(digits) else { return false }
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

    /// The issuer prefixes of the card networks people actually carry.
    static func hasCardPrefix(_ digits: [Int]) -> Bool {
        func prefix(_ n: Int) -> Int { digits.prefix(n).reduce(0) { $0 * 10 + $1 } }
        switch digits.first {
        case 4: return true                                                    // Visa
        case 5: return (51...55).contains(prefix(2))                           // Mastercard
        case 2: return (2221...2720).contains(prefix(4))                       // Mastercard 2-series
        case 3: return [34, 37, 35, 36, 38, 39].contains(prefix(2)) || (300...305).contains(prefix(3))   // Amex, JCB, Diners
        case 6: return prefix(4) == 6011 || prefix(2) == 65 || prefix(2) == 62 || (644...649).contains(prefix(3))   // Discover, UnionPay
        default: return false
        }
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
