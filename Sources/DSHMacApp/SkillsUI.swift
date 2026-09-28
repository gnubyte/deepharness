import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DSHCore

// MARK: - Shared pieces

struct SkillBadge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

extension SkillOrigin {
    var tint: Color {
        switch self {
        case .dsh: Color.accentColor
        case .claude: Color.orange
        case .cursor: Color.teal
        case .agents: Color.indigo
        case .qwen: Color.purple
        case .builtin: Color.gray
        }
    }
}

private struct SkillBadges: View {
    let skill: Skill
    var body: some View {
        HStack(spacing: 4) {
            SkillBadge(text: skill.origin.label, tint: skill.origin.tint)
            if skill.kind != .skill { SkillBadge(text: skill.kind.label) }
            if skill.origin != .builtin { SkillBadge(text: skill.scope == .project ? "Project" : "Everywhere") }
            if skill.alwaysApply { SkillBadge(text: "Always on", tint: Theme.successTint) }
            if !skill.globs.isEmpty { SkillBadge(text: "Files: \(skill.globs.first ?? "")") }
            if !skill.modelInvocable && !skill.alwaysApply { SkillBadge(text: "You run it") }
            if skill.shadowed { SkillBadge(text: "Overridden", tint: Theme.noticeTint) }
        }
    }
}

