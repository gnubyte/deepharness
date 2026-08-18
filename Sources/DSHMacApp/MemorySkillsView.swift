import SwiftUI
import DSHKit

/// Memory and skills for the current project.
///
/// The two sit together because they are the same decision made twice: what
/// the agent should know without being told. Memory is the small durable part
/// paid for on every request; a skill is the procedural part paid for only
/// when it is used.
struct MemorySkillsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case memory = "Memory"
        case skills = "Skills"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .memory

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memory & Skills").font(.headline)
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(12)

            Divider()

            switch tab {
            case .memory: MemoryPane()
            case .skills: SkillsPane()
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

// MARK: - Memory

struct MemoryPane: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var loadedFrom: String?
    @State private var dirty = false
    @State private var logEntry = ""
    @State private var showingLog = false

    var body: some View {
        Group {
            if let store = model.memory {
                if store.isInstalled {
                    editor(store)
                } else {
                    setup(store)
                }
            } else {
                ContentUnavailableView(
                    "No project folder",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Memory is stored inside a project. Open a project folder first (⌘O).")
                )
            }
        }
        // Re-reads on both a chat switch and any write this app made.
        .task(id: "\(model.selectedID ?? "")-\(model.memoryRevision)") { load() }
    }

    // MARK: Not yet installed

    private func setup(_ store: MemoryStore) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Memory is not set up in this project", systemImage: "brain")
                .font(.headline)

            Text("""
            Memory is kept as files inside the project, so the agent can read and \
            edit them with the tools it already has, and they review and diff like \
            anything else in the repo.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                FileRow(path: "MEMORY.md", note: "durable facts — injected into every session")
                FileRow(path: "memory/\(MemoryStore.logName(for: Date()))", note: "today's working log — read on demand")
                FileRow(path: ".agents/skills/memory/SKILL.md", note: "teaches the agent the protocol")
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Button {
                Task { _ = await model.installMemory(); load() }
            } label: {
                Label("Set Up Memory", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Installed

    private func editor(_ store: MemoryStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("MEMORY.md").font(.callout.monospaced())
                Text("injected every session")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                Spacer()
                Text(sizeNote)
                    .font(.caption)
                    .foregroundStyle(overLength ? .orange : .secondary)
                Button("Reveal") { model.revealLocally(store.memoryFile.path) }
                    .font(.caption)
                Button("Save") { save(store) }
                    .disabled(!dirty)
            }
            .padding(10)

            TextEditor(text: $draft)
                .font(.system(.callout, design: .monospaced))
                .onChange(of: draft) { _, _ in dirty = true }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.caption)
                Text("memory/\(MemoryStore.logName(for: Date()))")
                    .font(.caption.monospaced())
                TextField("Append a note to today's log…", text: $logEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(appendLog)
                Button("Append", action: appendLog)
                    .disabled(logEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Open") { showingLog.toggle() }
            }
            .padding(10)

            if showingLog {
                Divider()
                ScrollView {
                    Text(store.readLog() ?? "(empty)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 140)
            }
        }
    }

    private var overLength: Bool { draft.split(separator: "\n").count > 100 }

    private var sizeNote: String {
        let lines = draft.split(separator: "\n", omittingEmptySubsequences: false).count
        return overLength ? "\(lines) lines — consider moving detail to a skill" : "\(lines) lines"
    }

    private func load() {
        guard let store = model.memory else { return }
        draft = store.readMemory() ?? ""
        loadedFrom = store.memoryFile.path
        dirty = false
    }

    private func save(_ store: MemoryStore) {
        model.saveMemory(draft)
        dirty = false
    }

    private func appendLog() {
        let text = logEntry.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.appendToTodayLog(text)
        logEntry = ""
    }
}

private struct FileRow: View {
    let path: String
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(path).font(.caption.monospaced())
            Text(note).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Skills

struct SkillsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Skill?
    @State private var creating = false
    @State private var newName = ""
    @State private var newDescription = ""

    var body: some View {
        VStack(spacing: 0) {
            if model.skills.isEmpty {
                ContentUnavailableView(
                    "No skills",
                    systemImage: "book.closed",
                    description: Text("Skills are Markdown files the agent loads by name when a task calls for them.")
                )
            } else {
                List(model.skills, selection: Binding(
                    get: { selected?.name },
                    set: { name in selected = model.skills.first { $0.name == name } }
                )) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(.callout.monospaced())
                        Text(skill.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(skill.name)
                }
                .listStyle(.inset)
            }

            if let selected {
                Divider()
                ScrollView {
                    Text(selected.description)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 120)
            }

            Divider()
            HStack {
                Button {
                    creating = true
                } label: {
                    Label("New Skill", systemImage: "plus")
                }
                .disabled(model.memory == nil)

                Button("Reveal Folder") {
                    guard let store = model.memory else { return }
                    model.revealLocally(store.skillsDirectory.path)
                }
                .disabled(model.memory == nil)

                Spacer()
                Text("\(model.skills.count) available")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh") { Task { await model.refreshSkills(force: true) } }
            }
            .padding(10)
        }
        .task(id: model.selectedID) { await model.refreshSkills() }
        .sheet(isPresented: $creating) {
            NewSkillSheet(name: $newName, description: $newDescription) { create() }
        }
    }

    /// Write a `SKILL.md` into the project's highest-rank skills root.
    ///
    /// The provider watches these directories, so the catalog picks it up
    /// without a restart.
    private func create() {
        guard let store = model.memory else { return }
        let slug = newName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !slug.isEmpty else { return }

        let dir = store.skillsDirectory.appendingPathComponent(slug, isDirectory: true)
        let body = """
        ---
        name: \(slug)
        description: \(newDescription.isEmpty ? "Use when …" : newDescription)
        ---

        # \(newName)

        Write the procedure here. The description above is what the agent reads
        when deciding whether to load this skill, so make it say *when* to use it,
        not just what it is.
        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("SKILL.md")
            try body.write(to: file, atomically: true, encoding: .utf8)
            newName = ""
            newDescription = ""
            model.revealLocally(file.path)
            Task {
                // The provider's watcher debounces, so give it a moment.
                try? await Task.sleep(nanoseconds: 600_000_000)
                await model.refreshSkills(force: true)
            }
        } catch {
            model.note(AppModel.describe(error))
        }
    }
}

private struct NewSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    @Binding var description: String
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New skill").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("release-checklist"))
                TextField("When to use it", text: $description, prompt: Text("Use when cutting a release…"), axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
            }
            .formStyle(.grouped)

            Text("""
            The description is the only part the agent sees before loading, so it \
            should describe the trigger — when this applies — rather than the content.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460, height: 340)
    }
}
