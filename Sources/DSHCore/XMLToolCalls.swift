import Foundation

// MARK: - XML tool-call parser (Qwen / DeepSeek / Cline compatibility)
//
// Not every OpenAI-compatible backend (Ollama, LM Studio, some vLLM + Qwen
// setups) returns native `tool_calls`. Many Qwen-class models instead emit
// tool calls inline in the text using an XML convention such as:
//
//     <function=read_file>
//       <parameter=file_path>src/main.swift</parameter>
//       <parameter>start_line>1</parameter>
//     </function>
//
// or the Cline/DSH style:
//
//     <tool_name>read_file</tool_name>
//     <parameter_name>file_path</parameter_name>
//     src/main.swift
//     </tool_name>
//
// `OpenAIClient` runs the completed assistant text through this parser whenever
// the stream finished with zero native `tool_calls` but the text contains a
// recognizable block, so the same model can drive tools on either convention.
//
// NOTE: tag strings are assembled from angle-bracket characters built at
// runtime (LT/GT). This keeps the source free of literal `<tag>...</tag>`
// sequences and matches the idiom already used in `WebFetchTool.htmlToText`.

/// One tool call recovered from text.
public struct ParsedXMLToolCall: Sendable, Hashable {
    public let name: String
    /// Decoded key/value arguments (stringified).
    public let arguments: [String: String]

    /// JSON object of the arguments, ready to hand to a `ToolCall`.
    public var argumentsJSON: JSONString {
        guard !arguments.isEmpty else { return JSONString("{}") }
        do {
            let obj = arguments.mapValues { $0 as Any }
            let data = try JSONSerialization.data(withJSONObject: [String: Any].init(uniqueKeysWithValues: obj.map { ($0, $1) }), options: [.sortedKeys])
            return JSONString(String(decoding: data, as: UTF8.self))
        } catch {
            return JSONString("{}")
        }
    }
}

public enum XMLToolCalls {
    /// Angle brackets, built at runtime.
    static let LT = String(UnicodeScalar(60))   // <
    static let GT = String(UnicodeScalar(62))   // >

    /// Parse every tool block out of `text`. Returns `[]` when nothing matches.
    /// Both the `<function=name>...<parameter=k>v</parameter>...</function>`
    /// and the `<tool_name>NAME</tool_name><parameter_name>KEY</parameter_name>VALUE</tool_name>`
    /// conventions are understood.
    public static func parse(_ text: String) -> [ParsedXMLToolCall] {
        var out: [ParsedXMLToolCall] = []
        out.append(contentsOf: parseFunctionStyle(text))
        out.append(contentsOf: parseToolNameStyle(text))
        return out
    }

    /// Quick check: does `text` carry at least one recognizable tool block?
    public static func containsBlock(_ text: String) -> Bool {
        !parse(text).isEmpty
    }

    // MARK: <function=name> / <parameter=key>

    private static func parseFunctionStyle(_ text: String) -> [ParsedXMLToolCall] {
        let openPrefix = LT + "function="          // <function=
        let paramOpen = LT + "parameter="          // <parameter=
        let paramClose = LT + "/parameter" + GT    // </parameter>
        let blockClose = LT + "/function" + GT     // </function>

        var result: [ParsedXMLToolCall] = []
        var searchFrom = text.startIndex
        while let open = text.range(of: openPrefix, range: searchFrom..<text.endIndex) {
            // Tool name: from after "function=" to the next ">"
            guard let gtPos = text[open.upperBound...].firstIndex(of: GT.first!) else {
                searchFrom = open.upperBound; continue
            }
            let name = String(text[open.upperBound..<gtPos]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let closePos = text.range(of: blockClose, range: gtPos..<text.endIndex) else {
                searchFrom = open.upperBound; continue
            }
            let body = String(text[text.index(after: gtPos)..<closePos.lowerBound])
            result.append(ParsedXMLToolCall(name: name, arguments: extractParams(body, paramOpen: paramOpen, paramClose: paramClose)))
            searchFrom = closePos.upperBound
        }
        return result
    }

    private static func extractParams(_ body: String, paramOpen: String, paramClose: String) -> [String: String] {
        var out: [String: String] = [:]
        var searchFrom = body.startIndex
        while let open = body.range(of: paramOpen, range: searchFrom..<body.endIndex) {
            guard let gtPos = body[open.upperBound...].firstIndex(of: GT.first!) else { break }
            let key = String(body[open.upperBound..<gtPos]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let closePos = body.range(of: paramClose, range: gtPos..<body.endIndex) else {
                searchFrom = open.upperBound; continue
            }
            out[key] = String(body[body.index(after: gtPos)..<closePos.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            searchFrom = closePos.upperBound
        }
        return out
    }

    // MARK: <tool_name>NAME</tool_name> / <parameter_name>KEY</parameter_name>VALUE

    private static func parseToolNameStyle(_ text: String) -> [ParsedXMLToolCall] {
        let blockOpen = LT + "tool_name" + GT      // <tool_name>
        let blockClose = LT + "/tool_name" + GT    // </tool_name>
        let paramOpen = LT + "parameter_name" + GT // <parameter_name>
        let paramClose = LT + "/parameter_name" + GT

        var result: [ParsedXMLToolCall] = []
        var searchFrom = text.startIndex
        while let open = text.range(of: blockOpen, range: searchFrom..<text.endIndex) {
            guard let closePos = text.range(of: blockClose, range: open.upperBound..<text.endIndex) else { break }
            let body = String(text[open.upperBound..<closePos.lowerBound])
            // Tool name = first line(s) before the first <parameter_name>.
            let nameStart = body.startIndex
            let nameEnd = body.range(of: paramOpen)?.lowerBound ?? body.endIndex
            var name = String(body[nameStart..<nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            // The tool name itself may be wrapped: keep only the first token/line.
            if let firstNewline = name.firstIndex(of: "\n") {
                name = String(name[..<firstNewline]).trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty else { searchFrom = closePos.upperBound; continue }

            var args: [String: String] = [:]
            // Keys come from <parameter_name>K</parameter_name>; value is the
            // text after that, up to the next <parameter_name> (or block end).
            var argsFrom = nameEnd
            while let pOpen = body.range(of: paramOpen, range: argsFrom..<body.endIndex) {
                guard let pClose = body.range(of: paramClose, range: pOpen.upperBound..<body.endIndex) else { break }
                let key = String(body[pOpen.upperBound..<pClose.lowerBound]).trimmingCharacters(in: .whitespaces)
                let valStart = pClose.upperBound
                let valEnd = body.range(of: paramOpen, range: valStart..<body.endIndex)?.lowerBound ?? body.endIndex
                let value = String(body[valStart..<valEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { args[key] = value }
                argsFrom = valEnd
            }
            result.append(ParsedXMLToolCall(name: name, arguments: args))
            searchFrom = closePos.upperBound
        }
        return result
    }
}