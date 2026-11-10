import Foundation

// MARK: - The agent's handle on the model servers
//
// `model_server` lets the model look at — and, with the user's say-so, drive — the boxes running a Spark
// Swapper: what each serves, switching it, the context window it serves with, pictures on or off, installing a
// model, adding one from Hugging Face, and what changed lately. It is the same thing the model menu and Settings ▸
// Model Servers do, so "switch the Spark to the coding model and carry on" is one tool call rather than a trip
// to another window.
//
// The tool itself knows nothing about connections or the app: it reads the request out of the arguments, asks
// permission for anything that changes a box, and hands the request to the host.

/// What a `model_server` call asks for. `box` names a box by the start of its name or host name; nil means the box
/// behind the chat's own model, else the only box.
public enum ModelServerRequest: Sendable, Equatable {
    case status(box: String?)
    case switchModel(box: String?, model: String)
    /// `model` nil = the model that is serving.
    case setContext(box: String?, model: String?, tokens: Int)
    case setPictures(box: String?, enabled: Bool)
    case install(box: String?, model: String)
    /// `install` false only looks the repo up (nothing is downloaded).
    case addModel(box: String?, link: String, context: Int?, install: Bool)
    case activity(box: String?)

    /// Whether carrying it out changes anything on the box (and so needs the user's say-so).
    public var changesTheBox: Bool {
        switch self {
        case .status, .activity: false
        case .addModel(_, _, _, let install): install
        case .switchModel, .setContext, .setPictures, .install: true
        }
    }

    public var box: String? {
        switch self {
        case .status(let box), .activity(let box): box
        case .switchModel(let box, _), .install(let box, _): box
        case .setContext(let box, _, _): box
        case .setPictures(let box, _): box
        case .addModel(let box, _, _, _): box
        }
    }

