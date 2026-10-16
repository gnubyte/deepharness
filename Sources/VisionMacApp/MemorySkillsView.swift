import SwiftUI
import AppKit
import VisionHarnessCore

/// Memory and skills — the project's, or, in a chat without a project, your own.
///
/// Both are just files (in the project, or in your home folder), so they diff and review like anything
/// else. This app assembles the system prompt itself, so what is shown here is literally what the model
/// is told.
struct MemorySkillsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Selection = .instructions
    @State private var editing: URL?
    @State private var buffer = ""
    /// Bumped after a save, so the user's own files are read again.
    @State private var revision = 0

    enum Selection: Hashable { case instructions, skills, prompt }

    private var context: ProjectContext? { model.transport.projectContext }

    /// The selected chat has no project (or nothing is open): show the user's own, everywhere content.
    private var global: Bool {
        if let session = model.selectedSession { return session.isPlain }
        return model.project == nil
    }

    /// The instruction files shown: the project's, or the user's own from their home folder.
    private var files: [InstructionFile] {
        _ = revision
        return global ? ProjectContext.instructionFiles(root: model.transport.skillLocations.home) : (context?.instructions ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
                case .skills: SkillsManagerView()
                case .prompt: promptPreview
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 780, height: 600)
    }

    private var header: some View {
        HStack {
            Label("Memory & Skills", systemImage: "brain")
                .font(.headline)
            Spacer()
            if global {
                Text("Yours, everywhere (no project)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let project = model.project {
                Text(project.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Reload") {
                model.transport.refreshProjectContext()
                revision += 1
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Instructions

    @ViewBuilder
    private var instructions: some View {
        let files = self.files
        if files.isEmpty, global {
            EmptyStateView(icon: "doc.text",
                           title: "No instruction files of your own",
                           message: """
                           In a chat without a project, AGENTS.md, CLAUDE.md, .claude/CLAUDE.md or MEMORY.md \
                           in your home folder is read into every prompt. None exists yet.
                           """)
        } else if files.isEmpty {
            EmptyStateView(icon: "doc.text",
                           title: "No instruction files",
                           message: """
                           A file named AGENTS.md, QWEN.md, CLAUDE.md, VISION.md, or MEMORY.md in the \
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
                if !global {
                    Button("Set Up Memory Scaffold") { setUpMemory() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .font(.callout)
                }
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
        revision += 1
        editing = nil
    }

    private func setUpMemory() {
        guard let project = model.project else { return }
        try? ProjectContext.setUpMemory(root: project)
        model.transport.refreshProjectContext()
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
        let modelName = model.config.activeProvider?.model ?? "model"
        if global {
            // What a chat without a project starts from (its skills and the vault are added per chat).
            let chat = model.selectedSession ?? SessionVM(id: "preview", title: "", cwd: nil, preset: model.config.asPreset)
            let folder = model.transport.scratchFolder(for: chat)
            return AppTransport.basePrompt(for: chat, workspace: folder, coding: AppTransport.defaultSystemPrompt,
                                           model: modelName, projectContext: nil, home: model.transport.skillLocations.home)
        }
        guard let project = model.project else { return "Open a project to see its prompt." }
        let environment = ProjectContext.environmentBlock(workspace: project,
                                                          model: modelName,
                                                          preset: model.config.asPreset)
        let supplement = context?.promptSupplement(environment: environment) ?? environment
        return AppTransport.defaultSystemPrompt + "\n\n" + supplement
    }
}
