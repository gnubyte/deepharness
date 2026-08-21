import AppKit
import DSHCore

/// Applies colour to a text storage in one pass.
///
/// Highlighting is scoped to the visible range plus a margin, so a 20 000-line
/// file costs the same as a short one.
enum SyntaxHighlighter {
    struct Palette {
        var plain: NSColor
        var comment: NSColor
        var string: NSColor
        var number: NSColor
        var keyword: NSColor

        static var current: Palette {
            Palette(plain: .labelColor,
                    comment: .systemGreen.blended(withFraction: 0.25, of: .gray) ?? .systemGreen,
                    string: .systemRed.blended(withFraction: 0.2, of: .gray) ?? .systemRed,
                    number: .systemPurple,
                    keyword: .systemBlue)
        }
    }

    /// Colour `range` of `storage` according to `language`.
    static func apply(to storage: NSTextStorage, language: Language, range: NSRange, font: NSFont) {
        let palette = Palette.current
        let text = storage.string as NSString
        // Extend to whole lines so a token is never cut in half.
        let safe = text.lineRange(for: NSRange(location: min(range.location, text.length),
                                              length: min(range.length, max(0, text.length - range.location))))

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: palette.plain], range: safe)
        for token in scan(text.substring(with: safe), language: language) {
            let absolute = NSRange(location: safe.location + token.range.location, length: token.range.length)
            guard absolute.location + absolute.length <= storage.length else { continue }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: colour(token.kind, palette)]
            if token.kind == .comment {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            storage.addAttributes(attributes, range: absolute)
        }
        storage.endEditing()
    }

    private static func colour(_ kind: Token.Kind, _ palette: Palette) -> NSColor {
        switch kind {
        case .comment: palette.comment
        case .string: palette.string
        case .number: palette.number
        case .keyword: palette.keyword
        }
    }

    struct Token {
        enum Kind { case comment, string, number, keyword }
        var kind: Kind
        var range: NSRange
    }

    /// Single-pass scanner: comments and strings win over everything, then
    /// bare words are matched against the keyword set.
    static func scan(_ source: String, language: Language) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(source)
        var index = 0
        let count = characters.count

        // UTF-16 offsets, since NSRange indexes the NSString.
        var utf16Offsets = [Int](repeating: 0, count: count + 1)
        var offset = 0
        for (i, character) in characters.enumerated() {
            utf16Offsets[i] = offset
            offset += String(character).utf16.count
        }
        utf16Offsets[count] = offset

        func range(_ from: Int, _ to: Int) -> NSRange {
            NSRange(location: utf16Offsets[from], length: utf16Offsets[min(to, count)] - utf16Offsets[from])
        }

        func matches(_ needle: String, at position: Int) -> Bool {
            let needleChars = Array(needle)
            guard position + needleChars.count <= count else { return false }
            for (i, character) in needleChars.enumerated() where characters[position + i] != character {
                return false
            }
            return true
        }

        while index < count {
            let character = characters[index]

            if let lineComment = language.lineComment, matches(lineComment, at: index) {
                let start = index
                while index < count, characters[index] != "\n" { index += 1 }
                tokens.append(Token(kind: .comment, range: range(start, index)))
                continue
            }

            if let block = language.blockComment, matches(block.open, at: index) {
                let start = index
                index += block.open.count
                while index < count, !matches(block.close, at: index) { index += 1 }
                index = min(count, index + block.close.count)
                tokens.append(Token(kind: .comment, range: range(start, index)))
                continue
            }

            if language.quotes.contains(character) {
                let start = index
                let quote = character
                index += 1
                while index < count {
                    if language.escapes, characters[index] == "\\" { index += 2; continue }
                    if characters[index] == quote { index += 1; break }
                    // An unterminated literal ends at the line break rather
                    // than swallowing the rest of the file.
                    if characters[index] == "\n" { break }
                    index += 1
                }
                tokens.append(Token(kind: .string, range: range(start, index)))
                continue
            }

            if character.isNumber {
                let start = index
                while index < count,
                      characters[index].isHexDigit || characters[index] == "." ||
                      characters[index] == "_" || characters[index] == "x" ||
                      characters[index] == "X" {
                    index += 1
                }
                tokens.append(Token(kind: .number, range: range(start, index)))
                continue
            }

            if character.isLetter || character == "_" || character == "@" || character == "#" {
                let start = index
                if character == "@" || character == "#" { index += 1 }
                while index < count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    index += 1
                }
                let word = String(characters[start..<index])
                if language.keywords.contains(word) {
                    tokens.append(Token(kind: .keyword, range: range(start, index)))
                }
                continue
            }

            index += 1
        }
        return tokens
    }
}
