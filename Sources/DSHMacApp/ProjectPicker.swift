import SwiftUI
import AppKit

/// Folder selection for coding projects.
enum ProjectPicker {
    /// Ask for a directory to hand to the agent as a project.
    ///
    /// Only existing directories are offered because `workspace.create`
    /// adopts a directory and never makes one — letting the panel create a
    /// folder would produce a path the harness then rejects.
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the folder the agent should work in."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Pick a folder and open it as a project.
    @MainActor
    static func open(into model: AppModel) {
        guard let url = choose() else { return }
        Task { await model.openProject(path: url.path) }
    }
}

/// Compact display of the folder a chat runs in.
struct ProjectBadge: View {
    let path: String
    var projectTitle: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.caption2)
            Text(projectTitle ?? (path as NSString).lastPathComponent)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(path)
    }
}
