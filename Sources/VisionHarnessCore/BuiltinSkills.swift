import Foundation

// MARK: - Builtin skills
//
// Skills that ship with the app, written to SkillLocations.builtinSkills on
// launch ("Skills shipped with the app, re-installed on launch"). The shipped
// text is authoritative: a user copy at that path is rewritten whenever it
// differs, so an app update always brings the builtin set current. For a
// skill the user wants to own and edit, copy it into the user skills folder
// (higher precedence) instead of editing the builtin one.

public struct BuiltinSkill: Sendable {
    public let slug: String
    public let skillMarkdown: String
    /// Written alongside SKILL.md as reference the model reads on demand.
    public let files: [String: String]

    public init(slug: String, skillMarkdown: String, files: [String: String] = [:]) {
        self.slug = slug
        self.skillMarkdown = skillMarkdown
        self.files = files
    }
}

public enum SkillBuiltin {
    public static let all: [BuiltinSkill] = [godotDebugging]

    /// Write every builtin skill into `directory` unless an identical copy is
    /// already there. Returns the slugs that changed (for a launch note).
    @discardableResult
    public static func install(into directory: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var changed: [String] = []
        for skill in all {
            let folder = directory.appendingPathComponent(skill.slug, isDirectory: true)
            let manifest = folder.appendingPathComponent("SKILL.md")
            if let existing = try? String(contentsOf: manifest, encoding: .utf8),
               existing == skill.skillMarkdown {
                // Up to date; still ensure bundled files exist.
            } else {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try skill.skillMarkdown.write(to: manifest, atomically: true, encoding: .utf8)
                changed.append(skill.slug)
            }
            for (name, text) in skill.files {
                let file = folder.appendingPathComponent(name)
                if (try? String(contentsOf: file, encoding: .utf8)) != text {
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                }
            }
        }
        return changed
    }

    // MARK: - godot-debugging

    static let godotDebugging = BuiltinSkill(
        slug: "godot-debugging",
        skillMarkdown: """
        ---
        name: godot-debugging
        description: >-
          Debug a Godot 4 game/editor on macOS efficiently — use when the user
          mentions Godot, GDScript errors, a game that won't start, a black or
          frozen game window, or asks to verify a change "in the game". Covers
          running the engine as a background process, streaming its output,
          screenshotting the window, and watching for a freeze.
        ---

        # Goal

        Find and fix Godot problems with the fewest tokens: read the engine's own
        output first, look at pixels only when output can't answer the question.

        # Find the binary

        Try in order (run_shell_command, `command -v` each):
        `godot`, `godot4`, `/Applications/Godot.app/Contents/MacOS/Godot`,
        `~/Applications/Godot.app/Contents/MacOS/Godot`.
        Ask the user if none exist. The project folder is the one containing
        `project.godot` (`glob **/project.godot`).

        # Run it as a background process — never run_shell_command

        Godot is interactive and long-running: it belongs on `process_start`.
        ```
        process_start(command: "<godot> --path <project> --editor", description: "godot editor")
        process_read(id: "p1", until: "Godot Engine v", timeout: 30)
        ```
        If `until` times out, the returned output already shows why (missing
        display, import errors). A game run is the same without `--editor`.
        Send input to it with `process_write` (REPLs, prompts, in-game keys).

        # The cheap-first debug order

        1. `process_read` — GDScript errors print to the terminal:
           `SCRIPT ERROR:`, `ERROR:`, `user://` paths, stack-ish `at:` lines.
           `until: "SCRIPT ERROR"` waits for exactly this. Grep what you get for
           `res://` paths and open those files.
        2. Import/editor corruption: `--headless --import` (fast, no window, dies
           cleanly). Re-read its full output.
        3. Suspected crash/hang of the game: `inspect_process(match: "godot")` —
           ~100% CPU = render loop alive (look at pixels); 0% + no output =
           wedged (look at the last log lines and the stack in
           ~/Library/Logs/DiagnosticReports for the process name).
        4. Only now `screenshot(window: "Godot")` — black window vs wrong scene
           vs dialog overlay are different bugs. Name what you expect to see via
           `description:` and describe it back before acting.
        5. `screen_watch(window: "Godot")` distinguishes "renders once then
           freezes" (hung _process) from "animates but wrong".

        # Driving the app

        - `keyboard(app: "Godot", keys: ["F5"])` runs the scene from the editor;
          ["F8"] stops. Always pass `app` — it focuses first (the reliable
          pattern), and a `screenshot` after verifies.
        - `mouse(x:, y:)` for in-game UI clicks; coordinates come from the last
          screenshot's geometry (it is downscaled — scale back to window points
          from `list_windows`, and say so).
        - `ui_tree(app:)` is for NATIVE dialogs only (file pickers). Godot's
          window is one big metal layer: pixels, not a11y.

        # Verify, then stop the loop

        After each fix: `process_stop` the old run, `process_start` a new one,
        `process_read(until:)` for the line that used to error. Don't claim a
        fix without that observation. Clean up: stop processes you started;
        leave the user's own running.

        Gotchas, binary paths, headless flags and a worked session:
        `read_file` the bundled `macos-notes.md` next to this skill.
        """,
        files: [
            "macos-notes.md": """
            # Godot on macOS — reference

            ## Binary / invocation
            - Steam installs keep the binary inside the bundle:
              `~/Library/Application\\ Support/Steam/steamapps/common/Godot\\ Engine/Godot.app/Contents/MacOS/Godot`
            - `--path` selects the project; without it Godot opens the project manager.
            - Headless import (no window, exits): `--headless --import --path <proj>`
            - One-shot script run: `--headless --path <proj> --script res://tools/check.gd --quit`
            - Verbose logging for hard cases: `--verbose`; demos: `--quit-after 200`
              quits after N frames (turns an infinite run into a bounded one).

            ## Reading Godot's output
            - `SCRIPT ERROR: ... at: res://foo.gd:LINE` — the line to open.
            - `ERROR: ...` lines without SCRIPT are engine-level (resource
              load fails, null refs). Often the real cause sits two lines above.
            - First-run import is LOUD and mostly harmless; only judge errors on
              a second run after `--headless --import` finished once.
            - Watch for `[解禁 Godot]`-style localized noise: ignore banners,
              grep for ERROR/WARNING/SCRIPT.

            ## Window / screenshot specifics
            - The game window title is the project name from project.godot
              (`config/name=...`) — match on that or on "Godot".
            - Screenshots come downscaled to 1600 px long edge: a Retina game
              window (e.g. 1920×1080 pts) maps pixel→point at the ratio printed
              by `list_windows`; divide before clicking.
            - A window showing the macOS "Godot is not responding" beachball
              belongs to WindowServer, not the game: `screen_watch` sees no
              change; `inspect_process` CPU 0% confirms the wedge.

            ## A worked session (pattern to copy)
            1. `process_start(command: "godot --path game --editor", ...)` →
               `process_read(id, until: "Godot Engine v")`.
            2. `keyboard(app: "Godot", keys: ["F5"])` — start the scene.
            3. `process_read(id, until: "SCRIPT ERROR", timeout: 10)` — timeout
               means clean; a match gives file:line.
            4. `screenshot(window: "Godot", description: "player at spawn")`.
            5. Edit the script → `process_write(id, keys:["F8"], wait:1)` →
               `keyboard(app:"Godot", keys:["F5"])` → repeat from 3.
            6. Done: `process_stop(id)`.
            """
        ]
    )
}
