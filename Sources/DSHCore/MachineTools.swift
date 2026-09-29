import Foundation
import CoreGraphics

// MARK: - Machine tools (see and steer what's on screen)
//
// The debugging loop a human uses for a GUI app — run it, look at the window,
// read the error, screenshot the wrong-looking pixel — needs the same tools
// here. Screenshots and window enumeration go through CoreGraphics
// (`CGWindowListCopyWindowInfo`, `screencapture -l<id>`), clicking and typing
// through synthesized `CGEvent`s, so there is no dependency on cliclick or a
// JavaScript bridge. Accessibility permission (granted to DSH once, in System
// Settings) gates event posting; Screen Recording gates capture — both show
// the standard macOS prompts, and failures here say which one to fix.
//
// Images come back through ToolResult.images, so the engine ships them to the
// model on an attached user message (and prunes old ones so a long debug
// session doesn't burn the window on stale frames). When the selected model
// has no vision, the engine already swaps in a "use the text tools" note.
//
// Every tool here maps to ComputerAccess.observe/.control (see Permissions),
// so the first use in a chat asks once per chat and plan mode can't drive.

// MARK: - Window services (CoreGraphics, no AppleScript needed)

/// One on-screen window, from the window server. Layer 0 is ordinary app
/// windows; menubar/HUD/overlay chrome sits above it.
public struct WindowInfo: Sendable {
    public let id: UInt32
    public let owner: String
    public let title: String
    public let bounds: (x: Int, y: Int, w: Int, h: Int)
    public let layer: Int
}

public enum WindowServices {
    /// All on-screen windows, topmost first. Cheap (~ms) and needs no special
    /// permission — window *names* only require Screen Recording on some macOS
    /// versions, which is why titles may show as "?" until that is granted.
    public static func onScreenWindows(includeChrome: Bool = false) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [WindowInfo] = []
        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? UInt32 else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            let title = entry[kCGWindowName as String] as? String ?? ""
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            if !includeChrome && layer != 0 { continue }
            var bounds = (x: 0, y: 0, w: 0, h: 0)
            if let dict = entry[kCGWindowBounds as String] as? [String: CGFloat] {
                bounds = (Int(dict["X"] ?? 0), Int(dict["Y"] ?? 0), Int(dict["Width"] ?? 0), Int(dict["Height"] ?? 0))
            }
            out.append(WindowInfo(id: number, owner: owner, title: title, bounds: bounds, layer: layer))
        }
        return out
    }

    /// First window whose owner or title contains `needle` (case-insensitive),
    /// preferring ordinary windows over chrome.
    public static func match(_ needle: String) -> WindowInfo? {
        let lowered = needle.lowercased()
        let windows = onScreenWindows(includeChrome: true)
        return windows.first {
            $0.owner.lowercased().contains(lowered) || $0.title.lowercased().contains(lowered)
        }
    }
}

// MARK: - Image helpers

/// Cap what travels to the model: a 6K-px Retina window screenshot is ~1.5 MB
/// and thousands of vision tokens; 1600 px long-edge PNGs read fine and stay
/// near 200-400 KB. `sips` is the no-dependency downscaler.
enum ImagePipeline {
    static func prepare(pngAt file: URL, longEdge: Int) -> Data? {
        let scaled = file.deletingPathExtension().appendingPathExtension("s.png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        task.arguments = ["-Z", "\(longEdge)", file.path, "--out", scaled.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        var chosen: Data?
        if task.terminationStatus == 0 { chosen = try? Data(contentsOf: scaled) }
        if chosen == nil { chosen = try? Data(contentsOf: file) }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: scaled)
        guard let chosen, chosen.count > 32 else { return nil }
        return chosen
    }
}

private func tempPNG(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dsh-\(tag)-\(UUID().uuidString.prefix(8)).png")
}

