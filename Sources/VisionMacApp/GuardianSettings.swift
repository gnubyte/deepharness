import SwiftUI
import VisionHarnessCore

/// Settings ▸ Guardian: sign in with the guardian.503cm.com login, and the
/// syncs that follow from it — prompts (automatic on submit), skills both
/// ways, chats exported and imported, code projects uploaded to the account's
/// repo store.
struct GuardianSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address = GuardianService.defaultURL
    @State private var email = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var signingIn = false
    @State private var status: String?
    @State private var isSyncingSkills = false
    @State private var isExporting = false
    @State private var isImporting = false

    var body: some View {
        Form {
            Section("Account") {
                if model.guardian.isSignedIn {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.successTint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed in as \(model.guardian.accountEmail ?? "")")
                            Text("Prompts you send in chats sync to Guardian's history automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign Out", role: .destructive) { model.guardian.signOut() }
                    }
                } else if model.guardian.pendingTwoFactorChallenge != nil {
                    // A sign-in is waiting on the authenticator code.
                    TextField("Email", text: $email)
                        .autocorrectionDisabled()
                    HStack {
                        TextField("6-digit code", text: $twoFactorCode)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await submitTwoFactor() } }
                        Button {
                            Task { await submitTwoFactor() }
                        } label: {
                            if signingIn { ProgressView().controlSize(.small) } else { Text("Verify") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(signingIn || twoFactorCode.count != 6)
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Enter the 6-digit code from your authenticator app. Codes rotate every 30 seconds.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Start over") {
                        model.guardian.cancelTwoFactor()
                        twoFactorCode = ""
                        status = nil
                    }
                    .font(.caption)
                } else {
                    TextField("Guardian address", text: $address)
                        .autocorrectionDisabled()
                    TextField("Email", text: $email)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    HStack {
                        Button {
                            signingIn = true
                            status = nil
                            Task {
                                let ok = await model.guardian.signIn(address: address, email: email, password: password)
                                signingIn = false
                                status = ok ? "Signed in." : (model.guardian.lastError ?? "Sign-in failed.")
                                if ok { password = "" }
                            }
                        } label: {
                            if signingIn { ProgressView().controlSize(.small) } else { Text("Sign In") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(signingIn || email.isEmpty || password.isEmpty)
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Your password is exchanged for a session token and never stored — the token lives in your Keychain and calls only guardian endpoints you sign in to.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Skills") {
                HStack {
                    Button {
                        isSyncingSkills = true
                        Task {
                            await syncSkillsDown()
                            isSyncingSkills = false
                        }
                    } label: {
                        if isSyncingSkills { ProgressView().controlSize(.small) } else { Text("Import skills from Guardian") }
                    }
                    .disabled(!model.guardian.isSignedIn || isSyncingSkills)
                    Button("Deposit this project's skills") {
                        Task { await depositSkills() }
                    }
                    .disabled(!model.guardian.isSignedIn)
                }
                Text("A skill imported here is a copy; depositing publishes the project's .vision/skills to the account, where any Vision harness can take it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Chats") {
                HStack {
                    Button {
                        isExporting = true
                        Task { await exportChats() }
                    } label: {
                        if isExporting { ProgressView().controlSize(.small) } else { Text("Export all chats to Guardian") }
                    }
                    .disabled(!model.guardian.isSignedIn || isExporting)
                    Button("Import a chat from Guardian…") {
                        isImporting = true
                        Task { await importChats() }
                    }
                    .disabled(!model.guardian.isSignedIn || isImporting)
                }
                Text("Exported chats appear in Guardian under your account; importing them back restores them into this app's chat list.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Code projects") {
                Button("Upload the open project to Guardian") {
                    Task { await uploadProject() }
                }
                .disabled(!model.guardian.isSignedIn || model.project == nil)
                Text("The project's text files go to your account's private repo store — Guardian's own place for code, whatever GitHub it may or may not have — from where the AI Coders module can be pointed at it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let status {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Actions

    /// The second half of a 2FA sign-in: verify the authenticator code.
    private func submitTwoFactor() async {
        guard !twoFactorCode.isEmpty else { return }
        signingIn = true
        status = nil
        let ok = await model.guardian.verifyTwoFactor(code: twoFactorCode)
        signingIn = false
        if ok {
            twoFactorCode = ""
            status = "Signed in."
        } else {
            status = model.guardian.lastError ?? "That code didn't take — codes rotate every 30 seconds."
        }
    }

    private func syncSkillsDown() async {
        guard let client = model.guardian.client else { return }
        do {
            let remote = try await client.skills()
            let locations = model.transport.skillLocations
            var imported = 0
            for skill in remote where !skill.name.isEmpty {
                let folder = locations.userSkills.appendingPathComponent(skill.name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (path, text) in skill.files {
                    let file = folder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                }
                imported += 1
            }
            model.transport.refreshDrafts()
            status = "Imported \(imported) skill\(imported == 1 ? "" : "s") from Guardian."
        } catch {
            status = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func depositSkills() async {
        guard let client = model.guardian.client, let project = model.project else { return }
        let folder = AppPaths.projectFolder(project, "skills")
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
            status = "This project has no .vision/skills to deposit."
            return
        }
        var deposited = 0
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let skillID = entry.lastPathComponent
            var files: [String: String] = [:]
            if let enumerator = fileManager.enumerator(at: entry, includingPropertiesForKeys: nil) {
                while let next = enumerator.nextObject() {
                    guard let file = next as? URL,
                          let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    files[String(file.path.dropFirst(entry.path.count + 1))] = text
                }
            }
            let description = (try? String(contentsOf: entry.appendingPathComponent("SKILL.md"), encoding: .utf8))?
                .split(separator: "\n").filter { $0.contains("description:") }.first.map { String($0) } ?? skillID
            do {
                try await client.putSkill(name: skillID, description: description, files: files)
                deposited += 1
            } catch {
                status = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
                return
            }
        }
        status = "Deposited \(deposited) skill\(deposited == 1 ? "" : "s") to Guardian."
    }

    private func exportChats() async {
        guard let client = model.guardian.client else { return }
        let log = model.transport.log
        let sessions = model.transport.sessions
        var exported = 0
        for vm in sessions where vm.loaded {
            let payload = Self.chatJSON(vm)
            do {
                try await client.putChat(id: vm.id, title: vm.title, updatedAt: vm.updatedAt, payload: payload)
                exported += 1
            } catch {
                status = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
                isExporting = false
                return
            }
        }
        _ = log   // loaded timelines only; unloaded chats export on their next open
        status = "Exported \(exported) chat\(exported == 1 ? "" : "s") to Guardian."
        isExporting = false
    }

    private func importChats() async {
        guard let client = model.guardian.client else { return }
        do {
            let remote = try await client.chats()
            status = remote.isEmpty
                ? "Guardian holds no exported chats yet."
                : "Guardian holds \(remote.count) chat\(remote.count == 1 ? "" : "s") — importing the 20 most recent."
            for chat in remote.prefix(20) {
                let payload = try await client.chat(id: chat.id)
                Self.restoreChat(id: chat.id, title: chat.title, updatedAt: chat.updatedAt, payload: payload,
                                 transport: model.transport)
            }
            model.transport.reload()
        } catch {
            status = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
        }
        isImporting = false
    }

    private func uploadProject() async {
        guard let client = model.guardian.client, let project = model.project else { return }
        var files: [String: String] = [:]
        if let enumerator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil) {
            while let next = enumerator.nextObject() {
                guard let url = next as? URL else { continue }
                let path = String(url.path.dropFirst(project.path.count + 1))
                let skipped = ["node_modules/", ".git/", ".build/", "dist/", ".venv/", "__pycache__/", ".next/"]
                    .contains { path.contains($0) }
                guard !skipped, url.isFileURL,
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      text.utf8.count < 400_000 else { continue }
                files[path] = text
                if files.count >= 2_000 { break }
            }
        }
        do {
            try await client.putProject(name: project.lastPathComponent, files: files)
            status = "Uploaded \(files.count) files from \(project.lastPathComponent) to Guardian."
        } catch {
            status = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Chat (de)serialization — the harness's own transcript rows

    /// One chat as Guardian stores it: the log rows plus the chat's title.
    static func chatJSON(_ vm: SessionVM) -> Data {
        struct Chat: Codable {
            var id: String
            var title: String
            var cwd: String?
            var rows: [Row]
            struct Row: Codable {
                var kind: String
                var text: String?
                var toolName: String?
                var argSummary: String?
                var output: String?
                var isError: Bool
                var at: Date
            }
        }
        let rows = vm.entries.map { entry -> Chat.Row in
            switch entry.kind {
            case .message(let body):
                return .init(kind: body.role.rawValue, text: body.text, toolName: nil, argSummary: nil,
                             output: nil, isError: false, at: entry.at)
            case .tool(let tool):
                return .init(kind: "tool", text: tool.summary, toolName: tool.name, argSummary: tool.preview,
                             output: tool.output, isError: tool.isOk == false, at: entry.at)
            case .todos(let items):
                return .init(kind: "todos", text: items.map(\.content).joined(separator: "\n"), toolName: nil,
                             argSummary: nil, output: nil, isError: false, at: entry.at)
            case .compaction(let note):
                return .init(kind: "compaction", text: note.summary, toolName: nil, argSummary: "\(note.removed)",
                             output: nil, isError: false, at: entry.at)
            }
        }
        let chat = Chat(id: vm.id, title: vm.title, cwd: vm.cwd, rows: rows)
        return (try? JSONEncoder().encode(chat)) ?? Data()
    }

    /// Restore an exported chat into the app's list.
    static func restoreChat(id: String, title: String, updatedAt: Date, payload: Data, transport: AppTransport) {
        struct Chat: Codable {
            var id: String
            var title: String
            var cwd: String?
            var rows: [Row]
            struct Row: Codable {
                var kind: String
                var text: String?
                var toolName: String?
                var argSummary: String?
                var output: String?
                var isError: Bool
                var at: Date
            }
        }
        guard let chat = try? JSONDecoder().decode(Chat.self, from: payload) else { return }
        let log = transport.log
        var entries: [ChatEntry] = []
        for row in chat.rows {
            let at = row.at
            switch row.kind {
            case "user": entries.append(ChatEntry(at: at, kind: .message(.init(role: .user, text: row.text ?? ""))))
            case "assistant": entries.append(ChatEntry(at: at, kind: .message(.init(role: .assistant, text: row.text ?? ""))))
            case "notice": entries.append(ChatEntry(at: at, kind: .message(.init(role: .notice, text: row.text ?? ""))))
            case "error": entries.append(ChatEntry(at: at, kind: .message(.init(role: .error, text: row.text ?? ""))))
            case "tool":
                entries.append(ChatEntry(at: at, kind: .tool(.init(name: row.toolName ?? "tool", preview: row.argSummary ?? "",
                                                                   summary: row.text, output: row.output,
                                                                   isOk: !row.isError))))
            case "todos":
                entries.append(ChatEntry(at: at, kind: .todos(row.text?.split(separator: "\n").map {
                    TodoItem(id: UUID().uuidString, content: String($0))
                } ?? [])))
            case "compaction":
                entries.append(ChatEntry(at: at, kind: .compaction(
                    .init(removed: Int(row.argSummary ?? "") ?? 0, summary: row.text ?? "", at: at))))
            default: break
            }
        }
        if transport.sessions.contains(where: { $0.id == chat.id }) { return }
        log.store(LogSession(id: chat.id, title: title, cwd: chat.cwd,
                             preset: PermissionPreset.workspaceWrite.rawValue, updatedAt: updatedAt),
                  items: AppTransport.logRows(for: entries, sessionID: chat.id))
    }

}
