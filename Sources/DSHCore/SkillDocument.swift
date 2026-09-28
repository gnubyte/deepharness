import Foundation

// MARK: - SKILL.md / .mdc / command documents
//
// Every tool that shares skills (Claude Code, Cursor, Agent Skills, this app)
// writes the same shape: optional `---` YAML frontmatter, then Markdown. The
// frontmatter in the wild is not just `key: value` — descriptions are folded
// block scalars (`description: >`), Cursor's `globs` is a list or a comma
// string, Claude's `allowed-tools` is either. This reads all of those, keeps
// key order, and writes them back out.

public struct SkillDocument: Sendable, Equatable {
    /// Scalar fields (`description`, `alwaysApply`, …). Booleans stay "true"/"false".
    public var fields: [String: String]
    /// List fields (`globs`, `allowed-tools`, …).
    public var lists: [String: [String]]
    /// Original key order, for stable rewrites.
    public var order: [String]
    public var body: String
    /// Whether the text opened with a frontmatter block.
    public var hadFrontmatter: Bool

    public init(fields: [String: String] = [:], lists: [String: [String]] = [:],
                order: [String] = [], body: String = "", hadFrontmatter: Bool = false) {
        self.fields = fields
        self.lists = lists
        self.order = order
        self.body = body
        self.hadFrontmatter = hadFrontmatter
    }

    // MARK: Accessors

    public subscript(key: String) -> String? {
        get { fields[key] }
        set {
            if let newValue {
                if fields[key] == nil, lists[key] == nil { order.append(key) }
                lists[key] = nil
                fields[key] = newValue
            } else {
                fields[key] = nil
                lists[key] = nil
                order.removeAll { $0 == key }
            }
        }
    }

    public mutating func setList(_ key: String, _ values: [String]) {
        if fields[key] == nil, lists[key] == nil { order.append(key) }
        fields[key] = nil
        lists[key] = values
    }

    public func bool(_ key: String) -> Bool? {
        switch fields[key]?.lowercased() {
        case "true", "yes", "on": true
        case "false", "no", "off": false
        default: nil
        }
    }

    /// A list, whether written as a YAML list, `[a, b]`, or `a, b`.
    public func list(_ key: String) -> [String] {
        if let l = lists[key] { return l }
        guard let s = fields[key], !s.isEmpty else { return [] }
        return Self.splitList(s)
    }

    static func splitList(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
        // Split on commas that are not inside quotes or braces (globs like "**/*.{ts,tsx}").
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        var depth = 0
        for ch in t {
            if let q = quote { if ch == q { quote = nil }; cur.append(ch); continue }
            switch ch {
            case "\"", "'": quote = ch; cur.append(ch)
            case "{": depth += 1; cur.append(ch)
            case "}": depth = max(0, depth - 1); cur.append(ch)
            case "," where depth == 0: parts.append(cur); cur = ""
            default: cur.append(ch)
            }
        }
        parts.append(cur)
        return parts.map { Self.unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    // MARK: Parsing

    public static func parse(_ raw: String) -> SkillDocument {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return SkillDocument(body: text)
        }
        guard let end = lines.dropFirst().firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "---" || t == "..."
        }) else {
            return SkillDocument(body: text)   // unterminated: not frontmatter
        }
        var doc = SkillDocument(hadFrontmatter: true)
        let block = Array(lines[1..<end])
        var i = 0
        while i < block.count {
            let line = block[i]
            i += 1
            guard !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                  let colon = Self.keyColon(in: line) else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }

            // Following lines that belong to this key.
            var cont: [String] = []
            while i < block.count {
                let next = block[i]
                let isIndented = next.hasPrefix(" ") || next.hasPrefix("\t")
                let isTopList = next.hasPrefix("- ") || next == "-"
                if next.isEmpty || isIndented || (rest.isEmpty && isTopList) { cont.append(next); i += 1 } else { break }
            }

