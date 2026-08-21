import Foundation

// MARK: - Plugin manifests
//
// A plugin is a JSON manifest that declares extra tools, each backed by a
// shell command template. It needs no compilation and no process protocol —
// dropping a file in the plugins folder is the whole install step.
//
//   {
//     "name": "swift",
//     "description": "Swift package helpers",
//     "tools": [
//       { "name": "swift_test",
//         "description": "Run the package test suite. Use after changing code.",
//         "parameters": {"type":"object","properties":{"filter":{"type":"string"}}},
//         "command": "swift test ${filter:+--filter ${filter}}",
//         "requiresApproval": true }
//     ]
//   }
//
// `${key}` in `command` is replaced by the shell-quoted argument, so a value
// containing spaces or quotes cannot break out of its position.

public struct PluginManifest: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String?
    public var version: String?
    public var tools: [PluginToolSpec]

    public init(name: String, description: String? = nil, version: String? = nil, tools: [PluginToolSpec]) {
        self.name = name
        self.description = description
        self.version = version
        self.tools = tools
    }
}

public struct PluginToolSpec: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema object for the arguments. Defaults to "no arguments".
    public var parameters: JSONSchemaBox?
    /// Shell command template. `${key}` interpolates an argument.
    public var command: String
    /// Ask the user before running. Defaults to true — a plugin runs arbitrary
    /// shell, so silence is the wrong default.
    public var requiresApproval: Bool?
    public var timeout: Int?

    public init(name: String, description: String, parameters: JSONSchemaBox? = nil,
                command: String, requiresApproval: Bool? = nil, timeout: Int? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.command = command
        self.requiresApproval = requiresApproval
        self.timeout = timeout
    }
}

/// Carries an arbitrary JSON Schema through `Codable` without modelling it.
public struct JSONSchemaBox: Codable, Hashable, Sendable {
    public let json: String

    public init(json: String) { self.json = json }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Re-encode whatever object was there back to a JSON string.
        if let raw = try? container.decode(String.self) {
            json = raw
            return
        }
        let any = try container.decode(AnyCodable.self)
        let data = try JSONSerialization.data(withJSONObject: any.value, options: [.sortedKeys])
        json = String(decoding: data, as: UTF8.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            try container.encode(AnyCodable(obj))
        } else {
            try container.encode(json)
        }
    }
}

/// Minimal `Any` bridge for the schema box.
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues(\.value) }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let o as [String: Any]: try c.encode(o.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
}

// MARK: - The executor

/// One tool contributed by a plugin. Unlike the built-ins its identity is a
/// value, not a type, so the registry reads `instance.name` / `instance.spec`.
public struct PluginTool: ToolExecutor {
    /// Unused: plugin tools are registered under their instance name. The
    /// protocol's static requirements are satisfied so the type conforms.
    public static let name = "plugin"
    public static let spec = ToolSpec(name: "plugin", description: "", parameters: "{}")

    public let plugin: String
    public let declaration: PluginToolSpec

    public init(plugin: String, declaration: PluginToolSpec) {
        self.plugin = plugin
        self.declaration = declaration
    }

    public var name: String { declaration.name }

    public var spec: ToolSpec {
        ToolSpec(name: declaration.name,
                 description: declaration.description,
                 parameters: declaration.parameters?.json ?? #"{"type":"object","properties":{}}"#)
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let command = Self.interpolate(declaration.command, with: JSONArgs.dictionary(args))
        if declaration.requiresApproval ?? true {
            let approved = await context.requestPermission("plugin-\(UUID().uuidString)",
                                                           declaration.name,
                                                           "Plugin \(plugin) wants to run: \(command)")
            guard approved else {
                return .init(output: "Error: the user declined to run this plugin command.")
            }
        }
        let timeout = min(600, max(5, declaration.timeout ?? 120))
        let shellArgs = #"{"command":"#
            + (String(data: (try? JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "\"\"")
            + #","timeout":\#(timeout)}"#
        // Reuse the shell tool so timeout, truncation, and cwd behave identically.
        return await RunShellCommandTool().execute(args: JSONString(shellArgs), in: context)
    }

    /// Replace `${key}` with the shell-quoted argument value. Unknown keys
    /// collapse to an empty string so an optional parameter can be omitted.
    static func interpolate(_ template: String, with args: [String: Any]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "${") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "}", range: open.upperBound..<rest.endIndex) else {
                out += rest[open.lowerBound...]
                return out
            }
            let key = String(rest[open.upperBound..<close.lowerBound])
            out += shellQuote(stringify(args[key]))
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }

    private static func stringify(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: value as Any, options: [.fragmentsAllowed]) else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Single-quote for `/bin/bash`: everything is literal inside, and an
    /// embedded quote is closed, escaped, and reopened.
    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = value.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@,".contains($0) }
        if safe { return value }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

// MARK: - Loading

public enum PluginLoader {
    /// Plugins ship per-project and per-user; the project's win on a name clash.
    public static func directories(project: URL?) -> [URL] {
        var dirs: [URL] = []
        if let project { dirs.append(project.appendingPathComponent(".dsh/plugins", isDirectory: true)) }
        dirs.append(userDirectory)
        return dirs
    }

    public static var userDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("DSHMac/plugins", isDirectory: true)
    }

    /// Read every `*.json` manifest from the plugin directories.
    /// Malformed files are reported rather than crashing the load.
    public static func load(project: URL?) -> (plugins: [PluginManifest], errors: [String]) {
        var plugins: [PluginManifest] = []
        var errors: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for dir in directories(project: project) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: url)
                    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
                    guard !seen.contains(manifest.name) else { continue }
                    seen.insert(manifest.name)
                    plugins.append(manifest)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return (plugins, errors)
    }

    /// Flatten manifests into executors, dropping any tool whose name would
    /// shadow a built-in.
    public static func tools(from plugins: [PluginManifest], reserved: Set<String>) -> [any ToolExecutor] {
        var out: [any ToolExecutor] = []
        var taken = reserved
        for plugin in plugins {
            for declaration in plugin.tools where !taken.contains(declaration.name) {
                taken.insert(declaration.name)
                out.append(PluginTool(plugin: plugin.name, declaration: declaration))
            }
        }
        return out
    }

    /// Write a starter manifest so the folder is never empty on first open.
    @discardableResult
    public static func installExample() throws -> URL {
        let dir = userDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("example.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        let manifest = """
        {
          "name": "example",
          "description": "Sample plugin — edit or delete me.",
          "version": "1",
          "tools": [
            {
              "name": "git_status",
              "description": "Show the working tree status of the project's git repository.",
              "parameters": {"type": "object", "properties": {}},
              "command": "git status --short --branch",
              "requiresApproval": false
            }
          ]
        }
        """
        try manifest.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
