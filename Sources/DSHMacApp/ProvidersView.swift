import SwiftUI
import DSHKit

/// Provider configuration.
///
/// A self-hosted endpoint (vLLM, Ollama, LM Studio, any OpenAI-compatible
/// gateway) is a *hand-declared route* on the `llm-pi-ai` adapter: the harness
/// treats it as configuration rather than a code change, so this view writes a
/// settings section and the route registers on the next request.
struct ProvidersView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Active") {
                    ForEach(model.providers.filter(\.active)) { p in
                        ProviderRow(provider: p, modelCount: count(p))
                    }
                    if model.providers.filter(\.active).isEmpty {
                        Text("No active providers.").foregroundStyle(.secondary)
                    }
                }
                Section("Available") {
                    ForEach(model.providers.filter { !$0.active }.prefix(40)) { p in
                        ProviderRow(provider: p, modelCount: 0)
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add OpenAI-compatible endpoint", systemImage: "plus")
                }
                Spacer()
                Button("Refresh") { Task { await model.refreshProviders() } }
            }
            .padding(12)
        }
        .sheet(isPresented: $showingAdd) { AddEndpointView() }
        .task { await model.refreshProviders() }
    }

    private func count(_ p: ProviderVM) -> Int {
        model.models.filter { $0.provider == p.id }.count
    }
}

struct ProviderRow: View {
    let provider: ProviderVM
    let modelCount: Int

    var body: some View {
        HStack {
            Circle()
                .fill(provider.active ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                Text(provider.id).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if provider.declared {
                Text("custom")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            if modelCount > 0 {
                Text("\(modelCount) model\(modelCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Add endpoint

struct AddEndpointView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var routeKey = ""
    @State private var displayName = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var discovered: [String] = []
    @State private var chosen: Set<String> = []
    @State private var status: String?
    @State private var busy = false

    /// Presets for the endpoints people actually run locally.
    private let presets: [(String, String, String)] = [
        ("Ollama", "ollama-local", "http://127.0.0.1:11434/v1"),
        ("vLLM", "vllm-local", "http://127.0.0.1:8000/v1"),
        ("LM Studio", "lmstudio-local", "http://127.0.0.1:1234/v1"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an OpenAI-compatible endpoint").font(.title3).bold()

            HStack {
                ForEach(presets, id: \.1) { name, key, url in
                    Button(name) {
                        displayName = name
                        routeKey = key
                        baseURL = url
                    }
                    .buttonStyle(.bordered)
                }
            }

            Form {
                TextField("Display name", text: $displayName, prompt: Text("Ollama (local)"))
                TextField("Route key", text: $routeKey, prompt: Text("ollama-local"))
                TextField("Base URL", text: $baseURL, prompt: Text("http://127.0.0.1:11434/v1"))
                SecureField("API key", text: $apiKey, prompt: Text("optional for local servers"))
            }
            .formStyle(.grouped)

            HStack {
                Button {
                    Task { await discover() }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Discover models") }
                }
                .disabled(baseURL.isEmpty || busy)

                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            if !discovered.isEmpty {
                Text("Models").font(.caption).bold()
                List(discovered, id: \.self, selection: $chosen) { id in
                    Text(id).font(.system(.body, design: .monospaced))
                }
                .frame(minHeight: 120, maxHeight: 180)
                .border(Color.secondary.opacity(0.2))
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(routeKey.isEmpty || baseURL.isEmpty || chosen.isEmpty || busy)
            }
        }
        .padding(18)
        .frame(width: 560, height: 560)
    }

    private func discover() async {
        busy = true
        status = nil
        defer { busy = false }
        do {
            let found = try await model.api.discoverModels(
                settingsNs: "llm-pi-ai",
                baseURL: baseURL,
                api: "openai-completions",
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            discovered = found.compactMap { $0["id"]?.stringValue }
            chosen = Set(discovered)
            status = discovered.isEmpty ? "The endpoint listed no models." : "Found \(discovered.count)."
        } catch {
            // A local server that lists nothing is common; let the user proceed
            // by typing an id rather than dead-ending here.
            status = AppModel.describe(error)
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }

        // pi-ai requires a credential *reference* even where the endpoint needs
        // no auth, so a keyless local server still gets a stored placeholder.
        let credentialRef = "\(routeKey.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
        let models: [JSONValue] = chosen.sorted().map { ["id": .string($0)] }

        let profile: JSONValue = [
            "displayName": .string(displayName.isEmpty ? routeKey : displayName),
            "api": "openai-completions",
            "baseURL": .string(baseURL),
            "apiKeyEnv": .string(credentialRef),
            "models": .array(models),
        ]

        do {
            try await model.api.credentialsSet(
                ref: credentialRef,
                value: apiKey.isEmpty ? "no-auth-local-endpoint" : apiKey
            )
            _ = try await model.api.settingsUpdate(
                ns: "llm-pi-ai",
                patch: ["providers": [routeKey: profile]]
            )
            await model.refreshProviders()
            dismiss()
        } catch {
            status = AppModel.describe(error)
        }
    }
}
