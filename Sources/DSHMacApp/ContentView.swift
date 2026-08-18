import SwiftUI
import DSHKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SessionSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                if model.isConnected {
                    if let session = model.selected {
                        ConversationView(session: session)
                    } else {
                        EmptyStateView()
                    }
                } else {
                    ConnectView()
                }
            }
        }
        .task {
            if !model.isConnected { await model.connect() }
        }
        // Lives here, not in the conversation, so recovery is reachable even
        // with no chat selected — which is exactly when a wedged host is
        // hardest to deal with.
        .sheet(isPresented: $model.showRecovery) {
            HarnessRecoveryView().environment(model)
        }
        .sheet(isPresented: $model.showMemorySkills) {
            MemorySkillsView().environment(model)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.banner != nil }, set: { if !$0 { model.banner = nil } })
        ) {
            Button("OK") { model.banner = nil }
        } message: {
            Text(model.banner ?? "")
        }
    }
}

// MARK: - Sidebar

struct SessionSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedID) {
            if searching {
                SearchResults()
            } else {
                // Workspaces first, in the registry's durable order, then
                // whatever no workspace accounts for.
                ForEach(model.workspaces) { workspace in
                    WorkspaceSection(workspace: workspace)
                }
                let ungrouped = model.ungroupedSessions
                if !ungrouped.isEmpty {
                    Section(model.workspaces.isEmpty ? "Chats" : "Ungrouped") {
                        ForEach(ungrouped) { session in
                            SessionRow(session: session).tag(session.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { RunningAgentsBar() }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "Search chats")
        .onChange(of: model.searchQuery) { _, q in model.runSearch(q) }
        .overlay {
            if !searching, model.visibleSessions.isEmpty {
                ContentUnavailableView(
                    "No chats yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Press ⌘N to start one.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Chat") {
                        let id = model.activeProject?.id
                        Task { await model.newSession(workspaceId: id) }
                    }
                    Divider()
                    Button("Open Project Folder…") { ProjectPicker.open(into: model) }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                } primaryAction: {
                    let id = model.activeProject?.id
                    Task { await model.newSession(workspaceId: id) }
                }
                .disabled(!model.isConnected)
                .help("New chat (⌘N) · Open a project folder (⌘O)")
            }
        }
        .safeAreaInset(edge: .bottom) { ConnectionBar() }
        .onChange(of: model.selectedID) { _, id in
            guard let id, let vm = model.sessions.first(where: { $0.id == id }) else { return }
            Task { await model.hydrate(vm) }
        }
    }

    private var searching: Bool {
        !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

}

// MARK: - Workspace grouping

struct WorkspaceSection: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    @State private var renaming = false
    @State private var draftTitle = ""

    var body: some View {
        let sessions = model.sessions(in: workspace)
            .filter { !model.archivedSessionIds.contains($0.id) }

        Section {
            ForEach(sessions) { session in
                SessionRow(session: session).tag(session.id)
            }
            if sessions.isEmpty {
                Text("No chats").font(.caption).foregroundStyle(.tertiary)
            }
        } header: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.caption2)
                Text(workspace.title)
            }
            .contextMenu {
                Button("New Chat Here") {
                    // Attach through the workspace so the session is accounted
                    // by it, rather than merely sharing its path.
                    Task { await model.newSession(workspaceId: workspace.id) }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
                }
                Button("Rename…") {
                    draftTitle = workspace.title
                    renaming = true
                }
                Divider()
                Button("Remove Workspace", role: .destructive) {
                    Task { await model.deleteWorkspace(workspace) }
                }
                .help("Removes the grouping only — no files or chats are deleted")
            }
        }
        .alert("Rename workspace", isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                Task { await model.renameWorkspace(workspace, title: title) }
            }
        }
    }
}

// MARK: - Search

