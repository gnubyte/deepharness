import SwiftUI
import VisionHarnessCore

/// Settings ▸ AI Models ▸ Sensitive data: what is masked before a request goes to a model that isn't private, the
/// user's own terms, and a box to try it.
struct SensitiveDataSection: View {
    @Environment(AppModel.self) private var model
    @State private var terms = ""
    @State private var sample = "Email jane.doe@example.com or call 415-555-0132 about card 4111 1111 1111 1111; the key is sk-proj-Abc123Def456Ghi789Jkl0."
    /// The sample as a model that isn't private would get it.
    @State private var masked = ""

    var body: some View {
        let config = model.config
        VStack(alignment: .leading, spacing: 10) {
            Label("Sensitive data", systemImage: "eye.slash").font(.headline)
            Toggle("Mask sensitive data before sending it to models that aren't private",
                   isOn: binding(\.enabled))
                .toggleStyle(.switch)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Toggle("Secrets and keys", isOn: binding(\.secrets))
                    Toggle("Email addresses", isOn: binding(\.emails))
                    Toggle("Phone numbers", isOn: binding(\.phones))
                }
                GridRow {
                    Toggle("ID and card numbers", isOn: binding(\.ids))
                    Toggle("IP addresses", isOn: binding(\.ips))
                    Toggle("Custom terms", isOn: binding(\.terms))
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!config.shield.enabled)

            VStack(alignment: .leading, spacing: 4) {
                Text("Custom terms").font(.callout.weight(.semibold))
                TextEditor(text: $terms)
                    .font(Theme.mono(11))
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                    .disabled(!config.shield.enabled || !config.shield.terms)
                    .onChange(of: terms) { _, text in
                        let lines = text.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        if lines != config.shield.customTerms { config.shield.customTerms = lines }
                    }
                Text("One per line: client names, patient names, project code names — matched as whole words, in any case. Start a line with re: for a regular expression.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("Secrets in your Credentials Vault are always masked, whatever the switches say.", systemImage: "key.horizontal")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Try it").font(.callout.weight(.semibold))
                TextField("Type something with a name, an email, a key…", text: $sample, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                Text("What a model that isn't private would receive:").font(.caption).foregroundStyle(.secondary)
                Text(masked.isEmpty ? " " : masked)
                    .font(Theme.mono(11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
        .onAppear { terms = config.shield.customTerms.joined(separator: "\n") }
        .task(id: TryIt(sample: sample, settings: config.shield)) { await updateMasked() }
    }

    private struct TryIt: Equatable {
        var sample: String
        var settings: ShieldSettings
    }

    /// Mask the sample (the note left out) — after a moment's pause in the typing, and off the main thread, so a
    /// long paste doesn't hold up the window.
    private func updateMasked() async {
        if !masked.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }
        let sample = self.sample, settings = model.config.shield, vault = model.transport.vault
        let result = await Task.detached(priority: .userInitiated) {
            let detector = SensitiveDetector(settings: settings, vaultValues: vault.valuesForRedaction().map(\.value))
            let request = LLMRequest(systemPrompt: "", messages: [.user(sample)], tools: [], model: "")
            return Shield.mask(request, detector: detector).request.messages.first?.content ?? sample
        }.value
        if !Task.isCancelled { masked = result }
    }

    private func binding(_ key: WritableKeyPath<ShieldSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.config.shield[keyPath: key] },
                set: { model.config.shield[keyPath: key] = $0 })
    }
}
