import SwiftUI
import DSHCore

/// Settings › Models: the routes, which one is the *main model* (the conductor: the chat talks to it
/// and it hands out subagent tasks), and which ones serve subagents (the fleet). Two DGX Sparks and
/// Amazon Bedrock can all be at work at once, and swapping who leads is one click.
struct ProviderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ProviderProfile?
    @State private var removing: ProviderProfile?
    @State private var status: StatusLine?
    /// The last "Test All" answer for each route, shown on its row.
    @State private var results: [String: StatusLine] = [:]

    private var config: AppConfig { model.config }

    struct StatusLine: Equatable {
        enum Tone { case neutral, success, failure }
        var text: String
        var tone: Tone = .neutral
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ProviderRoutesList(results: results,
                                   edit: { editing = $0 },
                                   remove: { removing = $0 },
                                   report: { status = $0 })
                    .padding(20)
            }
            Divider()
            footer
        }
        .sheet(item: Binding(get: { editing.map(EditableProvider.init) },
                             set: { editing = $0?.profile })) { wrapper in
            ProviderEditor(profile: wrapper.profile)
        }
        .confirmationDialog("Remove \(removing?.displayName ?? "this route")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its saved API key is removed too.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                editing = ProviderProfile(kind: .openAICompat, name: "New server",
                                          baseURL: "http://127.0.0.1:8002/v1", model: "")
            } label: {
                Label("Add Server…", systemImage: "plus")
            }
            Button {
                model.showBedrockGuide()
            } label: {
                Label("Add Amazon Bedrock…", systemImage: "cloud.bolt")
            }
            Button("Test Main") { Task { await testMain() } }
                .disabled(config.activeProvider == nil)
            Button("Test All") { Task { await testAll() } }
                .disabled(config.providers.count < 2)
                .help("Ask every route whether it answers, and show the result on each row")
            if let status {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(color(for: status.tone))
                    .lineLimit(2).truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Wizard…") { model.showWizard = true }
        }
        .padding(10)
    }

    private func color(for tone: StatusLine.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .success: Theme.successTint
        case .failure: Theme.errorTint
        }
    }

    // MARK: Actions

    private func remove(_ provider: ProviderProfile) {
        config.removeProvider(provider)
        config.setAPIKey("", for: provider)
        model.transport.resetRouteCache()
    }

    private func testMain() async {
        guard let provider = config.activeProvider else {
            status = StatusLine(text: "No main model.", tone: .failure)
            return
        }
        status = StatusLine(text: "Testing \(AppTransport.routeLabel(provider))…")
        status = await Self.check(provider)
    }

    /// Ask every route at once; each row shows its own answer, so a Spark that is asleep is obvious.
    private func testAll() async {
        results = [:]
        let routes = config.providers.map { route -> ProviderProfile in
            var probe = route
            let key = config.apiKey(for: route)
            probe.apiKey = key.isEmpty ? nil : key
            return probe
        }
        status = StatusLine(text: "Testing \(routes.count) routes…")
        await withTaskGroup(of: (String, StatusLine).self) { group in
            for route in routes {
                group.addTask { (route.routeID, await Self.check(route)) }
            }
            for await (id, line) in group { results[id] = line }
        }
        let failed = results.values.filter { $0.tone == .failure }.count
        status = failed == 0
            ? StatusLine(text: "✔ All \(results.count) routes answered.", tone: .success)
            : StatusLine(text: "\(failed) of \(results.count) routes did not answer.", tone: .failure)
    }

    /// Does the route answer, and what does it serve?
    private static func check(_ provider: ProviderProfile) async -> StatusLine {
        let client = ProviderClients.make(provider)
        do {
            let models = try await client.listModels()
            let info = await client.modelInfo(nil)
            let window = info?.contextWindow.map { ", \($0.formatted())-token window" } ?? ""
            if provider.kind == .bedrock {
                return StatusLine(text: "✔ Connected to Amazon Bedrock — \(models.count) model(s) in \(provider.awsRegion ?? "the Region")\(window).", tone: .success)
            }
            return StatusLine(text: "✔ Connected — \(models.count) model(s) served\(window).", tone: .success)
        } catch {
            return StatusLine(text: AppTransport.describe(error), tone: .failure)
        }
    }
}

/// `sheet(item:)` needs Identifiable; `ProviderProfile` deliberately is not.
struct EditableProvider: Identifiable {
    let profile: ProviderProfile
    var id: String { profile.routeID }
    init(_ profile: ProviderProfile) { self.profile = profile }
}

// MARK: - The routes

/// The intro, the fleet card and one row per route: everything that scrolls on the Models page.
struct ProviderRoutesList: View {
    @Environment(AppModel.self) private var model
    var results: [String: ProviderSettings.StatusLine] = [:]
    let edit: (ProviderProfile) -> Void
    let remove: (ProviderProfile) -> Void
    let report: (ProviderSettings.StatusLine) -> Void