            if rest.hasPrefix("|") || rest.hasPrefix(">") {
                let folded = rest.hasPrefix(">")
                let strip = rest.contains("-")
                doc.assign(key, scalar: blockScalar(cont, folded: folded, strip: strip))
                continue
            }
            let nonBlank = cont.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if rest.isEmpty {
                let items = nonBlank.map { $0.trimmingCharacters(in: .whitespaces) }
                if !items.isEmpty, items.allSatisfy({ $0.hasPrefix("- ") || $0 == "-" }) {
                    doc.assign(key, list: items.map { unquote(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) }
                        .filter { !$0.isEmpty })
                } else if items.isEmpty {
                    doc.assign(key, scalar: "")
                }
                // A nested mapping (metadata:, hooks:) is not something we use.
                continue
            }
            if rest.hasPrefix("[") {
                var joined = rest
                for l in nonBlank { joined += " " + l.trimmingCharacters(in: .whitespaces) }
                doc.assign(key, list: splitList(joined))
                continue
            }
            if rest.hasPrefix("\"") || rest.hasPrefix("'") {
                var joined = rest
                let q = rest.first!
                // A quoted scalar that wraps onto indented lines.
                if !Self.closesQuote(rest, q) {
                    for l in nonBlank { joined += " " + l.trimmingCharacters(in: .whitespaces) }
                }
                doc.assign(key, scalar: unquote(joined))
                continue
            }
            // Plain scalar, possibly continued on indented lines.
            rest = stripComment(rest)
            for l in nonBlank { rest += " " + stripComment(l.trimmingCharacters(in: .whitespaces)) }
            doc.assign(key, scalar: rest.trimmingCharacters(in: .whitespaces))
        }

        var body = Array(lines[(end + 1)...])
        if body.first?.isEmpty == true { body.removeFirst() }
        doc.body = body.joined(separator: "\n")
        return doc
    }

    private mutating func assign(_ key: String, scalar: String) {
        if fields[key] == nil, lists[key] == nil { order.append(key) }
        lists[key] = nil
        fields[key] = scalar
    }

    private mutating func assign(_ key: String, list: [String]) {
        if fields[key] == nil, lists[key] == nil { order.append(key) }
        fields[key] = nil
        lists[key] = list
    }

    /// The colon ending a top-level key (not one inside a quoted key).
    private static func keyColon(in line: String) -> String.Index? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        if key.contains(" ") && !key.hasPrefix("\"") { return nil }   // prose, not a key
        return colon
    }

    private static func closesQuote(_ s: String, _ q: Character) -> Bool {
        var chars = Array(s.dropFirst())
        while let last = chars.last, last == " " { chars.removeLast() }
        guard chars.last == q else { return false }
        // An escaped final quote inside a double-quoted string doesn't close it.
        if q == "\"" {
            var backslashes = 0
            for c in chars.dropLast().reversed() { if c == "\\" { backslashes += 1 } else { break } }
            return backslashes % 2 == 0
        }
        return true
    }

    private static func blockScalar(_ lines: [String], folded: Bool, strip: Bool) -> String {
        let indent = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count } ?? 0
        let dedented = lines.map { l -> String in
            l.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(l.dropFirst(min(indent, l.count)))
        }
        var out = ""
        if folded {
            var prevBlank = true
            for l in dedented {
                if l.isEmpty { out += "\n"; prevBlank = true; continue }
                if !prevBlank { out += " " }
                out += l
                prevBlank = false
            }
        } else {
            out = dedented.joined(separator: "\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripComment(_ s: String) -> String {
        guard let r = s.range(of: " #") else { return s }
        return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let q = t.first, q == t.last, q == "\"" || q == "'" else { return t }
        let inner = String(t.dropFirst().dropLast())
        if q == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var out = ""
        var escaped = false
        for c in inner {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }

    // MARK: Rendering

    public func render() -> String {
        var out = ""
        if !order.isEmpty {
            out += "---\n"
            for key in order {
                if let s = fields[key] {
                    out += "\(key): \(Self.scalar(s))\n"
                } else if let l = lists[key] {
                    if l.isEmpty { out += "\(key): []\n" } else {
                        out += "\(key):\n"
                        for item in l { out += "  - \(Self.scalar(item))\n" }
                    }
                }
            }
            out += "---\n\n"
        }
        out += body
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    static func scalar(_ s: String) -> String {
        if s == "true" || s == "false" { return s }
        if s.isEmpty { return "\"\"" }
        let specialStart: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        let bare = !s.contains("\n") && !s.hasPrefix(" ") && !s.hasSuffix(" ")
            && !s.contains(": ") && !s.contains(" #") && !s.hasSuffix(":")
            && !(s.first.map(specialStart.contains) ?? false)
            && !["null", "yes", "no", "on", "off", "~"].contains(s.lowercased())
            && Double(s) == nil
        if bare { return s }
        var out = "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default: out.append(c)
            }
        }
        return out + "\""
    }
}
