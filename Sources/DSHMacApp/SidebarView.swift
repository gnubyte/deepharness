import SwiftUI
import AppKit
import DSHCore

/// Projects and chats. Anything running sorts to the top and stays reachable
/// without opening its chat.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var renameText = ""

    private var transport: AppTransport { model.transport }

    var body: some View {
        VStack(spacing: 0) {
            if model.anythingRunning { runningBar }

            List(selection: Binding(
                get: { transport.selectedID },
                set: { model.select($0) }
            )) {
                projectSection
                chatSection
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: Running bar

    private var runningBar: some View {
        let running = transport.runningSessions
        return Button {
            if let first = running.first { model.select(first.id) }
        } label: {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(running.count == 1 ? "1 agent running" : "\(running.count) agents running")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("Stop All") { model.stopAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.errorTint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.accentColor.opacity(0.12))
    }

    // MARK: Projects

    @ViewBuilder
    private var projectSection: some View {
        Section("Project") {
            if let project = model.project {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(project.lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let branch = ProjectContext.gitBranch(at: project) {
                            Text(branch)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project]) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(project.path, forType: .string)
                    }
                    Divider()
                    Button("Close Project") { model.closeProject() }
                }
            }

            Button {
                model.chooseProject()
            } label: {
                Label("Open Folder…", systemImage: "folder.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            let recents = model.config.liveRecentProjects.filter { $0 != model.project }
            if !recents.isEmpty {
                DisclosureGroup("Recent") {
                    ForEach(recents, id: \.self) { url in
                        Button {
                            model.openProject(url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                        .contextMenu {
                            Button("Remove from Recents") { model.forgetProject(url) }
                        }
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    // MARK: Chats

    @ViewBuilder
    private var chatSection: some View {
        let sessions = orderedSessions
        Section("Chats") {
            if sessions.isEmpty {
                Text("No chats yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                SessionRow(session: session,
                           isRenaming: renaming == session.id,
                           renameText: $renameText,
                           commitRename: { commitRename(session) })
                    .tag(session.id)
                    .contextMenu {
                        Button("Rename…") {
                            renameText = session.title
                            renaming = session.id
                        }
                        if session.running {
                            Button("Stop Agent") { transport.stopSession(session.id) }
                        }
                        if let cwd = session.workspaceURL {
                            Button("Reveal Project in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([cwd])
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { transport.deleteSession(session.id) }
                    }
            }
        }
    }

    /// Running chats first, then most recent.
    private var orderedSessions: [SessionVM] {
        transport.sessions.sorted {
            if $0.running != $1.running { return $0.running }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func commitRename(_ session: SessionVM) {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { transport.renameSession(session.id, to: title) }
        renaming = nil
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("New chat (⌘N)")

                Spacer()

                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let isRenaming: Bool
    @Binding var renameText: String
    let commitRename: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if session.running {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12)
            } else {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Title", text: $renameText, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                } else {
                    Text(session.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 4) {
                    if let project = session.projectName, project != model.project?.lastPathComponent {
                        Text(project)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Text(session.updatedAt.relativeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if session.running {
                Button {
                    model.transport.stopSession(session.id)
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.errorTint)
                .help("Stop this agent")
            }
        }
        .padding(.vertical, 2)
    }
}