    /// Read a request out of the tool's arguments; throws `ModelServerRequestError` with what is missing.
    public static func parse(_ args: JSONString) throws -> ModelServerRequest {
        let bag = JSONArgs.dictionary(args)
        func text(_ key: String) -> String? {
            guard let value = bag[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let box = text("box")
        let action = (text("action") ?? "status").lowercased().replacingOccurrences(of: "-", with: "_")
        switch action {
        case "status", "list":
            return .status(box: box)
        case "activity", "log":
            return .activity(box: box)
        case "switch", "swap":
            guard let model = text("model") else {
                throw ModelServerRequestError("switch needs `model`: a model's key or name from the status.")
            }
            return .switchModel(box: box, model: model)
        case "install":
            guard let model = text("model") else {
                throw ModelServerRequestError("install needs `model`: the key of a model the status lists as not installed.")
            }
            return .install(box: box, model: model)
        case "set_context", "context":
            guard let tokens = tokens(bag["context"]) else {
                throw ModelServerRequestError("set_context needs `context`: the window in tokens (262144) or short (\"256K\").")
            }
            return .setContext(box: box, model: text("model"), tokens: tokens)
        case "pictures", "set_pictures":
            guard let enabled = flag(bag["enabled"]) else {
                throw ModelServerRequestError("pictures needs `enabled`: true or false.")
            }
            return .setPictures(box: box, enabled: enabled)
        case "inspect_model", "add_model":
            guard let link = text("link") else {
                throw ModelServerRequestError("\(action) needs `link`: a Hugging Face link or owner/name.")
            }
            return .addModel(box: box, link: link, context: tokens(bag["context"]), install: action == "add_model")
        default:
            throw ModelServerRequestError("unknown action “\(action)”. Use status, switch, set_context, pictures, install, inspect_model, add_model or activity.")
        }
    }

    /// A context window as a model writes it: 262144, "262144", "256K", "512k", "1M", "262,144".
    public static func tokens(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let count = number.doubleValue
            return count >= 1 && count < 1e9 ? Int(count) : nil
        }
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !text.isEmpty else { return nil }
        var scale = 1.0
        if text.hasSuffix("k") {
            scale = 1024
            text.removeLast()
        } else if text.hasSuffix("m") {
            scale = 1024 * 1024
            text.removeLast()
        }
        text = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let count = Double(text), count > 0 else { return nil }
        // "1M" is 1,048,576 on a box that serves it; a model that says 1000000 means the same window.
        let total = count * scale
        return total >= 1 && total < 1e9 ? Int(total) : nil
    }

    /// true/false as a model writes it: a JSON boolean, or "on"/"off", "true"/"false", "yes"/"no".
    static func flag(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        switch (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "on"?, "true"?, "yes"?, "enable"?, "enabled"?: return true
        case "off"?, "false"?, "no"?, "disable"?, "disabled"?: return false
        default: return nil
        }
    }
}

/// Arguments `model_server` couldn't read.
public struct ModelServerRequestError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// `model_server`: look at and drive the Spark Swapper boxes.
public struct ModelServerTool: ToolExecutor {
    public static let name = "model_server"
    public static let spec = ToolSpec(
        name: name,
        description: """
        Look at and control the user's own model servers (DGX Spark or Strix Halo boxes running Spark Swapper): \
        what each box serves, its other models, memory and speed. Actions: `status` (default; read-only), \
        `switch` (stop the serving model and load another; takes minutes), `set_context` (serve a model with a \
        different context window, e.g. 256K or 512K; restarts it when it is serving), `pictures` (turn image \
        generation next to the model on or off), `install` (download a model the box lists as not installed), \
        `inspect_model` (look a Hugging Face repo up: can this box run it?), `add_model` (add a Hugging Face \
        model and install it) and `activity` (what changed on the box lately). Call `status` first to learn the \
        model keys. Anything but status, inspect_model and activity changes the box: do it only when the user \
        asks. If the box serves the model you are running on, a switch or a context change stops you until it \
        is back — finish what you are saying first.
        """,
        parameters: """
        {"type":"object","properties":{
            "action":{"type":"string","enum":["status","switch","set_context","pictures","install","inspect_model","add_model","activity"]},
            "box":{"type":"string","description":"Which box, by the start of its name or host name. Omit for the box behind this chat's model, or the only box."},
            "model":{"type":"string","description":"A model's key or name from status (switch, install, set_context)."},
            "context":{"description":"Context window in tokens (262144) or short (\\"256K\\", \\"512K\\") for set_context; optional for add_model.","anyOf":[{"type":"integer"},{"type":"string"}]},
            "enabled":{"type":"boolean","description":"For pictures: on or off."},
            "link":{"type":"string","description":"For inspect_model and add_model: a Hugging Face link or owner/name."}
        },"required":[]}
        """
    )

    /// What a request would do, in a sentence, for the permission prompt.
    public let describe: @Sendable (ModelServerRequest) async -> String
    /// Carry a request out and say what happened (an answer starting "Error:" when it didn't).
    public let perform: @Sendable (ModelServerRequest) async -> String

