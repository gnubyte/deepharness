import SwiftUI
import VisionHarnessCore

/// The routes as menu sections, shared by the toolbar and the composer: the primary, the subagent servers, the
/// backups and the others, each marked private (a lock) or masked (a shield); choosing one makes it the primary.
/// Routes that are switched off don't appear. Choosing a new primary keeps the previous one working as a subagent
/// server when a fleet is running — see `AppConfig.makeMain`.
struct RouteMenuSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        let usable = config.providers.filter(\.isEnabled)
        let workers = Set(model.transport.workerRoutes.map(\.routeID))
        let backups = Set(config.backupRoutes.map(\.routeID))
        let main = usable.filter { $0.routeID == config.activeRoute }
        let helping = usable.filter { workers.contains($0.routeID) }
        let standingBy = usable.filter { backups.contains($0.routeID) && !workers.contains($0.routeID) }
        let others = usable.filter { $0.routeID != config.activeRoute && !workers.contains($0.routeID) && !backups.contains($0.routeID) }

        section("Primary — answers you", main)
        section("Subagents — take side tasks in parallel", helping)
        section("Backups — take over if the primary fails", standingBy)
        section("Other models", others)
        if usable.count > 1 {
            Menu("Use for Subagents") {
                ForEach(usable.filter { $0.routeID != config.activeRoute }, id: \.routeID) { provider in
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
    private func section(_ title: String, _ routes: [ProviderProfile]) -> some View {
        if !routes.isEmpty {
            Section(title) {
                ForEach(routes, id: \.routeID) { provider in
                    Button {
                        guard provider.routeID != model.config.activeRoute else { return }
                        model.config.makeMain(provider.routeID)
                        model.transport.resetRouteCache()
                    } label: {
                        Label(provider.displayName,
                              systemImage: provider.isPrivateRoute ? "lock.fill" : "shield.lefthalf.filled")
                    }
                    .help(provider.isPrivateRoute ? "Private: may see sensitive data" : "Not private: sensitive details are masked before sending")
                }
            }
        }
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