@MainActor
private func openFile(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

// MARK: - Chat: pick skills for this conversation

/// The Skills button in the composer: pick, by hand, the skills this chat uses
/// (their instructions go into the prompt), and choose whether the model may
/// also pick skills on its own.
struct SkillsButton: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var open = false

    var body: some View {
        let pinned = model.config.sessionSkills[session.id]?.pinned.count ?? 0
        let pending = model.transport.pendingDrafts.count
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: pinned > 0 ? "graduationcap.fill" : "graduationcap")
                Text(pinned > 0 ? "Skills · \(pinned)" : "Skills")
                if pending > 0 {
                    Text("\(pending)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .background(Theme.noticeTint, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(pinned > 0 ? Color.accentColor : .secondary)
        .popover(isPresented: $open, arrowEdge: .top) {
            SkillPicker(session: session, close: { open = false })
                .environment(model)
        }
        .help("Choose the skills this chat uses. Also: /skills, /skill <name>, or /<name> to run one.")
    }
}

struct SkillPicker: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let close: () -> Void
    @State private var skills: [Skill] = []
    @State private var query = ""

    private var visible: [Skill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return skills.filter { !$0.shadowed && (q.isEmpty || $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)) }
    }

    var body: some View {
        let transport = model.transport
        let selection = transport.selection(for: session.id)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search skills", text: $query).textFieldStyle(.plain)
                if !selection.pinned.isEmpty {
                    Button("Clear selection") { transport.clearPinnedSkills(in: session) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()

            Toggle(isOn: Binding(get: { selection.auto }, set: { transport.setAutoSkills($0, in: session) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let the model choose skills").font(.callout)
                    Text(selection.auto ? "It sees each skill's description and loads the ones that fit."
                                        : "Off — only the skills ticked below are used.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()

            if !transport.pendingDrafts.isEmpty {
                Button {
                    model.settingsTab = .skills
                    model.showSettings = true
                    close()
                } label: {
                    Label("\(transport.pendingDrafts.count) skill\(transport.pendingDrafts.count == 1 ? "" : "s") awaiting your approval — review",
                          systemImage: "tray.and.arrow.down")
                        .font(.caption)
                        .foregroundStyle(Theme.noticeTint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .buttonStyle(.plain)
                Divider()
            }

            if visible.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "graduationcap").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text(skills.isEmpty ? "No skills yet" : "Nothing matches").font(.callout.weight(.medium))
                    Text("Create one, or import from Claude or Cursor, in Settings ▸ Skills.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { skill in
                            PickerRow(skill: skill, session: session)
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Manage…") { openSettings() }
                Spacer()
                Button {
                    model.skillsAction = .generate
                    openSettings()
                } label: { Label("Write one with AI", systemImage: "sparkles") }
            }
            .padding(10)
        }
        .frame(width: 420, height: 480)
        .task(id: transport.skillsRevision) { skills = transport.skills(for: session) }
        .onAppear { skills = transport.skills(for: session) }
    }

    private func openSettings() {
        model.settingsTab = .skills
        model.showSettings = true
        close()
    }
}

private struct PickerRow: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    let session: SessionVM

    var body: some View {
        let transport = model.transport
        let pinned = transport.isPinned(skill, in: session)
        let off = model.config.disabledSkills.contains(skill.id)
        Button {
            guard !off else { return }
            transport.setPinned(skill, !pinned, in: session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: pinned ? "checkmark.square.fill" : "square")
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(skill.name).font(.callout.weight(.medium))
                        if off { SkillBadge(text: "Off in Settings", tint: Theme.noticeTint) }
                    }
                    SkillBadges(skill: skill)
                    Text(skill.description)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
            .opacity(off ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .help(off ? "Turn it on in Settings ▸ Skills to use it." : (pinned ? "Selected — its instructions are in the prompt." : "Click to use it in this chat."))
    }
}

// MARK: - Settings: manage skills

struct SkillsManagerView: View {
    @Environment(AppModel.self) private var model

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", on = "On", off = "Off", pending = "To approve"
        var id: String { rawValue }
    }

    @State private var skills: [Skill] = []
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var editor: SkillEditorSheet.Target?
    @State private var showGenerate = false
    @State private var showImport = false
    @State private var exportSelection: Set<String>?
    @State private var message: String?
    @State private var trashing: Skill?

    private var transport: AppTransport { model.transport }

    private var filtered: [Skill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return skills.filter { s in
            let off = model.config.disabledSkills.contains(s.id)
            switch filter {
            case .all: break
            case .on: if off || s.shadowed { return false }
            case .off: if !off { return false }
            case .pending: return false
            }
            return q.isEmpty || s.name.lowercased().contains(q) || s.description.lowercased().contains(q)
        }
    }

    private var drafts: [SkillDraft] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return transport.pendingDrafts.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    private struct Group: Identifiable { let id: String; let title: String; let skills: [Skill] }

    private var groups: [Group] {
        var order: [String] = []
        var buckets: [String: [Skill]] = [:]
        for s in filtered {
            let title: String
            if s.origin == .builtin { title = "Built in to DSH" }
            else if s.origin == .dsh { title = s.scope == .project ? "This project — your skills" : "All projects — your skills" }
            else { title = "\(s.origin.label) — read from \(s.scope == .project ? "this project" : "your home folder")" }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(s)
        }
        return order.map { Group(id: $0, title: $0, skills: buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if skills.isEmpty && drafts.isEmpty {
                EmptyStateView(icon: "graduationcap", title: "No skills yet",
                               message: "A skill is a saved procedure the agent loads when a task matches. Write one, have the AI write one from what you want, or import from Claude Code or Cursor.") {
                    HStack {
                        Button("Write with AI…") { showGenerate = true }.buttonStyle(.borderedProminent)
                        Button("Import…") { showImport = true }
                    }
                }
            } else {
                list
            }
            Divider()
            footer
        }
        .task(id: transport.skillsRevision) { reload() }
        .onAppear { reload(); consumeAction() }
        .onChange(of: model.skillsAction) { _, _ in consumeAction() }
        .sheet(item: $editor) { target in
            SkillEditorSheet(target: target) { reload() }.environment(model)
        }
        .sheet(isPresented: $showGenerate) { GenerateSkillSheet { reload() }.environment(model) }
        .sheet(isPresented: $showImport) { ImportSkillsSheet { reload() }.environment(model) }
        .sheet(isPresented: Binding(get: { exportSelection != nil }, set: { if !$0 { exportSelection = nil } })) {
            ExportSkillsSheet(skills: skills.filter { !$0.shadowed }, preselected: exportSelection ?? []).environment(model)
        }
        .alert("Skills", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog("Move “\(trashing?.name ?? "")” to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let s = trashing {
                    do { try SkillManager.trash(s) } catch { message = error.localizedDescription }
                    transport.refreshDrafts()
                }
                trashing = nil
            }
            Button("Cancel", role: .cancel) { trashing = nil }
        } message: {
            Text(trashing.map { $0.isOwned ? "You can restore it from the Trash." : "This deletes the file from \($0.origin.label)'s folder; you can restore it from the Trash." } ?? "")
        }
    }

    private func reload() { skills = transport.skills(for: model.selectedSession) }

    private func consumeAction() {
        guard let action = model.skillsAction else { return }
        model.skillsAction = nil
        switch action {
        case .generate: showGenerate = true
        case .importSkills: showImport = true
        case .newManual: editor = .new(scope: model.project == nil ? .user : .project)
        }
    }

    // MARK: Toolbar / footer

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))

            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    Text(f == .pending && !transport.pendingDrafts.isEmpty ? "To approve (\(transport.pendingDrafts.count))" : f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)

            Spacer()
            Menu {
                Button("Write with AI…") { showGenerate = true }
                Button("Write by hand…") { editor = .new(scope: model.project == nil ? .user : .project) }
            } label: { Label("New", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
            Button { showImport = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
            Button { exportSelection = Set(skills.filter { $0.isOwned && !$0.shadowed }.map(\.id)) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(skills.isEmpty)
        }
        .padding(10)
    }

    private var footer: some View {
        @Bindable var config = model.config
        return HStack(spacing: 14) {
            Text("Also read:").font(.caption).foregroundStyle(.secondary)
            sourceToggle("Claude Code", .claude)
            sourceToggle("Cursor", .cursor)
            sourceToggle("Agents / Qwen", [.agents, .qwen])
            Spacer()
            Button("Reload") { transport.refreshDrafts(); reload() }
        }
        .font(.caption)
        .padding(10)
    }

    private func sourceToggle(_ title: String, _ source: SkillSources) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.config.skillSources.isSuperset(of: source) },
            set: { on in
                if on { model.config.skillSources.formUnion(source) } else { model.config.skillSources.subtract(source) }
                transport.refreshDrafts()
            }))
            .toggleStyle(.checkbox)
            .help("Read \(title) skills, commands and rules from where those tools keep them.")
    }

    // MARK: List

    private var list: some View {
        List {
            if !drafts.isEmpty && filter != .on && filter != .off {
                Section {
                    ForEach(drafts) { draft in DraftRow(draft: draft, review: { editor = .draft(draft) }, changed: reload) }
                } header: {
                    Label("Awaiting your approval", systemImage: "tray.and.arrow.down").foregroundStyle(Theme.noticeTint)
                }
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.skills) { skill in row(skill) }
                }
            }
            if filtered.isEmpty && drafts.isEmpty {
                Text("Nothing matches.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ skill: Skill) -> some View {
        let off = model.config.disabledSkills.contains(skill.id)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !off },
                set: { on in
                    if on { model.config.disabledSkills.remove(skill.id) } else { model.config.disabledSkills.insert(skill.id) }
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name).font(.callout.weight(.medium))
                SkillBadges(skill: skill)
                Text(skill.description).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Menu {
                Button(skill.isOwned ? "Edit…" : "View…") { editor = .skill(skill) }
                if !skill.isOwned {
                    Button("Copy to My Skills (this project)") { adopt(skill, .project) }.disabled(model.project == nil)
                    Button("Copy to My Skills (everywhere)") { adopt(skill, .user) }
                }
                Divider()
                Button("Export…") { exportSelection = [skill.id] }
                Button("Reveal in Finder") { openFile(skill.url) }
                if skill.origin != .builtin {
                    Divider()
                    Button("Move to Trash…", role: .destructive) { trashing = skill }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .opacity(off || skill.shadowed ? 0.55 : 1)
        .padding(.vertical, 2)
    }

    private func adopt(_ skill: Skill, _ scope: SkillScope) {
        do {
            _ = try SkillManager.adopt(skill, scope: scope, projectRoot: model.project, locations: transport.skillLocations)
            transport.refreshDrafts()
            message = "Copied “\(skill.name)” to your DSH skills. It now overrides the original and you can edit it."
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Draft row

private struct DraftRow: View {
    @Environment(AppModel.self) private var model
    let draft: SkillDraft
    let review: () -> Void
    let changed: () -> Void
    @State private var error: String?
    @State private var conflict = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.noticeTint).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(draft.name).font(.callout.weight(.medium))
                    SkillBadge(text: draft.sourceLabel, tint: Theme.noticeTint)
                    SkillBadge(text: draft.scope == .project ? "Project" : "Everywhere")
                }
                Text(draft.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let note = draft.note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.errorTint) }
            }
            Spacer(minLength: 0)
            Button("Review") { review() }
            Button("Approve") { approve(.fail) }.buttonStyle(.borderedProminent)
            Button(role: .destructive) { reject() } label: { Image(systemName: "xmark") }.help("Reject and delete this draft")
        }
        .padding(.vertical, 3)
        .confirmationDialog("A skill named “\(draft.name)” already exists.", isPresented: $conflict, titleVisibility: .visible) {
            Button("Replace it", role: .destructive) { approve(.replace) }
            Button("Keep both") { approve(.rename) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func approve(_ policy: ConflictPolicy) {
        do {
            _ = try SkillDrafts.approve(draft, projectRoot: model.project, conflict: policy, locations: model.transport.skillLocations)
            model.transport.refreshDrafts()
            changed()
        } catch let e as SkillError {
            if case .exists = e { conflict = true } else { error = e.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }

    private func reject() {
        do {
            try SkillDrafts.reject(draft)
            model.transport.refreshDrafts()
            changed()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Editor (skills, drafts, new)

struct SkillEditorSheet: View {
    enum Target: Identifiable {
        case skill(Skill), draft(SkillDraft), new(scope: SkillScope)
        var id: String {
            switch self {
            case .skill(let s): "skill:\(s.id)"
            case .draft(let d): "draft:\(d.id)"
            case .new: "new"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: Target
    let changed: () -> Void

    @State private var text = ""
    @State private var original = ""
    @State private var scope: SkillScope = .project
    @State private var error: String?
    @State private var conflict = false
    @State private var improving = false
    @State private var improveNote = ""

    private var readOnly: Bool {
        if case .skill(let s) = target { return !s.isOwned }
        return false
    }

    private var title: String {
        switch target {
        case .skill(let s): s.isOwned ? "Edit skill" : "\(s.origin.label) \(s.kind.label.lowercased()) (read-only)"
        case .draft: "Review draft"
        case .new: "New skill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if case .draft(let d) = target { SkillBadge(text: d.sourceLabel, tint: Theme.noticeTint) }
                if case .skill(let s) = target { SkillBadges(skill: s) }
            }
            .padding(12)
            Divider()
            TextEditor(text: $text)
                .font(Theme.mono(12))
                .disabled(readOnly)
                .padding(4)
            let issues = SkillLint.check(text)
            if !issues.isEmpty && !readOnly {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(issues) { issue in
                            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                .font(.caption)
                                .foregroundStyle(issue.severity == .error ? Theme.errorTint : issue.severity == .warning ? Theme.noticeTint : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(maxHeight: 84)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.errorTint).padding(.horizontal, 12).padding(.top, 6) }
            Divider()
            footer
        }
        .frame(width: 720, height: 600)
        .onAppear(perform: load)
        .confirmationDialog("A skill with that name already exists.", isPresented: $conflict, titleVisibility: .visible) {
            Button("Replace it", role: .destructive) { activate(.replace) }
            Button("Keep both") { activate(.rename) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch target {
            case .skill(let s):
                if readOnly {
                    Button("Copy to My Skills (this project)") { adopt(s, .project) }.disabled(model.project == nil)
                    Button("Copy to My Skills (everywhere)") { adopt(s, .user) }
                } else {
                    Button { Task { await improve() } } label: { Label(improving ? "Improving…" : "Improve with AI", systemImage: "sparkles") }
                        .disabled(improving)
                }
            case .draft:
                Picker("Goes to", selection: $scope) {
                    Text("This project").tag(SkillScope.project)
                    Text("Everywhere").tag(SkillScope.user)
                }
                .pickerStyle(.menu).fixedSize()
                Button(role: .destructive) { reject() } label: { Text("Reject") }
            case .new:
                Picker("Save to", selection: $scope) {
                    Text("This project").tag(SkillScope.project).disabled(model.project == nil)
                    Text("Everywhere").tag(SkillScope.user)
                }
                .pickerStyle(.menu).fixedSize()
            }
            Spacer()
            Button(readOnly ? "Close" : "Cancel") { dismiss() }
            switch target {
            case .skill(let s) where !readOnly:
                Button("Save") { save(s) }.buttonStyle(.borderedProminent).disabled(text == original)
            case .draft(let d):
                Button("Save Draft") { saveDraft(d) }.disabled(text == original)
                Button("Approve & Activate") { activate(.fail) }.buttonStyle(.borderedProminent)
            case .new:
                Button("Create") { activate(.fail) }.buttonStyle(.borderedProminent)
            default: EmptyView()
            }
        }
        .padding(12)
    }

    // MARK: Actions

    private func load() {
        switch target {
        case .skill(let s): text = SkillManager.read(s)
        case .draft(let d):
            text = (try? String(contentsOf: d.skillFile, encoding: .utf8)) ?? ""
            scope = d.scope
        case .new(let sc):
            scope = sc
            text = SkillManager.scaffold(name: "new-skill", description: "Use when …")
        }
        original = text
    }

    private func save(_ skill: Skill) {
        do {
            try SkillManager.write(skill, text: text)
            model.transport.refreshDrafts()
            changed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func saveDraft(_ draft: SkillDraft) {
        do {
            try SkillDrafts.update(draft, text: text)
            try SkillDrafts.retarget(draft, scope: scope, projectRoot: model.project)
            model.transport.refreshDrafts()
            original = text
            changed()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func activate(_ policy: ConflictPolicy) {
        let locations = model.transport.skillLocations
        do {
            switch target {
            case .draft(let d):
                try SkillDrafts.update(d, text: text)
                try SkillDrafts.retarget(d, scope: scope, projectRoot: model.project)
                let fresh = SkillDrafts.list(locations: locations).first { $0.id == d.id } ?? d
                _ = try SkillDrafts.approve(fresh, projectRoot: model.project, conflict: policy, locations: locations)
            case .new:
                _ = try SkillManager.create(text: text, scope: scope, projectRoot: model.project, conflict: policy, locations: locations)
            default: return
            }
            model.transport.refreshDrafts()
            changed()
            dismiss()
        } catch let e as SkillError {
            if case .exists = e { conflict = true } else { error = e.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }

    private func reject() {
        guard case .draft(let d) = target else { return }
        do {
            try SkillDrafts.reject(d)
            model.transport.refreshDrafts()
            changed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func adopt(_ skill: Skill, _ scope: SkillScope) {
        do {
            _ = try SkillManager.adopt(skill, scope: scope, projectRoot: model.project, locations: model.transport.skillLocations)
            model.transport.refreshDrafts()
            changed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func improve() async {
        improving = true
        defer { improving = false }
        do {
            let goal = "Improve this skill: tighten the description so it triggers at the right time, fix unclear or missing steps, and add verification. Keep its purpose and name."
            let out = try await model.transport.generateSkill(goal: goal, from: nil, improving: text)
            text = out.text
            error = nil
        } catch { self.error = "Couldn't improve it: \(error.localizedDescription)" }
    }
}

// MARK: - Generate with AI

struct GenerateSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let changed: () -> Void

    @State private var goal = ""
    @State private var scope: SkillScope = .project
    @State private var fromChat = false
    @State private var working = false
    @State private var generated: GeneratedSkill?
    @State private var text = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var chat: SessionVM? { model.selectedSession }
    private var chatHasHistory: Bool { !(chat?.entries.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Write a skill with AI", systemImage: "sparkles").font(.headline)
            if generated == nil {
                Text("Describe what the skill should do and when it should be used. The model writes it; you review it before anything is active.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $goal)
                    .font(.body)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                if goal.isEmpty {
                    Text("For example: “Debug a Godot 4 game: run it headless, read the errors, fix the GDScript, and confirm with a screenshot.”")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Toggle("Base it on this chat (“turn what we just did into a skill”)", isOn: $fromChat)
                    .disabled(!chatHasHistory)
                Picker("Save for", selection: $scope) {
                    Text("This project").tag(SkillScope.project).disabled(model.project == nil)
                    Text("All my projects").tag(SkillScope.user)
                }
                .pickerStyle(.segmented).frame(maxWidth: 320)
            } else {
                Text("Review and edit it, then save it to the approval queue or activate it now.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(Theme.mono(12))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                    .frame(minHeight: 280)
                ForEach(SkillLint.check(text).filter { $0.severity >= .warning }) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.noticeTint)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.errorTint) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Writing…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(working ? "Stop" : "Cancel") { working ? task?.cancel() : dismiss() }
                if generated == nil {
                    Button("Generate") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || goal.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)
                } else {
                    Button("Regenerate") { generated = nil }
                    Button("Save as Draft") { save(activate: false) }
                    Button("Save & Activate") { save(activate: true) }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 640, height: generated == nil ? 430 : 620)
        .onAppear { scope = model.project == nil ? .user : .project }
    }

    private func start() {
        working = true
        error = nil
        task = Task {
            do {
                let out = try await model.transport.generateSkill(goal: goal, from: fromChat ? chat : nil)
                if Task.isCancelled { working = false; return }
                generated = out
                text = out.text
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func save(activate: Bool) {
        let locations = model.transport.skillLocations
        do {
            if activate {
                _ = try SkillManager.create(text: text, scope: scope, projectRoot: model.project, conflict: .rename, locations: locations)
            } else {
                _ = try SkillDrafts.create(text: text, scope: scope, projectRoot: model.project, source: fromChat ? "chat" : "ai", locations: locations)
            }
            model.transport.refreshDrafts()
            changed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Import

struct ImportSkillsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let changed: () -> Void

    @State private var plan: ImportPlan?
    @State private var selected: Set<String> = []
    @State private var scope: SkillScope = .project
    @State private var review = false
    @State private var link = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import skills", systemImage: "square.and.arrow.down").font(.headline)
            if let plan { reviewStage(plan) } else { chooseStage }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.errorTint) }
            if let done { Label(done, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Theme.successTint) }
        }
        .padding(16)
        .frame(width: 660, height: 560)
        .onAppear { scope = model.project == nil ? .user : .project }
        .onDisappear { if let plan { SkillImporter.dispose(plan) } }
    }

    private var chooseStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring in skills, rules and commands from Claude Code, Cursor, Agent Skills, or a repository. You'll see what was found and choose what to import — nothing is run.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { choose(directory: true) } label: { Label("Choose Folder…", systemImage: "folder") }
                Button { choose(directory: false) } label: { Label("Choose File or Zip…", systemImage: "doc.zipper") }
                Menu("Common places") {
                    ForEach(commonPlaces, id: \.path) { place in
                        Button(place.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { scan(place) }
                    }
                    if commonPlaces.isEmpty { Text("No .claude / .cursor folders found") }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Divider()
            Text("Or fetch from a link (https): a GitHub repository or folder, a .zip, or a .md/.mdc file.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("https://github.com/owner/repo/tree/main/skills", text: $link).textFieldStyle(.roundedBorder)
                Button("Fetch") { fetch() }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            if busy { HStack { ProgressView().controlSize(.small); Text("Working…").font(.caption).foregroundStyle(.secondary) } }
            Spacer()
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }
    }

    private var commonPlaces: [URL] {
        var out: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        for rel in [".claude", ".cursor", ".agents"] {
            let url = home.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { out.append(url) }
        }
        if let project = model.project {
            for rel in [".claude", ".cursor", ".agents", ".qwen"] {
                let url = project.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: url.path) { out.append(url) }
            }
        }
        return out
    }

    @ViewBuilder
    private func reviewStage(_ plan: ImportPlan) -> some View {
        Text("Found in \(plan.source.lastPathComponent.isEmpty ? plan.source.path : plan.source.lastPathComponent):")
            .font(.callout).foregroundStyle(.secondary)
        if plan.candidates.isEmpty {
            EmptyStateView(icon: "questionmark.folder", title: "Nothing to import", message: plan.notes.joined(separator: " ")) {
                Button("Back") { SkillImporter.dispose(plan); self.plan = nil }
            }
        } else {
            List {
                ForEach(plan.candidates) { cand in
                    Toggle(isOn: Binding(get: { selected.contains(cand.id) },
                                         set: { if $0 { selected.insert(cand.id) } else { selected.remove(cand.id) } })) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(cand.name).font(.callout.weight(.medium))
                                SkillBadge(text: cand.origin.label, tint: cand.origin.tint)
                                SkillBadge(text: cand.isInstructionFile ? "Project instructions" : cand.kind.label)
                                if cand.hasScripts { SkillBadge(text: "Has scripts", tint: Theme.noticeTint) }
                                if cand.fileCount > 1 { SkillBadge(text: "\(cand.fileCount) files") }
                            }
                            Text(cand.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            ForEach(cand.issues, id: \.self) { Text("⚠︎ \($0)").font(.caption2).foregroundStyle(Theme.noticeTint) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            ForEach(plan.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if plan.candidates.contains(where: { selected.contains($0.id) && $0.hasScripts }) {
                Label("Some selected skills bundle scripts. They never run automatically, but read them before you let the agent use them.",
                      systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(Theme.noticeTint)
            }
            HStack {
                Picker("Import to", selection: $scope) {
                    Text("This project").tag(SkillScope.project).disabled(model.project == nil)
                    Text("All my projects").tag(SkillScope.user)
                }
                .pickerStyle(.menu).fixedSize()
                Toggle("Review each first", isOn: $review)
                    .toggleStyle(.checkbox)
                    .help("Put them in the approval queue instead of activating right away.")
                Spacer()
                Button(selected.count == plan.candidates.count ? "Select None" : "Select All") {
                    selected = selected.count == plan.candidates.count ? [] : Set(plan.candidates.map(\.id))
                }
            }
            HStack {
                Button("Back") { SkillImporter.dispose(plan); self.plan = nil; selected = []; done = nil }
                Spacer()
                Button("Close") { dismiss() }
                Button(review ? "Add \(selected.count) for Review" : "Import \(selected.count)") { performImport(plan) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
    }

    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.message = directory ? "Choose a folder with skills, a .claude or .cursor folder, or a whole project."
                                  : "Choose a .zip, .md or .mdc file."
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }

    private func scan(_ url: URL) {
        busy = true
        error = nil
        Task {
            do {
                let found = try await Task.detached { try SkillImporter.scan(url) }.value
                show(found)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func fetch() {
        busy = true
        error = nil
        Task {
            do { show(try await SkillImporter.scan(remote: link)) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func show(_ found: ImportPlan) {
        plan = found
        selected = Set(found.candidates.map(\.id))
        done = nil
    }

    private func performImport(_ plan: ImportPlan) {
        do {
            let result = try SkillImporter.perform(plan, selecting: selected, scope: scope, projectRoot: model.project,
                                                   asDraft: review, conflict: .rename, locations: model.transport.skillLocations)
            model.transport.refreshDrafts()
            changed()
            var parts: [String] = []
            if !result.imported.isEmpty { parts.append("Imported \(result.imported.count)") }
            if !result.drafts.isEmpty { parts.append("\(result.drafts.count) waiting in Awaiting approval") }
            done = parts.joined(separator: " · ")
            if !result.skipped.isEmpty {
                error = result.skipped.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            } else {
                error = nil
            }
            selected = []
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Export

struct ExportSkillsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let skills: [Skill]
    let preselected: Set<String>

    @State private var selected: Set<String> = []
    @State private var format: ExportFormat = .portable
    @State private var message: String?
    @State private var isError = false
    @State private var conflictFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Export skills", systemImage: "square.and.arrow.up").font(.headline)
            List(skills) { skill in
                Toggle(isOn: Binding(get: { selected.contains(skill.id) },
                                     set: { if $0 { selected.insert(skill.id) } else { selected.remove(skill.id) } })) {
                    HStack(spacing: 6) {
                        Text(skill.name).font(.callout)
                        SkillBadge(text: skill.origin.label, tint: skill.origin.tint)
                        if skill.kind != .skill { SkillBadge(text: skill.kind.label) }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 180)
            Picker("Format", selection: $format) {
                ForEach(ExportFormat.allCases) { f in Text(f.label).tag(f) }
            }
            Text(format.detail).font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(isError ? Theme.errorTint : Theme.successTint) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Write into a Folder…") { chooseFolder() }.disabled(selected.isEmpty)
                Button("Save Zip…") { saveZip() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 500)
        .onAppear { selected = preselected }
        .confirmationDialog("Some of these already exist in that folder.", isPresented: Binding(get: { conflictFolder != nil }, set: { if !$0 { conflictFolder = nil } }),
                            titleVisibility: .visible) {
            Button("Replace them", role: .destructive) { if let f = conflictFolder { write(to: f, conflict: .replace) }; conflictFolder = nil }
            Button("Keep both") { if let f = conflictFolder { write(to: f, conflict: .rename) }; conflictFolder = nil }
            Button("Cancel", role: .cancel) { conflictFolder = nil }
        }
    }

    private var chosen: [Skill] { skills.filter { selected.contains($0.id) } }

    private func saveZip() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "dsh-skills.zip"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SkillExporter.zip(chosen, format: format, to: url)
            message = "Saved \(chosen.count) skill\(chosen.count == 1 ? "" : "s") to \(url.lastPathComponent)."
            isError = false
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { message = error.localizedDescription; isError = true }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder to write into — a project root, or your home folder for user-wide skills."
        panel.prompt = "Export Here"
        if let project = model.project { panel.directoryURL = project }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url, conflict: .fail)
    }

    private func write(to folder: URL, conflict: ConflictPolicy) {
        do {
            let written = try SkillExporter.write(chosen, format: format, into: folder, conflict: conflict)
            message = "Wrote \(written.count) item\(written.count == 1 ? "" : "s") under \(folder.lastPathComponent)."
            isError = false
            if let first = written.first { NSWorkspace.shared.activateFileViewerSelecting([first]) }
        } catch let e as SkillError {
            if case .exists = e { conflictFolder = folder } else { message = e.localizedDescription; isError = true }
        } catch { message = error.localizedDescription; isError = true }
    }
}
