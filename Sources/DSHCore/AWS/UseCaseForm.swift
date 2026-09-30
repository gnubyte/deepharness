import Foundation

// MARK: - Anthropic's use-case form

/// Who will use the models ("intendedUsers" in the form). "0" = the company's own staff is what AWS's
/// examples use; 1 and 2 follow the console's order (external, both) but are not documented.
public enum UseCaseAudience: Int, Sendable, Hashable, CaseIterable {
    case `internal` = 0
    case external = 1
    case both = 2
}

/// Anthropic's "first time use" form, submitted once per AWS account (or organization) before Claude
/// models can be used. AWS keeps it as the JSON of `toJSON()`; it can't be changed later.
public struct UseCaseForm: Hashable, Sendable {
    public var companyName: String
    public var companyWebsite: String
    public var industry: String
    public var useCases: String
    public var intendedUsers: UseCaseAudience
    public var otherIndustry: String

    public init(companyName: String, companyWebsite: String, industry: String, useCases: String,
                intendedUsers: UseCaseAudience = .internal, otherIndustry: String = "") {
        self.companyName = companyName
        self.companyWebsite = companyWebsite
        self.industry = industry
        self.useCases = useCases
        self.intendedUsers = intendedUsers
        self.otherIndustry = otherIndustry
    }

    /// Industries to offer. AWS doesn't publish the accepted list; "Energy" and "Government" appear in
    /// public examples, the rest follow the console's wording as best known. "Other" sends the text in
    /// `otherIndustry`.
    public static let industries: [String] = [
        "Technology", "Financial Services", "Healthcare", "Education", "Government", "Energy", "Retail",
        "Manufacturing", "Media and Entertainment", "Telecommunications", "Legal", "Other",
    ]

    /// The most JSON AWS takes (the form's `formData` is limited to 16 KB).
    static let maxJSONBytes = 16384

    /// What's missing, in words, or nil when the form can be sent.
    public var problem: String? {
        if BedrockText.isBlank(companyName) { return "Enter your company or organization name (or your own name)." }
        if !WebsiteCheck.isAcceptable(normalizedWebsite) { return "Enter your company's website, like https://example.com." }
        if BedrockText.isBlank(industry) { return "Choose an industry." }
        if BedrockText.equals(industry, "Other"), BedrockText.isBlank(otherIndustry) { return "Describe your industry." }
        if BedrockText.isBlank(useCases) { return "Describe briefly what you'll use the models for." }
        if toJSON().utf8.count > Self.maxJSONBytes { return "The description is too long; shorten it." }
        return nil
    }

    /// "example.com" → "https://example.com".
    public var normalizedWebsite: String {
        let site = BedrockText.trimmed(companyWebsite)
        return site.isEmpty || site.range(of: "://", options: .literal) != nil ? site : "https://" + site
    }

    /// {"companyName": …, "companyWebsite": …, "intendedUsers": "0", "industryOption": …,
    /// "otherIndustryOption": …, "useCases": …}, compact, in that order, every value a string.
    public func toJSON() -> String {
        let isOther = BedrockText.equals(industry, "Other")
        let fields: [(String, String)] = [
            ("companyName", BedrockText.trimmed(companyName)),
            ("companyWebsite", normalizedWebsite),
            ("intendedUsers", String(intendedUsers.rawValue)),
            ("industryOption", BedrockText.trimmed(industry)),
            ("otherIndustryOption", isOther ? BedrockText.trimmed(otherIndustry) : ""),
            ("useCases", BedrockText.trimmed(useCases)),
        ]
        return "{" + fields.map { "\(Self.quote($0.0)):\(Self.quote($0.1))" }.joined(separator: ",") + "}"
    }

    /// The form as the CLI takes a blob argument: base64 of the UTF-8 JSON (the app also passes
    /// --cli-binary-format base64, so a user's raw-in-base64-out setting can't double-encode it).
    public func toBase64() -> String {
        Data(toJSON().utf8).base64EncodedString()
    }

    /// Read the form back from GetUseCaseForModelAccess's formData as the CLI prints it (base64). The
    /// stored value may itself be base64 again (Terraform's AWS provider decodes it twice), so up to two
    /// layers are unwrapped.
    public static func fromFormData(_ formData: String) -> UseCaseForm? {
        var text = BedrockText.trimmed(formData)
        for _ in 0..<3 {
            if let form = parse(json: text) { return form }
            guard let bytes = decodeBase64(text) else { return nil }
            text = BedrockText.trimmed(String(decoding: bytes, as: UTF8.self))
        }
        return nil
    }

