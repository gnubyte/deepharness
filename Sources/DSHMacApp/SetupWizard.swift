import SwiftUI
import AppKit
import DSHCore

/// First-run configuration, re-runnable from Settings or the Help menu.
///
/// The job is narrow: find a model server, prove we can reach it, and pin a
/// permission preset. Everything else in the app assumes those three are done.
struct SetupWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome
    @State private var kind: ProviderProfile.Kind = .openAICompat
    @State private var host = ""
    @State private var port = ""
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var discovered: [String] = []
    @State private var probe: ProbeState = .idle
    @State private var preset: PermissionPreset = .workspaceWrite

    enum Step: Int, CaseIterable {
        case welcome, backend, connection, models, permissions, project, done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .backend: "Backend"
            case .connection: "Connection"
            case .models: "Model"
            case .permissions: "Permissions"
            case .project: "Project"
            case .done: "Ready"
            }
        }
    }

    enum ProbeState: Equatable {
        case idle, running, ok(Int), failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Divider()
            ScrollView {
                content
                    .padding(28)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 580)
        .onAppear(perform: seedFromConfig)
    }

    // MARK: Header

    /// Seven labels do not fit across a sheet, so the steps are a segmented
    /// bar and only the current one is named.
    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach(Step.allCases, id: \.rawValue) { entry in
                    Capsule()
                        .fill(entry.rawValue <= step.rawValue ? Color.accentColor : Theme.hairline)
                        .frame(height: 3)
                }
            }
            HStack {
                Text(step.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(Theme.metaFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .backend: backendStep
        case .connection: connectionStep
        case .models: modelStep
        case .permissions: permissionStep
        case .project: projectStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Set up DSH")
                .font(.largeTitle.weight(.semibold))
            Text("""
            This app is the agent harness — it runs the tool loop itself and talks straight to a \
            model server. Nothing else has to be installed or kept running.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                bullet("server.rack", "Point it at a model",
                       "A DGX Spark or any OpenAI-compatible server on your network, a local Ollama or LM Studio, or a cloud provider.")
                bullet("wrench.and.screwdriver", "Give it tools",
                       "Read, write, edit, glob, grep, shell, and web fetch — the Qwen Code tool set, so prompts and skills written for it work here.")
                bullet("chevron.left.forwardslash.chevron.right", "Work in a project",
                       "Open a folder to get a file tree, an editor, and a terminal beside the chat.")
            }
            .padding(.top, 4)
        }
    }

    private func bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var backendStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where does the model run?").font(.title2.weight(.semibold))
            Text("You can change this later, and keep more than one configured.")
                .font(.callout).foregroundStyle(.secondary)

            ForEach(ProviderProfile.Kind.allCases, id: \.self) { candidate in
                Button {
                    kind = candidate
                    applyDefaults(for: candidate)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 16))
                            .foregroundStyle(kind == candidate ? Color.accentColor : .secondary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(for: candidate)).font(.callout.weight(.medium))
                            Text(detail(for: candidate)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if kind == candidate {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(kind == candidate ? Color.accentColor.opacity(0.10) : Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(kind == candidate ? Color.accentColor.opacity(0.5) : Theme.hairline)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label(for kind: ProviderProfile.Kind) -> String {
        switch kind {
        case .openAICompat: "DGX Spark or another server on your network"
        default: kind.label
        }
    }

    private func detail(for kind: ProviderProfile.Kind) -> String {
        switch kind {
        case .openAICompat:
            "An OpenAI-compatible endpoint — vLLM, SGLang, llama.cpp, or the serving stack on a DGX Spark. Reached over your LAN."
        case .ollama: "Models running locally through Ollama on this Mac."
        case .lmStudio: "Models running locally through LM Studio on this Mac."
        case .openAI: "OpenAI's hosted API. Needs an API key."
        case .openRouter: "Many hosted models behind one API. Needs an API key."
        }
    }

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection").font(.title2.weight(.semibold))
            Text(connectionHint)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Address").frame(width: 70, alignment: .trailing)
                    TextField(addressPlaceholder, text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                if usesPort {
                    GridRow {
                        Text("Port").frame(width: 70, alignment: .trailing)
                        TextField("8002", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }
                if needsKey {
                    GridRow {
                        Text("API key").frame(width: 70, alignment: .trailing)
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("URL").frame(width: 70, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(baseURL)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.callout)

            HStack(spacing: 10) {
                Button("Test Connection") { Task { await runProbe() } }
                    .disabled(probe == .running || host.isEmpty)
                probeIndicator
            }
            .padding(.top, 4)

            if case .failed(let reason) = probe {
                Card(fill: Theme.errorTint.opacity(0.10)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reason).font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(troubleshooting)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var connectionHint: String {
        switch kind {
        case .openAICompat:
            "Enter the address of the machine serving the model and the port its OpenAI-compatible API listens on. On a DGX Spark following the setup guide that is port 8002, and the address is the box's hostname or LAN IP."
        case .ollama:
            "Ollama serves an OpenAI-compatible API on this Mac. The defaults are usually right — start it with `ollama serve` if it is not already running."
        case .lmStudio:
            "Start LM Studio's local server (Developer ▸ Start Server) and load a model, then test the connection."
        case .openAI, .openRouter:
            "Paste an API key. It is stored in your login keychain, never in the app's preferences file."
        }
    }

    private var addressPlaceholder: String {
        switch kind {
        case .openAICompat: "spark.local or 192.168.1.50"
        case .ollama, .lmStudio: "127.0.0.1"
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        }
    }

    private var usesPort: Bool {
        kind == .openAICompat || kind == .ollama || kind == .lmStudio
    }

    private var needsKey: Bool { kind == .openAI || kind == .openRouter }

    /// The endpoint we will actually call.
    private var baseURL: String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed.hasSuffix("/v1") || trimmed.contains("/v1/")
                ? trimmed
                : trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1"
        }
        let portPart = port.trimmingCharacters(in: .whitespaces)
        let hostPart = portPart.isEmpty ? trimmed : "\(trimmed):\(portPart)"
        return "http://\(hostPart)/v1"
    }

    private var troubleshooting: String {
        switch kind {
        case .openAICompat:
            "Check the server is bound to 0.0.0.0 rather than 127.0.0.1 — a server listening only on loopback is unreachable from another machine. Then confirm the port and that no firewall is in the way."
        case .ollama:
            "Run `ollama serve` in a terminal, then `ollama list` to confirm a model is installed."
        case .lmStudio:
            "In LM Studio, open the Developer tab, load a model, and press Start Server."
        case .openAI, .openRouter:
            "Check the key is current and has credit or quota on the account."
        }
    }

    @ViewBuilder
    private var probeIndicator: some View {
        switch probe {
        case .idle: EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let count):
            Label(count == 0 ? "Reached the server" : "Reached the server — \(count) model(s)",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.successTint)
        case .failed:
            Label("Could not connect", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.errorTint)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a model").font(.title2.weight(.semibold))
            if discovered.isEmpty {
                Text("The server did not return a model list, so type the model id it expects. On a vLLM or SGLang server that is the name it was launched with.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("model id", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
            } else {
                Text("These are the models \(baseURL) reports.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(discovered, id: \.self) { candidate in
                            Button {
                                modelID = candidate
                            } label: {
                                HStack {
                                    Image(systemName: modelID == candidate ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(modelID == candidate ? Color.accentColor : .secondary)
                                    Text(candidate).font(Theme.mono(12))
                                    Spacer()
                                    if isToolCapable(candidate) {
                                        Text("tools")
                                            .font(.system(size: 9, weight: .semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Theme.successTint.opacity(0.18), in: Capsule())
                                    }
                                }
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                                .background(modelID == candidate ? Color.accentColor.opacity(0.10) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 240)

                TextField("or type a model id", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
            }

            Card {
                Label {
                    Text("An agent needs a model that can call tools. Qwen3, Qwen2.5-Coder, and DeepSeek-V3-class models work well; very small models will struggle.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A hint, not a guarantee — the families that reliably emit tool calls.
    private func isToolCapable(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return ["qwen", "deepseek", "gpt-4", "gpt-5", "llama-3", "llama3", "mistral", "command-r"]
            .contains { lowered.contains($0) }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How much can the agent do?").font(.title2.weight(.semibold))
            Text("This is the preset new chats start with. Each chat keeps the preset it was created with.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(PermissionPreset.allCases, id: \.self) { candidate in
                Button {
                    preset = candidate
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(preset == candidate ? candidate.tint : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.label).font(.callout.weight(.medium))
                            Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if preset == candidate {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(candidate.tint)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(preset == candidate ? candidate.tint.opacity(0.10) : Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(preset == candidate ? candidate.tint.opacity(0.5) : Theme.hairline)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var projectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open a project").font(.title2.weight(.semibold))
            Text("""
            The project folder is the agent's working directory and its permission boundary. \
            You can skip this and open one whenever you like.
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let project = model.project {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.lastPathComponent).font(.callout.weight(.medium))
                            Text(project.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Button("Change…") { model.chooseProject() }
                    }
                }
            } else {
                Button {
                    model.chooseProject()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.successTint)
            Text("You're set up").font(.largeTitle.weight(.semibold))

            Card {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Server").foregroundStyle(.secondary)
                        Text(baseURL).font(Theme.mono(11)).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text(modelID.isEmpty ? "—" : modelID).font(Theme.mono(11))
                    }
                    GridRow {
                        Text("Permissions").foregroundStyle(.secondary)
                        Text(preset.label)
                    }
                    GridRow {
                        Text("Project").foregroundStyle(.secondary)
                        Text(model.project?.path ?? "none yet")
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.callout)
            }

            Text("Run this wizard again any time from Settings, or the Help menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { back() }
            }
            Spacer()
            if step == .project {
                Button("Skip") { step = .done }
            }
            Button(step == .done ? "Start Working" : "Continue") { advance() }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
    }

    private var canAdvance: Bool {
        switch step {
        case .connection: !host.trimmingCharacters(in: .whitespaces).isEmpty
        case .models: !modelID.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func advance() {
        switch step {
        case .connection:
            // Discover models on the way through, so the next step is useful
            // even if the user never pressed Test.
            Task {
                if case .ok = probe {} else { await runProbe() }
                step = .models
            }
        case .models:
            saveProvider()
            step = .permissions
        case .permissions:
            model.config.preset = preset.rawValue
            step = .project
        case .done:
            finish()
        default:
            step = Step(rawValue: step.rawValue + 1) ?? .done
        }
    }

    private func finish() {
        saveProvider()
        model.config.preset = preset.rawValue
        model.config.wizardCompleted = true
        if model.transport.sessions.isEmpty { model.newChat() }
        dismiss()
    }

    // MARK: Actions

    private func seedFromConfig() {
        if let active = model.config.activeProvider {
            kind = active.kind
            modelID = active.model
            preset = model.config.asPreset
            let components = URLComponents(string: active.baseURL)
            if let host_ = components?.host {
                host = host_
                port = components?.port.map(String.init) ?? ""
            } else {
                host = active.baseURL
            }
        } else {
            applyDefaults(for: kind)
        }
    }

    private func applyDefaults(for kind: ProviderProfile.Kind) {
        probe = .idle
        discovered = []
        switch kind {
        case .ollama:
            host = "127.0.0.1"; port = "11434"; modelID = "qwen3:8b"
        case .lmStudio:
            host = "127.0.0.1"; port = "1234"; modelID = ""
        case .openAICompat:
            host = ""; port = "8002"; modelID = ""
        case .openAI:
            host = "https://api.openai.com/v1"; port = ""; modelID = "gpt-4o"
        case .openRouter:
            host = "https://openrouter.ai/api/v1"; port = ""; modelID = "qwen/qwen3-32b"
        }
    }

    private var draftProfile: ProviderProfile {
        ProviderProfile(kind: kind,
                        name: kind == .openAICompat ? "DGX Spark / server" : kind.label,
                        baseURL: baseURL,
                        apiKey: apiKey.isEmpty ? nil : apiKey,
                        model: modelID.isEmpty ? "model" : modelID)
    }

    private func runProbe() async {
        probe = .running
        let client = OpenAIClient(profile: draftProfile)
        do {
            let models = try await client.listModels()
            discovered = models.sorted()
            probe = .ok(models.count)
            if modelID.isEmpty, let first = models.first { modelID = first }
        } catch {
            discovered = []
            probe = .failed(AppTransport.describe(error))
        }
    }

    private func saveProvider() {
        var profile = draftProfile
        let key = apiKey
        profile.apiKey = nil                      // the key lives in the keychain
        model.config.activate(profile)
        if !key.isEmpty { model.config.setAPIKey(key, for: profile) }
    }
}