    public init(describe: @escaping @Sendable (ModelServerRequest) async -> String,
                perform: @escaping @Sendable (ModelServerRequest) async -> String) {
        self.describe = describe
        self.perform = perform
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let request: ModelServerRequest
        do {
            request = try ModelServerRequest.parse(args)
        } catch {
            return ToolResult(output: "Error: \(error.localizedDescription)")
        }
        if request.changesTheBox {
            // A subagent works on a slice of the task: the box everyone shares isn't its to change.
            guard context.depth == 0 else {
                return ToolResult(output: "Error: only the main agent may change a model server. Report back and let it decide.")
            }
            switch context.policy.preset {
            case .plan:
                return ToolResult(output: "Error: plan mode changes nothing. Put the change in the plan instead.")
            case .fullAccess:
                break
            case .workspaceWrite:
                let detail = await describe(request)
                let approved = await context.requestPermission("model-server-\(UUID().uuidString)", Self.name, detail)
                guard approved else {
                    return ToolResult(output: "Error: the user declined. Don't try again — ask what they would like instead.")
                }
            }
        }
        return ToolResult(output: await perform(request))
    }
}

// MARK: - A box's status, in words

extension SwapperStatus {
    /// What the box serves and could serve, for a model to read: one line per model, keys first, so a follow-up
    /// `switch` can name one. `name` is the box's name, `summary` what it is ("DGX Spark · Swapper 2.2.0").
    public func report(name: String, summary: String) -> String {
        var lines = ["\(name) — \(summary)"]
        if let model = activeModel {
            var line = "Serving: \(model.title) (key `\(model.key)`, model id `\(model.served_id)`, \(Self.shortWindow(model.window)) context"
            if let speed = model.speedText(roomForEstimate: true) { line += ", \(speed)" }
            lines.append(line + ")")
        } else if let loading, let model = models[loading] {
            lines.append("Loading: \(model.title) (key `\(model.key)`) — nothing answers yet")
        } else {
            lines.append("Serving: nothing right now")
        }
        if let job, job.isRunning {
            let title = models[job.target]?.title ?? job.target
            lines.append("Busy: switching to \(title) — \(job.currentStep?.label ?? "working")")
        }
        if let install = install_job, install.isRunning, let key = install.installingModel {
            lines.append("Installing: \(models[key]?.title ?? key) — \(install.currentStep?.label ?? "working")")
        }
        if let memory = memory?.value?.summary { lines.append("Memory: \(memory)") }
        if let pictures = pictures?.value, pictures.isInstalled {
            lines.append("Pictures: \(pictures.summary ?? (pictures.isOn ? "On" : "Off"))")
        }
        lines.append("Models:")
        for model in ordered {
            var parts = ["`\(model.key)` — \(model.title)", "\(Self.shortWindow(model.window)) context"]
            if let speed = model.speedText(roomForEstimate: true) { parts.append(speed) }
            if model.key == active {
                parts.append("serving")
            } else if !model.isInstalled {
                if let install = model.install, let summary = install.summary {
                    parts.append("not installed (\(summary))")
                } else {
                    parts.append("not installed")
                }
            } else {
                parts.append("installed, switching takes \(model.switchDuration)")
            }
            let windows = model.contextChoices
            if !windows.isEmpty { parts.append("windows: " + windows.map(\.name).joined(separator: " or ")) }
            if model.isExperimental { parts.append("experimental") }
            lines.append("- " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }
}

extension SwapperHFInspection {
    /// What the box said about a Hugging Face repo, for a model to read.
    public func report() -> String {
        var lines = ["\(repo): \(title ?? repo)"]
        var facts: [String] = []
        if let format = format?.value { facts.append(format) }
        if let quantization = quantization?.value { facts.append(quantization) }
        if let sizeText { facts.append(sizeText) }
        if let context_native { facts.append("\(SwapperStatus.shortWindow(context_native)) native context") }
        if let license = license?.value { facts.append("license \(license)") }
        if gated == true { facts.append("gated") }
        if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
        if let runsWith = profile_label?.value { lines.append("Runs with: \(runsWith)") }
        if let memory_gib { lines.append("Needs about \(Int(memory_gib)) GiB of memory") }
        if let existing = catalog_title?.value {
            var line = "The box's catalog already has this model as “\(existing)”"
            if let wrapped = catalog_key, let key = wrapped.value { line += " (key `\(key)`)" }
            lines.append(line + ": install that one instead.")
        }
        if let choices = gguf?.value, !choices.isEmpty {
            lines.append("Quantizations: " + choices.map { $0.label ?? $0.id }.joined(separator: ", "))
        }
        for problem in problems ?? [] { lines.append("Problem: \(problem)") }
        for warning in warnings ?? [] { lines.append("Note: \(warning)") }
        lines.append(canRun ? "This box can run it." : "This box can't run it.")
        return lines.joined(separator: "\n")
    }
}
