import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VisionHarnessCore

/// Above the composer: what makes this chat different. Its extra folders, its
/// worktree and whether that's ready to finish, or the person it talks to.
struct ChatContextBars: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let person = session.person {
                HStack(spacing: 7) {
                    PersonAvatar(person: person, size: 18)
                    Text("You're talking to \(person.displayName) in Guardian. They use their own tools there; this app's tools don't run in this thread.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !session.additionalFolders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Text("Also working in").font(.system(size: 10)).foregroundStyle(.secondary)
                        ForEach(session.additionalFolders, id: \.self) { path in
                            HStack(spacing: 3) {
                                Image(systemName: "folder").font(.system(size: 9))
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 11))
                                Button {
                                    model.transport.removeFolder(path, from: session)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .help("Remove from this chat")
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .help(path)
                        }
                    }
                }
            }
            if let worktree = session.worktree {
                worktreeBar(worktree)
            }
        }
    }

    private func worktreeBar(_ worktree: WorktreeRef) -> some View {
        let status = session.worktreeStatus
        let ready = (status?.hasWork ?? false) && !session.running
        return HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
            Text(worktree.branch).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(Self.describe(status)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(ready ? "Merge & Finish…" : "Finish…") { model.finishingWorktree = session }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(ready ? .green : .secondary)
                .disabled(session.running)
                .help("Merge into \(worktree.baseBranch), delete the worktree and archive this chat")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background((ready ? Color.green : Color.primary).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func describe(_ status: WorktreeStatus?) -> String {
        guard let status else { return "" }
        guard status.exists else { return "· the folder is gone" }
        var parts: [String] = []
        if status.ahead > 0 { parts.append("\(status.ahead) commit\(status.ahead == 1 ? "" : "s")") }
        if status.isDirty { parts.append("\(status.changedFiles.count) uncommitted") }
        return parts.isEmpty ? "· no changes yet" : "· " + parts.joined(separator: ", ")
    }
}

// MARK: - Worktree sheets

struct NewWorktreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: WorktreeRequest
    @State private var title = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Chat in a Worktree").font(.system(size: 14, weight: .semibold))
            Text("The chat gets its own folder and branch from \(request.project.lastPathComponent), so your checkout isn't touched until you merge.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("What's this work? (names the branch)", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(Theme.errorTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Creating…" : "Create", action: start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func start() {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !working else { return }
        working = true
        failure = nil
        Task {
            do {
                try await model.startWorktreeChat(project: request.project, title: name)
                dismiss()
            } catch {
                failure = error.localizedDescription
                working = false
            }
        }
    }
}

/// Merge, clean up, archive. Nothing is lost if a step refuses: the steps
/// before it stay done and the chat stays open.
struct FinishWorktreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionVM
    @State private var commitMessage = ""
    @State private var status: WorktreeStatus?
    @State private var working = false
    @State private var failure: String?
    @State private var conflict = false
    @State private var confirmDiscard = false

    private var transport: AppTransport { model.transport }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let worktree = session.worktree {
                Text("Finish “\(session.title)”").font(.system(size: 14, weight: .semibold))
                Text("Merges \(worktree.branch) into \(worktree.baseBranch), deletes the worktree and its branch, and saves this chat to the archive.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                summary(worktree)
                if status?.isDirty == true {
                    TextField("Commit message for the uncommitted changes", text: $commitMessage)
                        .textFieldStyle(.roundedBorder)
                }
                if let failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(Theme.errorTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if conflict {
                    Button("Ask the Agent to Resolve It") {
                        model.send("Merging this branch into \(worktree.baseBranch) conflicts. Merge \(worktree.baseBranch) into this branch, resolve the conflicts, run the tests and commit.", in: session)
                        dismiss()
                    }
                }
                HStack {
                    Button("Discard Work…", role: .destructive) { confirmDiscard = true }
                        .disabled(working)
                    Spacer()
                    Button("Not Yet") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(working ? "Working…" : primaryTitle(worktree)) { finish(worktree) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(working || status == nil
                                  || (status?.isDirty == true && commitMessage.trimmingCharacters(in: .whitespaces).isEmpty))
                }
                .confirmationDialog("Discard this worktree's work?", isPresented: $confirmDiscard) {
                    Button("Delete Worktree and Branch", role: .destructive) { discard(worktree) }
                } message: {
                    Text("Uncommitted changes and commits on \(worktree.branch) are deleted and can't be recovered. The chat is still archived.")
                }
            }
        }
        .padding(18)
        .frame(width: 480)
        .task {
            await transport.refreshWorktreeStatus(session)
            status = session.worktreeStatus
            if commitMessage.isEmpty { commitMessage = session.title }
        }
    }

    private func primaryTitle(_ worktree: WorktreeRef) -> String {
        status?.hasWork == true ? "Merge into \(worktree.baseBranch)" : "Delete Worktree & Archive"
    }

    @ViewBuilder
    private func summary(_ worktree: WorktreeRef) -> some View {
        if let status {
            VStack(alignment: .leading, spacing: 3) {
                if !status.exists {
                    Label("The worktree folder is already gone.", systemImage: "exclamationmark.triangle")
                }
                if status.ahead > 0 { Label("\(status.ahead) commit\(status.ahead == 1 ? "" : "s") to merge", systemImage: "arrow.triangle.merge") }
                if status.behind > 0 { Label("\(worktree.baseBranch) has \(status.behind) newer commit\(status.behind == 1 ? "" : "s")", systemImage: "arrow.down") }
                if status.isDirty { Label("\(status.changedFiles.count) uncommitted file\(status.changedFiles.count == 1 ? "" : "s"), committed first", systemImage: "pencil") }
                if !status.hasWork && status.exists { Label("Nothing to merge", systemImage: "checkmark") }
            }
            .font(.system(size: 12))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func finish(_ worktree: WorktreeRef) {
        working = true
        failure = nil
        conflict = false
        Task {
            defer { working = false }
            let git = transport.worktrees
            do {
                if status?.isDirty == true {
                    try await git.commitAll(worktree, message: commitMessage.trimmingCharacters(in: .whitespaces))
                }
                var reason = "Worktree \(worktree.branch) removed; nothing to merge"
                switch await git.merge(worktree, title: session.title) {
                case .merged(let commits):
                    reason = "Merged \(worktree.branch) into \(worktree.baseBranch) (\(commits) commit\(commits == 1 ? "" : "s"))"
                case .nothingToMerge:
                    break
                case .refused(let why):
                    if status?.exists == false { break }
                    failure = why
                    await refresh()
                    return
                case .conflict(let files):
                    let named = files.isEmpty ? "" : ": " + files.prefix(6).joined(separator: ", ")
                    failure = "That merge conflicts\(named). It was aborted, so \(worktree.baseBranch) is unchanged."
                    conflict = true
                    await refresh()
                    return
                }
                try await git.cleanUp(worktree)
                transport.archiveSession(session.id, reason: reason)
                dismiss()
            } catch {
                failure = error.localizedDescription
                await refresh()
            }
        }
    }

    private func discard(_ worktree: WorktreeRef) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await transport.worktrees.discard(worktree)
                transport.archiveSession(session.id, reason: "Discarded worktree \(worktree.branch) without merging")
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func refresh() async {
        await transport.refreshWorktreeStatus(session)
        status = session.worktreeStatus
    }
}

// MARK: - The archive

/// Every chat that left the sidebar: search them, read them, bring one back.
struct ChatArchiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [ArchivedChat]?
    @State private var selectedID: String?
    @State private var transcript = ""
    @State private var confirmDelete = false

    private var archive: ChatArchive { model.transport.archive }
    private var visible: [ArchivedChat] { results ?? archive.chats }
    private var selected: ArchivedChat? { visible.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat Archive").font(.system(size: 14, weight: .semibold))
                Text("\(archive.chats.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([archive.directory]) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    TextField("Search titles and messages", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
                    List(visible, selection: $selectedID) { chat in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chat.title).font(.system(size: 12)).lineLimit(1)
                            Text(subtitle(chat)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(chat.id)
                    }
                    .overlay {
                        if visible.isEmpty {
                            Text(search.isEmpty ? "Archived chats appear here." : "Nothing matches.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 860, height: 600)
        .task(id: search) {
            guard !search.trimmingCharacters(in: .whitespaces).isEmpty else {
                results = nil
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let query = search
            let chats = archive.chats
            let found = await Task.detached(priority: .userInitiated) { ChatArchive.search(query, in: chats) }.value
            if !Task.isCancelled { results = found }
        }
        .task(id: selectedID) {
            guard let chat = selected else {
                transcript = ""
                return
            }
            transcript = await Task.detached(priority: .userInitiated) { ChatArchive.transcript(of: chat) }.value
        }
    }

    private func subtitle(_ chat: ArchivedChat) -> String {
        ([chat.project, chat.archivedAt.relativeLabel] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var detail: some View {
        if let chat = selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let reason = chat.reason {
                            Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Restore") {
                        model.transport.restoreArchived(chat.id)
                        dismiss()
                    }
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                .padding(10)
                Divider()
                ScrollView {
                    Text(transcript)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .confirmationDialog("Delete “\(chat.title)” for good?", isPresented: $confirmDelete) {
                Button("Delete Forever", role: .destructive) {
                    archive.deleteForever(chat.id)
                    selectedID = nil
                }
            } message: {
                Text("Its files are removed from the archive and can't be recovered.")
            }
        } else {
            EmptyStateView(icon: "archivebox", title: "Pick a chat", message: "Read it here, or restore it to the sidebar.") { EmptyView() }
        }
    }
}
