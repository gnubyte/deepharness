import Foundation

// MARK: - Chats without a project
//
// A chat with a project folder is a coding agent working in that folder. A chat without one is a regular
// conversation: it gets a prompt of its own (it never asks for a folder), a scratch folder of its own to work in
// when something needs files or commands, the user's own instruction files and skills, and no project context.

public enum ChatPrompt {
    /// Which kind of prompt a chat gets.
    public enum Kind: Equatable, Sendable {
        /// A project folder is open: the coding agent.
        case coding
        /// No project: a regular conversation.
        case plain
    }

    public static func kind(project: URL?) -> Kind {
        project == nil ? .plain : .coding
    }

    /// The prompt for a regular conversation, with the chat's scratch folder.
    public static func plain(scratch: URL, platform: String = "macOS") -> String {
        "You are Vision, a helpful assistant in a native \(platform) app. This is a regular conversation: no project folder is open and none is needed — never ask the user to open one. Answer directly and naturally; match the length of your answer to the question. Use tools only when they help: look things up with web_fetch, use one of the user's skills when it fits the request, and remember lasting preferences with memory. When something needs files or commands — a skill that runs a script, a document to draft, data to convert — work in this chat's own scratch folder, \(scratch.path); it belongs to this chat and starts empty. Tell the user where a file you made is when it matters."
    }

    /// Where memory lives on the Mac, said after the prompt above (the Mac has no memory tool: the user's own
    /// MEMORY.md is read into every chat without a project).
    public static let macMemory =
        "Memory here is the user's own ~/MEMORY.md, which is read into every chat without a project: to remember a lasting preference, add a line to it (writing outside the scratch folder asks the user first)."

    /// The base prompt for a chat: the coding agent's with a project, the plain one without.
    public static func base(project: URL?, scratch: URL, codingPrompt: String) -> String {
        switch kind(project: project) {
        case .coding: codingPrompt
        case .plain: plain(scratch: scratch) + " " + macMemory
        }
    }

    /// A chat's own scratch folder: `<app data>/Chats/<chat id>`.
    public static func scratchFolder(chatID: String, appSupport: URL) -> URL {
        appSupport.appendingPathComponent("Chats", isDirectory: true).appendingPathComponent(chatID, isDirectory: true)
    }

    /// Machine facts for a chat without a project (no project folder, no branch).
    public static func environment(scratch: URL, model: String, preset: PermissionPreset) -> String {
        [
            "--- Environment ---",
            "Chat folder (scratch): \(scratch.path)",
            "Platform: macOS",
            "Today's date: \(ProjectContext.dayStamp())",
            "Model: \(model)",
            "Permission preset: \(preset.rawValue)",
        ].joined(separator: "\n")
    }

    /// The user's own instruction files (in their home folder), for a chat without a project.
    public static func userInstructions(_ files: [InstructionFile]) -> String? {
        guard !files.isEmpty else { return nil }
        return files.map { file in
            """
            --- ~/\(file.label) (the user's own instructions — follow these) ---
            \(file.text.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }.joined(separator: "\n\n")
    }
}
