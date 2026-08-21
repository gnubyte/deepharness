import SwiftUI
import Observation
import DSHCore

/// Which half of the app the window is showing.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case chat, code
    var id: String { rawValue }

    var label: String { self == .chat ? "Chat" : "Code" }
    var icon: String { self == .chat ? "bubble.left.and.bubble.right" : "chevron.left.forwardslash.chevron.right" }
}

/// Root-level state: the config, the transport that drives sessions, the
/// current project folder, and the code-mode workspace.
@MainActor
@Observable
final class AppModel {
    let config = AppConfig.shared
    let transport: AppTransport
    /// File tree, open editors, and terminals for the current project.
    let code = CodeWorkspace()

    var mode: WorkspaceMode = .chat {
        didSet { config.lastMode = mode.rawValue }
    }
    /// Presented over everything on first run, and on demand afterwards.
    var showWizard = false
    var showSettings = false
    var showMemoryAndSkills = false
    /// The folder both modes operate in.
    private(set) var project: URL?

    init() {
        transport = AppTransport(config: config)
        mode = WorkspaceMode(rawValue: config.lastMode) ?? .chat
        showWizard = !config.wizardCompleted || !config.isConfigured

        // The agent's file writes drive the editor's live reload.
        transport.onFilesChanged = { [weak self] changes in
            self?.code.applyExternalChanges(changes)
        }

        // Reopen the most recent project so the app comes back where it left off.
        if let recent = config.liveRecentProjects.first {
            openProject(recent, activateSession: false)
        }
    }

    var selectedSession: SessionVM? { transport.selected }

    // MARK: - Projects

    /// Ask for a folder and adopt it.
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the folder the agent should work in."
        if let project { panel.directoryURL = project }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    /// Adopt `url` as the project: it becomes the agent's working directory,
    /// the permission boundary, and the root of the file tree.
    func openProject(_ url: URL, activateSession: Bool = true) {
        project = url
        config.touchProject(url.path)
        transport.adoptProject(url)
        code.open(root: url)

        guard activateSession else { return }
        // Return to this project's most recent chat rather than piling up
        // empty ones.
        if let existing = transport.sessions.first(where: { $0.cwd == url.path }) {
            select(existing.id)
        } else {
            _ = newChat()
        }
    }

    func closeProject() {
        project = nil
        transport.adoptProject(nil)
        code.close()
    }

    func forgetProject(_ url: URL) {
        config.forgetProject(url.path)
        if project == url { closeProject() }
    }

    // MARK: - Sessions

    func select(_ id: String?) {
        transport.selectedID = id
        if let session = transport.selected {
            transport.hydrate(session)
            // Following a chat into its project keeps both modes in step.
            if let cwd = session.cwd, cwd != project?.path {
                openProject(URL(fileURLWithPath: cwd), activateSession: false)
            }
        }
    }

    @discardableResult
    func newChat() -> SessionVM {
        let session = transport.newSession(cwd: project?.path)
        return session
    }

    func send(_ text: String, in session: SessionVM) {
        transport.send(text, sessionID: session.id)
    }

    // MARK: - Stopping

    func stopSelected() {
        guard let session = selectedSession, session.running else { return }
        transport.stopSession(session.id)
    }

    func stopAll() { transport.stopAll() }

    var anythingRunning: Bool { !transport.runningSessions.isEmpty }
}
