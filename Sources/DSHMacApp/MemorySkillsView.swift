import SwiftUI
import AppKit
import DSHCore

/// Project memory and skills.
///
/// Both are just files in the project, so they diff and review like anything
/// else in the repo. This app assembles the system prompt itself, so what is
/// shown here is literally what the model is told.
struct MemorySkillsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Selection = .instructions
    @State private var editing: URL?
    @State private var buffer = ""
    @State private var newSkillName = ""
    @State private var newSkillDescription = ""
    @State private var showNewSkill = false

    enum Selection: Hashable { case instructions, skills, prompt }

    private var context: ProjectContext? { model.transport.projectContext }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.project == nil {
                EmptyStateView(icon: "folder.badge.questionmark",
                               title: "No project open",
                               message: "Memory and skills belong to a project folder.") {
                    Button("Open Folder…") { model.chooseProject() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Picker("", selection: $selection) {
                    Text("Instructions").tag(Selection.instructions)
                    Text("Skills").tag(Selection.skills)
                    Text("System prompt").tag(Selection.prompt)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)

                Divider()
                Group {
                    switch selection {
                    case .instructions: instructions
                    case .skills: skills
                    case .prompt: promptPreview
                    }
                }
                .frame(maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 540)
        .sheet(isPresented: $showNewSkill) { newSkillSheet }
    }

    private var header: some View {
        HStack {
            Label("Memory & Skills", systemImage: "brain")
                .font(.headline)
            Spacer()
            if let project = model.project {
                Text(project.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Reload") { model.transport.refreshProjectContext() }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Instructions

    @ViewBuilder
    private var instructions: some View {
        let files = context?.instructions ?? []
        if files.isEmpty {
            EmptyStateView(icon: "doc.text",
                           title: "No instruction files",
                           message: """
                           A file named AGENTS.md, QWEN.md, CLAUDE.md, DSH.md, or MEMORY.md in the \
                           project root is loaded into every prompt. Create the memory scaffold to \
                           get started.
                           """) {
                Button("Set Up Memory") { setUpMemory() }
                    .buttonStyle(.borderedProminent)
            }
        } else if let editing, let file = files.first(where: { $0.url == editing }) {
            editor(for: file)
        } else {
            List {
                ForEach(files) { file in
                    Button {
                        buffer = file.text
                        editing = file.url
                    } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.label).font(.callout.weight(.medium))
                                Text("\(file.lineCount) lines")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if file.lineCount > 100 {
                                Label("long", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(Theme.noticeTint)
                                    .help("This is loaded on every request. Move detail into a skill.")
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Set Up Memory Scaffold") { setUpMemory() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.callout)
            }
        }
    }

    private func editor(for file: InstructionFile) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    editing = nil
                } label: {
                    Label("All files", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.caption)
                Spacer()
                Text(file.label).font(.caption.weight(.medium))
                Spacer()
                Button("Save") { save(to: file.url) }
                    .disabled(buffer == file.text)
            }
            .padding(8)
            Divider()
            TextEditor(text: $buffer)
                .font(Theme.mono(12))
                .padding(4)
        }
    }

    private func save(to url: URL) {
        try? buffer.write(to: url, atomically: true, encoding: .utf8)
        model.transport.refreshProjectContext()
        editing = nil
    }

    private func setUpMemory() {
        guard let project = model.project else { return }
        try? ProjectContext.setUpMemory(root: project)
        model.transport.refreshProjectContext()
    }

    // MARK: Skills

    @ViewBuilder
    private var skills: some View {
        let catalog = context?.skills ?? []
        VStack(spacing: 0) {
            if catalog.isEmpty {
                EmptyStateView(icon: "graduationcap",
                               title: "No skills yet",
                               message: """
                               A skill is a folder with a SKILL.md whose description says when it \
                               applies. The model sees only that line until it loads the file.
                               """) {
                    Button("New Skill…") { showNewSkill = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(catalog) { skill in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: "graduationcap.fill").foregroundStyle(.tint)
                                Text(skill.name).font(.callout.weight(.medium))
                                Spacer()
                                Text(rootLabel(skill.rank))
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.surfaceStrong, in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            Text(skill.description)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("Open in Editor") {
                                model.mode = .code
                                model.code.reveal(skill.url)
                                dismiss()
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([skill.url])
                            }
                        }
                    }
                }
                HStack {
                    Button("New Skill…") { showNewSkill = true }
                    Spacer()
                }
                .padding(10)
            }
        }
    }

    private func rootLabel(_ rank: Int) -> String {
        switch rank {
        case 100: ".dsh/skills"
        case 200: ".agents/skills"
        case 300: ".qwen/skills"
        default: "user"
        }
    }

    private var newSkillSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New skill").font(.headline)
            TextField("Name", text: $newSkillName)
            TextField("When does it apply?", text: $newSkillDescription, axis: .vertical)
                .lineLimit(2...4)
            Text("The description is the only thing the model sees before deciding to load the skill, so say when it applies rather than what it contains.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { showNewSkill = false }
                Button("Create") { createSkill() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newSkillName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func createSkill() {
        guard let project = model.project else { return }
        if let url = try? ProjectContext.createSkill(root: project,
                                                     name: newSkillName,
                                                     description: newSkillDescription) {
            model.transport.refreshProjectContext()
            model.mode = .code
            model.code.reveal(url)
        }
        newSkillName = ""
        newSkillDescription = ""
        showNewSkill = false
        dismiss()
    }

    // MARK: Prompt preview

    private var promptPreview: some View {
        ScrollView {
            Text(previewText)
                .font(Theme.mono(11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private var previewText: String {
        guard let project = model.project else { return "Open a project to see its prompt." }
        let modelName = model.config.activeProvider?.model ?? "model"
        let environment = ProjectContext.environmentBlock(workspace: project,
                                                          model: modelName,
                                                          preset: model.config.asPreset)
        let supplement = context?.promptSupplement(environment: environment) ?? environment
        return AppTransport.defaultSystemPrompt + "\n\n" + supplement
    }
}
