import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VisionHarnessCore

/// Where a chat can be sent in Guardian.
private enum SendTarget: String, CaseIterable, Identifiable {
    case person, coder, deliveryBoard, kanban
    var id: String { rawValue }
    var label: String {
        switch self {
        case .person: "A person"
        case .coder: "AI Coders project"
        case .deliveryBoard: "Project board"
        case .kanban: "Kanban"
        }
    }
    var help: String {
        switch self {
        case .person: "They get your directive and the files in a chat of their own, and start on it as a task. Their reply comes back here."
        case .coder: "Starts an AI Coders chat on the project with your directive and the files."
        case .deliveryBoard: "Adds a card to the project's delivery board, in the column you pick. Files go in as links, because this board's cards don't hold attachments."
        case .kanban: "Adds a card to a Kanban board, in the column you pick, with the files attached."
        }
    }
}

/// Send a whole chat, plus any files, to someone in Guardian with a directive.
struct SendToGuardianSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionVM

    @State private var target: SendTarget = .person
    @State private var directive = ""
    @State private var includeTranscript = true
    /// Mask what the shield would mask for any model that isn't private. Guardian is an online service.
    @State private var maskSensitive = true
    @State private var files: [URL] = []

    @State private var person: GuardianPerson?
    @State private var projects: [GuardianProject] = []
    @State private var project: GuardianProject?
    @State private var deliveryColumn: GuardianDeliveryColumn = .backlog
    @State private var boards: [GuardianBoard] = []
    @State private var board: GuardianBoard?
    @State private var columns: [GuardianBoardColumn] = []
    @State private var column: GuardianBoardColumn?

    @State private var loadError: String?
    @State private var sending = false
    @State private var failure: String?

    private var client: GuardianClient? { model.guardian.client }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Send to Guardian").font(.system(size: 14, weight: .semibold))
            Picker("Send to", selection: $target) {
                ForEach(SendTarget.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(target.help).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            destination

            Text("What should they do with it?").font(.system(size: 12, weight: .medium))
            TextEditor(text: $directive)
                .font(.system(size: 12))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))

            Toggle("Include this whole chat (“\(session.title)”)", isOn: $includeTranscript)
                .font(.system(size: 12))
            if ProviderClients.shield?.detector() != nil {
                Toggle("Mask sensitive details in the text", isOn: $maskSensitive).font(.system(size: 12))
                if maskSensitive && !files.isEmpty {
                    Text("Files you add go as they are: the shield can't check them.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            filesList

            if let failure = failure ?? loadError {
                Text(failure).font(.system(size: 11)).foregroundStyle(Theme.errorTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
        }
        .padding(18)
        .frame(width: 520)
        .task(id: target) { await load() }
        .task(id: board) { await loadColumns() }
    }

    @ViewBuilder
    private var destination: some View {
        switch target {
        case .person:
            let people = model.guardianPeople
            if people.isEmpty {
                Text("No people are shared with this account.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Picker("Person", selection: $person) {
                    Text("Choose…").tag(GuardianPerson?.none)
                    ForEach(people) { candidate in
                        Text(candidate.title.map { "\(candidate.displayName), \($0)" } ?? candidate.displayName)
                            .tag(GuardianPerson?.some(candidate))
                    }
                }
            }
        case .coder:
            projectPicker
        case .deliveryBoard:
            projectPicker
            Picker("Column", selection: $deliveryColumn) {
                ForEach(GuardianDeliveryColumn.allCases) { Text($0.label).tag($0) }
            }
        case .kanban:
            Picker("Board", selection: $board) {
                Text("Choose…").tag(GuardianBoard?.none)
                ForEach(boards) { Text($0.title).tag(GuardianBoard?.some($0)) }
            }
            Picker("Column", selection: $column) {
                Text("Choose…").tag(GuardianBoardColumn?.none)
                ForEach(columns) { Text($0.title).tag(GuardianBoardColumn?.some($0)) }
            }
            .disabled(board == nil)
        }
    }

    private var projectPicker: some View {
        Picker("Project", selection: $project) {
            Text("Choose…").tag(GuardianProject?.none)
            ForEach(projects) { Text($0.name).tag(GuardianProject?.some($0)) }
        }
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(files, id: \.self) { file in
                HStack(spacing: 5) {
                    Image(systemName: "doc").font(.system(size: 10))
                    Text(file.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                    Button {
                        files.removeAll { $0 == file }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add Files…", action: addFiles).font(.system(size: 12))
        }
    }

    private var canSend: Bool {
        guard !sending, !directive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch target {
        case .person: return person != nil
        case .coder, .deliveryBoard: return project != nil
        case .kanban: return board != nil && column != nil
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            files.append(contentsOf: panel.urls.filter { !files.contains($0) })
        }
    }

    private func load() async {
        loadError = nil
        guard let client else {
            loadError = "Sign in to Guardian first (Settings ▸ Models)."
            return
        }
        do {
            switch target {
            case .person: await model.refreshGuardian()
            case .coder, .deliveryBoard: if projects.isEmpty { projects = try await client.coderProjects() }
            case .kanban: if boards.isEmpty { boards = try await client.kanbanBoards() }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadColumns() async {
        column = nil
        columns = []
        guard let board, let client else { return }
        do {
            columns = try await client.kanbanColumns(boardID: board.id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func send() {
        guard let client, canSend else { return }
        sending = true
        failure = nil
        let text = directive.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { sending = false }
            do {
                let summary = try await deliver(client: client, directive: text)
                model.transport.recordNote(summary, in: session)
                dismiss()
            } catch {
                failure = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The two texts as the shield would send them, with one set of placeholders across both.
    private static func masked(_ directive: String, _ transcript: String?, detector: SensitiveDetector) -> (String, String?) {
        var messages = [LLMMessage(role: .user, content: directive)]
        if let transcript { messages.append(LLMMessage(role: .user, content: transcript)) }
        let request = LLMRequest(systemPrompt: "", messages: messages, tools: [], model: "")
        let result = Shield.mask(request, detector: detector).request.messages
        return (result.first?.content ?? directive, transcript == nil ? nil : result.dropFirst().first?.content ?? transcript)
    }

    /// Upload, then hand over. Returns the line recorded in this chat.
    private func deliver(client: GuardianClient, directive: String) async throws -> String {
        var directive = directive
        var transcript = includeTranscript ? model.transport.transcriptMarkdown(of: session) : nil
        if maskSensitive, let detector = ProviderClients.shield?.detector() {
            (directive, transcript) = Self.masked(directive, transcript, detector: detector)
        }
        var attachmentIDs: [String] = []
        var links: [String] = []
        if let transcript {
            let name = "chat-transcript.md"
            let id = try await client.upload(name: name, contentType: "text/markdown", data: Data(transcript.utf8))
            attachmentIDs.append(id)
            links.append("- [\(name)](/uploads/\(id)/view)")
        }
        for file in files {
            let data = try Data(contentsOf: file)
            let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let id = try await client.upload(name: file.lastPathComponent, contentType: type, data: data)
            attachmentIDs.append(id)
            links.append("- [\(file.lastPathComponent)](/uploads/\(id)/view)")
        }
        let title = String((directive.split(separator: "\n").first.map(String.init) ?? directive).prefix(120))
        let linked = links.isEmpty ? directive : directive + "\n\nFiles:\n" + links.joined(separator: "\n")
        let what = includeTranscript ? "this chat" : "a directive"
        let extra = files.isEmpty ? "" : " and \(files.count) file\(files.count == 1 ? "" : "s")"

        switch target {
        case .person:
            guard let person else { throw GuardianError.server("Choose a person.") }
            let chat = try await client.createChat(personID: person.id)
            model.transport.followGuardianReply(client: client, chatID: chat, content: directive,
                                                attachmentIDs: attachmentIDs, person: person, in: session)
            return "Sent \(what)\(extra) to \(person.displayName) in Guardian: “\(title)”"
        case .coder:
            guard let project else { throw GuardianError.server("Choose a project.") }
            try await client.sendToCoderProject(projectID: project.id, title: title, content: directive, attachmentIDs: attachmentIDs)
            return "Sent \(what)\(extra) to AI Coders on \(project.name): “\(title)”"
        case .deliveryBoard:
            guard let project else { throw GuardianError.server("Choose a project.") }
            // A card's body goes to the coder, so the conversation goes in as words too.
            var body = linked
            if let transcript { body += "\n\n---\n\n" + String(transcript.prefix(30_000)) }
            try await client.addDeliveryCard(projectID: project.id, title: title, body: body, column: deliveryColumn)
            return "Added a card to \(deliveryColumn.label) on \(project.name)'s board: “\(title)”"
        case .kanban:
            guard let board, let column else { throw GuardianError.server("Choose a board and column.") }
            let result = try await client.addKanbanCard(boardID: board.id, columnID: column.id, title: title,
                                                        description: directive, attachmentIDs: attachmentIDs)
            let missed = result.failedAttachments > 0 ? " \(result.failedAttachments) file(s) couldn't be attached." : ""
            return "Added a card to \(column.title) on \(board.title): “\(title)”.\(missed)"
        }
    }
}

/// Bring a backup from another DSH or Vision into this install.
struct BackupImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let contents: BackupImport.Contents
    @State private var chosen: Set<BackupImport.Module> = []
    @State private var working = false
    @State private var report: BackupImport.Report?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Backup").font(.system(size: 14, weight: .semibold))
            if let report {
                done(report)
            } else {
                Text(contents.root.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(BackupImport.Module.allCases.filter(contents.available.contains)) { module in
                    Toggle(module.label, isOn: Binding(
                        get: { chosen.contains(module) },
                        set: { if $0 { chosen.insert(module) } else { chosen.remove(module) } }))
                        .font(.system(size: 12))
                }
                Text("Your current data folder is copied aside first. Files merge: a local file newer than the backup's is kept. Settings and secrets from the backup replace the ones here. The app restarts afterwards.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(Theme.errorTint)
                }
                HStack {
                    Spacer()
                    Button("Cancel") {
                        cleanUp()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(working ? "Importing…" : "Import", action: run)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(working || chosen.isEmpty || model.anythingRunning)
                }
                if model.anythingRunning {
                    Text("Stop the running agents first.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            // OpenClaw is a separate app: opt in, since this writes to its folder.
            chosen = contents.available.subtracting([.openClaw])
        }
    }

    private func done(_ report: BackupImport.Report) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(report.filesCopied) files copied, \(report.filesKeptNewer) newer local files kept, \(report.settingsRestored) settings and \(report.secretsRestored) secrets restored.")
                .font(.system(size: 12))
            if let safety = report.safetyCopy {
                Text("Your previous data is at \(safety.path)").font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ForEach(report.errors.prefix(6), id: \.self) { error in
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.errorTint)
            }
            HStack {
                Spacer()
                Button("Restart Now") { Self.relaunch() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func run() {
        working = true
        failure = nil
        let contents = contents
        let chosen = chosen
        let home = HarnessMemory.standard.appSupport
        Task.detached(priority: .userInitiated) {
            do {
                let result = try BackupImport.restore(contents, modules: chosen, into: home)
                await MainActor.run {
                    // The running app would write its old settings back over these.
                    report = result
                    working = false
                    cleanUp()
                }
            } catch {
                await MainActor.run {
                    failure = error.localizedDescription
                    working = false
                }
            }
        }
    }

    private func cleanUp() {
        if let temporary = contents.temporary { try? FileManager.default.removeItem(at: temporary) }
    }

    /// In memory, the app still holds its old state, and would write it back.
    private static func relaunch() {
        ConversationLog.shared.flush(wait: true)
        UserDefaults.standard.synchronize()
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
            try? process.run()
        }
        NSApp.terminate(nil)
    }
}