    private static func parse(json: String) -> UseCaseForm? {
        guard json.unicodeScalars.first == "{", let value = JSONValue(parsing: json), value.object != nil else { return nil }
        let audience = BedrockJSON.int(value, "intendedUsers", default: 0)
        return UseCaseForm(
            companyName: BedrockJSON.string(value, "companyName") ?? "",
            companyWebsite: BedrockJSON.string(value, "companyWebsite") ?? "",
            industry: BedrockJSON.string(value, "industryOption") ?? "",
            useCases: BedrockJSON.string(value, "useCases") ?? "",
            intendedUsers: UseCaseAudience(rawValue: audience) ?? .internal,
            otherIndustry: BedrockJSON.string(value, "otherIndustryOption") ?? "")
    }

    // MARK: JSON text

    /// A JSON string literal the way the Windows app's encoder (.NET's relaxed one) writes it — AWS
    /// stores what is sent, and the size limit is on these bytes. `"` and `\` are escaped and control
    /// characters become \b \t \n \f \r or \u00XX, but `< > & ' +` and letters of any script stay as
    /// they are. Escaped as \uXXXX (uppercase hex): every character outside the Basic Multilingual Plane
    /// (as its surrogate pair, so an emoji takes 12 bytes) and, inside it, those with no printable form:
    /// C1 controls, unassigned code points, private use, line and paragraph separators, spaces other than
    /// the plain one, and U+FEFF.
    static func quote(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x10000...:
                let offset = scalar.value - 0x10000
                out += unicodeEscape(0xD800 + (offset >> 10)) + unicodeEscape(0xDC00 + (offset & 0x3FF))
            default:
                if needsEscape(scalar) { out += unicodeEscape(scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    private static func unicodeEscape(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
    }

    /// A BMP character .NET writes as \uXXXX: the C0 and C1 controls (and DEL), unassigned and private-use code
    /// points, line and paragraph separators, every space but the plain one, and the byte order mark. (A format
    /// character such as a zero-width space or a soft hyphen is written as it is.)
    static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 0x20 && value < 0x7F { return false }
        if value == 0xFEFF { return true }
        switch scalar.properties.generalCategory {
        case .control, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator: return true
        default: return false
        }
    }

    // MARK: Base64

    /// `Convert.FromBase64String`: white space (space, tab, CR, LF) is skipped anywhere, the rest must
    /// be a multiple of four characters with `=` only as the last one or two, and stray low bits before
    /// the padding are ignored. Nil for anything else.
    static func decodeBase64(_ text: String) -> [UInt8]? {
        var symbols: [UInt8] = []
        symbols.reserveCapacity(text.utf8.count)
        for byte in text.utf8 where byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { symbols.append(byte) }
        guard symbols.count % 4 == 0 else { return nil }
        var padding = 0
        while padding < 2, symbols.count > padding, symbols[symbols.count - 1 - padding] == 0x3D { padding += 1 }
        symbols.removeLast(padding)
        var out: [UInt8] = []
        out.reserveCapacity(symbols.count / 4 * 3)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in symbols {
            let value: UInt32
            switch byte {
            case 0x41...0x5A: value = UInt32(byte - 0x41)
            case 0x61...0x7A: value = UInt32(byte - 0x61 + 26)
            case 0x30...0x39: value = UInt32(byte - 0x30 + 52)
            case 0x2B: value = 62
            case 0x2F: value = 63
            default: return nil
            }
            buffer = (buffer << 6) | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
                buffer &= (1 << UInt32(bits)) - 1
            }
        }
        return out
    }
}

/// Whether the text is a website Anthropic's form will take: what the Windows app accepts, which it
/// decides with `Uri.TryCreate(text, UriKind.Absolute)` — an http or https URL whose `Host` contains a dot.
/// System.Uri's rules are written out here rather than asking `URL`, whose parsing differs between macOS
/// releases (and is more lenient about spaces). They were measured, not guessed: this agrees with
/// System.Uri on every one of some 500,000 generated URL-like strings, except hosts that mix characters
/// IDN processing maps or refuses (emoji, zero-width and soft-hyphen characters, ideographic full stops,
/// no-break spaces …) with a label that starts with "-" or "_" or is over 63 characters — there this is
/// more lenient, and AWS has the last word on such an address anyway.
enum WebsiteCheck {
    static func isAcceptable(_ text: String) -> Bool {
        // System.Uri refuses strings of 65520 UTF-16 units or more.
        if text.utf16.count >= 65520 { return false }
        let s = Array(text.unicodeScalars)
        let start: Int
        if hasPrefix(s, "https://") { start = 8 } else if hasPrefix(s, "http://") { start = 7 } else { return false }

        // The authority runs to the first "/", "?" or "#".
        var end = start
        while end < s.count, s[end] != "/", s[end] != "?", s[end] != "#" { end += 1 }
        let authority = Array(s[start..<end])

        // Everything before the first "@" is user info (anything goes in it: "user:password@"), but System.Uri
        // stops looking for the "@" at a backslash. If nothing follows the "@" and the text ends there, the
        // whole authority is read as the host instead.
        var hostAndPort = authority
        let lookEnd = authority.firstIndex(of: "\\") ?? authority.count
        if let at = authority[..<lookEnd].firstIndex(of: "@") {
            if at + 1 < authority.count {
                hostAndPort = Array(authority[(at + 1)...])
            } else if end < s.count {
                return false
            }
        }

        // An IPv6 literal: what follows the "]" only matters when it is a port (or a backslash right
        // after it, which is invalid as anywhere else in a host); anything else is ignored.
        if hostAndPort.first == "[" {
            guard let close = hostAndPort.firstIndex(of: "]"), let groups = ipv6Groups(Array(hostAndPort[1..<close])) else { return false }
            let rest = hostAndPort[(close + 1)...]
            if rest.first == "\\" { return false }
            if rest.first == ":", !isPort(Array(rest.dropFirst())) { return false }
            return keepsDottedQuad(groups)
        }
        let colon = hostAndPort.firstIndex(of: ":")
        if let colon, !isPort(Array(hostAndPort[(colon + 1)...])) { return false }
        return hasDottedHost(colon.map { Array(hostAndPort[..<$0]) } ?? hostAndPort)
    }