    var body: some View {
        let config = model.config
        VStack(alignment: .leading, spacing: 14) {
            Text("Any OpenAI-compatible server works — a DGX Spark, vLLM or SGLang on your network, a local Ollama or LM Studio, a hosted API — and so does Amazon Bedrock with your AWS sign-in. Use several at once: one is the main model you talk to, the others take subagent tasks in parallel.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FleetCard()
            if config.providers.isEmpty {
                Text("No routes yet. Add a server, add Amazon Bedrock, or run the setup wizard.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            }
            ForEach(config.providers, id: \.routeID) { provider in
                RouteRow(provider: provider,
                         result: results[provider.routeID],
                         edit: { edit(provider) },
                         remove: { remove(provider) },
                         report: report)
            }
        }
    }
}

// MARK: - The fleet at a glance

/// Who leads and who helps, drawn as a line of chips, with the one switch that applies to the whole
/// fleet. Hidden with a single route (there is nothing to arrange).
struct FleetCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        if let main = config.mainRoute, config.providers.count > 1 {
            let workers = model.transport.workerRoutes
            VStack(alignment: .leading, spacing: 10) {
                if workers.isEmpty {
                    Label("Several servers? Put them all to work", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.callout.weight(.semibold))
                    Text("\(AppTransport.routeLabel(main)) is the main model. Turn on “Use for subagents” for another server — a second DGX Spark, or Amazon Bedrock — and the main model hands side tasks to it, so they run in parallel instead of queueing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("\(AppTransport.routeLabel(main)) leads · subagents run on \(workers.count == 1 ? "1 other server" : "\(workers.count) other servers")",
                          systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.callout.weight(.semibold))
                    HStack(alignment: .center, spacing: 8) {
                        chip(AppTransport.routeLabel(main), systemImage: "crown.fill", filled: true)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        ForEach(workers, id: \.routeID) { worker in
                            chip("\(AppTransport.routeLabel(worker)) · \(worker.subagentParallel ?? 2) at a time",
                                 systemImage: "gearshape.2", filled: false)
                        }
                    }
                    Toggle("When those are all busy, let subagents use the main server too",
                           isOn: Binding(get: { config.subagentsUsePrimary },
                                         set: { config.subagentsUsePrimary = $0 }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    if workers.contains(where: { $0.kind == .bedrock }) {
                        Label("Subagent tasks sent to Amazon Bedrock are billed to your AWS account.", systemImage: "creditcard")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
        }
    }

    private func chip(_ text: String, systemImage: String, filled: Bool) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(filled ? Color.accentColor.opacity(0.18) : Theme.surfaceStrong, in: Capsule())
            .lineLimit(1)
    }
}

// MARK: - One route

struct RouteRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderProfile
    var result: ProviderSettings.StatusLine?
    let edit: () -> Void
    let remove: () -> Void
    let report: (ProviderSettings.StatusLine) -> Void

    private var config: AppConfig { model.config }
    private var isMain: Bool { config.activeRoute == provider.routeID }
    /// Effective worker: flagged, not the main model, and not the same machine as one already counted.
    private var isEffectiveWorker: Bool { model.transport.workerRoutes.contains { $0.routeID == provider.routeID } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: provider.kind.icon)
                .font(.system(size: 15))
                .foregroundStyle(isMain ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .background(isMain ? Color.accentColor.opacity(0.14) : Theme.surface, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(provider.name).font(.callout.weight(.semibold))
                    if isMain { badge("Main model", tint: .accentColor, filled: true) }
                    else if isEffectiveWorker { badge("Subagents", tint: .secondary, filled: false) }
                }
                ForEach(detailLines, id: \.self) { line in
                    Text(line)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let result {
                    Text(result.text)
                        .font(.caption)
                        .foregroundStyle(result.tone == .success ? Theme.successTint : result.tone == .failure ? Theme.errorTint : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !isMain { workerControls }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if !isMain {
                    Button("Make Main") { makeMain() }
                        .controlSize(.small)
                        .help("Talk to this model and let it hand out subagent tasks. The current main model stays in the fleet as a subagent server.")
                }
                if provider.kind == .bedrock {
                    Button("Change…") { model.showBedrockGuide(page: .model, route: provider) }
                        .controlSize(.small)
                        .help("Pick another Amazon Bedrock model or Region, or sign in with another AWS account.")
                    Button("Sign in") { model.showBedrockGuide(page: .signIn, route: provider) }
                        .controlSize(.small)
                        .help("Sign in to AWS again — for when the sign-in has run out.")
                }
                Button("Edit…", action: edit).controlSize(.small)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .controlSize(.small)
                    .help("Remove this route")
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(isMain ? Color.accentColor.opacity(0.6) : Theme.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }

    /// What the route points at, one fact per line so a long model id never hides the rest.
    private var detailLines: [String] {
        var lines: [String]
        if provider.kind == .bedrock {
            let auth = provider.awsProfile.map { "AWS profile \($0)" } ?? "Bedrock API key"
            lines = [provider.model, "\(provider.awsRegion ?? "no Region") · \(auth)"]
        } else {
            lines = ["\(provider.model) · \(provider.baseURL)"]
        }
        if let window = provider.contextWindow { lines[lines.count - 1] += " · \(window.formatted()) ctx" }
        return lines
    }

    /// Subagent settings for a route that is not the main model. (The flag is kept while a route is
    /// main, so it returns to the fleet on its own when another route takes over.)
    @ViewBuilder
    private var workerControls: some View {
        HStack(spacing: 8) {
            Toggle("Use for subagents", isOn: Binding(
                get: { provider.isSubagentWorker },
                set: { config.setSubagentWorker(provider.routeID, $0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Use this server for subagents: side tasks the main model hands out run here, in parallel with the main model.")
            if provider.isSubagentWorker {
                Text("at a time:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { min(max(provider.subagentParallel ?? 2, 1), 8) },
                    set: { config.setSubagentParallel(provider.routeID, $0) })) {
                    ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 56)
                .controlSize(.small)
                .help("How many subagents may work on this server at the same time")
                if !isEffectiveWorker {
                    Text("· the same server as another route already serving subagents, so not used")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("A self-hosted server runs one model at a time (a Spark swaps them); a second route on it would only queue behind the first.")
                }
            }
        }
    }

    private func badge(_ text: String, tint: Color, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(filled ? tint.opacity(0.18) : Theme.surfaceStrong, in: Capsule())
    }

    private func makeMain() {
        config.makeMain(provider.routeID)
        model.transport.resetRouteCache()
        report(.init(text: "\(AppTransport.routeLabel(provider)) is now the main model."))
    }
}
