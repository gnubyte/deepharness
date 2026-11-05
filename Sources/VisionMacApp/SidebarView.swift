import SwiftUI
import AppKit
import VisionHarnessCore

/// The left side: a big New Chat, search, then chats under collapsible
/// projects, or newest-first with one click. Agent mode lists its threads and
/// Guardian's people instead.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var search = ""
    /// `search`, a moment after typing stops.
    @State private var query = ""

    private var transport: AppTransport { model.transport }
    private var config: AppConfig { model.config }
    private var isAgentMode: Bool { model.mode == .agent }

    var body: some View {
        VStack(spacing: 0) {
            NewChatButton()
                .padding(.horizontal, 10)
                .padding(.top, 8)
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 8)
            navigation
                .padding(.horizontal, 6)
                .padding(.top, 6)
            if model.anythingRunning { runningBar.padding(.top, 6) }
            if !isAgentMode { sortPicker.padding(.horizontal, 10).padding(.top, 8) }

            List(selection: Binding(
                get: { transport.selectedID },
                set: { model.select($0) }
            )) {
                if isAgentMode {
                    agentList
                } else if config.sidebarByRecent {
                    recentList
                } else {
                    projectList
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) { footer }
        .task(id: search) {
            try? await Task.sleep(nanoseconds: 180_000_000)
            if !Task.isCancelled { query = search }
        }
    }

    // MARK: Top

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search chats", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private var navigation: some View {
        VStack(spacing: 0) {
            navRow("Open Folder…", icon: "folder.badge.plus") { model.chooseProject() }
            navRow("Chat Archive", icon: "archivebox", count: transport.archive.chats.count) { model.showArchive = true }
            navRow("Memory & Skills", icon: "brain") { model.showMemoryAndSkills = true }
        }
    }

    private func navRow(_ title: String, icon: String, count: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 18).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12))
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sortPicker: some View {
        Picker("Show chats", selection: Binding(get: { config.sidebarByRecent }, set: { config.sidebarByRecent = $0 })) {
            Text("Projects").tag(false)
            Text("Recent").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help("Group chats under their projects, or list them newest first")
    }

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

    // MARK: Which chats

    private var chats: [SessionVM] {
        transport.sessions.filter { !$0.isAgent && matches($0) }
    }

    private func matches(_ session: SessionVM) -> Bool {
        ModelSearch.matches(query: query, fields: [session.title, session.projectName ?? "", session.worktree?.branch ?? ""])
    }

    private static func newestFirst(_ a: SessionVM, _ b: SessionVM) -> Bool {
        if a.running != b.running { return a.running }
        return a.updatedAt > b.updatedAt
    }

    // MARK: By project

    private struct ProjectGroup: Identifiable {
        let id: String
        let url: URL?
        var name: String { url?.lastPathComponent ?? "Without a Project" }
        var chats: [SessionVM]
    }

    /// Projects with the latest activity first; opened projects with no chats after them.
    private var groups: [ProjectGroup] {
        var byPath: [String: [SessionVM]] = [:]
        // Standardized, so a path through a symlink can't make a second group.
        let key: (String) -> String = { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for chat in chats { byPath[chat.projectPath.map(key) ?? "", default: []].append(chat) }
        var groups = byPath.map { path, chats in
            ProjectGroup(id: path, url: path.isEmpty ? nil : URL(fileURLWithPath: path),
                         chats: chats.sorted(by: Self.newestFirst))
        }
        groups.sort { a, b in
            guard let first = a.chats.first, let second = b.chats.first else { return false }
            return Self.newestFirst(first, second)
        }
        if query.isEmpty {
            for url in config.liveRecentProjects where byPath[key(url.path)] == nil {
                groups.append(ProjectGroup(id: key(url.path), url: url, chats: []))
            }
        }
        return groups
    }

    @ViewBuilder
    private var projectList: some View {
        let groups = groups
        if groups.isEmpty {
            Text(query.isEmpty ? "No chats yet" : "No chats match")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        ForEach(groups) { group in
            ProjectHeader(url: group.url, name: group.name, count: group.chats.count,
                          isCurrent: group.url != nil && group.url?.standardizedFileURL == model.project?.standardizedFileURL,
                          isExpanded: isExpanded(group), toggle: { toggle(group) })
            if isExpanded(group) {
                ForEach(group.chats) { session in
                    row(session)
                }
            }
        }
    }

    private func isExpanded(_ group: ProjectGroup) -> Bool {
        !query.isEmpty || !config.sidebarCollapsed.contains(group.id)
    }

    private func toggle(_ group: ProjectGroup) {
        if config.sidebarCollapsed.contains(group.id) {
            config.sidebarCollapsed.remove(group.id)
        } else {
            config.sidebarCollapsed.insert(group.id)
        }
    }

    // MARK: Most recent

    @ViewBuilder
    private var recentList: some View {
        let sorted = chats.sorted(by: Self.newestFirst)
        if sorted.isEmpty {
            Text(query.isEmpty ? "No chats yet" : "No chats match")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        ForEach(sorted) { session in
            row(session, showProject: true)
        }
    }

    // MARK: Agent mode

    @ViewBuilder
    private var agentList: some View {
        let threads = transport.sessions.filter { $0.isAgent && matches($0) }
        Section("Threads") {
            ForEach(threads.sorted(by: Self.threadOrder)) { session in
                row(session)
            }
        }
        let people = model.guardianPeople.filter { person in
            !threads.contains { $0.person?.id == person.id }
                && ModelSearch.matches(query: query, fields: [person.displayName, person.title ?? ""])
        }
        if !people.isEmpty {
            Section("People in Guardian") {
                ForEach(people) { person in
                    Button {
                        model.openThread(with: person)
                    } label: {
                        HStack(spacing: 7) {
                            PersonAvatar(person: person, size: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(person.displayName).font(.system(size: 12)).lineLimit(1)
                                if let title = person.title {
                                    Text(title).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The main thread on top, then people, newest first.
    private static func threadOrder(_ a: SessionVM, _ b: SessionVM) -> Bool {
        if (a.person == nil) != (b.person == nil) { return a.person == nil }
        return a.updatedAt > b.updatedAt
    }

    // MARK: Rows

    private func row(_ session: SessionVM, showProject: Bool = false) -> some View {
        SessionRow(session: session, showProject: showProject,
                   isRenaming: renaming == session.id,
                   renameText: $renameText,
                   commitRename: { commitRename(session) })
            .tag(session.id)
            .contextMenu { menu(for: session) }
    }

    @ViewBuilder
    private func menu(for session: SessionVM) -> some View {
        Button("Rename…") {
            renameText = session.title
            renaming = session.id
        }
        if session.running {
            Button("Stop Agent") { transport.stopSession(session.id) }
        }
        Button("Add Folder to This Chat…") { model.addFolder(to: session) }
        if model.guardian.isSignedIn {
            Button("Send to Guardian…") { model.sendingToGuardian = session }
        }
        if let cwd = session.workspaceURL, !session.isAgent {
            Button("Reveal Project in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([cwd])
            }
        } else if !session.isAgent {
            Button("Reveal Chat Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([transport.scratchFolder(for: session, create: true)])
            }
        }
        Divider()
        if session.worktree != nil {
            // Archiving alone would strand the worktree; finishing deals with it.
            Button("Finish Worktree…") { model.finishingWorktree = session }
                .disabled(session.running)
        } else {
            Button("Archive") { transport.archiveSession(session.id, reason: "Archived from the sidebar") }
                .disabled(session.running)
            Button("Delete", role: .destructive) { transport.deleteSession(session.id) }
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
                if let email = model.guardian.accountEmail {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(email).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
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

/// The big green button, top left. The arrow beside it offers a worktree.
private struct NewChatButton: View {
    @Environment(AppModel.self) private var model

    private static let green = Color(red: 0.11, green: 0.66, blue: 0.33)

    var body: some View {
        HStack(spacing: 1) {
            Button {
                let session = model.newChat()
                model.select(session.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.mode == .agent ? "brain.head.profile" : "plus.bubble.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(model.mode == .agent ? "New Thread" : "New Chat")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .frame(maxWidth: .infinity)
                .background(Self.green)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New chat (⌘N)")

            if model.mode != .agent {
                Menu {
                    Button("New Chat") { model.select(model.newChat().id) }
                    Button("New Chat Without a Project") { model.select(model.newPlainChat().id) }
                    Button("New Chat in a Worktree…") { model.requestWorktreeChat() }
                        .disabled(model.project == nil)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 38)
                        .background(Self.green)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 32, height: 38)
                .background(Self.green)
                .help("More ways to start a chat")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Self.green.opacity(0.35), radius: 4, y: 1)
    }
}

/// One project's row: folds its chats, starts a new one.
private struct ProjectHeader: View {
    @Environment(AppModel.self) private var model
    let url: URL?
    let name: String
    let count: Int
    let isCurrent: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: isCurrent ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !isExpanded && count > 0 {
                        Text("\(count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering, let url {
                Button {
                    model.openProject(url, activateSession: false)
                    model.select(model.newChat().id)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New chat in \(name)")
            }
        }
        .padding(.top, 4)
        .onHover { hovering = $0 }
        .help(url?.path ?? "Chats with no project folder")
        .contextMenu {
            if let url {
                Button("New Chat") {
                    model.openProject(url, activateSession: false)
                    model.select(model.newChat().id)
                }
                Button("New Chat in a Worktree…") { model.requestWorktreeChat(project: url) }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                if count == 0 {
                    Divider()
                    Button("Remove from List") { model.forgetProject(url) }
                }
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    var showProject = false
    let isRenaming: Bool
    @Binding var renameText: String
    let commitRename: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            icon
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
                    if showProject, let project = session.projectName {
                        Text(project)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
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
        .padding(.leading, session.isAgent || showProject ? 0 : 12)
    }

    @ViewBuilder
    private var icon: some View {
        if session.running {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12)
        } else if let person = session.person {
            PersonAvatar(person: person, size: 16)
        } else {
            Image(systemName: session.isAgent ? "brain.head.profile"
                  : session.worktree != nil ? "arrow.triangle.branch" : "bubble.left")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .help(session.worktree.map { "In worktree branch \($0.branch)" } ?? "")
        }
    }
}

/// A person's picture when it's a usable address, otherwise their initials.
struct PersonAvatar: View {
    let person: GuardianPerson
    let size: CGFloat

    private var initials: String {
        person.displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        Group {
            if let raw = person.avatarUrl, raw.hasPrefix("https://"), let url = URL(string: raw) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.25))
            Text(initials).font(.system(size: size * 0.42, weight: .semibold))
        }
    }
}
