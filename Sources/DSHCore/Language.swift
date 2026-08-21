import Foundation

/// A language's lexical vocabulary. Deliberately shallow: enough to colour
/// comments, strings, numbers, and keywords, which is what makes code readable
/// at a glance. It is not a parser and does not try to be.
public struct Language: Sendable {
    public var name: String
    public var keywords: Set<String>
    public var lineComment: String?
    public var blockComment: (open: String, close: String)?
    /// Quote characters that open a string literal.
    public var quotes: Set<Character>
    /// Strings may contain backslash escapes.
    public var escapes: Bool

    public static func detect(for url: URL) -> Language {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if ["makefile", "dockerfile"].contains(name) || ext == "mk" { return .shell }
        switch ext {
        case "swift": return .swift
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "java", "kt", "go", "rs",
             "js", "jsx", "ts", "tsx", "mjs", "cjs", "dart", "scala", "php", "zig":
            return .cFamily(ext)
        case "py", "rb", "pl", "r", "jl": return .scripting(ext)
        case "sh", "bash", "zsh", "fish", "env", "gitignore", "conf", "cfg", "ini",
             "properties", "toml", "gradle", "podspec", "xcconfig":
            return .shell
        case "json": return .json
        case "yaml", "yml": return .yaml
        case "html", "htm", "xml", "svg", "plist", "entitlements": return .markup
        case "css", "scss", "sass", "less": return .css
        case "sql": return .sql
        case "md", "markdown", "mdx", "rst", "txt", "log": return .plain
        default: return .plain
        }
    }

    public static let plain = Language(name: "Text", keywords: [], lineComment: nil,
                                blockComment: nil, quotes: [], escapes: false)

    public static let swift = Language(
        name: "Swift",
        keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
                   "func", "import", "init", "inout", "internal", "let", "open", "operator",
                   "private", "protocol", "public", "rethrows", "static", "struct", "subscript",
                   "typealias", "var", "actor", "async", "await", "break", "case", "continue",
                   "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
                   "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is",
                   "nil", "super", "self", "Self", "throw", "throws", "true", "try", "some", "any",
                   "final", "lazy", "weak", "unowned", "mutating", "nonmutating", "override",
                   "required", "convenience", "indirect", "@MainActor", "@Observable", "@State"],
        lineComment: "//", blockComment: ("/*", "*/"), quotes: ["\""], escapes: true)

    public static func cFamily(_ ext: String) -> Language {
        var keywords: Set<String> = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
            "else", "enum", "extern", "float", "for", "goto", "if", "int", "long", "register",
            "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
            "union", "unsigned", "void", "volatile", "while", "class", "public", "private",
            "protected", "new", "delete", "this", "true", "false", "null", "nullptr", "namespace",
            "template", "typename", "using", "virtual", "override", "final", "try", "catch", "throw",
        ]
        switch ext {
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            keywords.formUnion(["function", "let", "var", "const", "async", "await", "export",
                                "import", "from", "of", "in", "typeof", "instanceof", "yield",
                                "interface", "type", "implements", "extends", "readonly", "as",
                                "undefined", "NaN"])
        case "go":
            keywords.formUnion(["func", "package", "import", "defer", "go", "chan", "map",
                                "range", "select", "type", "var", "nil", "make", "len", "cap"])
        case "rs":
            keywords.formUnion(["fn", "let", "mut", "impl", "trait", "pub", "crate", "mod",
                                "use", "match", "loop", "move", "ref", "Some", "None", "Ok",
                                "Err", "self", "Self", "where", "dyn", "async", "await"])
        case "kt":
            keywords.formUnion(["fun", "val", "var", "object", "companion", "data", "when",
                                "is", "as", "suspend", "lateinit", "init"])
        case "php":
            keywords.formUnion(["echo", "function", "elseif", "foreach", "endforeach", "array"])
        default: break
        }
        var language = Language(name: ext.uppercased(), keywords: keywords,
                                lineComment: "//", blockComment: ("/*", "*/"),
                                quotes: ["\"", "'", "`"], escapes: true)
        if ext == "php" { language.lineComment = "//" }
        return language
    }

    public static func scripting(_ ext: String) -> Language {
        var keywords: Set<String> = [
            "and", "as", "assert", "break", "class", "continue", "def", "del", "elif", "else",
            "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
            "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
            "True", "False", "None", "async", "await", "self",
        ]
        if ext == "rb" {
            keywords.formUnion(["do", "end", "module", "require", "attr_accessor", "nil",
                                "true", "false", "unless", "elsif", "then", "puts"])
        }
        return Language(name: ext.uppercased(), keywords: keywords, lineComment: "#",
                        blockComment: nil, quotes: ["\"", "'"], escapes: true)
    }

    public static let shell = Language(
        name: "Shell",
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                   "esac", "function", "return", "exit", "export", "local", "readonly", "source",
                   "echo", "set", "unset", "shift", "trap", "in", "select", "until"],
        lineComment: "#", blockComment: nil, quotes: ["\"", "'"], escapes: true)

    public static let json = Language(name: "JSON", keywords: ["true", "false", "null"],
                               lineComment: nil, blockComment: nil, quotes: ["\""], escapes: true)

    public static let yaml = Language(name: "YAML", keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                               lineComment: "#", blockComment: nil, quotes: ["\"", "'"], escapes: true)

    public static let markup = Language(name: "Markup", keywords: [], lineComment: nil,
                                 blockComment: ("<!--", "-->"), quotes: ["\"", "'"], escapes: false)

    public static let css = Language(name: "CSS", keywords: ["import", "media", "keyframes", "supports",
                                                      "font-face", "important", "root"],
                              lineComment: nil, blockComment: ("/*", "*/"), quotes: ["\"", "'"], escapes: true)

    public static let sql = Language(
        name: "SQL",
        keywords: ["select", "from", "where", "insert", "into", "values", "update", "set",
                   "delete", "create", "table", "drop", "alter", "join", "left", "right",
                   "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset",
                   "and", "or", "not", "null", "as", "distinct", "union", "index", "primary", "key"],
        lineComment: "--", blockComment: ("/*", "*/"), quotes: ["'", "\""], escapes: true)
}
