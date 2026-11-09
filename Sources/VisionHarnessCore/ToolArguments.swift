import Foundation

// MARK: - Tool-call arguments that are nearly JSON
//
// Local models get tool-call arguments slightly wrong in a handful of ways: the object wrapped in a ```json fence
// or a sentence, a trailing comma, Python's True / False / None, a real line break or tab inside a string (a file's
// contents, typically), a regex backslash that isn't a JSON escape ("\d+"), or the whole object sent again as one
// JSON string. Every tool reads its arguments as a JSON object, so each of these used to reach the tool as no
// arguments at all, and the model was told "file_path is required" about a call that plainly had one.
//
// `repaired` fixes those, and only those: the result must parse as a JSON object, or nothing is changed.
// `problem` names what is still wrong, so the engine can say so instead of running the tool with nothing.

public enum ToolArguments {
    /// A corrected copy of `raw` when it is not a JSON object but can be made into one; nil when it already is one,
    /// when it is empty, or when it can't be fixed.
    public static func repaired(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" || object(trimmed) != nil { return nil }
        return fixed(trimmed, depth: 0)
    }

    /// What is wrong with `raw` as a tool call's arguments; nil when it is a JSON object, or empty (a tool
    /// with no parameters).
    public static func problem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" { return nil }
        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "not valid JSON"
        }
        if value is [String: Any] { return nil }
        if value is [Any] { return "a JSON array, not an object" }
        if value is String { return "a JSON string, not an object" }
        return "a single value, not an object"
    }

    /// The text of the error a call with unusable arguments gets back. Nothing ran.
    public static func message(tool: String, problem: String) -> String {
        "Error: the arguments for \(tool) were \(problem), so nothing ran. Send the call again with its arguments as one JSON object, for example {\"name\": \"value\"}, using the parameter names in the tool's description."
    }

    // MARK: Repair

    private static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return value as? [String: Any]
    }

    private static func fixed(_ text: String, depth: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if object(trimmed) != nil { return trimmed }
        guard depth < 2 else { return nil }

        // The object, sent as a JSON string: "{\"path\": \"a\"}".
        if trimmed.hasPrefix("\""), let data = trimmed.data(using: .utf8),
           let inner = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String {
            return fixed(inner, depth: depth + 1)
        }

        var candidates: [String] = []
        for base in [trimmed, withoutFence(trimmed)] {
            candidates.append(base)
            // The object with words around it: "Here are the arguments: {...}".
            if let open = base.firstIndex(of: "{"), let close = base.lastIndex(of: "}"), open < close {
                candidates.append(String(base[open...close]))
            }
        }
        for candidate in candidates {
            if object(candidate) != nil { return candidate }
            let normal = normalized(candidate)
            if object(normal) != nil { return normal }
        }
        return nil
    }

    /// The text inside a ``` fence, or the text itself when there is none.
    static func withoutFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        // Split on the "\n" code unit: in Swift "\r\n" is one Character, which a Character split would miss.
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One pass over the text that fixes what JSON forbids but a model meant plainly: raw control characters and
    /// stray backslashes inside strings, trailing commas, and Python's literals outside them.
    static func normalized(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let escapable = Set("\"\\/bfnrtu".unicodeScalars)
        var out = String.UnicodeScalarView()
        var inString = false
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inString {
                if c == "\\" {
                    if i + 1 < scalars.count, escapable.contains(scalars[i + 1]) {
                        out.append(c)
                        out.append(scalars[i + 1])
                        i += 2
                    } else {
                        // "\d" in a regex: the model meant a backslash.
                        out.append(contentsOf: "\\\\".unicodeScalars)
                        i += 1
                    }
                    continue
                }
                if c == "\"" {
                    inString = false
                    out.append(c)
                } else if c.value < 0x20 {
                    switch c {
                    case "\n": out.append(contentsOf: "\\n".unicodeScalars)
                    case "\r": out.append(contentsOf: "\\r".unicodeScalars)
                    case "\t": out.append(contentsOf: "\\t".unicodeScalars)
                    default: out.append(contentsOf: String(format: "\\u%04x", c.value).unicodeScalars)
                    }
                } else {
                    out.append(c)
                }
                i += 1
                continue
            }

            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }
            if c == "," {
                var j = i + 1
                while j < scalars.count, scalars[j].properties.isWhitespace { j += 1 }
                if j < scalars.count, scalars[j] == "}" || scalars[j] == "]" {
                    i += 1 // a trailing comma
                    continue
                }
                out.append(c)
                i += 1
                continue
            }
            if c.properties.isAlphabetic {
                var j = i
                while j < scalars.count, scalars[j].properties.isAlphabetic { j += 1 }
                let word = String(String.UnicodeScalarView(scalars[i..<j]))
                switch word {
                case "True": out.append(contentsOf: "true".unicodeScalars)
                case "False": out.append(contentsOf: "false".unicodeScalars)
                case "None": out.append(contentsOf: "null".unicodeScalars)
                default: out.append(contentsOf: scalars[i..<j])
                }
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