    private static func hasPrefix(_ s: [Unicode.Scalar], _ prefix: String) -> Bool {
        let p = Array(prefix.unicodeScalars)
        guard s.count >= p.count else { return false }
        for (a, b) in zip(s, p) where lower(a) != b { return false }
        return true
    }

    private static func lower(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        scalar.value >= 0x41 && scalar.value <= 0x5A ? Unicode.Scalar(scalar.value + 0x20)! : scalar
    }

    /// Empty, or ASCII digits worth at most 65535 (leading zeros are fine).
    private static func isPort(_ digits: [Unicode.Scalar]) -> Bool {
        guard digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { return false }
        let significant = digits.drop { $0 == "0" }
        return significant.count <= 5 && (significant.isEmpty || Int(String(String.UnicodeScalarView(significant)))! <= 65535)
    }

    // MARK: Host names

    /// A DNS-style host (or a number System.Uri reads as an IPv4 address) that has a dot in it once
    /// System.Uri has normalized it: "example.com", "1.2.3.4", and also "2130706433" (= 127.0.0.1).
    private static func hasDottedHost(_ host: [Unicode.Scalar]) -> Bool {
        guard !host.isEmpty, host.allSatisfy(isHostCharacter) else { return false }
        // One trailing dot is fine ("example.com."); an empty label anywhere else is not. IDN processing
        // reads U+3002, U+FF0E and U+FF61 as dots too.
        var labels = host.split(omittingEmptySubsequences: false) { isDot($0) }
        if labels.last?.isEmpty == true { labels.removeLast() }
        guard labels.allSatisfy({ !$0.isEmpty }) else { return false }
        func count(_ label: ArraySlice<Unicode.Scalar>) -> Int { String(String.UnicodeScalarView(label)).utf16.count }
        // System.Uri's limit as measured: a name with a label over 63 characters may be 256 characters
        // long at most (a name of short labels has no limit of its own).
        if labels.contains(where: { count($0) > 63 }), String(String.UnicodeScalarView(host)).utf16.count > 256 { return false }
        // Two more of System.Uri's hostname rules, as measured: from the third label on, none starts with
        // "-" or "_"; and when the first label is all digits (System.Uri tries it as an IPv4 address
        // first) the same holds from the second label on, and those labels are at most 63 characters.
        func startsWithSeparator(_ label: ArraySlice<Unicode.Scalar>) -> Bool { label.first == "-" || label.first == "_" }
        if labels.dropFirst(2).contains(where: startsWithSeparator) { return false }
        if labels.first?.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) == true {
            let later = labels.dropFirst()
            if later.contains(where: { startsWithSeparator($0) || count($0) > 63 }) { return false }
        }
        return host.contains(".") || isIPv4Integer(host)
    }

    private static func isDot(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "." || scalar.value == 0x3002 || scalar.value == 0xFF0E || scalar.value == 0xFF61
    }

