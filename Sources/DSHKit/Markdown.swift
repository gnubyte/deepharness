import Foundation

/// One block of rendered markdown.
///
/// SwiftUI's `AttributedString(markdown:)` handles *inline* syntax only — it
/// flattens code fences, headings, and lists into one run. Block structure is
/// therefore parsed here, and each block's inline text is handed to
/// AttributedString afterwards.
public enum MarkdownBlock: Identifiable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case listItem(marker: String, text: String, depth: Int)
    case quote(String)
    case rule

    public var id: String {
        switch self {
        case .paragraph(let t): "p:\(t.hashValue)"
        case .heading(let l, let t): "h\(l):\(t.hashValue)"
        case .code(let lang, let t): "c:\(lang ?? ""):\(t.hashValue)"
        case .listItem(let m, let t, let d): "l:\(d):\(m):\(t.hashValue)"
        case .quote(let t): "q:\(t.hashValue)"
        case .rule: "hr:\(UUID().uuidString)"
        }
    }
}

public enum Markdown {
    /// Split text into renderable blocks.
    ///
    /// Deliberately small: fences, ATX headings, bullet/ordered lists, block
    /// quotes, and thematic breaks. An unterminated fence still closes at end
    /// of input, so a streaming response renders as code while it arrives
    /// instead of showing raw backticks.
    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        var lines = source.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code — consume until the closing fence or end of input.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    body.append(next)
                }
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    text: body.joined(separator: "\n")
                ))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if let item = parseListItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            paragraph.append(trimmed)
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, rest.first == " " || rest.isEmpty else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let depth = min(indent / 2, 3)

        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return .listItem(marker: "•", text: String(trimmed.dropFirst(2)), depth: depth)
        }
        // Ordered: digits followed by `.` or `)`.
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let after = trimmed.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return .listItem(marker: "\(digits).", text: String(after.dropFirst(2)), depth: depth)
            }
        }
        return nil
    }

    /// Render one block's inline syntax (bold, italic, code spans, links).
    ///
    /// Falls back to the raw text when the inline parse fails, so malformed
    /// markdown degrades to plain text rather than vanishing.
    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}
