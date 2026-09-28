import SwiftUI
import AppKit
import DSHCore

/// Settings: model routes, permissions, editor and terminal, and the plugin
/// catalog. The wizard is the guided path; this is the direct one.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ProviderSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(SettingsTab.models)
            SparkSettings()
                .tabItem { Label("Spark", systemImage: "bolt.horizontal.circle") }
                .tag(SettingsTab.spark)
            SkillsManagerView()
                .tabItem { Label("Skills", systemImage: "graduationcap") }
                .tag(SettingsTab.skills)
            PluginSettings()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.plugins)
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "text.cursor") }
                .tag(SettingsTab.editor)
        }
        .frame(width: 780, height: 600)
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
    @State private var headerRows: [HeaderRow] = []
    @State private var reasoning: String = ""
    @State private var detected: String?
    private let original: ProviderProfile

    init(profile: ProviderProfile) {
        _draft = State(initialValue: profile)
        original = profile
        _headerRows = State(initialValue:
            (profile.customHeaders ?? [:]).map { HeaderRow(key: $0.key, value: $0.value) })
        _reasoning = State(initialValue: profile.reasoningEffort ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("API") {
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(ProviderProfile.Kind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    TextField("Name", text: $draft.name)
                    TextField("Base URL", text: $draft.baseURL)
                        .font(Theme.mono(11))
                    if draft.needsAPIKey {
                        SecureField("API key", text: $apiKey)
                        Text("Stored locally and only used to make API requests from this app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Model") {
                    TextField("Model", text: $draft.model)
                        .font(Theme.mono(11))
                    if !models.isEmpty {
                        Picker("Discovered", selection: $draft.model) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    LabeledContent("Temperature") {
                        TextField("default", value: $draft.temperature, format: .number)
                            .frame(width: 80)
                    }
                    LabeledContent("Max output tokens") {
                        TextField("default", value: $draft.maxOutputTokens, format: .number)
                            .frame(width: 100)
                    }
                    LabeledContent("Context window") {
                        HStack {
                            TextField("auto", value: $draft.contextWindow, format: .number)
                                .frame(width: 100)
                            Button("Detect") { Task { await detect() } }
                        }
                    }
                    Text(detected ?? "Leave blank to auto-detect from the server (vLLM/SGLang report max_model_len). Only set it to force a smaller window.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Default thinking", selection: $reasoning) {
                        Text("Server default").tag("")
                        ForEach(ThinkingLevel.allCases, id: \.self) { level in
                            Text("\(level.label) — \(level.blurb)").tag(level.rawValue)
                        }
                    }
                    Text("Sent as enable_thinking / reasoning_effort. Each chat can override it from the composer or with /think.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                }
                Section("Custom Headers") {
                    ForEach($headerRows) { $row in
                        HStack(spacing: 8) {
                            TextField("name", text: $row.key)
                                .font(Theme.mono(11))
                            TextField("value", text: $row.value)
                                .font(Theme.mono(11))
                        }
                    }
                    .onDelete { headerRows.remove(atOffsets: $0) }
                    Button("Add Header") { headerRows.append(HeaderRow()) }
                    if !headerRows.isEmpty {
                        Text("Extra HTTP headers sent with every request.")
                            .font(.caption).foregroundStyle(.secondary)
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

    private func detect() async {
        detected = "Asking the server…"
        var probe = draft
        probe.apiKey = apiKey.isEmpty ? nil : apiKey
        let info = await OpenAIClient(profile: probe).modelInfo()
        if let limit = info?.contextWindow {
            let follow = (info?.id).flatMap { $0 != draft.model ? " (serving `\($0)`)" : nil } ?? ""
            detected = "Detected \(limit.formatted()) tokens\(follow). Leave the field blank to always use the live value."
        } else if let served = info?.servedModels, !served.isEmpty {
            detected = "The server answered but reports no window for \(draft.model); set one here."
        } else {
            detected = "Could not reach the server to detect the window."
        }
    }

    private func save() {
        var profile = draft
        profile.apiKey = nil
        let headers = headerRows
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .reduce(into: [String: String]()) { $0[$1.key] = $1.value }
        profile.customHeaders = headers.isEmpty ? nil : headers
        profile.reasoningEffort = reasoning.isEmpty ? nil : reasoning
        if original.routeID != profile.routeID {
            model.config.removeProvider(original)
        }
        model.config.activate(profile)
        model.config.setAPIKey(apiKey, for: profile)
        model.transport.resetRouteCache()
        dismiss()
    }
}

/// One editable custom HTTP header.
private struct HeaderRow: Identifiable {
    var id = UUID()
    var key: String
    var value: String
    init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
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


// MARK: - Spark

/// Where the Spark Swapper lives and how to log in to it.
private struct SparkSettings: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var testing = false
    /// Local confirmation (the chat window has its own; two alerts on one
    /// shared flag would fight while this sheet is up).
    @State private var pending: SwapperStatus.Model?

    var body: some View {
        let spark = model.spark
        Form {
            Section {
                TextField("Address", text: $url, prompt: Text("https://192.168.68.69:8999"))
                    .font(Theme.mono(11))
                TextField("Username", text: $user)
                SecureField("Password", text: $pass)
                HStack {
                    Button(testing ? "Connecting…" : "Save & Connect") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(testing || url.isEmpty || user.isEmpty || pass.isEmpty)
                    if spark.pinnedFingerprint != nil {
                        Button("Forget Certificate") { spark.pinnedFingerprint = nil }
                    }
                }
            } header: {
                Text("Spark Swapper")
            } footer: {
                Text("The login you created on the swapper's web page. The password is kept in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let fp = spark.untrustedFingerprint {
                Section("Certificate") {
                    Text("The swapper uses a self-signed certificate. Trust it if this fingerprint matches the server's (`sudo openssl x509 -in /etc/spark-swapper/tls.crt -noout -fingerprint -sha256`):")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Text(fp).font(Theme.mono(10)).textSelection(.enabled)
                    Button("Trust This Certificate") { spark.trustPresentedCertificate() }
                }
            }

            Section("Status") {
                if let err = spark.lastError, spark.untrustedFingerprint == nil {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.errorTint)
                        .font(.caption)
                }
                if let s = spark.status {
                    if let line = spark.progressLine {
                        Label(line, systemImage: "hourglass")
                    }
                    ForEach(s.ordered) { m in
                        HStack {
                            Image(systemName: m.key == s.active ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(m.key == s.active ? Theme.successTint : .secondary)
                            VStack(alignment: .leading) {
                                Text(m.title)
                                Text("\(m.served_id) · \(m.context.formatted()) ctx · \(m.engine ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.key != s.active {
                                Button("Switch") { pending = m }
                                    .disabled(s.isSwitching)
                            }
                        }
                    }
                    if let oc = s.openclaw_primary {
                        Text("OpenClaw → \(oc)").font(.caption).foregroundStyle(.secondary)
                    }
                } else if spark.isConfigured {
                    Text("Not connected yet.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            url = spark.url
            user = spark.username
            pass = spark.password
        }
        .alert("Switch the Spark to \(pending?.title ?? "")?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Switch") {
                if let t = pending { Task { await spark.swap(to: t.key) } }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("The current model stops and the new one loads (Flash takes about 11 minutes). Chats and OpenClaw follow automatically.")
        }
    }

    private func connect() async {
        testing = true
        defer { testing = false }
        let spark = model.spark
        spark.url = url.trimmingCharacters(in: .whitespaces)
        spark.username = user.trimmingCharacters(in: .whitespaces)
        spark.password = pass
        await spark.refresh()
        spark.startMonitoring()
    }
}