/// Run a short helper binary (screencapture/osascript) capturing stdout.
private func runBinary(_ path: String, _ args: [String], timeout: TimeInterval) async
    -> (out: Data, err: Data, status: Int32) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let outPipe = Pipe(), errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            do { try task.run() } catch {
                continuation.resume(returning: (Data(), Data("\(error.localizedDescription)".data(using: .utf8) ?? Data()), -1))
                return
            }
            // Read to EOF on a deadline so a hung helper can't wedge the loop.
            let deadline = Date().addingTimeInterval(timeout)
            var outData = Data(), errData = Data()
            while task.isRunning || Date() < deadline {
                outData.append(outPipe.fileHandleForReading.availableData)
                errData.append(errPipe.fileHandleForReading.availableData)
                if !task.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if task.isRunning {
                task.terminate()
                // Drain whatever remains after the kill signal lands.
                outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            }
            task.waitUntilExit()
            continuation.resume(returning: (outData, errData, task.terminationStatus))
        }
    }
}

// MARK: - screenshot

public struct ScreenshotTool: ToolExecutor {
    public static let name = "screenshot"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Capture the screen (or one window, or one area) as a PNG and show it to \
            the model. `window` matches an app or window-title substring (e.g. "Godot") \
            — the usual way to watch a running game; `area` is x,y,w,h in points. \
            Big captures are downscaled to keep vision tokens sane. Pair with \
            process_start to debug GUI apps: start it, screenshot it, read its output, \
            fix, repeat.
            """,
        parameters: """
        {"type":"object","properties":{"window":{"type":"string","description":"Capture the window whose app or title contains this text"},"area":{"type":"string","description":"Region as x,y,width,height (points)"},"description":{"type":"string","description":"What you are looking for in the shot"}},"required":[]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        var captureArgs = ["-x", "-o", "-t", "png"]
        var what = "main display"
        if let window = Self.string(args, "window"), !window.isEmpty {
            guard let hit = WindowServices.match(window) else {
                let titles = WindowServices.onScreenWindows().prefix(12)
                    .map { "\($0.owner) — \($0.title.isEmpty ? "(untitled)" : $0.title)" }
                return .init(output: "Error: no window matching \"\(window)\". On screen now:\n"
                    + titles.joined(separator: "\n")
                    + "\n(list_windows shows everything; process_list shows what you started).")
            }
            what = "\(hit.owner) — \(hit.title.isEmpty ? "(window \(hit.id))" : hit.title)"
            captureArgs += ["-l", "\(hit.id)"]
        } else if let area = Self.string(args, "area"), !area.isEmpty {
            let clean = area.replacingOccurrences(of: " ", with: "")
            guard clean.split(separator: ",").count == 4 else {
                return .init(output: "Error: area must be x,y,width,height (e.g. \"100,200,800,600\").")
            }
            what = "region \(clean)"
            captureArgs += ["-R", clean]
        }
        let file = tempPNG("shot")
        captureArgs.append(file.path)
        let result = await runBinary("/usr/sbin/screencapture", captureArgs, timeout: 20)
        guard result.status == 0,
              let data = ImagePipeline.prepare(pngAt: file, longEdge: 1600) else {
            try? FileManager.default.removeItem(at: file)
            let why = String(decoding: result.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = result.status == 0 ? "capture produced no image" : "screencapture exit \(result.status): \(why.prefix(200))"
            return .init(output: "Error: \(reason).\nIf nothing was captured: System Settings → Privacy & Security → Screen Recording — enable DSH, then relaunch it.")
        }
        let note = Self.string(args, "description")
        return .init(output: "Captured \(what) (\(data.count / 1024) KB)\(note.map { " — looking for: \($0)" } ?? ""). It is shown below; describe what you see before deciding the next step.",
                     images: [MessageAttachment(kind: .image, name: "screenshot-\(what.prefix(30).replacingOccurrences(of: " ", with: "-")).png", data: data)])
    }
}

// MARK: - list_windows

public struct ListWindowsTool: ToolExecutor {
    public static let name = "list_windows"
    public static let spec = ToolSpec(
        name: name,
        description: "List on-screen windows: id, app — title, size. Target of screenshot/window= and the cheap way to see what is open (no screenshot tokens spent).",
        parameters: """
        {"type":"object","properties":{"app":{"type":"string","description":"Only windows of this app (substring)"}}}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let needle = Self.string(args, "app")
        var windows = WindowServices.onScreenWindows()
        if let needle, !needle.isEmpty {
            let lowered = needle.lowercased()
            windows = windows.filter { $0.owner.lowercased().contains(lowered) || $0.title.lowercased().contains(lowered) }
        }
        guard !windows.isEmpty else {
            return .init(output: needle.map { "No window matching \"\($0)\" is on screen." } ?? "No visible windows.")
        }
        let lines = windows.prefix(40).map { w in
            "• \(w.id)  \(w.owner) — \(w.title.isEmpty ? "(untitled)" : w.title)  [\(w.bounds.w)×\(w.bounds.h) at \(w.bounds.x),\(w.bounds.y)]"
        }
        return .init(output: "Windows (topmost first):\n" + lines.joined(separator: "\n")
            + (windows.count > 40 ? "\n… \(windows.count - 40) more" : ""))
    }
}

// MARK: - screen_watch

public struct ScreenWatchTool: ToolExecutor {
    public static let name = "screen_watch"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Watch a window: capture it every `interval` seconds for up to `duration`, \
            and return only the frames that actually changed — a freeze check for a \
            hung game ("every frame identical" = wedged), or watching an animation \
            settle. Cheaper than repeated screenshots when most frames are identical.
            """,
        parameters: """
        {"type":"object","properties":{"window":{"type":"string","description":"Window/app title substring"},"interval":{"type":"number","description":"Seconds between captures (default 1.5, min 0.5)"},"duration":{"type":"number","description":"Total seconds to watch (default 8, max 30)"}},"required":["window"]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let needle = Self.string(args, "window"), !needle.isEmpty,
              let hit = WindowServices.match(needle) else {
            return .init(output: "Error: no window matching \"\(Self.string(args, "window") ?? "?")\" right now.")
        }
        let interval = min(10, max(0.5, Self.double(args, "interval", default: 1.5)))
        let duration = min(30, max(interval, Self.double(args, "duration", default: 8)))
        let shots = max(2, Int(duration / interval))

        var previous: Data?
        var changed: [MessageAttachment] = []
        var identical = 0
        for index in 0..<shots {
            let file = tempPNG("watch")
            let result = await runBinary("/usr/sbin/screencapture",
                                        ["-x", "-o", "-t", "png", "-l", "\(hit.id)", file.path],
                                        timeout: 10)
            let data = result.status == 0 ? ImagePipeline.prepare(pngAt: file, longEdge: 1280) : nil
            guard let data else {
                try? FileManager.default.removeItem(at: file)
                return .init(output: "Error: capture failed at frame \(index) for \"\(hit.owner)\" (closed? grant Screen Recording to DSH).")
            }
            if let previous, data == previous {
                identical += 1
            } else {
                changed.append(MessageAttachment(kind: .image, name: "frame-\(index).png", data: data))
            }
            previous = data
            if index < shots - 1 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        if changed.count <= 1 {
            return .init(output: "Watched \"\(hit.owner) — \(hit.title)\" for \(Int(duration))s: \(shots) frames, essentially no pixel change — the window is not redrawing (hung, or idle by design). Its process is up if process_list/inspect_process says so; that points at the game loop, not the window.")
        }
        // First frame (context) + the most recent changes, capped so tokens stay sane.
        var picked: [MessageAttachment] = []
        if let first = changed.first { picked.append(first) }
        picked.append(contentsOf: changed.suffix(4))
        return .init(output: "Watched \"\(hit.owner) — \(hit.title)\" for \(Int(duration))s: \(changed.count) of \(shots) frames changed (\(identical) identical). Showing \(picked.count) (first + latest).")
            .withImages(picked)
    }
}

extension ToolResult {
    fileprivate func withImages(_ images: [MessageAttachment]) -> ToolResult {
        var copy = self
        copy.images = images
        return copy
    }
}

// MARK: - ui_tree

public struct UITreeTool: ToolExecutor {
    public static let name = "ui_tree"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Dump an app's accessibility tree (buttons, text, menus, values, positions) \
            by app/process name — the cheap text alternative to screenshots for NATIVE \
            apps (dialogs, editors, tool windows). Godot's own window draws its whole \
            UI with its renderer, so its tree is near-empty: use screenshot for the \
            game/editor viewport, and this for native panels (open-file dialogs, etc.).
            """,
        parameters: """
        {"type":"object","properties":{"app":{"type":"string","description":"Application/process name (e.g. 'Godot', 'Finder')"},"max_depth":{"type":"integer","description":"How deep to walk (default 3, max 6)"}},"required":["app"]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let app = Self.string(args, "app"), !app.isEmpty else {
            return .init(output: "Error: app is required.")
        }
        let depth = min(6, max(1, Self.int(args, "max_depth", default: 3)))
        let escaped = app.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        // One osascript call walks the front window. Two AppleScript rules
        // learned the hard way: System Events terminology only parses inside a
        // `tell` block (so even the handlers wrap their access in one), and
        // there is no \" string escape (quotes are built with character id 34).
        let script = """
        on walk(elems, level, maxLevel)
            set out to ""
            set pad to ""
            repeat level times
                set pad to pad & "  "
            end repeat
            repeat with e in elems
                set out to out & my describe(e, pad) & linefeed
                if level < maxLevel then
                    set kids to my childrenOf(e)
                    if kids is not {} then set out to out & my walk(kids, level + 1, maxLevel)
                end if
            end repeat
            return out
        end walk

        on childrenOf(e)
            tell application "System Events"
                try
                    return UI elements of e
                on error
                    return {}
                end try
            end tell
        end childrenOf

        on describe(e, pad)
            tell application "System Events"
                set Q to character id 34
                set s to pad
                try
                    set s to s & (role of e as text)
                end try
                try
                    set d to description of e
                    if d is not missing value then
                        set d to d as text
                        if d is not "" then set s to s & " " & Q & d & Q
                    end if
                end try
                try
                    set v to value of e
                    if v is not missing value then
                        set v to v as text
                        if (count of v) > 80 then set v to (text 1 thru 80 of v) & "…"
                        if v is not "" then set s to s & " = " & v
                    end if
                end try
                try
                    set pp to position of e
                    set ss to size of e
                    set s to s & " [" & (item 1 of pp) & "," & (item 2 of pp) & " " & (item 1 of ss) & "x" & (item 2 of ss) & "]"
                end try
                return s
            end tell
        end describe

        tell application "System Events"
            if not (exists process "\(escaped)") then return "ERROR_NO_PROCESS"
            tell process "\(escaped)"
                if (count of windows) is 0 then return "ERROR_NO_WINDOWS"
                set elems to UI elements of front window
            end tell
            return my walk(elems, 0, \(depth))
        end tell
        """
        let result = await runBinary("/usr/bin/osascript", ["-e", script], timeout: 25)
        let out = String(decoding: result.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errText = String(decoding: result.err, as: UTF8.self)
        if result.status != 0 || out.hasPrefix("ERROR_") {
            switch out {
            case "ERROR_NO_PROCESS":
                return .init(output: "Error: no running process named '\(app)'. Check the name (list_windows / process_list / inspect_process).")
            case "ERROR_NO_WINDOWS":
                return .init(output: "Error: '\(app)' is running but has no windows to inspect.")
            default:
                return .init(output: "Error: could not read the accessibility tree of '\(app)': \(errText.prefix(200)). Grant Accessibility permission: System Settings → Privacy & Security → Accessibility → DSH.")
            }
        }
        guard !out.isEmpty else {
            return .init(output: "'\(app)' exposes no UI elements — it almost certainly draws its own pixels (a game engine window). Use screenshot instead.")
        }
        let capped = out.count > 12_000 ? String(out.prefix(12_000)) + "\n… [truncated at 12k chars]" : out
        return .init(output: "Accessibility tree of '\(app)' (front window, depth \(depth)):\n\(capped)")
    }
}

// MARK: - inspect_process

public struct InspectProcessTool: ToolExecutor {
    public static let name = "inspect_process"
    public static let spec = ToolSpec(
        name: name,
        description: """
            System-level process inspection via ps/lsof: pid, CPU, memory, elapsed, \
            command — filter by name substring or inspect one pid (adds open files/ \
            sockets). Was Godot really started? Is it pegging CPU (render loop) or at \
            0% (wedged)? For processes YOU started with process_start, prefer \
            process_read — this one sees everything, including what the user launched.
            """,
        parameters: """
        {"type":"object","properties":{"match":{"type":"string","description":"Substring to match against the command (e.g. 'Godot')"},"pid":{"type":"integer","description":"Inspect one pid instead (adds lsof summary)"}},"required":[]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let pid = Self.int(args, "pid", default: 0)
        if pid > 0 {
            let out = await PTY.runCommand(
                "ps -p \(pid) -o pid,%cpu,%mem,etime,state,comm; echo '--- files ---'; lsof -p \(pid) 2>/dev/null | awk '$4 ~ /^[0-9]+[ru]?$/ || $5 == \"IPv4\" || $5 == \"IPv6\" {print $4, $5, $8, $9}' | head -25",
                cwd: context.policy.workspaceRoot, timeout: 15)
            let text = String(decoding: out.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(output: text.isEmpty ? "No process with pid \(pid)." : text)
        }
        guard let match = Self.string(args, "match"), !match.isEmpty else {
            return .init(output: "Error: give a match string or a pid.")
        }
        let safe = match.replacingOccurrences(of: "'", with: "'\\''")
        let out = await PTY.runCommand(
            "ps axo pid,%cpu,%mem,etime,state,command | grep -i '\(safe)' | grep -v grep | head -20",
            cwd: context.policy.workspaceRoot, timeout: 15)
        let text = String(decoding: out.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(output: text.isEmpty ? "No process command-line matching \"\(match)\"." : text)
    }
}

// MARK: - mouse / keyboard / focus_app (control, via CGEvent)

public struct MouseTool: ToolExecutor {
    public static let name = "mouse"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Click at screen coordinates (points, top-left origin): button=left/right/ \
            middle, clicks=1 or 2 (double), or drag with to_x/to_y (press at x,y, move, \
            release). Needs Accessibility permission for DSH. Coordinates come from \
            screenshot/list_windows geometry. Screenshot after clicking to verify.
            """,
        parameters: """
        {"type":"object","properties":{"x":{"type":"integer","description":"Screen x (points)"},"y":{"type":"integer","description":"Screen y (points)"},"button":{"type":"string","enum":["left","right","middle"],"description":"Default left"},"clicks":{"type":"integer","description":"1 default, 2 for double-click"},"to_x":{"type":"integer","description":"Drag release x"},"to_y":{"type":"integer","description":"Drag release y"}},"required":["x","y"]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let x = Self.double(args, "x", default: -1), y = Self.double(args, "y", default: -1)
        guard x >= 0, y >= 0 else { return .init(output: "Error: x and y are required (points from screenshot/list_windows).") }
        let button = (Self.string(args, "button") ?? "left").lowercased()
        let clicks = max(1, min(2, Self.int(args, "clicks", default: 1)))
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return .init(output: "Error: cannot create an event source (is the session headless?).")
        }
        let point = CGPoint(x: x, y: y)
        let cgButton: CGMouseButton = button == "right" ? .right : button == "middle" ? .center : .left
        let (down, up): (CGEventType, CGEventType) = button == "right"
            ? (.rightMouseDown, .rightMouseUp)
            : button == "middle" ? (.otherMouseDown, .otherMouseUp) : (.leftMouseDown, .leftMouseUp)

        func post(_ type: CGEventType, _ at: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: cgButton)?
                .post(tap: .cghidEventTap)
        }

        if let toX = Optional(Self.double(args, "to_x", default: -1)), toX >= 0,
           let toY = Optional(Self.double(args, "to_y", default: -1)), toY >= 0 {
            // Drag: press, several intermediate moves (some apps track them), release.
            post(down, point)
            let steps = 6
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                post(.mouseMoved, CGPoint(x: x + (toX - x) * t, y: y + (toY - y) * t))
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            post(up, CGPoint(x: toX, y: toY))
            return .init(output: "Dragged (\(Int(x)),\(Int(y))) → (\(Int(toX)),\(Int(toY))).")
        }

        post(.mouseMoved, point)
        try? await Task.sleep(nanoseconds: 40_000_000)
        for click in 0..<clicks {
            post(down, point)
            post(up, point)
            if click < clicks - 1 { try? await Task.sleep(nanoseconds: 60_000_000) }
        }
        return .init(output: "Clicked \(button)\(clicks > 1 ? " ×\(clicks)" : "") at (\(Int(x)),\(Int(y))). Screenshot to verify.")
    }
}

public struct KeyboardTool: ToolExecutor {
    public static let name = "keyboard"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Type into the frontmost app: text=literal string, and/or keys like \
            ["cmd,s"] ["return"] ["ctrl,c"] ["esc"] ["up","down"] with modifiers \
            cmd/ctrl/alt/shift. `app` activates that app first (the reliable pattern: \
            keyboard(app:"Godot", keys:["F5"])). Refused into terminal emulators and \
            DSH itself — that route would bypass the shell permission gate.
            """,
        parameters: """
        {"type":"object","properties":{"text":{"type":"string","description":"Literal text to type"},"keys":{"type":"array","items":{"type":"string"},"description":"Key combos, e.g. ['cmd,s','return']"},"app":{"type":"string","description":"Activate this app first (name)"}},"required":[]}
        """
    )

    public init() {}

    /// Ask System Events for the frontmost GUI process: (name, pid). A plain
    /// osascript call keeps DSHCore AppKit-free; costs ~50 ms.
    static func frontmostProcess() async -> (name: String, pid: pid_t)? {
        let result = await runBinary("/usr/bin/osascript", [
            "-e", "tell application \"System Events\" to get name of first process whose frontmost is true",
            "-e", "tell application \"System Events\" to get unix id of first process whose frontmost is true",
        ], timeout: 10)
        guard result.status == 0 else { return nil }
        let lines = String(decoding: result.out, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (lines[0].trimmingCharacters(in: .whitespaces), pid)
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        // Terminal-guard: resolve the *destination* app and refuse TTYs and DSH.
        var targetName = "frontmost app"
        if let app = Self.string(args, "app"), !app.isEmpty {
            targetName = app
            let quoted = app.replacingOccurrences(of: "\"", with: "\\\"")
            // set frontmost (System Events) only touches *running* processes —
            // unlike `tell application … activate`, which can launch a copy.
            let activated = await runBinary("/usr/bin/osascript", [
                "-e", "tell application \"System Events\" to set frontmost of process \"\(quoted)\" to true",
            ], timeout: 10)
            guard activated.status == 0 else {
                return .init(output: "Error: '\(app)' is not running or cannot be focused: \(String(decoding: activated.err, as: UTF8.self).prefix(200))")
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let front = await Self.frontmostProcess(), TerminalGuard.isBlocked(pid: front.pid) {
                return .init(output: TerminalGuard.refusal(appName: app))
            }
        } else if let front = await Self.frontmostProcess(), TerminalGuard.isBlocked(pid: front.pid) {
            return .init(output: TerminalGuard.refusal(appName: front.name))
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return .init(output: "Error: cannot create an event source.")
        }
        var typed = 0, pressed = 0
        if let text = Self.string(args, "text"), !text.isEmpty {
            // Unicode string injection: layout-independent, handles any scalar.
            for chunk in text.splitChunked(size: 20) {
                var utf16 = Array(chunk.utf16)
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    var empty = [UInt16]()
                    up.keyboardSetUnicodeString(stringLength: 0, unicodeString: &empty)
                    up.post(tap: .cghidEventTap)
                }
                typed += chunk.count
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        if let combos = JSONArgs.dictionary(args)["keys"] as? [Any] {
            for case let combo as String in combos {
                let parsed = Self.parseCombo(combo)
                guard let code = Self.keyCodes[parsed.key.lowercased()] else {
                    return .init(output: "Error: unknown key '\(combo)'. Known: enter, tab, esc, space, delete, up/down/left/right, home, end, pgup, pgdn, f1–f12, a–z, 0–9.")
                }
                var flags = CGEventFlags(rawValue: 0)
                if parsed.cmd { flags.insert(.maskCommand) }
                if parsed.ctrl { flags.insert(.maskControl) }
                if parsed.alt { flags.insert(.maskAlternate) }
                if parsed.shift { flags.insert(.maskShift) }
                for down in [true, false] {
                    if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) {
                        event.flags = flags
                        event.post(tap: .cghidEventTap)
                    }
                }
                pressed += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        guard typed > 0 || pressed > 0 else { return .init(output: "Error: give text and/or keys.") }
        return .init(output: "Typed \(typed) characters and \(pressed) key combo(s) into \(targetName). Screenshot to verify.")
    }

    // MARK: key mapping

    /// Virtual key codes (kVK_*), from Apple's HITools mapping.
    static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "enter": 36, "return": 36, "tab": 48, "esc": 53, "escape": 53,
            "space": 49, "delete": 51, "backspace": 51,
            "up": 126, "down": 125, "left": 123, "right": 124,
            "home": 115, "end": 119, "pgup": 116, "pgdn": 121,
        ]
        let fKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in fKeys.enumerated() { map["f\(index + 1)"] = code }
        let letterRows: [(String, [CGKeyCode])] = [
            ("qwertyuiop", [24, 26, 28, 25, 51, 29, 31, 32, 33, 30]),
            ("asdfghjkl", [0, 1, 2, 3, 4, 5, 6, 7, 8]),
            ("zxcvbnm", [6, 7, 8, 9, 11, 45, 46]),
            ("1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]),
        ]
        for (row, codes) in letterRows {
            for (i, ch) in row.enumerated() { map[String(ch)] = codes[i] }
        }
        return map
    }()

    struct Combo { var key: String; var cmd = false, ctrl = false, alt = false, shift = false }

    static func parseCombo(_ combo: String) -> Combo {
        let parts = combo.lowercased().split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        var c = Combo(key: parts.last ?? combo)
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": c.cmd = true
            case "ctrl", "control": c.ctrl = true
            case "alt", "option", "opt": c.alt = true
            case "shift": c.shift = true
            default: break
            }
        }
        return c
    }
}

public struct FocusAppTool: ToolExecutor {
    public static let name = "focus_app"
    public static let spec = ToolSpec(
        name: name,
        description: "Bring an application to the front by name (before screenshotting a game that renders behind other windows, or before keyboard/mouse input).",
        parameters: """
        {"type":"object","properties":{"app":{"type":"string","description":"Application name (e.g. 'Godot')"}},"required":["app"]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let app = Self.string(args, "app"), !app.isEmpty else {
            return .init(output: "Error: app is required.")
        }
        let quoted = app.replacingOccurrences(of: "\"", with: "\\\"")
        let result = await runBinary("/usr/bin/osascript", [
            "-e", "tell application \"System Events\" to set frontmost of process \"\(quoted)\" to true",
        ], timeout: 10)
        guard result.status == 0 else {
            let why = String(decoding: result.err, as: UTF8.self).prefix(160)
            return .init(output: "Error: '\(app)' is not running or not focusable (\(why)). process_list/inspect_process to check; process_start or `open -a \"\(app)\"` to launch it.")
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return .init(output: "Focused \(app).")
    }
}

// MARK: - view_image

public struct ViewImageTool: ToolExecutor {
    public static let name = "view_image"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Show an image FILE to the model — a screenshot the user dropped in, a \
            frame a process saved, an art asset under review. Downscaled to ~1600 px \
            long edge so vision tokens stay sane.
            """,
        parameters: """
        {"type":"object","properties":{"file_path":{"type":"string","description":"Image path (png/jpg/gif/webp; may be relative to the project)"}},"required":["file_path"]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "file_path") else {
            return .init(output: "Error: file_path is required.")
        }
        let (url, _) = context.policy.resolve(raw)
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) else {
            return .init(output: "Error: \(url.lastPathComponent) doesn't look like an image (\(ext.isEmpty ? "no extension" : ext)).")
        }
        // Downscale through a temp copy so the user's file is untouched.
        let tmp = tempPNG("view")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/cp")
        task.arguments = [url.path, tmp.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let data = ImagePipeline.prepare(pngAt: tmp, longEdge: 1600) else {
            try? FileManager.default.removeItem(at: tmp)
            return .init(output: "Error: cannot read \(url.path).")
        }
        return .init(output: "Loaded \(url.lastPathComponent) (\(data.count / 1024) KB).",
                     images: [MessageAttachment(kind: .image, name: url.lastPathComponent, data: data)])
    }
}

// MARK: - arg helpers

extension ToolExecutor {
    fileprivate static func double(_ json: JSONString, _ key: String, default def: Double) -> Double {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        if let d = dict[key] as? Double { return d }
        if let i = dict[key] as? Int { return Double(i) }
        return def
    }
}

extension String {
    /// Chunk for unicode keyboard injection (events carry ~20 utf16 units well).
    fileprivate func splitChunked(size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var count = 0
        for character in self {
            current.append(character)
            count += String(character).utf16.count
            if count >= size { chunks.append(current); current = ""; count = 0 }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