struct SearchResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section(header: Text(headerText)) {
            ForEach(model.searchHits) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: hit)).lineLimit(1)
                    Text(hit.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
                .tag(hit.sessionId)
            }
            if let error = model.searchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.searchHits.isEmpty {
                Text("No matches").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// The contract caps results at 20 with no cursor, so `hasMore` is an
    /// instruction to narrow the query rather than a page to fetch.
    private var headerText: String {
        if model.searchError != nil { return "Search unavailable" }
        return model.searchHasMore
            ? "Results (showing first \(model.searchHits.count) — refine to narrow)"
            : "Results (\(model.searchHits.count))"
    }

    private func title(for hit: SearchHit) -> String {
        model.sessions.first { $0.id == hit.sessionId }?.displayTitle ?? "Chat"
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var renaming = false
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: 8) {
            if session.running {
                ProgressView().controlSize(.small).frame(width: 12)
            } else {
                Circle()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .frame(width: 12)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle).lineLimit(1)
                Text(session.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Reachable without selecting the chat first.
            StopButton(session: session, compact: true)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Rename…") {
                draftTitle = session.displayTitle
                renaming = true
            }
            Button("Fork") { Task { await model.fork(session) } }
            if session.running {
                Divider()
                Button("Stop Agent") { Task { await model.stop(session) } }
                Button("Stop Subagents") { Task { await model.stopSubagents(session) } }
            }
            Divider()
            if model.archivedSessionIds.contains(session.id) {
                Button("Unarchive") { Task { await model.setArchived(session, archived: false) } }
            } else {
                Button("Archive") { Task { await model.setArchived(session, archived: true) } }
            }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                Task { await model.rename(session, to: title) }
            }
        }
    }
}

// MARK: - Connection status

struct ConnectionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if case .failed = model.connection {
                Button("Retry") { Task { await model.connect() } }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Button {
                model.showRecovery = true
            } label: {
                Image(systemName: "stethoscope").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Harness recovery — stop agents, reconnect, restart")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var color: Color {
        switch model.connection {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }

    private var label: String {
        switch model.connection {
        case .connected(let version, _): "Connected · dsh \(version)"
        case .connecting: "Connecting…"
        case .failed(let why): why
        case .disconnected: "Not connected"
        }
    }
}

// MARK: - Empty / connect states

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No chat selected", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Open a project folder to have the agent work in it, or start a chat in the host directory.")
        } actions: {
            VStack(spacing: 8) {
                Button("Open Project Folder…") { ProjectPicker.open(into: model) }
                    .buttonStyle(.borderedProminent)
                Button("New Chat") { Task { await model.newSession() } }
            }
        }
    }
}

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var urlText = "http://127.0.0.1:3099"
    @State private var repoPath = ""
    @State private var port = 3099

    var body: some View {
        VStack(spacing: 20) {
            Group {
                if let logo = logoImage {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                } else {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                }
            }
            Text("Connect to a harness").font(.title2).bold()

            if case .failed(let why) = model.connection {
                Text(why)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
            }

            GroupBox("Attach to a running server") {
                HStack {
                    TextField("http://127.0.0.1:3099", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                    Button("Connect") {
                        guard let url = URL(string: urlText) else { return }
                        model.baseURL = url
                        Task { await model.connect() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(6)
            }

            GroupBox("Or start one from a checkout") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("/path/to/deepseek-harness", text: $repoPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseRepo() }
                    }
                    HStack {
                        Text("Port")
                        TextField("", value: $port, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Spacer()
                        Button("Start & Connect") {
                            Task { await model.startHarnessAndConnect(repoPath: repoPath, port: port) }
                        }
                        .disabled(repoPath.isEmpty)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: 560)
        .padding(40)
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url { repoPath = url.path }
    }
}

/// Loads the bundled logo from the app's Resources, falling back to nil so the
/// view can show its SF Symbol placeholder instead.
private var logoImage: NSImage? {
    if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"),
       let image = NSImage(contentsOf: url) {
        return image
    }
    return nil
}
