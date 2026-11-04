import SwiftUI
import DSHCore

/// The routes as menu sections, shared by the toolbar and the composer: choose the main model (the
/// conductor the chat talks to), switch each other route's subagent duty on or off, and reach the
/// Amazon Bedrock model picker. Choosing a new main model keeps the previous one working as a
/// subagent server when a fleet is running — see `AppConfig.makeMain`.
struct RouteMenuSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        let guardianRoutes = config.providers.filter { $0.kind == .guardian }
        let otherRoutes = config.providers.filter { $0.kind != .guardian }
        if !guardianRoutes.isEmpty {
            Section("Guardian — \(model.guardian.accountEmail ?? "signed in")") {
                ForEach(guardianRoutes, id: \.routeID) { provider in
                    Button {
                        guard provider.routeID != config.activeRoute else { return }
                        config.makeMain(provider.routeID)
                        model.transport.resetRouteCache()
                    } label: {
                        Label(provider.displayName,
                              systemImage: provider.routeID == config.activeRoute ? "checkmark" : "shield.lefthalf.filled")
                    }
                }
            }
        }
        Section("Main model — the chat talks to it") {
            ForEach(otherRoutes, id: \.routeID) { provider in
                Button {
                    guard provider.routeID != config.activeRoute else { return }
                    config.makeMain(provider.routeID)
                    model.transport.resetRouteCache()
                } label: {
                    Label(provider.displayName,
                          systemImage: provider.routeID == config.activeRoute ? "checkmark" : provider.kind.icon)
                }
            }
            if guardianRoutes.isEmpty {
                Button("Sign in to Guardian…") {
                    model.settingsTab = .models
                    model.showSettings = true
                }
            }
        }
        if config.providers.count > 1 {
            Section("Subagent servers — take side tasks in parallel") {
                ForEach(config.providers.filter { $0.routeID != config.activeRoute }, id: \.routeID) { provider in
                    Toggle(isOn: Binding(get: { provider.isSubagentWorker },
                                         set: { config.setSubagentWorker(provider.routeID, $0) })) {
                        Text(provider.displayName)
                    }
                }
            }
        }
        bedrockSection(config)
    }

    @ViewBuilder
    private func bedrockSection(_ config: AppConfig) -> some View {
        let routes = config.providers.filter { $0.kind == .bedrock }
        Section("Amazon Bedrock") {
            if routes.isEmpty {
                Button("Add Amazon Bedrock…") { model.showBedrockGuide() }
            } else {
                // The main model's route when it is a Bedrock one, else the first — the picker
                // replaces that route's model, so the fleet keeps its shape.
                let target = config.mainRoute.flatMap { $0.kind == .bedrock ? $0 : nil } ?? routes[0]
                Button("Choose a Bedrock Model…") { model.showBedrockGuide(page: .model, route: target) }
                Button("Add Another Bedrock Model…") { model.showBedrockGuide() }
            }
        }
    }
}
