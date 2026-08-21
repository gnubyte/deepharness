import SwiftUI
import AppKit
import DSHCore

/// Settings: model routes, permissions, editor and terminal, and the plugin
/// catalog. The wizard is the guided path; this is the direct one.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProviderSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
            PluginSettings()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "text.cursor") }
        }
        .frame(width: 620, height: 460)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Permissions for new chats") {
                ForEach(PermissionPreset.allCases, id: \.self) { preset in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            model.config.preset = preset.rawValue
                        } label: {
                            Image(systemName: model.config.asPreset == preset
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.config.asPreset == preset ? preset.tint : .secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.label)
                            Text(preset.detail)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Setup") {
                LabeledContent("Configuration wizard") {
                    Button("Run Again…") { model.showWizard = true }
                }
                LabeledContent("Project") {
                    HStack {
                        Text(model.project?.path ?? "none open")
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Button("Change…") { model.chooseProject() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Providers

private struct ProviderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ProviderProfile?
    @State private var probeResult: String?

    private var config: AppConfig { model.config }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(config.providers, id: \.routeID) { provider in
                    HStack(spacing: 10) {
                        Image(systemName: provider.kind.icon)
                            .foregroundStyle(config.activeRoute == provider.routeID ? Color.accentColor : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.name).font(.callout.weight(.medium))
                            Text("\(provider.model) · \(provider.baseURL)")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if config.activeRoute == provider.routeID {
                            Text("Active")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        } else {
                            Button("Use") { config.activeRoute = provider.routeID }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = provider }
                    .contextMenu {
                        Button("Edit…") { editing = provider }
                        Button("Remove", role: .destructive) { config.removeProvider(provider) }
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    editing = ProviderProfile(kind: .openAICompat, name: "New server",
                                              baseURL: "http://127.0.0.1:8002/v1", model: "")
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button("Test Active") { Task { await test() } }
                    .disabled(config.activeProvider == nil)
                if let probeResult {
                    Text(probeResult).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Button("Wizard…") { model.showWizard = true }
            }
            .padding(10)
        }
        .sheet(item: Binding(get: { editing.map(EditableProvider.init) },
                             set: { editing = $0?.profile })) { wrapper in
            ProviderEditor(profile: wrapper.profile)
        }
    }

    private func test() async {
        guard let provider = config.activeProvider else { return }
        probeResult = "Testing…"
        do {
            let models = try await OpenAIClient(profile: provider).listModels()
            probeResult = "OK — \(models.count) model(s)"
        } catch {
            probeResult = AppTransport.describe(error)
        }
    }
}

/// `sheet(item:)` needs Identifiable; `ProviderProfile` deliberately is not.
private struct EditableProvider: Identifiable {
    let profile: ProviderProfile
    var id: String { profile.routeID }
    init(_ profile: ProviderProfile) { self.profile = profile }
}

private struct ProviderEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProviderProfile
    @State private var apiKey: String = ""
    @State private var status: String?
    @State private var models: [String] = []
    private let original: ProviderProfile

    init(profile: ProviderProfile) {
        _draft = State(initialValue: profile)
        original = profile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(ProviderProfile.Kind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                TextField("Name", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL)
                    .font(Theme.mono(11))
                TextField("Model", text: $draft.model)
                    .font(Theme.mono(11))
                if draft.needsAPIKey {
                    SecureField("API key", text: $apiKey)
                }
                LabeledContent("Temperature") {
                    TextField("default", value: $draft.temperature, format: .number)
                        .frame(width: 80)
                }
                if !models.isEmpty {
                    Picker("Discovered", selection: $draft.model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Discover Models") { Task { await discover() } }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480)
        .onAppear { apiKey = model.config.apiKey(for: original) }
    }

    private func discover() async {
        status = "Connecting…"
        var probe = draft
        probe.apiKey = apiKey.isEmpty ? nil : apiKey
        do {
            models = try await OpenAIClient(profile: probe).listModels().sorted()
            status = "Found \(models.count) model(s)"
            if draft.model.isEmpty, let first = models.first { draft.model = first }
        } catch {
            models = []
            status = AppTransport.describe(error)
        }
    }

    private func save() {
        var profile = draft
        profile.apiKey = nil
        if original.routeID != profile.routeID {
            model.config.removeProvider(original)
        }
        model.config.activate(profile)
        model.config.setAPIKey(apiKey, for: profile)
        dismiss()
    }
}

// MARK: - Plugins

private struct PluginSettings: View {
    @Environment(AppModel.self) private var model

    private var transport: AppTransport { model.transport }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Loaded") {
                    if transport.plugins.isEmpty {
                        Text("No plugins loaded.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(transport.plugins) { plugin in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .foregroundStyle(.tint)
                                Text(plugin.name).font(.callout.weight(.medium))
                                if let version = plugin.version {
                                    Text("v\(version)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(plugin.tools.count) tool(s)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let description = plugin.description {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(plugin.tools, id: \.name) { tool in
                                HStack(spacing: 5) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    Text(tool.name).font(Theme.mono(10))
                                    Text(tool.description)
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 6)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                if !transport.pluginErrors.isEmpty {
                    Section("Could not load") {
                        ForEach(transport.pluginErrors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(Theme.errorTint)
                        }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("A plugin is a JSON manifest declaring tools backed by shell commands. Drop one in either folder and reload.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Plugins Folder") {
                        try? FileManager.default.createDirectory(at: PluginLoader.userDirectory,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.open(PluginLoader.userDirectory)
                    }
                    Button("Add Example") {
                        _ = try? PluginLoader.installExample()
                        transport.refreshProjectContext()
                    }
                    Spacer()
                    Button("Reload") { transport.refreshProjectContext() }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Editor

private struct EditorSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var config = model.config
        Form {
            Section("Editor") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $config.editorFontSize, in: 9...24, step: 1)
                        Text("\(Int(config.editorFontSize))pt")
                            .font(Theme.metaFont).monospacedDigit().frame(width: 34)
                    }
                }
                Toggle("Wrap long lines", isOn: $config.editorWraps)
                Toggle("Show line numbers", isOn: $config.editorLineNumbers)
            }
            Section("Terminal") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $config.terminalFontSize, in: 9...24, step: 1)
                        Text("\(Int(config.terminalFontSize))pt")
                            .font(Theme.metaFont).monospacedDigit().frame(width: 34)
                    }
                }
                LabeledContent("Shell") {
                    TextField(PTY.defaultShell, text: $config.terminalShell)
                        .font(Theme.mono(11))
                }
                Text("Leave the shell blank to use your login shell (\(PTY.defaultShell)). New terminals pick this up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