    /// Letters, digits, "-" and "_" (and any non-ASCII character except the C1 controls, which System.Uri
    /// hands to IDN processing), plus the dot between labels.
    private static func isHostCharacter(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v >= 0x80 { return v > 0x9F }
        return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x2D || v == 0x5F || v == 0x2E
    }

    /// A single number System.Uri reads as an IPv4 address that fits in 32 bits: decimal ("2130706433"),
    /// octal with a leading 0 ("017700000001") or hex with 0x ("0x7f000001").
    private static func isIPv4Integer(_ host: [Unicode.Scalar]) -> Bool {
        var digits = host[...]
        var radix: UInt64 = 10
        if digits.count >= 2, digits.first == "0" {
            if digits[digits.startIndex + 1] == "x" || digits[digits.startIndex + 1] == "X" {
                radix = 16
                digits = digits.dropFirst(2)
            } else {
                radix = 8
                digits = digits.dropFirst(1)
            }
        }
        guard !digits.isEmpty else { return false }
        var value: UInt64 = 0
        for scalar in digits {
            guard let digit = digitValue(scalar), UInt64(digit) < radix else { return false }
            value = value * radix + UInt64(digit)
            if value > 0xFFFF_FFFF { return false }
        }
        return true
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value) - 0x30
        case 0x41...0x46: return Int(scalar.value) - 0x41 + 10
        case 0x61...0x66: return Int(scalar.value) - 0x61 + 10
        default: return nil
        }
    }

    // MARK: IPv6 literals

    /// The eight 16-bit groups of an IPv6 literal (`::` expanded, a trailing dotted quad turned into
    /// two groups, a "%zone" ignored), or nil when it isn't one.
    static func ipv6Groups(_ literal: [Unicode.Scalar]) -> [UInt16]? {
        let address = literal.firstIndex(of: "%").map { Array(literal[..<$0]) } ?? literal
        let text = String(String.UnicodeScalarView(address))
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String, mayEndInIPv4: Bool) -> [UInt16]? {
            if part.isEmpty { return [] }
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            var out: [UInt16] = []
            for (index, piece) in pieces.enumerated() {
                if piece.contains(".") {
                    guard mayEndInIPv4, index == pieces.count - 1, let quad = dottedQuad(String(piece)) else { return nil }
                    out += [UInt16(quad[0]) << 8 | UInt16(quad[1]), UInt16(quad[2]) << 8 | UInt16(quad[3])]
                } else {
                    guard (1...4).contains(piece.utf8.count), let value = UInt16(piece, radix: 16), piece.utf8.allSatisfy(\.isASCIIHexDigit)
                    else { return nil }
                    out.append(value)
                }
            }
            return out
        }
        if halves.count == 1 {
            guard let all = groups(halves[0], mayEndInIPv4: true), all.count == 8 else { return nil }
            return all
        }
        guard let head = groups(halves[0], mayEndInIPv4: false), let tail = groups(halves[1], mayEndInIPv4: true),
              head.count + tail.count <= 7 else { return nil }
        return head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
    }

    /// "1.2.3.4" → four octets, each 0…255; leading zeros are only tolerated in the last one, and only one.
    private static func dottedQuad(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for (index, part) in parts.enumerated() {
            guard (1...3).contains(part.utf8.count), part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let value = UInt8(part) else { return nil }
            if part.hasPrefix("0"), part.count > 1, index < 3 || part.hasPrefix("00") { return nil }
            octets.append(value)
        }
        return octets
    }

    /// System.Uri writes an IPv6 host back with a dotted quad only for IPv4-compatible and -mapped
    /// addresses, SIIT (::ffff:0:a.b.c.d) and ISATAP (…:0:5efe:a.b.c.d); "Host contains a dot" holds
    /// for those alone.
    static func keepsDottedQuad(_ g: [UInt16]) -> Bool {
        if g[0] == 0, g[1] == 0, g[2] == 0, g[3] == 0, g[6] != 0 {
            if g[4] == 0, g[5] == 0 || g[5] == 0xFFFF { return true }
            if g[4] == 0xFFFF, g[5] == 0 { return true }
        }
        return g[4] == 0 && g[5] == 0x5EFE
    }
}

private extension UInt8 {
    var isASCIIHexDigit: Bool { (self >= 0x30 && self <= 0x39) || (self >= 0x41 && self <= 0x46) || (self >= 0x61 && self <= 0x66) }
}

// MARK: - Submitting it

public enum UseCaseSubmission: Sendable, Hashable {
    case submitted
    /// This account already has a form on file (AWS doesn't allow changing it), so nothing was sent.
    case alreadyOnFile
}
